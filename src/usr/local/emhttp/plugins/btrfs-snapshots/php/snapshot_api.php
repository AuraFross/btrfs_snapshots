<?php
/**
 * BTRFS Snapshots Plugin - AJAX API Endpoint
 *
 * Handles all asynchronous requests from the WebGUI.
 * Called via GET/POST with ?action=<action_name>.
 *
 * Actions:
 *   list_shares       - All user shares with BTRFS/subvolume status
 *   list_snapshots    - Snapshots for a specific share
 *   create_snapshot   - Trigger snapshot creation
 *   delete_snapshot   - Delete a specific snapshot
 *   convert_subvolume - Convert share directory to BTRFS subvolume
 *   get_status        - Overall plugin status summary
 *   save_share_config - Save per-share configuration
 */

// Unraid environment bootstrap
// Note: Unraid's auto_prepend (local_prepend.php) already handles CSRF
// validation, sets $var from state/var.ini, and configures the environment.
$docroot = $docroot ?? $_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp';
require_once "{$docroot}/webGui/include/Helpers.php";
require_once dirname(__FILE__) . '/helpers.php';

// Ensure $var is available (set by local_prepend.php for POST, load for GET)
if (!isset($var) || !is_array($var)) {
    $var = @parse_ini_file("{$docroot}/state/var.ini") ?: [];
}

// Route the request
$action = $_REQUEST['action'] ?? '';

switch ($action) {
    case 'list_shares':
        action_list_shares();
        break;
    case 'list_snapshots':
        action_list_snapshots();
        break;
    case 'create_snapshot':
        verify_csrf();
        action_create_snapshot();
        break;
    case 'delete_snapshot':
        verify_csrf();
        action_delete_snapshot();
        break;
    case 'convert_subvolume':
        verify_csrf();
        action_convert_subvolume();
        break;
    case 'get_status':
        action_get_status();
        break;
    case 'save_share_config':
        verify_csrf();
        action_save_share_config();
        break;
    default:
        json_response(['error' => 'Unknown action: ' . htmlspecialchars($action)], 400);
}

/* ─── Action Handlers ─────────────────────────────────────────────────── */

/**
 * List all user shares with BTRFS and subvolume status.
 */
function action_list_shares(): void {
    $cfg = get_plugin_config();
    $shares = get_all_shares();
    $result = [];

    foreach ($shares as $share) {
        $disks = get_share_disks($share);
        $share_cfg = get_share_config($share);
        $btrfs_disks = [];
        $subvol_status = [];

        foreach ($disks as $disk) {
            $share_path = $disk . '/' . $share;
            $is_btrfs = is_btrfs_disk($disk);
            $is_subvol = $is_btrfs ? is_btrfs_subvolume($share_path) : false;
            $btrfs_disks[] = [
                'disk'       => basename($disk),
                'path'       => $disk,
                'is_btrfs'   => $is_btrfs,
                'is_subvol'  => $is_subvol,
            ];
        }

        $any_btrfs = false;
        $all_btrfs = true;
        $all_subvol = true;
        $any_subvol = false;
        foreach ($btrfs_disks as $d) {
            if ($d['is_btrfs']) {
                $any_btrfs = true;
                if ($d['is_subvol']) {
                    $any_subvol = true;
                } else {
                    $all_subvol = false;
                }
            } else {
                $all_btrfs = false;
            }
        }

        $snap_count = count_snapshots($share);
        $last_snap = get_last_snapshot($share);

        $result[] = [
            'name'          => $share,
            'disks'         => $btrfs_disks,
            'has_btrfs'     => $any_btrfs,
            'all_btrfs'     => $any_btrfs && $all_btrfs,
            'is_subvolume'  => $any_subvol && $all_subvol,
            'needs_convert' => $any_btrfs && !$all_subvol,
            'snap_count'    => $snap_count,
            'last_snapshot' => $last_snap,
            'enabled'       => ($share_cfg['ENABLED'] === 'yes'),
            'schedule'      => $share_cfg['SCHEDULE'],
        ];
    }

    json_response(['shares' => $result]);
}

/**
 * List snapshots for a specific share.
 */
function action_list_snapshots(): void {
    $share = sanitize_share_name($_REQUEST['share'] ?? '');
    if ($share === '') {
        json_response(['error' => 'Share name is required'], 400);
    }
    $snapshots = list_share_snapshots($share);
    json_response([
        'share'     => $share,
        'snapshots' => $snapshots,
        'count'     => count($snapshots),
    ]);
}

/**
 * Create a snapshot for a share.
 */
function action_create_snapshot(): void {
    $share = sanitize_share_name($_POST['share'] ?? '');
    if ($share === '') {
        json_response(['error' => 'Share name is required'], 400);
    }

    $cfg = get_plugin_config();
    if ($cfg['ENABLED'] !== 'yes') {
        json_response(['error' => 'Plugin is disabled'], 403);
    }

    $script = BTRFS_SNAP_SCRIPTS . '/snapshot_create.sh';
    if (!file_exists($script)) {
        json_response(['error' => 'Snapshot creation script not found'], 500);
    }

    $escaped_share = escapeshellarg($share);
    $cmd = "bash " . escapeshellarg($script) . " {$escaped_share} 2>&1";
    $output = [];
    $retval = -1;
    exec($cmd, $output, $retval);

    btrfs_snap_log("Create snapshot for share '{$share}': exit={$retval}", $retval === 0 ? 'INFO' : 'ERROR');

    if ($retval !== 0) {
        json_response([
            'error'  => 'Snapshot creation failed',
            'output' => implode("\n", $output),
            'code'   => $retval,
        ], 500);
    }

    json_response([
        'success' => true,
        'message' => "Snapshot created for '{$share}'",
        'output'  => implode("\n", $output),
    ]);
}

/**
 * Delete a specific snapshot.
 * Delegates to snapshot_delete.sh which performs strict path validation.
 */
function action_delete_snapshot(): void {
    $path = $_POST['path'] ?? '';

    // Basic pre-validation before handing off to the script
    if ($path === '' || strpos($path, '..') !== false) {
        json_response(['error' => 'Invalid snapshot path'], 400);
    }

    if (!validate_mount_path($path)) {
        json_response(['error' => 'Path is not under a valid mount point'], 403);
    }

    $script = BTRFS_SNAP_SCRIPTS . '/snapshot_delete.sh';
    if (!file_exists($script)) {
        json_response(['error' => 'Snapshot deletion script not found'], 500);
    }

    $escaped = escapeshellarg($path);
    $cmd = "bash " . escapeshellarg($script) . " {$escaped} 2>&1";
    $output = [];
    $retval = -1;
    exec($cmd, $output, $retval);

    btrfs_snap_log("Delete snapshot '{$path}': exit={$retval}", $retval === 0 ? 'INFO' : 'ERROR');

    if ($retval !== 0) {
        $error_msg = 'Failed to delete snapshot';
        if ($retval === 2) $error_msg = 'Path validation failed (security block)';
        if ($retval === 3) $error_msg = 'Snapshot deletion failed';
        json_response([
            'error'  => $error_msg,
            'output' => implode("\n", $output),
            'code'   => $retval,
        ], $retval === 2 ? 403 : 500);
    }

    json_response([
        'success' => true,
        'message' => 'Snapshot deleted',
        'path'    => $path,
    ]);
}

/**
 * Convert a share directory to a BTRFS subvolume.
 * The script iterates all disks for the given share automatically.
 */
function action_convert_subvolume(): void {
    $share = sanitize_share_name($_POST['share'] ?? '');

    if ($share === '') {
        json_response(['error' => 'Share name is required'], 400);
    }

    $script = BTRFS_SNAP_SCRIPTS . '/subvolume_check.sh';
    if (!file_exists($script)) {
        json_response(['error' => 'Subvolume conversion script not found'], 500);
    }

    $escaped_share = escapeshellarg($share);
    // Script runs non-interactively (no tty) so it skips confirmation prompt
    $cmd = "bash " . escapeshellarg($script) . " --convert {$escaped_share} 2>&1";
    $output = [];
    $retval = -1;
    exec($cmd, $output, $retval);

    btrfs_snap_log("Convert subvolume share='{$share}': exit={$retval}",
        $retval === 0 ? 'INFO' : 'ERROR');

    if ($retval !== 0) {
        $error_msg = 'Subvolume conversion failed';
        if ($retval === 2) $error_msg = 'Conversion failed (rollback attempted)';
        if ($retval === 3) $error_msg = 'Share not found on any disk';
        json_response([
            'error'  => $error_msg,
            'output' => implode("\n", $output),
            'code'   => $retval,
        ], 500);
    }

    json_response([
        'success' => true,
        'message' => "Share '{$share}' converted to subvolume on all eligible disks",
        'output'  => implode("\n", $output),
    ]);
}

/**
 * Get overall plugin status.
 */
function action_get_status(): void {
    $cfg = get_plugin_config();
    $shares = get_all_shares();
    $total_snapshots = 0;
    $configured_shares = 0;
    $btrfs_shares = 0;

    foreach ($shares as $share) {
        $share_cfg = get_share_config($share);
        if ($share_cfg['ENABLED'] === 'yes' && $share_cfg['SCHEDULE'] !== 'global') {
            $configured_shares++;
        }
        $snap_count = count_snapshots($share);
        $total_snapshots += $snap_count;

        $disks = get_share_disks($share);
        foreach ($disks as $disk) {
            if (is_btrfs_disk($disk)) {
                $btrfs_shares++;
                break;
            }
        }
    }

    // Estimate total snapshot disk usage
    $disk_usage = '—';
    $du_output = @shell_exec("du -sh /mnt/*/.*snapshots* /mnt/*/*/.snapshots 2>/dev/null | tail -1");
    if ($du_output) {
        $disk_usage = trim(explode("\t", $du_output)[0] ?? '—');
    }

    json_response([
        'enabled'           => ($cfg['ENABLED'] === 'yes'),
        'schedule'          => $cfg['DEFAULT_SCHEDULE'],
        'total_shares'      => count($shares),
        'btrfs_shares'      => $btrfs_shares,
        'configured_shares' => $configured_shares,
        'total_snapshots'   => $total_snapshots,
        'disk_usage'        => $disk_usage,
        'config'            => $cfg,
    ]);
}

/**
 * Save per-share configuration.
 */
function action_save_share_config(): void {
    $share = sanitize_share_name($_POST['share'] ?? '');
    if ($share === '') {
        json_response(['error' => 'Share name is required'], 400);
    }

    $config = [
        'ENABLED'          => ($_POST['ENABLED'] ?? 'yes') === 'yes' ? 'yes' : 'no',
        'SCHEDULE'         => $_POST['SCHEDULE'] ?? 'global',
        'RETENTION_HOURS'  => intval($_POST['RETENTION_HOURS'] ?? 0),
        'RETENTION_DAYS'   => intval($_POST['RETENTION_DAYS'] ?? 0),
        'RETENTION_WEEKS'  => intval($_POST['RETENTION_WEEKS'] ?? 0),
        'RETENTION_MONTHS' => intval($_POST['RETENTION_MONTHS'] ?? 0),
        'SNAPDIR'          => preg_replace('/[^a-zA-Z0-9_\-\.]/', '', $_POST['SNAPDIR'] ?? '.snapshots'),
        'SMB_SHADOW_COPY'  => ($_POST['SMB_SHADOW_COPY'] ?? 'no') === 'yes' ? 'yes' : 'no',
    ];

    // Validate schedule value
    $valid_schedules = array_keys(BTRFS_SNAP_SCHEDULES);
    $valid_schedules[] = 'global';
    if (!in_array($config['SCHEDULE'], $valid_schedules)) {
        $config['SCHEDULE'] = 'global';
    }

    if (!save_share_config($share, $config)) {
        json_response(['error' => 'Failed to save share configuration'], 500);
    }

    btrfs_snap_log("Saved config for share '{$share}'");

    // Re-run Samba configuration if shadow_copy2 setting may have changed
    $smb_script = BTRFS_SNAP_SCRIPTS . '/smb_configure.sh';
    if (file_exists($smb_script)) {
        exec("bash " . escapeshellarg($smb_script) . " 2>&1", $smb_output, $smb_ret);
        if ($smb_ret !== 0) {
            btrfs_snap_log("smb_configure.sh failed: " . implode("\n", $smb_output), 'WARN');
        }
    }

    json_response([
        'success' => true,
        'message' => "Configuration saved for '{$share}'",
        'config'  => $config,
    ]);
}
