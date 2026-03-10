#!/bin/bash
#
# smb_configure.sh - Configure Samba shadow_copy2 for BTRFS snapshot shares
#
# Usage: smb_configure.sh
#
# For each share with SMB_SHADOW_COPY enabled, injects shadow_copy2 into
# the share's vfs objects in /etc/samba/smb-shares.conf and adds the
# required shadow:* parameters. This must be done in smb-shares.conf
# (not smb-extra.conf) because Unraid loads smb-shares.conf AFTER
# smb-extra.conf, and per-share settings in smb-shares.conf override
# those in smb-extra.conf.
#
# Re-run after every Samba restart (handled by svcs_restarted event hook).
#
# Exit codes:
#   0 - Success
#   1 - Configuration error
#   2 - Samba reload failed
#

###############################################################################
# Configuration
###############################################################################

PLUGIN_NAME="btrfs-snapshots"
GLOBAL_CFG="/boot/config/plugins/${PLUGIN_NAME}/${PLUGIN_NAME}.cfg"
SHARE_CFG_DIR="/boot/config/plugins/${PLUGIN_NAME}/shares"
LOG_FILE="/var/log/${PLUGIN_NAME}.log"
SMB_SHARES_CONF="/etc/samba/smb-shares.conf"
SNAP_DIR_NAME=".snapshots"

# Defaults
PLUGIN_ENABLED="yes"
USE_UTC="yes"

###############################################################################
# Logging
###############################################################################

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "${ts} [${level}] [smb_configure] ${msg}" >> "${LOG_FILE}"
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
# Get shares that need shadow_copy2
###############################################################################

get_shadow_shares() {
    if [[ ! -d "${SHARE_CFG_DIR}" ]]; then
        return
    fi

    local cfg
    for cfg in "${SHARE_CFG_DIR}"/*.cfg; do
        [[ -f "$cfg" ]] || continue

        # Source the share config to check SMB_SHADOW_COPY
        local ENABLED="" SMB_SHADOW_COPY="" SNAPDIR=""
        # shellcheck source=/dev/null
        source "$cfg"

        if [[ "${ENABLED}" == "yes" && "${SMB_SHADOW_COPY}" == "yes" ]]; then
            local name
            name="$(basename "${cfg}" .cfg)"
            echo "${name}"
        fi
    done
}

###############################################################################
# Patch smb-shares.conf for a single share
###############################################################################

patch_share_in_smb_conf() {
    local share_name="$1"
    local conf_file="$2"

    # Check if this share exists in the conf file
    if ! grep -q "^\[${share_name}\]" "$conf_file" 2>/dev/null; then
        log "WARN" "Share [${share_name}] not found in ${conf_file}"
        return 1
    fi

    # Load share-specific config (source sets SNAPDIR if present)
    local cfg_file="${SHARE_CFG_DIR}/${share_name}.cfg"
    local SNAPDIR=".snapshots"
    if [[ -f "${cfg_file}" ]]; then
        # shellcheck source=/dev/null
        source "${cfg_file}"
        SNAPDIR="${SNAPDIR:-.snapshots}"
    fi

    # Determine localtime setting
    local shadow_localtime="no"
    if [[ "${USE_UTC}" != "yes" ]]; then
        shadow_localtime="yes"
    fi

    # 1. Add shadow_copy2 to vfs objects if not already present
    # Find the vfs objects line for this share section
    local in_section=false
    local modified=false
    local tmpfile="${conf_file}.btrfs-tmp"

    while IFS= read -r line; do
        # Detect section headers
        if [[ "$line" =~ ^\[.*\]$ ]]; then
            if [[ "$line" == "[${share_name}]" ]]; then
                in_section=true
            else
                # Leaving our section — inject shadow params before we leave
                if [[ "$in_section" == true && "$modified" == true ]]; then
                    echo "	shadow:snapdir = ${SNAPDIR}"
                    echo "	shadow:format = @GMT-%Y.%m.%d-%H.%M.%S"
                    echo "	shadow:sort = desc"
                    echo "	shadow:localtime = ${shadow_localtime}"
                    echo "	shadow:snapdirseverywhere = yes"
                fi
                in_section=false
            fi
        fi

        if [[ "$in_section" == true ]]; then
            # Check for vfs objects line
            if [[ "$line" =~ ^[[:space:]]*vfs\ objects\ = ]]; then
                if [[ "$line" != *"shadow_copy2"* ]]; then
                    # Prepend shadow_copy2 to vfs objects
                    local existing_vfs
                    existing_vfs="$(echo "$line" | sed 's/.*vfs objects = //')"
                    echo "	vfs objects = shadow_copy2 ${existing_vfs}"
                    modified=true
                else
                    # Already has shadow_copy2
                    echo "$line"
                    modified=true
                fi
                continue
            fi
        fi

        echo "$line"
    done < "$conf_file" > "$tmpfile"

    # Handle case where share is the last section (no following section header)
    if [[ "$in_section" == true && "$modified" == true ]]; then
        echo "	shadow:snapdir = ${SNAPDIR}" >> "$tmpfile"
        echo "	shadow:format = @GMT-%Y.%m.%d-%H.%M.%S" >> "$tmpfile"
        echo "	shadow:sort = desc" >> "$tmpfile"
        echo "	shadow:localtime = ${shadow_localtime}" >> "$tmpfile"
        echo "	shadow:snapdirseverywhere = yes" >> "$tmpfile"
    fi

    if [[ "$modified" == true ]]; then
        mv "$tmpfile" "$conf_file"
        log "INFO" "Patched [${share_name}] in ${conf_file} with shadow_copy2"
        return 0
    else
        rm -f "$tmpfile"
        log "WARN" "Could not find vfs objects line for [${share_name}]"
        return 1
    fi
}

###############################################################################
# Remove shadow_copy2 from smb-shares.conf for all shares
###############################################################################

clean_smb_conf() {
    local conf_file="$1"

    [[ -f "$conf_file" ]] || return 0

    # Remove shadow_copy2 from vfs objects lines and remove shadow:* lines
    sed -i \
        -e 's/shadow_copy2 //g' \
        -e '/^[[:space:]]*shadow:snapdir/d' \
        -e '/^[[:space:]]*shadow:format/d' \
        -e '/^[[:space:]]*shadow:sort/d' \
        -e '/^[[:space:]]*shadow:localtime/d' \
        -e '/^[[:space:]]*shadow:snapdirseverywhere/d' \
        "$conf_file"
}

###############################################################################
# Reload Samba
###############################################################################

reload_samba() {
    if ! pidof smbd &>/dev/null; then
        log "WARN" "smbd is not running, skipping reload"
        return 0
    fi

    if smbcontrol smbd reload-config &>/dev/null; then
        log "INFO" "Samba configuration reloaded successfully"
        return 0
    else
        log "ERROR" "Failed to reload Samba configuration"
        return 1
    fi
}

###############################################################################
# Main
###############################################################################

main() {
    load_config

    if [[ ! -f "${SMB_SHARES_CONF}" ]]; then
        log "WARN" "${SMB_SHARES_CONF} not found, skipping"
        exit 0
    fi

    # If plugin is disabled, clean up and reload
    if [[ "${ENABLED:-yes}" != "yes" ]]; then
        log "INFO" "Plugin is disabled, cleaning Samba configuration"
        clean_smb_conf "${SMB_SHARES_CONF}"
        reload_samba
        exit 0
    fi

    # Clean old smb-extra.conf markers from previous approach
    local SMB_EXTRA="/boot/config/smb-extra.conf"
    if [[ -f "${SMB_EXTRA}" ]] && grep -q "BTRFS-SNAPSHOTS-START" "${SMB_EXTRA}" 2>/dev/null; then
        sed -i '/### BTRFS-SNAPSHOTS-START ###/,/### BTRFS-SNAPSHOTS-END ###/d' "${SMB_EXTRA}"
        log "INFO" "Cleaned old markers from smb-extra.conf"
    fi

    # Clean any previous shadow_copy2 injections from smb-shares.conf to start fresh
    clean_smb_conf "${SMB_SHARES_CONF}"

    # Get shares that want shadow_copy2
    local shares
    shares="$(get_shadow_shares)"

    if [[ -z "$shares" ]]; then
        log "INFO" "No shares configured for shadow_copy2"
        reload_samba
        exit 0
    fi

    # Patch each share
    local share_count=0
    while IFS= read -r share; do
        [[ -z "$share" ]] && continue

        if patch_share_in_smb_conf "${share}" "${SMB_SHARES_CONF}"; then
            ((share_count++))
        fi
    done <<< "${shares}"

    log "INFO" "Configured shadow_copy2 for ${share_count} shares"

    # Reload Samba
    if ! reload_samba; then
        echo "Warning: Samba reload failed." >&2
        exit 2
    fi

    echo "Samba configuration updated for ${share_count} shares"
    exit 0
}

main "$@"
