#!/bin/bash
#
# snapshot_create.sh - Create BTRFS snapshots for an Unraid share
#
# Usage: snapshot_create.sh <share_name> [snapshot_type]
#
# Creates read-only BTRFS snapshots at:
#   <share_path>/.snapshots/@GMT-YYYY.MM.DD-HH.MM.SS
#
# Iterates all array disks and pools where the share exists,
# verifies each is a BTRFS subvolume, checks free space, then
# creates a read-only snapshot with Windows Previous Versions
# compatible naming.
#
# snapshot_type is stored in metadata but doesn't change behavior.
# Valid types: manual, scheduled, pre-update (default: manual)
#
# Exit codes:
#   0 - At least one snapshot created successfully
#   1 - Invalid arguments or configuration error
#   2 - No eligible disks found for this share
#   3 - All snapshot attempts failed
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
MIN_FREE_BYTES=$((1 * 1024 * 1024 * 1024))  # 1 GB minimum free space

# Defaults (overridden by global config)
TIMEZONE_MODE="utc"  # utc or local
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
    echo "${ts} [${level}] [snapshot_create] ${msg}" >> "${LOG_FILE}"

    # Also print to stdout for interactive use
    if [[ -t 1 ]]; then
        echo "${ts} [${level}] ${msg}"
    fi
}

###############################################################################
# Input Sanitization
###############################################################################

# Validate that a string contains only safe characters for paths/names.
# Allows alphanumeric, dash, underscore, dot, space.
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
        # Source the config (key=value format, bash-compatible)
        # shellcheck source=/dev/null
        source "${GLOBAL_CFG}"

        # Map config keys to our variables
        TIMEZONE_MODE="${TIMEZONE_MODE:-utc}"
        PLUGIN_ENABLED="${PLUGIN_ENABLED:-yes}"
    else
        log "WARN" "Global config not found at ${GLOBAL_CFG}, using defaults"
    fi
}

###############################################################################
# Generate Snapshot Name
###############################################################################

# Generates @GMT-YYYY.MM.DD-HH.MM.SS compatible with Windows Previous Versions
# and Samba's vfs_shadow_copy2 module.
generate_snapshot_name() {
    if [[ "${TIMEZONE_MODE}" == "local" ]]; then
        date '+@GMT-%Y.%m.%d-%H.%M.%S'
    else
        date -u '+@GMT-%Y.%m.%d-%H.%M.%S'
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

    if [[ ${#disks[@]} -eq 0 ]]; then
        return 1
    fi

    printf '%s\n' "${disks[@]}"
}

###############################################################################
# Check if a Path is on BTRFS
###############################################################################

is_btrfs() {
    local path="$1"
    local fstype
    fstype="$(stat -f -c '%T' "$path" 2>/dev/null)" || return 1
    [[ "$fstype" == "btrfs" ]]
}

###############################################################################
# Check if a Path is a BTRFS Subvolume
###############################################################################

is_subvolume() {
    local path="$1"
    # btrfs subvolume show succeeds only on subvolumes
    btrfs subvolume show "$path" &>/dev/null
}

###############################################################################
# Check Available Space
###############################################################################

# Returns 0 if there is at least MIN_FREE_BYTES available, 1 otherwise.
check_free_space() {
    local path="$1"
    local avail_kb
    avail_kb="$(df --output=avail "$path" 2>/dev/null | tail -1 | tr -d ' ')"

    if [[ -z "$avail_kb" || "$avail_kb" -le 0 ]]; then
        log "WARN" "Could not determine free space for ${path}"
        return 1
    fi

    local avail_bytes=$((avail_kb * 1024))
    if [[ $avail_bytes -lt $MIN_FREE_BYTES ]]; then
        local avail_mb=$((avail_bytes / 1024 / 1024))
        local min_mb=$((MIN_FREE_BYTES / 1024 / 1024))
        log "WARN" "Insufficient space on ${path}: ${avail_mb}MB free (minimum: ${min_mb}MB)"
        return 1
    fi

    return 0
}

###############################################################################
# Create Snapshot
###############################################################################

create_snapshot() {
    local share_path="$1"
    local snap_name="$2"
    local snap_type="$3"
    local snap_dir="${share_path}/${SNAP_DIR_NAME}"
    local snap_path="${snap_dir}/${snap_name}"

    # Create .snapshots directory if it doesn't exist
    if [[ ! -d "${snap_dir}" ]]; then
        mkdir -p "${snap_dir}" || {
            log "ERROR" "Failed to create snapshot directory: ${snap_dir}"
            return 1
        }
        log "INFO" "Created snapshot directory: ${snap_dir}"
    fi

    # Check if snapshot already exists (race condition guard)
    if [[ -d "${snap_path}" ]]; then
        log "WARN" "Snapshot already exists: ${snap_path}"
        return 0
    fi

    # Create read-only snapshot
    if btrfs subvolume snapshot -r "${share_path}" "${snap_path}" &>/dev/null; then
        log "INFO" "Created snapshot: ${snap_path} (type=${snap_type})"

        # Write metadata file alongside the snapshot (not inside — snapshot is read-only)
        cat > "${snap_path}.meta" <<-SNAPMETA
type=${snap_type}
created=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
share=$(basename "${share_path}")
disk=$(echo "${share_path}" | grep -oP '/mnt/[^/]+')
SNAPMETA

        return 0
    else
        log "ERROR" "Failed to create snapshot: ${snap_path}"
        return 1
    fi
}

###############################################################################
# Main
###############################################################################

main() {
    local share_name="$1"
    local snap_type="${2:-manual}"

    # Validate arguments
    if [[ -z "${share_name}" ]]; then
        echo "Usage: snapshot_create.sh <share_name> [snapshot_type]" >&2
        echo "  snapshot_type: manual (default), scheduled, pre-update" >&2
        exit 1
    fi

    # Sanitize share name
    share_name="$(sanitize_name "${share_name}")" || exit 1

    # Validate snapshot type
    case "${snap_type}" in
        manual|scheduled|pre-update|hourly|daily|weekly|monthly) ;;
        *)
            log "ERROR" "Invalid snapshot type: ${snap_type}"
            echo "Error: Invalid snapshot type '${snap_type}'. Use: manual, scheduled, pre-update, daily, weekly, monthly" >&2
            exit 1
            ;;
    esac

    # Load configuration
    load_config

    # Check if plugin is enabled
    if [[ "${PLUGIN_ENABLED}" != "yes" ]]; then
        log "INFO" "Plugin is disabled, skipping snapshot creation"
        exit 0
    fi

    # Generate snapshot name
    local snap_name
    snap_name="$(generate_snapshot_name)"
    log "INFO" "Starting snapshot creation for share '${share_name}' (type=${snap_type}, name=${snap_name})"

    # Find all disks that contain this share
    local disks
    disks="$(find_share_disks "${share_name}")" || {
        log "ERROR" "Share '${share_name}' not found on any disk"
        echo "Error: Share '${share_name}' not found on any disk" >&2
        exit 2
    }

    local success_count=0
    local fail_count=0
    local skip_count=0

    while IFS= read -r disk; do
        local share_path="${disk}/${share_name}"
        log "INFO" "Processing ${share_path}"

        # Check if the disk is BTRFS
        if ! is_btrfs "${disk}"; then
            log "INFO" "Skipping ${disk}: not BTRFS filesystem"
            ((skip_count++))
            continue
        fi

        # Check if the share directory is a subvolume
        if ! is_subvolume "${share_path}"; then
            log "WARN" "Skipping ${share_path}: not a BTRFS subvolume (run subvolume_check.sh --convert '${share_name}' to convert)"
            ((skip_count++))
            continue
        fi

        # Check available space
        if ! check_free_space "${disk}"; then
            log "WARN" "Skipping ${share_path}: insufficient free space"
            ((skip_count++))
            continue
        fi

        # Create the snapshot
        if create_snapshot "${share_path}" "${snap_name}" "${snap_type}"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done <<< "${disks}"

    # Summary
    log "INFO" "Snapshot creation complete for '${share_name}': ${success_count} created, ${fail_count} failed, ${skip_count} skipped"

    if [[ ${success_count} -eq 0 && ${fail_count} -gt 0 ]]; then
        exit 3
    elif [[ ${success_count} -eq 0 && ${skip_count} -gt 0 ]]; then
        exit 2
    fi

    exit 0
}

main "$@"
