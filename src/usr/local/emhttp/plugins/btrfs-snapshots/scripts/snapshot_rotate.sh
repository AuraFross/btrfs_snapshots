#!/bin/bash
#
# snapshot_rotate.sh - Per-type FIFO rotation for BTRFS snapshots
#
# Usage: snapshot_rotate.sh <share_name> [type]
#
# type: daily, weekly, or monthly
#       If omitted, all three types are rotated for the share.
#
# Each snapshot's type is read from the .snapshot_meta file inside the
# snapshot directory. Only snapshots with type=daily, weekly, or monthly
# are auto-rotated. Snapshots with type=manual, scheduled, pre-update,
# or missing metadata are never deleted by this script.
#
# Retention counts come from the per-share config:
#   SCHEDULE_DAILY_RETAIN=7
#   SCHEDULE_WEEKLY_RETAIN=4
#   SCHEDULE_MONTHLY_RETAIN=12
#
# For each type, the N most recent snapshots (sorted by filename timestamp)
# are kept; any older ones are deleted.
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments or configuration error
#

###############################################################################
# Configuration
###############################################################################

PLUGIN_NAME="btrfs-snapshots"
GLOBAL_CFG="/boot/config/plugins/${PLUGIN_NAME}/${PLUGIN_NAME}.cfg"
SHARE_CFG_DIR="/boot/config/plugins/${PLUGIN_NAME}/shares"
LOG_FILE="/var/log/${PLUGIN_NAME}.log"
SNAP_DIR_NAME=".snapshots"

PLUGIN_ENABLED="yes"

###############################################################################
# Logging
###############################################################################

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "${ts} [${level}] [snapshot_rotate] ${msg}" >> "${LOG_FILE}"
    if [[ -t 1 ]]; then
        echo "${ts} [${level}] ${msg}"
    fi
}

###############################################################################
# Input Sanitization
###############################################################################

sanitize_name() {
    local input="$1"
    if [[ ! "$input" =~ ^[a-zA-Z0-9._\ -]+$ ]]; then
        log "ERROR" "Invalid characters in name: ${input}"
        return 1
    fi
    echo "$input"
}

###############################################################################
# Load Configuration
###############################################################################

load_config() {
    if [[ -f "${GLOBAL_CFG}" ]]; then
        # shellcheck source=/dev/null
        source "${GLOBAL_CFG}"
        PLUGIN_ENABLED="${PLUGIN_ENABLED:-yes}"
    fi
}

load_share_config() {
    local share_name="$1"
    local cfg_file="${SHARE_CFG_DIR}/${share_name}.cfg"

    # Start from global config retain values as fallback
    SCHEDULE_HOURLY_RETAIN=0
    SCHEDULE_DAILY_RETAIN=2
    SCHEDULE_WEEKLY_RETAIN=1
    SCHEDULE_MONTHLY_RETAIN=0

    # Read global retain values first
    if [[ -f "${GLOBAL_CFG}" ]]; then
        local key val
        while IFS='=' read -r key val; do
            key="${key//[[:space:]]/}"
            val="${val//\"/}"
            case "$key" in
                SCHEDULE_HOURLY_RETAIN)  SCHEDULE_HOURLY_RETAIN="$val" ;;
                SCHEDULE_DAILY_RETAIN)   SCHEDULE_DAILY_RETAIN="$val" ;;
                SCHEDULE_WEEKLY_RETAIN)  SCHEDULE_WEEKLY_RETAIN="$val" ;;
                SCHEDULE_MONTHLY_RETAIN) SCHEDULE_MONTHLY_RETAIN="$val" ;;
            esac
        done < "${GLOBAL_CFG}"
    fi

    # Per-share config overrides global if set (non-empty)
    if [[ -f "${cfg_file}" ]]; then
        local phr pdyr pwr pmr
        phr="$(grep -m1 '^SCHEDULE_HOURLY_RETAIN='  "$cfg_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"')"
        pdyr="$(grep -m1 '^SCHEDULE_DAILY_RETAIN='   "$cfg_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"')"
        pwr="$(grep -m1 '^SCHEDULE_WEEKLY_RETAIN='  "$cfg_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"')"
        pmr="$(grep -m1 '^SCHEDULE_MONTHLY_RETAIN=' "$cfg_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"')"
        [[ -n "$phr"  ]] && SCHEDULE_HOURLY_RETAIN="$phr"
        [[ -n "$pdyr" ]] && SCHEDULE_DAILY_RETAIN="$pdyr"
        [[ -n "$pwr"  ]] && SCHEDULE_WEEKLY_RETAIN="$pwr"
        [[ -n "$pmr"  ]] && SCHEDULE_MONTHLY_RETAIN="$pmr"
        log "INFO" "Loaded config for '${share_name}': hourly_retain=${SCHEDULE_HOURLY_RETAIN} daily_retain=${SCHEDULE_DAILY_RETAIN} weekly_retain=${SCHEDULE_WEEKLY_RETAIN} monthly_retain=${SCHEDULE_MONTHLY_RETAIN}"
    else
        log "WARN" "No config found for '${share_name}', using global defaults"
    fi
}

###############################################################################
# Discover Configured Shares
###############################################################################

get_configured_shares() {
    if [[ ! -d "${SHARE_CFG_DIR}" ]]; then
        return
    fi

    local cfg
    for cfg in "${SHARE_CFG_DIR}"/*.cfg; do
        [[ -f "$cfg" ]] || continue
        local name
        name="$(basename "${cfg}" .cfg)"
        echo "${name}"
    done
}

###############################################################################
# Discover Disks for a Share
###############################################################################

find_share_disks() {
    local share_name="$1"
    local disks=()
    local skip="user user0 remotes addons disks rootshare"
    local entry

    for entry in /mnt/*/; do
        local name
        name="$(basename "$entry")"
        case " $skip " in
            *" $name "*) continue ;;
        esac
        if [[ -d "${entry}${share_name}" ]]; then
            disks+=("${entry%/}")
        fi
    done

    printf '%s\n' "${disks[@]}"
}

###############################################################################
# Parse Snapshot Timestamp
###############################################################################

# Converts @GMT-YYYY.MM.DD-HH.MM.SS to epoch seconds for sorting.
snap_to_epoch() {
    local snap_name="$1"
    local ts_part="${snap_name#@GMT-}"

    if [[ ! "$ts_part" =~ ^([0-9]{4})\.([0-9]{2})\.([0-9]{2})-([0-9]{2})\.([0-9]{2})\.([0-9]{2})$ ]]; then
        echo "0"
        return
    fi

    local datestr="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
    date -u -d "${datestr}" '+%s' 2>/dev/null || echo "0"
}

###############################################################################
# Get Snapshot Type from Metadata
###############################################################################

# Reads the type= field from .snapshot_meta inside a snapshot directory.
# Returns "manual" if the meta file is missing or has no type field.
# Only daily, weekly, monthly snapshots are auto-rotatable.
get_snap_type() {
    local snap_path="$1"
    local meta_file="${snap_path}/.snapshot_meta"
    if [[ -f "$meta_file" ]]; then
        local snap_type
        snap_type="$(grep -m1 '^type=' "$meta_file" 2>/dev/null | cut -d'=' -f2)"
        echo "${snap_type:-manual}"
    else
        echo "manual"
    fi
}

###############################################################################
# Rotate Snapshots of One Type on One Disk
###############################################################################

rotate_type_on_disk() {
    local share_name="$1"
    local disk="$2"
    local type="$3"
    local retain="$4"

    local snap_dir="${disk}/${share_name}/${SNAP_DIR_NAME}"
    [[ -d "${snap_dir}" ]] || return 0

    # Collect all snapshots of the specified type with their epoch timestamps
    local -a typed_snaps=()
    local snap_entry

    for snap_entry in "${snap_dir}"/@GMT-*; do
        [[ -d "${snap_entry}" ]] || continue

        local snap_name
        snap_name="$(basename "${snap_entry}")"

        # Validate filename format
        if [[ ! "$snap_name" =~ ^@GMT-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{2}\.[0-9]{2}\.[0-9]{2}$ ]]; then
            continue
        fi

        # Filter by type
        local snap_type
        snap_type="$(get_snap_type "${snap_entry}")"
        if [[ "${snap_type}" != "${type}" ]]; then
            continue
        fi

        local epoch
        epoch="$(snap_to_epoch "${snap_name}")"
        [[ "${epoch}" == "0" ]] && continue

        typed_snaps+=("${snap_entry}|${epoch}")
    done

    local snap_count=${#typed_snaps[@]}

    if [[ $snap_count -eq 0 ]]; then
        log "INFO" "No ${type} snapshots on ${disk} for '${share_name}'"
        return 0
    fi

    log "INFO" "Found ${snap_count} ${type} snapshots on ${disk} for '${share_name}' (retain: ${retain})"

    if [[ $snap_count -le $retain ]]; then
        log "INFO" "All ${type} snapshots within retention limit on ${disk}"
        return 0
    fi

    # Sort newest-first by epoch
    local sorted_snaps
    sorted_snaps="$(printf '%s\n' "${typed_snaps[@]}" | sort -t'|' -k2 -rn)"

    # Keep the newest RETAIN entries; delete the rest
    local idx=0
    local deleted=0
    local errors=0

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local snap_path="${entry%%|*}"
        ((idx++))

        if [[ $idx -gt $retain ]]; then
            if btrfs subvolume delete "${snap_path}" &>/dev/null; then
                log "INFO" "Rotated (deleted): ${snap_path}"
                ((deleted++))
            else
                log "ERROR" "Failed to delete during rotation: ${snap_path}"
                ((errors++))
            fi
        fi
    done <<< "${sorted_snaps}"

    log "INFO" "Rotation complete for ${type} on ${disk}/${share_name}: ${deleted} deleted, ${errors} errors"
    return 0
}

###############################################################################
# Rotate All Types for a Share
###############################################################################

rotate_share() {
    local share_name="$1"
    local type="${2:-}"

    log "INFO" "Starting rotation for share '${share_name}' type='${type:-all}'"

    load_share_config "${share_name}"

    local disks
    disks="$(find_share_disks "${share_name}")"

    if [[ -z "$disks" ]]; then
        log "INFO" "No disks found for share '${share_name}', nothing to rotate"
        return 0
    fi

    local -a types_to_rotate=()

    if [[ -n "$type" ]]; then
        case "$type" in
            hourly|daily|weekly|monthly)
                types_to_rotate=("$type")
                ;;
            *)
                log "WARN" "Unknown snapshot type '${type}', skipping rotation"
                return 1
                ;;
        esac
    else
        types_to_rotate=(hourly daily weekly monthly)
    fi

    local t
    for t in "${types_to_rotate[@]}"; do
        local retain
        case "$t" in
            hourly)  retain="${SCHEDULE_HOURLY_RETAIN:-0}" ;;
            daily)   retain="${SCHEDULE_DAILY_RETAIN:-2}" ;;
            weekly)  retain="${SCHEDULE_WEEKLY_RETAIN:-1}" ;;
            monthly) retain="${SCHEDULE_MONTHLY_RETAIN:-0}" ;;
        esac

        while IFS= read -r disk; do
            rotate_type_on_disk "${share_name}" "${disk}" "${t}" "${retain}"
        done <<< "${disks}"
    done

    log "INFO" "Rotation finished for share '${share_name}'"
    return 0
}

###############################################################################
# Main
###############################################################################

main() {
    local share_name="${1:-}"
    local type="${2:-}"

    load_config

    if [[ "${PLUGIN_ENABLED}" != "yes" ]]; then
        log "INFO" "Plugin is disabled, skipping rotation"
        exit 0
    fi

    if [[ -n "${share_name}" ]]; then
        share_name="$(sanitize_name "${share_name}")" || exit 1
        rotate_share "${share_name}" "${type}"
    else
        log "INFO" "Starting rotation for all configured shares"

        local shares
        shares="$(get_configured_shares)"

        if [[ -z "$shares" ]]; then
            log "INFO" "No configured shares found in ${SHARE_CFG_DIR}"
            exit 0
        fi

        local share
        while IFS= read -r share; do
            [[ -z "$share" ]] && continue

            local cfg_file="${SHARE_CFG_DIR}/${share}.cfg"
            local share_enabled="yes"
            if [[ -f "$cfg_file" ]]; then
                share_enabled="$(grep -E '^ENABLED=' "$cfg_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"')"
                share_enabled="${share_enabled:-yes}"
            fi

            if [[ "$share_enabled" != "yes" ]]; then
                log "INFO" "Share '${share}' is disabled, skipping"
                continue
            fi

            rotate_share "${share}" ""
        done <<< "${shares}"

        log "INFO" "All share rotations complete"
    fi

    exit 0
}

main "$@"
