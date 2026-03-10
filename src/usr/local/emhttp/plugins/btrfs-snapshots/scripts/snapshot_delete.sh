#!/bin/bash
#
# snapshot_delete.sh - Safely delete a BTRFS snapshot
#
# Usage: snapshot_delete.sh <snapshot_path>
#
# Validates that the path matches the expected snapshot pattern to
# prevent arbitrary subvolume or directory deletion, then removes
# the BTRFS subvolume.
#
# Security: Only deletes paths matching:
#   /mnt/<mount>/<share>/.snapshots/@GMT-YYYY.MM.DD-HH.MM.SS
#
# Exit codes:
#   0 - Snapshot deleted successfully
#   1 - Invalid arguments
#   2 - Path validation failed (security block)
#   3 - Deletion failed
#

###############################################################################
# Configuration
###############################################################################

PLUGIN_NAME="btrfs-snapshots"
GLOBAL_CFG="/boot/config/plugins/${PLUGIN_NAME}/${PLUGIN_NAME}.cfg"
LOG_FILE="/var/log/${PLUGIN_NAME}.log"
SNAP_DIR_NAME=".snapshots"

###############################################################################
# Logging
###############################################################################

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "${ts} [${level}] [snapshot_delete] ${msg}" >> "${LOG_FILE}"
    if [[ -t 1 ]]; then
        echo "${ts} [${level}] ${msg}"
    fi
}

###############################################################################
# Load Configuration
###############################################################################

load_config() {
    if [[ -f "${GLOBAL_CFG}" ]]; then
        # shellcheck source=/dev/null
        source "${GLOBAL_CFG}"
    fi
}

###############################################################################
# Path Validation
###############################################################################

# Validates that the given path matches the expected snapshot pattern.
# This is the PRIMARY security gate -- prevents arbitrary deletion.
#
# Valid pattern:
#   /mnt/<mount>/<share>/.snapshots/@GMT-YYYY.MM.DD-HH.MM.SS
#   where <mount> is any mount point under /mnt/ (e.g. disk1, cache, pool-fast, etc.)
validate_snapshot_path() {
    local path="$1"

    # Resolve to absolute path, prevent symlink traversal
    local resolved
    resolved="$(readlink -f "$path" 2>/dev/null)"
    if [[ -z "$resolved" ]]; then
        # Path doesn't exist yet or can't be resolved; use the literal path
        # but still validate the pattern
        resolved="$path"
    fi

    # Pattern: /mnt/<mount>/<share>/.snapshots/@GMT-YYYY.MM.DD-HH.MM.SS
    # mount: any valid mount point name under /mnt/
    local pattern='^/mnt/[a-zA-Z0-9._-]+/[a-zA-Z0-9._[:space:]-]+/\.snapshots/@GMT-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{2}\.[0-9]{2}\.[0-9]{2}$'

    if [[ ! "$resolved" =~ $pattern ]]; then
        log "SECURITY" "Path validation FAILED: ${resolved}"
        log "SECURITY" "Expected pattern: /mnt/<mount>/<share>/.snapshots/@GMT-YYYY.MM.DD-HH.MM.SS"
        return 1
    fi

    # Additional safety: no path traversal components
    if [[ "$resolved" == *".."* ]]; then
        log "SECURITY" "Path contains traversal component: ${resolved}"
        return 1
    fi

    return 0
}

###############################################################################
# Verify it's Actually a BTRFS Subvolume
###############################################################################

verify_subvolume() {
    local path="$1"

    if ! btrfs subvolume show "$path" &>/dev/null; then
        log "ERROR" "Not a BTRFS subvolume: ${path}"
        return 1
    fi

    return 0
}

###############################################################################
# Delete Snapshot
###############################################################################

delete_snapshot() {
    local snap_path="$1"

    # Use btrfs subvolume delete (not rm!)
    local output
    output="$(btrfs subvolume delete "${snap_path}" 2>&1)"
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        log "INFO" "Deleted snapshot: ${snap_path}"
        return 0
    else
        log "ERROR" "Failed to delete snapshot: ${snap_path} -- ${output}"
        return 1
    fi
}

###############################################################################
# Main
###############################################################################

main() {
    local snapshot_path="$1"

    # Validate arguments
    if [[ -z "${snapshot_path}" ]]; then
        echo "Usage: snapshot_delete.sh <snapshot_path>" >&2
        echo "" >&2
        echo "  snapshot_path: Full path to a snapshot, e.g.:" >&2
        echo "    /mnt/disk1/MyShare/.snapshots/@GMT-2026.03.09-15.30.00" >&2
        exit 1
    fi

    # Remove trailing slash if present
    snapshot_path="${snapshot_path%/}"

    # Load configuration
    load_config

    # SECURITY: Validate the path matches expected snapshot pattern
    if ! validate_snapshot_path "${snapshot_path}"; then
        echo "Error: Path does not match expected snapshot pattern." >&2
        echo "Only paths matching /mnt/<disk>/<share>/.snapshots/@GMT-YYYY.MM.DD-HH.MM.SS are allowed." >&2
        exit 2
    fi

    # Check the snapshot exists
    if [[ ! -d "${snapshot_path}" ]]; then
        log "WARN" "Snapshot path does not exist: ${snapshot_path}"
        echo "Warning: Snapshot does not exist: ${snapshot_path}" >&2
        # Exit 0 -- idempotent; deleting something already gone is not an error
        exit 0
    fi

    # Verify it's actually a BTRFS subvolume
    if ! verify_subvolume "${snapshot_path}"; then
        echo "Error: Path exists but is not a BTRFS subvolume: ${snapshot_path}" >&2
        exit 3
    fi

    # Perform the deletion
    log "INFO" "Deleting snapshot: ${snapshot_path}"
    if delete_snapshot "${snapshot_path}"; then
        echo "Snapshot deleted: ${snapshot_path}"
        exit 0
    else
        echo "Error: Failed to delete snapshot: ${snapshot_path}" >&2
        exit 3
    fi
}

main "$@"
