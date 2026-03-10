#!/bin/bash
#
# snapshot_rotate.sh - GFS rotation for BTRFS snapshots
#
# Usage: snapshot_rotate.sh [share_name]
#
# If share_name is provided, rotate snapshots for that share only.
# If omitted, rotate snapshots for ALL configured shares.
#
# Implements Grandfather-Father-Son (GFS) retention policy:
#   - Keep N most recent snapshots per hourly bucket
#   - Keep N most recent snapshots per daily bucket
#   - Keep N most recent snapshots per weekly bucket
#   - Keep N most recent snapshots per monthly bucket
#
# The algorithm identifies which time bucket each snapshot belongs to,
# keeps the most recent snapshot in each bucket (up to the retention
# count), and deletes the rest.
#
# Per-share config is loaded from:
#   /boot/config/plugins/btrfs-snapshots/shares/<name>.cfg
#
# Expected config keys:
#   RETENTION_HOURLY=24
#   RETENTION_DAILY=7
#   RETENTION_WEEKLY=4
#   RETENTION_MONTHLY=12
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
SCRIPTS_DIR="$(dirname "$(readlink -f "$0")")"
SNAP_DIR_NAME=".snapshots"

# Default retention (overridden per-share)
DEFAULT_RETENTION_HOURLY=24
DEFAULT_RETENTION_DAILY=7
DEFAULT_RETENTION_WEEKLY=4
DEFAULT_RETENTION_MONTHLY=12

# Defaults
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

# Load per-share configuration, setting retention variables.
load_share_config() {
    local share_name="$1"
    local cfg_file="${SHARE_CFG_DIR}/${share_name}.cfg"

    # Reset to defaults
    RETENTION_HOURLY="${DEFAULT_RETENTION_HOURLY}"
    RETENTION_DAILY="${DEFAULT_RETENTION_DAILY}"
    RETENTION_WEEKLY="${DEFAULT_RETENTION_WEEKLY}"
    RETENTION_MONTHLY="${DEFAULT_RETENTION_MONTHLY}"

    if [[ -f "${cfg_file}" ]]; then
        # shellcheck source=/dev/null
        source "${cfg_file}"
        log "INFO" "Loaded config for share '${share_name}': hourly=${RETENTION_HOURLY} daily=${RETENTION_DAILY} weekly=${RETENTION_WEEKLY} monthly=${RETENTION_MONTHLY}"
    else
        log "WARN" "No config found for share '${share_name}' at ${cfg_file}, using defaults"
    fi
}

###############################################################################
# Discover Configured Shares
###############################################################################

# Returns a list of all share names that have config files.
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

# Discovers all mount points under /mnt/ where this share has data.
find_share_disks() {
    local share_name="$1"
    local disks=()
    local skip="user user0 remotes addons disks rootshare"
    local entry

    for entry in /mnt/*/; do
        local name
        name="$(basename "$entry")"
        # Skip virtual/system mounts
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
    local ts_part="${snap_name#@GMT-}"  # YYYY.MM.DD-HH.MM.SS

    if [[ ! "$ts_part" =~ ^([0-9]{4})\.([0-9]{2})\.([0-9]{2})-([0-9]{2})\.([0-9]{2})\.([0-9]{2})$ ]]; then
        echo "0"
        return
    fi

    local datestr="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"

    # Convert to epoch; use UTC since that's how they're created by default
    date -u -d "${datestr}" '+%s' 2>/dev/null || echo "0"
}

###############################################################################
# Compute Time Buckets
###############################################################################

# Returns the hourly bucket key for an epoch: YYYY-MM-DD-HH
bucket_hourly() {
    date -u -d "@$1" '+%Y-%m-%d-%H' 2>/dev/null
}

# Returns the daily bucket key: YYYY-MM-DD
bucket_daily() {
    date -u -d "@$1" '+%Y-%m-%d' 2>/dev/null
}

# Returns the weekly bucket key: YYYY-WNN (ISO week number)
bucket_weekly() {
    date -u -d "@$1" '+%Y-W%V' 2>/dev/null
}

# Returns the monthly bucket key: YYYY-MM
bucket_monthly() {
    date -u -d "@$1" '+%Y-%m' 2>/dev/null
}

###############################################################################
# GFS Rotation Logic
###############################################################################

# Given a list of snapshots (path|epoch, one per line, sorted newest-first),
# apply GFS retention and return the list of snapshots to DELETE.
#
# Algorithm:
# 1. Assign each snapshot to its time buckets (hourly, daily, weekly, monthly).
# 2. For each granularity, keep the newest snapshot in each bucket, up to N buckets.
# 3. A snapshot is KEPT if it's the representative of any bucket at any granularity.
# 4. All other snapshots are marked for deletion.
apply_gfs_retention() {
    local -a snap_lines=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && snap_lines+=("$line")
    done

    if [[ ${#snap_lines[@]} -eq 0 ]]; then
        return
    fi

    # Build arrays: snap_paths and snap_epochs (already sorted newest-first)
    local -a snap_paths=()
    local -a snap_epochs=()
    local entry
    for entry in "${snap_lines[@]}"; do
        snap_paths+=("${entry%%|*}")
        snap_epochs+=("${entry##*|}")
    done

    local total=${#snap_paths[@]}

    # Track which snapshots to keep (by index)
    local -A keep_set

    # Process each granularity
    local granularity
    for granularity in hourly daily weekly monthly; do
        local max_buckets
        case "$granularity" in
            hourly)  max_buckets="${RETENTION_HOURLY}" ;;
            daily)   max_buckets="${RETENTION_DAILY}" ;;
            weekly)  max_buckets="${RETENTION_WEEKLY}" ;;
            monthly) max_buckets="${RETENTION_MONTHLY}" ;;
        esac

        # If retention is 0, skip this granularity
        [[ "$max_buckets" -le 0 ]] 2>/dev/null && continue

        # Track buckets seen and how many we've kept
        local -A seen_buckets=()
        local kept=0
        local idx

        for idx in $(seq 0 $((total - 1))); do
            local epoch="${snap_epochs[$idx]}"
            local bucket

            case "$granularity" in
                hourly)  bucket="$(bucket_hourly "$epoch")" ;;
                daily)   bucket="$(bucket_daily "$epoch")" ;;
                weekly)  bucket="$(bucket_weekly "$epoch")" ;;
                monthly) bucket="$(bucket_monthly "$epoch")" ;;
            esac

            [[ -z "$bucket" ]] && continue

            # If we haven't seen this bucket yet, this is the newest in it
            if [[ -z "${seen_buckets[$bucket]+x}" ]]; then
                seen_buckets[$bucket]=1
                ((kept++))

                # Keep this snapshot if we haven't exceeded our bucket limit
                if [[ $kept -le $max_buckets ]]; then
                    keep_set[$idx]=1
                fi
            fi
        done
    done

    # Output snapshots to delete (those NOT in keep_set)
    local idx
    for idx in $(seq 0 $((total - 1))); do
        if [[ -z "${keep_set[$idx]+x}" ]]; then
            echo "${snap_paths[$idx]}"
        fi
    done
}

###############################################################################
# Rotate Snapshots for a Single Share
###############################################################################

rotate_share() {
    local share_name="$1"

    log "INFO" "Starting rotation for share '${share_name}'"

    # Load share-specific retention config
    load_share_config "${share_name}"

    # Find all disks
    local disks
    disks="$(find_share_disks "${share_name}")"

    if [[ -z "$disks" ]]; then
        log "INFO" "No disks found for share '${share_name}', nothing to rotate"
        return 0
    fi

    local total_deleted=0
    local total_kept=0
    local total_errors=0

    while IFS= read -r disk; do
        local snap_dir="${disk}/${share_name}/${SNAP_DIR_NAME}"

        [[ -d "${snap_dir}" ]] || continue

        # Collect all snapshots with their epochs, sorted newest-first
        local -a snap_list=()
        local snap_entry
        for snap_entry in "${snap_dir}"/@GMT-*; do
            [[ -d "${snap_entry}" ]] || continue

            local snap_name
            snap_name="$(basename "${snap_entry}")"

            # Validate format
            if [[ ! "$snap_name" =~ ^@GMT-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{2}\.[0-9]{2}\.[0-9]{2}$ ]]; then
                continue
            fi

            local epoch
            epoch="$(snap_to_epoch "${snap_name}")"
            [[ "$epoch" == "0" ]] && continue

            snap_list+=("${snap_entry}|${epoch}")
        done

        local snap_count=${#snap_list[@]}
        if [[ $snap_count -eq 0 ]]; then
            log "INFO" "No snapshots found on ${disk} for '${share_name}'"
            continue
        fi

        log "INFO" "Found ${snap_count} snapshots on ${disk} for '${share_name}'"

        # Sort newest-first by epoch (field after |)
        local sorted_snaps
        sorted_snaps="$(printf '%s\n' "${snap_list[@]}" | sort -t'|' -k2 -rn)"

        # Apply GFS retention and get list of snapshots to delete
        local to_delete
        to_delete="$(echo "${sorted_snaps}" | apply_gfs_retention)"

        if [[ -z "$to_delete" ]]; then
            log "INFO" "All snapshots on ${disk} for '${share_name}' are within retention policy"
            ((total_kept += snap_count))
            continue
        fi

        # Count kept
        local delete_count
        delete_count="$(echo "${to_delete}" | wc -l)"
        local keep_count=$((snap_count - delete_count))
        ((total_kept += keep_count))

        # Delete expired snapshots
        while IFS= read -r snap_path; do
            [[ -z "$snap_path" ]] && continue

            local snap_name
            snap_name="$(basename "${snap_path}")"

            if btrfs subvolume delete "${snap_path}" &>/dev/null; then
                log "INFO" "Rotated (deleted): ${snap_path}"
                ((total_deleted++))
            else
                log "ERROR" "Failed to delete during rotation: ${snap_path}"
                ((total_errors++))
            fi
        done <<< "${to_delete}"
    done <<< "${disks}"

    log "INFO" "Rotation complete for '${share_name}': ${total_deleted} deleted, ${total_kept} kept, ${total_errors} errors"
    return 0
}

###############################################################################
# Main
###############################################################################

main() {
    local share_name="$1"

    # Load global configuration
    load_config

    # Check if plugin is enabled
    if [[ "${PLUGIN_ENABLED}" != "yes" ]]; then
        log "INFO" "Plugin is disabled, skipping rotation"
        exit 0
    fi

    if [[ -n "${share_name}" ]]; then
        # Rotate a single share
        share_name="$(sanitize_name "${share_name}")" || exit 1
        rotate_share "${share_name}"
    else
        # Rotate all configured shares
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

            # Check if share is enabled in its config
            local cfg_file="${SHARE_CFG_DIR}/${share}.cfg"
            local share_enabled="yes"
            if [[ -f "$cfg_file" ]]; then
                share_enabled="$(grep -E '^ENABLED=' "$cfg_file" 2>/dev/null | cut -d'=' -f2)"
                share_enabled="${share_enabled:-yes}"
            fi

            if [[ "$share_enabled" != "yes" ]]; then
                log "INFO" "Share '${share}' is disabled, skipping"
                continue
            fi

            rotate_share "${share}"
        done <<< "${shares}"

        log "INFO" "All share rotations complete"
    fi

    exit 0
}

main "$@"
