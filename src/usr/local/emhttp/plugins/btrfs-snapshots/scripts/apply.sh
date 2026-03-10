#!/bin/bash
#
# apply.sh - Apply settings after form submission in Unraid web UI
#
# Usage: apply.sh
#
# Called by Unraid's update.php after the settings form is submitted.
# Performs the following:
#   1. Validates the current configuration
#   2. Regenerates cron jobs (calls cron_update.sh)
#   3. Reconfigures Samba shadow_copy2 (calls smb_configure.sh)
#   4. Outputs status messages for the Unraid progress frame
#
# This script outputs HTML-compatible status messages that are displayed
# in the Unraid settings page progress/result frame.
#
# Exit codes:
#   0 - All operations succeeded
#   1 - One or more operations failed (partial success possible)
#

###############################################################################
# Configuration
###############################################################################

PLUGIN_NAME="btrfs-snapshots"
GLOBAL_CFG="/boot/config/plugins/${PLUGIN_NAME}/${PLUGIN_NAME}.cfg"
SHARE_CFG_DIR="/boot/config/plugins/${PLUGIN_NAME}/shares"
LOG_FILE="/var/log/${PLUGIN_NAME}.log"
SCRIPTS_DIR="$(dirname "$(readlink -f "$0")")"

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
    echo "${ts} [${level}] [apply] ${msg}" >> "${LOG_FILE}"
}

###############################################################################
# Status Output
###############################################################################

# Output a status message for the Unraid progress frame.
# These are displayed to the user in the web UI.
status_ok() {
    echo "  OK: $*"
    log "INFO" "$*"
}

status_warn() {
    echo "  WARNING: $*"
    log "WARN" "$*"
}

status_error() {
    echo "  ERROR: $*"
    log "ERROR" "$*"
}

status_info() {
    echo "  $*"
    log "INFO" "$*"
}

###############################################################################
# Load Configuration
###############################################################################

load_config() {
    if [[ -f "${GLOBAL_CFG}" ]]; then
        # shellcheck source=/dev/null
        source "${GLOBAL_CFG}"
        PLUGIN_ENABLED="${PLUGIN_ENABLED:-yes}"
    else
        status_warn "Global configuration file not found at ${GLOBAL_CFG}"
        return 1
    fi
}

###############################################################################
# Validate Configuration
###############################################################################

validate_config() {
    local errors=0

    status_info "Validating configuration..."

    # Check global config exists and is readable
    if [[ ! -f "${GLOBAL_CFG}" ]]; then
        status_error "Global config missing: ${GLOBAL_CFG}"
        ((errors++))
    elif [[ ! -r "${GLOBAL_CFG}" ]]; then
        status_error "Global config not readable: ${GLOBAL_CFG}"
        ((errors++))
    fi

    # Check config directory exists
    if [[ ! -d "${SHARE_CFG_DIR}" ]]; then
        status_warn "Share config directory missing: ${SHARE_CFG_DIR}"
        mkdir -p "${SHARE_CFG_DIR}" 2>/dev/null && status_ok "Created ${SHARE_CFG_DIR}" || {
            status_error "Failed to create ${SHARE_CFG_DIR}"
            ((errors++))
        }
    fi

    # Validate each share config
    if [[ -d "${SHARE_CFG_DIR}" ]]; then
        local cfg_count=0
        local cfg
        for cfg in "${SHARE_CFG_DIR}"/*.cfg; do
            [[ -f "$cfg" ]] || continue
            ((cfg_count++))

            local share_name
            share_name="$(basename "${cfg}" .cfg)"

            # Validate share name characters
            if [[ ! "$share_name" =~ ^[a-zA-Z0-9._\ -]+$ ]]; then
                status_error "Invalid share name in config: ${share_name}"
                ((errors++))
                continue
            fi

            # Source and validate keys
            (
                # Subshell to avoid polluting our namespace
                # shellcheck source=/dev/null
                source "$cfg" 2>/dev/null

                # Validate schedule
                local schedule="${SCHEDULE:-disabled}"
                case "$schedule" in
                    every15min|hourly|every6hours|daily|weekly|disabled) ;;
                    *)
                        # Allow raw cron expressions
                        if [[ ! "$schedule" =~ ^[0-9*/,-]+[[:space:]]+[0-9*/,-]+[[:space:]]+[0-9*/,-]+[[:space:]]+[0-9*/,-]+[[:space:]]+[0-9*/,-]+$ ]]; then
                            echo "INVALID_SCHEDULE:${share_name}:${schedule}"
                        fi
                        ;;
                esac

                # Validate retention values are positive integers
                local key
                for key in RETENTION_HOURLY RETENTION_DAILY RETENTION_WEEKLY RETENTION_MONTHLY; do
                    local val="${!key}"
                    if [[ -n "$val" && ! "$val" =~ ^[0-9]+$ ]]; then
                        echo "INVALID_RETENTION:${share_name}:${key}=${val}"
                    fi
                done
            ) | while IFS= read -r validation_msg; do
                if [[ "$validation_msg" == INVALID_SCHEDULE:* ]]; then
                    local parts="${validation_msg#INVALID_SCHEDULE:}"
                    status_warn "Share '${parts%%:*}' has invalid schedule: ${parts#*:}"
                elif [[ "$validation_msg" == INVALID_RETENTION:* ]]; then
                    local parts="${validation_msg#INVALID_RETENTION:}"
                    status_warn "Share '${parts%%:*}' has invalid retention: ${parts#*:}"
                fi
            done
        done

        if [[ $cfg_count -eq 0 ]]; then
            status_info "No share configurations found"
        else
            status_ok "Validated ${cfg_count} share configuration(s)"
        fi
    fi

    # Check that scripts are present and executable
    local required_scripts=("snapshot_create.sh" "snapshot_delete.sh" "snapshot_list.sh"
                            "snapshot_rotate.sh" "subvolume_check.sh" "smb_configure.sh"
                            "cron_update.sh")
    local missing=0
    local script
    for script in "${required_scripts[@]}"; do
        if [[ ! -f "${SCRIPTS_DIR}/${script}" ]]; then
            status_error "Missing script: ${script}"
            ((missing++))
        elif [[ ! -x "${SCRIPTS_DIR}/${script}" ]]; then
            # Try to make it executable
            chmod +x "${SCRIPTS_DIR}/${script}" 2>/dev/null
        fi
    done

    if [[ $missing -gt 0 ]]; then
        status_error "${missing} required script(s) missing"
        ((errors++))
    else
        status_ok "All required scripts present"
    fi

    # Check btrfs tools are available
    if ! command -v btrfs &>/dev/null; then
        status_error "btrfs command not found (btrfs-progs not installed?)"
        ((errors++))
    else
        status_ok "btrfs tools available"
    fi

    return $errors
}

###############################################################################
# Update Cron Jobs
###############################################################################

update_cron() {
    status_info "Updating cron jobs..."

    if [[ ! -x "${SCRIPTS_DIR}/cron_update.sh" ]]; then
        chmod +x "${SCRIPTS_DIR}/cron_update.sh" 2>/dev/null
    fi

    local output
    output="$("${SCRIPTS_DIR}/cron_update.sh" 2>&1)"
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        status_ok "Cron jobs updated: ${output}"
        return 0
    else
        status_error "Cron update failed: ${output}"
        return 1
    fi
}

###############################################################################
# Update Samba Configuration
###############################################################################

update_samba() {
    status_info "Updating Samba configuration..."

    if [[ ! -x "${SCRIPTS_DIR}/smb_configure.sh" ]]; then
        chmod +x "${SCRIPTS_DIR}/smb_configure.sh" 2>/dev/null
    fi

    local output
    output="$("${SCRIPTS_DIR}/smb_configure.sh" 2>&1)"
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        status_ok "Samba configuration updated: ${output}"
        return 0
    elif [[ $rc -eq 2 ]]; then
        status_warn "Samba config written but reload failed: ${output}"
        return 1
    else
        status_error "Samba configuration failed: ${output}"
        return 1
    fi
}

###############################################################################
# Main
###############################################################################

main() {
    local errors=0

    echo "Applying BTRFS Snapshots configuration..."
    echo ""
    log "INFO" "=== Apply settings started ==="

    # Load configuration
    if ! load_config; then
        ((errors++))
    fi

    # Validate
    if ! validate_config; then
        status_warn "Configuration has issues (see above), proceeding anyway"
    fi

    echo ""

    # Update cron jobs
    if ! update_cron; then
        ((errors++))
    fi

    # Update Samba configuration
    if ! update_samba; then
        ((errors++))
    fi

    echo ""

    # Final status
    if [[ $errors -eq 0 ]]; then
        echo "Settings applied successfully."
        log "INFO" "=== Apply settings completed successfully ==="
    else
        echo "Settings applied with ${errors} error(s). Check ${LOG_FILE} for details."
        log "WARN" "=== Apply settings completed with ${errors} error(s) ==="
    fi

    exit $( [[ $errors -gt 0 ]] && echo 1 || echo 0 )
}

main "$@"
