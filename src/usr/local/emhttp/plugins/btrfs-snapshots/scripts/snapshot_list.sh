#!/bin/bash
#
# snapshot_list.sh - List all BTRFS snapshots for a share
#
# Usage: snapshot_list.sh <share_name>
#
# Outputs a JSON array of all snapshots across all disks for the
# given share. Each entry contains disk, path, name, timestamp,
# and exclusive size information.
#
# Output format (JSON array):
# [
#   {
#     "disk": "/mnt/disk1",
#     "path": "/mnt/disk1/ShareName/.snapshots/@GMT-2026.03.09-15.30.00",
#     "name": "@GMT-2026.03.09-15.30.00",
#     "timestamp": "2026-03-09T15:30:00Z",
#     "size": "1.50GiB"
#   },
#   ...
# ]
#
# Exit codes:
#   0 - Success (outputs JSON, may be empty array)
#   1 - Invalid arguments
#

###############################################################################
# Configuration
###############################################################################

PLUGIN_NAME="btrfs-snapshots"
GLOBAL_CFG="/boot/config/plugins/${PLUGIN_NAME}/${PLUGIN_NAME}.cfg"
LOG_FILE="/var/log/${PLUGIN_NAME}.log"
SNAP_DIR_NAME=".snapshots"

# Defaults
TIMEZONE_MODE="utc"

###############################################################################
# Logging
###############################################################################

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "${ts} [${level}] [snapshot_list] ${msg}" >> "${LOG_FILE}"
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
        TIMEZONE_MODE="${TIMEZONE_MODE:-utc}"
    fi
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
# Parse @GMT Timestamp to ISO 8601
###############################################################################

# Converts @GMT-YYYY.MM.DD-HH.MM.SS to ISO 8601 format.
# If TIMEZONE_MODE is utc, appends Z; otherwise uses local offset.
parse_gmt_timestamp() {
    local snap_name="$1"

    # Extract components from @GMT-YYYY.MM.DD-HH.MM.SS
    local ts_part="${snap_name#@GMT-}"  # YYYY.MM.DD-HH.MM.SS

    if [[ ! "$ts_part" =~ ^([0-9]{4})\.([0-9]{2})\.([0-9]{2})-([0-9]{2})\.([0-9]{2})\.([0-9]{2})$ ]]; then
        echo "unknown"
        return
    fi

    local year="${BASH_REMATCH[1]}"
    local month="${BASH_REMATCH[2]}"
    local day="${BASH_REMATCH[3]}"
    local hour="${BASH_REMATCH[4]}"
    local minute="${BASH_REMATCH[5]}"
    local second="${BASH_REMATCH[6]}"

    if [[ "${TIMEZONE_MODE}" == "local" ]]; then
        # Get the local timezone offset
        local offset
        offset="$(date '+%z' 2>/dev/null)"
        # Format: +HHMM -> +HH:MM
        if [[ "$offset" =~ ^([+-][0-9]{2})([0-9]{2})$ ]]; then
            offset="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
        fi
        echo "${year}-${month}-${day}T${hour}:${minute}:${second}${offset}"
    else
        echo "${year}-${month}-${day}T${hour}:${minute}:${second}Z"
    fi
}

###############################################################################
# Get Exclusive Size of a Snapshot
###############################################################################

# Uses btrfs subvolume show to get the exclusive size.
# Falls back to "unknown" if not available.
get_snapshot_size() {
    local snap_path="$1"

    # Try qgroup first for exclusive data
    local show_output
    show_output="$(btrfs subvolume show "${snap_path}" 2>/dev/null)"

    if [[ -n "$show_output" ]]; then
        # Look for "Exclusive" line in btrfs subvolume show output
        # Format varies by kernel version; try common patterns
        local exclusive
        exclusive="$(echo "$show_output" | grep -i 'exclusive' | head -1 | awk '{print $NF}')"

        if [[ -n "$exclusive" && "$exclusive" != "0" ]]; then
            echo "$exclusive"
            return
        fi
    fi

    # Fallback: try btrfs qgroup show
    # Get the subvolume ID
    local subvol_id
    subvol_id="$(echo "$show_output" | grep -i 'subvolume id' | awk '{print $NF}')"

    if [[ -n "$subvol_id" ]]; then
        local disk_mount
        disk_mount="$(echo "${snap_path}" | grep -oP '^/mnt/[^/]+')"
        local qgroup_output
        qgroup_output="$(btrfs qgroup show -reF "${disk_mount}" 2>/dev/null | grep "0/${subvol_id}" | awk '{print $3}')"

        if [[ -n "$qgroup_output" ]]; then
            echo "$qgroup_output"
            return
        fi
    fi

    echo "unknown"
}

###############################################################################
# Escape JSON String
###############################################################################

json_escape() {
    local str="$1"
    # Escape backslash, double quote, and control characters
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\t'/\\t}"
    str="${str//$'\r'/\\r}"
    echo "$str"
}

###############################################################################
# Main
###############################################################################

main() {
    local share_name="$1"

    # Validate arguments
    if [[ -z "${share_name}" ]]; then
        echo "Usage: snapshot_list.sh <share_name>" >&2
        exit 1
    fi

    # Sanitize
    share_name="$(sanitize_name "${share_name}")" || exit 1

    # Load configuration
    load_config

    # Find all disks with this share
    local disks
    disks="$(find_share_disks "${share_name}")"

    if [[ -z "$disks" ]]; then
        # No disks found - output empty array
        echo "[]"
        exit 0
    fi

    # Collect all snapshots
    local first=true
    echo "["

    while IFS= read -r disk; do
        local snap_dir="${disk}/${share_name}/${SNAP_DIR_NAME}"

        # Skip if no .snapshots directory
        [[ -d "${snap_dir}" ]] || continue

        # Iterate snapshot directories matching the @GMT pattern
        local snap_entry
        for snap_entry in "${snap_dir}"/@GMT-*; do
            # Skip if glob didn't match (no snapshots)
            [[ -d "${snap_entry}" ]] || continue

            local snap_name
            snap_name="$(basename "${snap_entry}")"

            # Validate it's actually a @GMT snapshot name
            if [[ ! "$snap_name" =~ ^@GMT-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{2}\.[0-9]{2}\.[0-9]{2}$ ]]; then
                continue
            fi

            # Verify it's a BTRFS subvolume (not just a regular directory)
            if ! btrfs subvolume show "${snap_entry}" &>/dev/null; then
                continue
            fi

            # Parse timestamp
            local timestamp
            timestamp="$(parse_gmt_timestamp "${snap_name}")"

            # Get size
            local size
            size="$(get_snapshot_size "${snap_entry}")"

            # Output JSON entry
            if [[ "$first" == true ]]; then
                first=false
            else
                echo ","
            fi

            local j_disk j_path j_name j_ts j_size
            j_disk="$(json_escape "$disk")"
            j_path="$(json_escape "$snap_entry")"
            j_name="$(json_escape "$snap_name")"
            j_ts="$(json_escape "$timestamp")"
            j_size="$(json_escape "$size")"

            printf '  {"disk": "%s", "path": "%s", "name": "%s", "timestamp": "%s", "size": "%s"}' \
                "$j_disk" "$j_path" "$j_name" "$j_ts" "$j_size"
        done
    done <<< "${disks}"

    echo ""
    echo "]"

    exit 0
}

main "$@"
