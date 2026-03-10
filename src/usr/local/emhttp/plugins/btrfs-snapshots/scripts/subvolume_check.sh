#!/bin/bash
#
# subvolume_check.sh - Check and optionally convert share directories to BTRFS subvolumes
#
# Usage:
#   subvolume_check.sh <share_name>              # Check status (JSON output)
#   subvolume_check.sh --convert <share_name>     # Convert directories to subvolumes
#
# Without --convert: outputs JSON status of each disk showing whether it's
# BTRFS and whether the share directory is already a subvolume.
#
# With --convert: performs an in-place conversion of a regular directory to
# a BTRFS subvolume using the mv/create/reflink-copy method. This is
# DESTRUCTIVE and includes rollback on failure.
#
# JSON output format (check mode):
# [
#   {
#     "disk": "/mnt/disk1",
#     "share_path": "/mnt/disk1/ShareName",
#     "is_btrfs": true,
#     "is_subvolume": true,
#     "needs_conversion": false
#   },
#   ...
# ]
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments
#   2 - Conversion failed (with rollback attempted)
#   3 - Share not found on any disk
#

###############################################################################
# Configuration
###############################################################################

PLUGIN_NAME="btrfs-snapshots"
GLOBAL_CFG="/boot/config/plugins/${PLUGIN_NAME}/${PLUGIN_NAME}.cfg"
LOG_FILE="/var/log/${PLUGIN_NAME}.log"

###############################################################################
# Logging
###############################################################################

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "${ts} [${level}] [subvolume_check] ${msg}" >> "${LOG_FILE}"
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
# Filesystem Checks
###############################################################################

is_btrfs() {
    local path="$1"
    local fstype
    fstype="$(stat -f -c '%T' "$path" 2>/dev/null)" || return 1
    [[ "$fstype" == "btrfs" ]]
}

is_subvolume() {
    local path="$1"
    btrfs subvolume show "$path" &>/dev/null
}

###############################################################################
# JSON Output Helpers
###############################################################################

json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    echo "$str"
}

###############################################################################
# Check Mode - Output JSON Status
###############################################################################

check_mode() {
    local share_name="$1"

    local disks
    disks="$(find_share_disks "${share_name}")" || {
        echo "[]"
        log "WARN" "Share '${share_name}' not found on any disk"
        return 3
    }

    local first=true
    echo "["

    while IFS= read -r disk; do
        local share_path="${disk}/${share_name}"
        local disk_is_btrfs="false"
        local path_is_subvol="false"
        local needs_conversion="false"

        if is_btrfs "${disk}"; then
            disk_is_btrfs="true"

            if is_subvolume "${share_path}"; then
                path_is_subvol="true"
            else
                needs_conversion="true"
            fi
        fi

        if [[ "$first" == true ]]; then
            first=false
        else
            echo ","
        fi

        local j_disk j_path
        j_disk="$(json_escape "$disk")"
        j_path="$(json_escape "$share_path")"

        printf '  {"disk": "%s", "share_path": "%s", "is_btrfs": %s, "is_subvolume": %s, "needs_conversion": %s}' \
            "$j_disk" "$j_path" "$disk_is_btrfs" "$path_is_subvol" "$needs_conversion"
    done <<< "${disks}"

    echo ""
    echo "]"
    return 0
}

###############################################################################
# Convert Mode - Convert Directory to Subvolume
###############################################################################

# Convert a single share directory to a BTRFS subvolume.
#
# Method:
# 1. Rename original directory to a temporary name
# 2. Create a new BTRFS subvolume at the original path
# 3. Copy all contents using --reflink=always (CoW, nearly instant, no extra space)
# 4. Preserve ownership, permissions, timestamps, xattrs
# 5. If anything fails, rollback by removing the subvolume and renaming back
#
# CRITICAL: This operation should be performed while the share is not actively
# being written to. Ideally with the array stopped or share disabled.
convert_directory_to_subvolume() {
    local share_path="$1"
    local disk="$2"
    local share_name="$3"
    local tmp_path="${share_path}.btrfs-convert-tmp"

    log "INFO" "=== Starting subvolume conversion for ${share_path} ==="

    # Safety: Check we're on BTRFS
    if ! is_btrfs "${disk}"; then
        log "ERROR" "Cannot convert: ${disk} is not BTRFS"
        return 1
    fi

    # Safety: Already a subvolume?
    if is_subvolume "${share_path}"; then
        log "INFO" "${share_path} is already a subvolume, no conversion needed"
        return 0
    fi

    # Safety: Check temp path doesn't already exist (interrupted previous conversion)
    if [[ -e "${tmp_path}" ]]; then
        log "ERROR" "Temporary path ${tmp_path} already exists!"
        log "ERROR" "A previous conversion may have been interrupted."
        log "ERROR" "Inspect manually: if original data is in ${tmp_path}, rename it back."
        return 1
    fi

    # Check available space (reflink copy shouldn't use extra space, but be safe)
    local avail_kb
    avail_kb="$(df --output=avail "${disk}" 2>/dev/null | tail -1 | tr -d ' ')"
    if [[ -n "$avail_kb" && "$avail_kb" -lt 1048576 ]]; then
        log "WARN" "Less than 1GB free on ${disk}, proceeding with caution (reflink should not use extra space)"
    fi

    # Step 1: Rename original directory
    log "INFO" "Step 1/4: Renaming ${share_path} -> ${tmp_path}"
    if ! mv "${share_path}" "${tmp_path}"; then
        log "ERROR" "Failed to rename directory. Aborting."
        return 1
    fi

    # Step 2: Create new subvolume
    log "INFO" "Step 2/4: Creating BTRFS subvolume at ${share_path}"
    if ! btrfs subvolume create "${share_path}"; then
        log "ERROR" "Failed to create subvolume. Rolling back..."
        mv "${tmp_path}" "${share_path}" 2>/dev/null
        log "INFO" "Rollback: renamed ${tmp_path} back to ${share_path}"
        return 1
    fi

    # Step 3: Copy contents with reflink
    # Using cp -a for full archive mode (preserves everything) + --reflink=always
    # for CoW cloning (near-instant, no extra disk space on BTRFS)
    log "INFO" "Step 3/4: Copying contents with reflink (CoW)..."
    log "INFO" "  Source: ${tmp_path}/  Dest: ${share_path}/"

    # We use a subshell to capture errors properly
    local copy_error=0
    if ! cp -a --reflink=always "${tmp_path}/." "${share_path}/" 2>"${LOG_FILE}.convert-err"; then
        copy_error=1
        local err_msg
        err_msg="$(cat "${LOG_FILE}.convert-err" 2>/dev/null)"
        log "ERROR" "Copy failed: ${err_msg}"
    fi
    rm -f "${LOG_FILE}.convert-err"

    if [[ $copy_error -ne 0 ]]; then
        # ROLLBACK: Remove the partial subvolume, restore original
        log "ERROR" "Rolling back conversion..."

        # Remove contents of the new subvolume first
        # (Can't delete subvolume if it contains nested subvolumes that were copied)
        # Use find to delete nested subvolumes first
        local nested
        while IFS= read -r nested; do
            btrfs subvolume delete "$nested" &>/dev/null
        done < <(btrfs subvolume list -o "${share_path}" 2>/dev/null | awk '{print $NF}' | sort -r | while read -r subpath; do echo "${disk}/${subpath}"; done)

        btrfs subvolume delete "${share_path}" &>/dev/null

        if [[ ! -e "${share_path}" ]]; then
            mv "${tmp_path}" "${share_path}" 2>/dev/null
            log "INFO" "Rollback complete: original directory restored"
        else
            log "ERROR" "ROLLBACK FAILED: Could not delete new subvolume."
            log "ERROR" "Original data preserved at: ${tmp_path}"
            log "ERROR" "Manual intervention required!"
        fi
        return 1
    fi

    # Step 4: Verify and clean up
    log "INFO" "Step 4/4: Verifying conversion..."

    if ! is_subvolume "${share_path}"; then
        log "ERROR" "Verification failed: ${share_path} is not a subvolume after conversion!"
        log "ERROR" "Original data preserved at: ${tmp_path}"
        return 1
    fi

    # Verify file count matches (basic sanity check)
    local orig_count new_count
    orig_count="$(find "${tmp_path}" -not -path "${tmp_path}/.snapshots/*" 2>/dev/null | wc -l)"
    new_count="$(find "${share_path}" -not -path "${share_path}/.snapshots/*" 2>/dev/null | wc -l)"

    # Allow small differences (metadata files, etc.) but flag large discrepancies
    local diff=$((orig_count - new_count))
    if [[ ${diff#-} -gt 10 ]]; then
        log "WARN" "File count mismatch: original=${orig_count}, new=${new_count} (diff=${diff})"
        log "WARN" "Original data preserved at: ${tmp_path}"
        log "WARN" "Please verify the conversion manually before removing ${tmp_path}"
        return 0  # Don't auto-delete on mismatch
    fi

    # Remove the old directory
    log "INFO" "Conversion verified. Removing temporary directory: ${tmp_path}"
    rm -rf "${tmp_path}"

    log "INFO" "=== Subvolume conversion complete for ${share_path} ==="
    return 0
}

convert_mode() {
    local share_name="$1"

    log "INFO" "Starting subvolume conversion for share '${share_name}'"

    local disks
    disks="$(find_share_disks "${share_name}")" || {
        log "ERROR" "Share '${share_name}' not found on any disk"
        echo "Error: Share '${share_name}' not found on any disk" >&2
        return 3
    }

    local success_count=0
    local fail_count=0
    local skip_count=0

    while IFS= read -r disk; do
        local share_path="${disk}/${share_name}"

        # Skip non-BTRFS disks
        if ! is_btrfs "${disk}"; then
            log "INFO" "Skipping ${disk}: not BTRFS"
            ((skip_count++))
            continue
        fi

        # Skip if already a subvolume
        if is_subvolume "${share_path}"; then
            log "INFO" "Skipping ${share_path}: already a subvolume"
            ((skip_count++))
            continue
        fi

        # Perform conversion
        echo "Converting ${share_path} to BTRFS subvolume..."
        if convert_directory_to_subvolume "${share_path}" "${disk}" "${share_name}"; then
            echo "  SUCCESS: ${share_path}"
            ((success_count++))
        else
            echo "  FAILED: ${share_path} (check ${LOG_FILE} for details)"
            ((fail_count++))
        fi
    done <<< "${disks}"

    echo ""
    echo "Conversion summary: ${success_count} converted, ${fail_count} failed, ${skip_count} skipped"
    log "INFO" "Conversion summary for '${share_name}': ${success_count} converted, ${fail_count} failed, ${skip_count} skipped"

    if [[ $fail_count -gt 0 ]]; then
        return 2
    fi
    return 0
}

###############################################################################
# Main
###############################################################################

main() {
    local mode="check"
    local share_name=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --convert)
                mode="convert"
                shift
                ;;
            --help|-h)
                echo "Usage: subvolume_check.sh [--convert] <share_name>"
                echo ""
                echo "Options:"
                echo "  --convert   Convert regular directories to BTRFS subvolumes"
                echo "              WARNING: This is a destructive operation!"
                echo ""
                echo "Without --convert, outputs JSON status of each disk."
                exit 0
                ;;
            -*)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
            *)
                share_name="$1"
                shift
                ;;
        esac
    done

    if [[ -z "${share_name}" ]]; then
        echo "Usage: subvolume_check.sh [--convert] <share_name>" >&2
        exit 1
    fi

    # Sanitize
    share_name="$(sanitize_name "${share_name}")" || exit 1

    # Load configuration
    load_config

    case "${mode}" in
        check)
            check_mode "${share_name}"
            ;;
        convert)
            # Extra confirmation for convert mode when running interactively
            if [[ -t 0 && -t 1 ]]; then
                echo "WARNING: Subvolume conversion is a significant operation."
                echo "It renames the existing directory, creates a BTRFS subvolume,"
                echo "and copies data back using reflink (CoW)."
                echo ""
                echo "This should be done when the share is NOT actively being written to."
                echo ""
                read -r -p "Continue with conversion of '${share_name}'? [y/N] " confirm
                if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
                    echo "Aborted."
                    exit 0
                fi
            fi
            convert_mode "${share_name}"
            ;;
    esac
}

main "$@"
