#!/bin/bash
#
# cron_update.sh - Generate cron jobs for BTRFS snapshot scheduling
#
# Usage: cron_update.sh
#
# Reads all per-share configuration files and generates a cron file at
# /etc/cron.d/btrfs-snapshots. Each share can have up to three independent
# schedules (daily, weekly, monthly), each with a user-defined time and day.
#
# Per-share config keys read from /boot/config/plugins/btrfs-snapshots/shares/<name>.cfg:
#   ENABLED="yes"
#   SCHEDULE_DAILY_ENABLED="yes"    - Enable daily snapshots
#   SCHEDULE_DAILY_HOUR="0"         - Hour to run (0-23)
#   SCHEDULE_DAILY_MINUTE="0"       - Minute to run (0-59)
#   SCHEDULE_WEEKLY_ENABLED="yes"   - Enable weekly snapshots
#   SCHEDULE_WEEKLY_DAY="0"         - Day of week (0=Sun ... 6=Sat)
#   SCHEDULE_WEEKLY_HOUR="2"        - Hour to run (0-23)
#   SCHEDULE_WEEKLY_MINUTE="0"      - Minute to run (0-59)
#   SCHEDULE_MONTHLY_ENABLED="no"   - Enable monthly snapshots
#   SCHEDULE_MONTHLY_DAY="1"        - Day of month (1-28)
#   SCHEDULE_MONTHLY_HOUR="3"       - Hour to run (0-23)
#   SCHEDULE_MONTHLY_MINUTE="0"     - Minute to run (0-59)
#
# If the plugin is disabled globally, removes the cron file entirely.
#
# Exit codes:
#   0 - Success
#   1 - Configuration error
#

###############################################################################
# Configuration
###############################################################################

PLUGIN_NAME="btrfs-snapshots"
GLOBAL_CFG="/boot/config/plugins/${PLUGIN_NAME}/${PLUGIN_NAME}.cfg"
SHARE_CFG_DIR="/boot/config/plugins/${PLUGIN_NAME}/shares"
LOG_FILE="/var/log/${PLUGIN_NAME}.log"
CRON_FILE="/etc/cron.d/${PLUGIN_NAME}"
SCRIPTS_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}/scripts"

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
    echo "${ts} [${level}] [cron_update] ${msg}" >> "${LOG_FILE}"
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
        PLUGIN_ENABLED="${PLUGIN_ENABLED:-yes}"
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
# Clamp an integer to a range; return default if not a number
###############################################################################

clamp_int() {
    local val="$1" min="$2" max="$3" default="$4"
    if [[ ! "$val" =~ ^[0-9]+$ ]]; then echo "$default"; return; fi
    if (( val < min )); then echo "$min"; return; fi
    if (( val > max )); then echo "$max"; return; fi
    echo "$val"
}

###############################################################################
# Generate Cron File
###############################################################################

###############################################################################
# Load Global Schedule Defaults
###############################################################################

# Reads SCHEDULE_* keys from the global config into GLOBAL_SCHEDULE_* vars.
load_global_schedules() {
    GLOBAL_SCHEDULE_HOURLY_ENABLED="no"
    GLOBAL_SCHEDULE_HOURLY_MINUTE="0"
    GLOBAL_SCHEDULE_DAILY_ENABLED="yes"
    GLOBAL_SCHEDULE_DAILY_HOUR="0"
    GLOBAL_SCHEDULE_DAILY_MINUTE="0"
    GLOBAL_SCHEDULE_WEEKLY_ENABLED="yes"
    GLOBAL_SCHEDULE_WEEKLY_DAY="0"
    GLOBAL_SCHEDULE_WEEKLY_HOUR="2"
    GLOBAL_SCHEDULE_WEEKLY_MINUTE="0"
    GLOBAL_SCHEDULE_MONTHLY_ENABLED="no"
    GLOBAL_SCHEDULE_MONTHLY_DAY="1"
    GLOBAL_SCHEDULE_MONTHLY_HOUR="3"
    GLOBAL_SCHEDULE_MONTHLY_MINUTE="0"

    if [[ -f "${GLOBAL_CFG}" ]]; then
        local key val
        while IFS='=' read -r key val; do
            key="${key//[[:space:]]/}"
            val="${val//\"/}"
            case "$key" in
                SCHEDULE_HOURLY_ENABLED)  GLOBAL_SCHEDULE_HOURLY_ENABLED="$val" ;;
                SCHEDULE_HOURLY_MINUTE)   GLOBAL_SCHEDULE_HOURLY_MINUTE="$val" ;;
                SCHEDULE_DAILY_ENABLED)   GLOBAL_SCHEDULE_DAILY_ENABLED="$val" ;;
                SCHEDULE_DAILY_HOUR)      GLOBAL_SCHEDULE_DAILY_HOUR="$val" ;;
                SCHEDULE_DAILY_MINUTE)    GLOBAL_SCHEDULE_DAILY_MINUTE="$val" ;;
                SCHEDULE_WEEKLY_ENABLED)  GLOBAL_SCHEDULE_WEEKLY_ENABLED="$val" ;;
                SCHEDULE_WEEKLY_DAY)      GLOBAL_SCHEDULE_WEEKLY_DAY="$val" ;;
                SCHEDULE_WEEKLY_HOUR)     GLOBAL_SCHEDULE_WEEKLY_HOUR="$val" ;;
                SCHEDULE_WEEKLY_MINUTE)   GLOBAL_SCHEDULE_WEEKLY_MINUTE="$val" ;;
                SCHEDULE_MONTHLY_ENABLED) GLOBAL_SCHEDULE_MONTHLY_ENABLED="$val" ;;
                SCHEDULE_MONTHLY_DAY)     GLOBAL_SCHEDULE_MONTHLY_DAY="$val" ;;
                SCHEDULE_MONTHLY_HOUR)    GLOBAL_SCHEDULE_MONTHLY_HOUR="$val" ;;
                SCHEDULE_MONTHLY_MINUTE)  GLOBAL_SCHEDULE_MONTHLY_MINUTE="$val" ;;
            esac
        done < "${GLOBAL_CFG}"
    fi
}

###############################################################################
# Resolve "global" schedule values for a share
###############################################################################

resolve_global_schedules() {
    [[ "$SCHEDULE_HOURLY_ENABLED"  == "global" ]] && SCHEDULE_HOURLY_ENABLED="$GLOBAL_SCHEDULE_HOURLY_ENABLED"
    [[ -z "$SCHEDULE_HOURLY_MINUTE"            ]] && SCHEDULE_HOURLY_MINUTE="$GLOBAL_SCHEDULE_HOURLY_MINUTE"
    [[ "$SCHEDULE_DAILY_ENABLED"   == "global" ]] && SCHEDULE_DAILY_ENABLED="$GLOBAL_SCHEDULE_DAILY_ENABLED"
    [[ -z "$SCHEDULE_DAILY_HOUR"               ]] && SCHEDULE_DAILY_HOUR="$GLOBAL_SCHEDULE_DAILY_HOUR"
    [[ -z "$SCHEDULE_DAILY_MINUTE"             ]] && SCHEDULE_DAILY_MINUTE="$GLOBAL_SCHEDULE_DAILY_MINUTE"
    [[ "$SCHEDULE_WEEKLY_ENABLED"  == "global" ]] && SCHEDULE_WEEKLY_ENABLED="$GLOBAL_SCHEDULE_WEEKLY_ENABLED"
    [[ -z "$SCHEDULE_WEEKLY_DAY"               ]] && SCHEDULE_WEEKLY_DAY="$GLOBAL_SCHEDULE_WEEKLY_DAY"
    [[ -z "$SCHEDULE_WEEKLY_HOUR"              ]] && SCHEDULE_WEEKLY_HOUR="$GLOBAL_SCHEDULE_WEEKLY_HOUR"
    [[ -z "$SCHEDULE_WEEKLY_MINUTE"            ]] && SCHEDULE_WEEKLY_MINUTE="$GLOBAL_SCHEDULE_WEEKLY_MINUTE"
    [[ "$SCHEDULE_MONTHLY_ENABLED" == "global" ]] && SCHEDULE_MONTHLY_ENABLED="$GLOBAL_SCHEDULE_MONTHLY_ENABLED"
    [[ -z "$SCHEDULE_MONTHLY_DAY"              ]] && SCHEDULE_MONTHLY_DAY="$GLOBAL_SCHEDULE_MONTHLY_DAY"
    [[ -z "$SCHEDULE_MONTHLY_HOUR"             ]] && SCHEDULE_MONTHLY_HOUR="$GLOBAL_SCHEDULE_MONTHLY_HOUR"
    [[ -z "$SCHEDULE_MONTHLY_MINUTE"           ]] && SCHEDULE_MONTHLY_MINUTE="$GLOBAL_SCHEDULE_MONTHLY_MINUTE"
}

###############################################################################
# Generate Cron File
###############################################################################

generate_cron_file() {
    local shares
    shares="$(get_configured_shares)"

    if [[ -z "$shares" ]]; then
        log "INFO" "No configured shares, removing cron file"
        remove_cron_file
        return 0
    fi

    load_global_schedules

    local entry_count=0
    # Build cron content line by line
    local -a lines=(
        "# BTRFS Snapshots Plugin - Auto-generated cron jobs"
        "# Do not edit manually - regenerated by cron_update.sh"
        "# Last updated: $(date '+%Y-%m-%d %H:%M:%S')"
        "#"
        "SHELL=/bin/bash"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ""
    )

    while IFS= read -r share; do
        [[ -z "$share" ]] && continue

        local cfg_file="${SHARE_CFG_DIR}/${share}.cfg"

        # Reset all schedule variables before sourcing
        local ENABLED="yes"
        local SCHEDULE_HOURLY_ENABLED="no"
        local SCHEDULE_HOURLY_MINUTE="0"
        local SCHEDULE_DAILY_ENABLED="no"
        local SCHEDULE_DAILY_HOUR="0"
        local SCHEDULE_DAILY_MINUTE="0"
        local SCHEDULE_WEEKLY_ENABLED="no"
        local SCHEDULE_WEEKLY_DAY="0"
        local SCHEDULE_WEEKLY_HOUR="2"
        local SCHEDULE_WEEKLY_MINUTE="0"
        local SCHEDULE_MONTHLY_ENABLED="no"
        local SCHEDULE_MONTHLY_DAY="1"
        local SCHEDULE_MONTHLY_HOUR="3"
        local SCHEDULE_MONTHLY_MINUTE="0"

        if [[ -f "${cfg_file}" ]]; then
            # shellcheck source=/dev/null
            source "${cfg_file}"
        fi

        # Resolve any "global" values from the global config
        resolve_global_schedules

        if [[ "${ENABLED}" != "yes" ]]; then
            lines+=("# ${share}: disabled" "")
            continue
        fi

        local safe_share="${share//\"/\\\"}"
        local share_entries=0

        lines+=("# Share: ${share}")

        # Hourly schedule
        if [[ "${SCHEDULE_HOURLY_ENABLED}" == "yes" ]]; then
            local hm
            hm="$(clamp_int "${SCHEDULE_HOURLY_MINUTE}" 0 59 0)"
            lines+=("${hm} * * * * root ${SCRIPTS_DIR}/snapshot_create.sh \"${safe_share}\" hourly >> ${LOG_FILE} 2>&1 && ${SCRIPTS_DIR}/snapshot_rotate.sh \"${safe_share}\" hourly >> ${LOG_FILE} 2>&1")
            ((entry_count++))
            ((share_entries++))
            log "INFO" "Cron entry for '${share}' (hourly): ${hm} * * * *"
        fi

        # Daily schedule
        if [[ "${SCHEDULE_DAILY_ENABLED}" == "yes" ]]; then
            local dh dm
            dh="$(clamp_int "${SCHEDULE_DAILY_HOUR}"   0 23 0)"
            dm="$(clamp_int "${SCHEDULE_DAILY_MINUTE}" 0 59 0)"
            lines+=("${dm} ${dh} * * * root ${SCRIPTS_DIR}/snapshot_create.sh \"${safe_share}\" daily >> ${LOG_FILE} 2>&1 && ${SCRIPTS_DIR}/snapshot_rotate.sh \"${safe_share}\" daily >> ${LOG_FILE} 2>&1")
            ((entry_count++))
            ((share_entries++))
            log "INFO" "Cron entry for '${share}' (daily): ${dm} ${dh} * * *"
        fi

        # Weekly schedule
        if [[ "${SCHEDULE_WEEKLY_ENABLED}" == "yes" ]]; then
            local wd wh wm
            wd="$(clamp_int "${SCHEDULE_WEEKLY_DAY}"    0  6 0)"
            wh="$(clamp_int "${SCHEDULE_WEEKLY_HOUR}"   0 23 2)"
            wm="$(clamp_int "${SCHEDULE_WEEKLY_MINUTE}" 0 59 0)"
            lines+=("${wm} ${wh} * * ${wd} root ${SCRIPTS_DIR}/snapshot_create.sh \"${safe_share}\" weekly >> ${LOG_FILE} 2>&1 && ${SCRIPTS_DIR}/snapshot_rotate.sh \"${safe_share}\" weekly >> ${LOG_FILE} 2>&1")
            ((entry_count++))
            ((share_entries++))
            log "INFO" "Cron entry for '${share}' (weekly): ${wm} ${wh} * * ${wd}"
        fi

        # Monthly schedule
        if [[ "${SCHEDULE_MONTHLY_ENABLED}" == "yes" ]]; then
            local md mh mm
            md="$(clamp_int "${SCHEDULE_MONTHLY_DAY}"    1 28  1)"
            mh="$(clamp_int "${SCHEDULE_MONTHLY_HOUR}"   0 23  3)"
            mm="$(clamp_int "${SCHEDULE_MONTHLY_MINUTE}" 0 59  0)"
            lines+=("${mm} ${mh} ${md} * * root ${SCRIPTS_DIR}/snapshot_create.sh \"${safe_share}\" monthly >> ${LOG_FILE} 2>&1 && ${SCRIPTS_DIR}/snapshot_rotate.sh \"${safe_share}\" monthly >> ${LOG_FILE} 2>&1")
            ((entry_count++))
            ((share_entries++))
            log "INFO" "Cron entry for '${share}' (monthly): ${mm} ${mh} ${md} * *"
        fi

        if [[ $share_entries -eq 0 ]]; then
            lines+=("# ${share}: no schedules enabled")
        fi

        lines+=("")

    done <<< "${shares}"

    if [[ $entry_count -eq 0 ]]; then
        log "INFO" "No active cron entries, removing cron file"
        remove_cron_file
        return 0
    fi

    # Write cron file
    printf '%s\n' "${lines[@]}" > "${CRON_FILE}"

    # Cron files in /etc/cron.d must be owned by root, not world-writable
    chmod 644 "${CRON_FILE}" 2>/dev/null

    log "INFO" "Generated cron file with ${entry_count} entries at ${CRON_FILE}"
    echo "Cron updated: ${entry_count} scheduled entries"
    return 0
}

###############################################################################
# Remove Cron File
###############################################################################

remove_cron_file() {
    if [[ -f "${CRON_FILE}" ]]; then
        rm -f "${CRON_FILE}"
        log "INFO" "Removed cron file: ${CRON_FILE}"
        echo "Cron file removed"
    fi
}

###############################################################################
# Main
###############################################################################

main() {
    load_config

    if [[ "${PLUGIN_ENABLED}" != "yes" ]]; then
        log "INFO" "Plugin is disabled, removing cron file"
        remove_cron_file
        exit 0
    fi

    generate_cron_file
    exit 0
}

main "$@"
