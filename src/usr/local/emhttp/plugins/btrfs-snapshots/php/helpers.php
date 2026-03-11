<?php
/**
 * BTRFS Snapshots Plugin - Shared Helper Functions
 *
 * Common utilities used across the plugin's PHP pages and API endpoints.
 * Provides configuration management, filesystem helpers, and input validation.
 */

// Plugin constants
define('BTRFS_SNAP_PLUGIN', 'btrfs-snapshots');
define('BTRFS_SNAP_CFG_DIR', '/boot/config/plugins/' . BTRFS_SNAP_PLUGIN);
define('BTRFS_SNAP_CFG_FILE', BTRFS_SNAP_CFG_DIR . '/' . BTRFS_SNAP_PLUGIN . '.cfg');
define('BTRFS_SNAP_SHARES_DIR', BTRFS_SNAP_CFG_DIR . '/shares');
define('BTRFS_SNAP_SCRIPTS', '/usr/local/emhttp/plugins/' . BTRFS_SNAP_PLUGIN . '/scripts');
define('BTRFS_SNAP_LOG', '/var/log/btrfs-snapshots.log');

/**
 * Get valid mount path prefixes dynamically from /proc/mounts.
 * Includes all BTRFS mounts under /mnt/ plus /mnt/user/.
 * Results are cached for the duration of the request.
 */
function get_valid_mount_prefixes(): array {
    static $prefixes = null;
    if ($prefixes !== null) return $prefixes;
    $prefixes = ['/mnt/user/'];
    $mounts = @file_get_contents('/proc/mounts') ?: '';
    foreach (explode("\n", $mounts) as $line) {
        $parts = preg_split('/\s+/', $line);
        if (count($parts) >= 3 && strpos($parts[1], '/mnt/') === 0 && $parts[2] === 'btrfs') {
            $prefixes[] = $parts[1];
        }
    }
    // Fallback: always allow /mnt/disk and /mnt/cache even if not yet mounted
    $prefixes[] = '/mnt/disk';
    $prefixes[] = '/mnt/cache';
    return array_unique($prefixes);
}

// Schedule options
define('BTRFS_SNAP_SCHEDULES', [
    'disabled'     => 'Disabled',
    'every15min'   => 'Every 15 Minutes',
    'hourly'       => 'Hourly',
    'every6hours'  => 'Every 6 Hours',
    'daily'        => 'Daily',
    'weekly'       => 'Weekly',
]);

/**
 * Default plugin configuration values.
 */
function btrfs_snap_defaults(): array {
    return [
        'ENABLED'                  => 'yes',
        'SCHEDULE_HOURLY_ENABLED'  => 'no',
        'SCHEDULE_HOURLY_MINUTE'   => '0',
        'SCHEDULE_HOURLY_RETAIN'   => '0',
        'SCHEDULE_DAILY_ENABLED'   => 'yes',
        'SCHEDULE_DAILY_HOUR'      => '0',
        'SCHEDULE_DAILY_MINUTE'    => '0',
        'SCHEDULE_DAILY_RETAIN'    => '2',
        'SCHEDULE_WEEKLY_ENABLED'  => 'yes',
        'SCHEDULE_WEEKLY_DAY'      => '0',
        'SCHEDULE_WEEKLY_HOUR'     => '2',
        'SCHEDULE_WEEKLY_MINUTE'   => '0',
        'SCHEDULE_WEEKLY_RETAIN'   => '1',
        'SCHEDULE_MONTHLY_ENABLED' => 'no',
        'SCHEDULE_MONTHLY_DAY'     => '1',
        'SCHEDULE_MONTHLY_HOUR'    => '3',
        'SCHEDULE_MONTHLY_MINUTE'  => '0',
        'SCHEDULE_MONTHLY_RETAIN'  => '0',
        'SNAPSHOT_FORMAT'          => '@GMT-%Y.%m.%d-%H.%M.%S',
        'USE_UTC'                  => 'yes',
        'AUTO_CONVERT_SUBVOLUMES'  => 'no',
        'HIDE_SNAPDIR'             => 'yes',
        'LOG_LEVEL'                => 'info',
    ];
}

/**
 * Read global plugin configuration, merged with defaults.
 */
function get_plugin_config(): array {
    $defaults = btrfs_snap_defaults();
    if (function_exists('parse_plugin_cfg')) {
        $cfg = parse_plugin_cfg(BTRFS_SNAP_PLUGIN);
        return array_merge($defaults, $cfg ?: []);
    }
    // Fallback: parse cfg file directly
    $cfg = [];
    if (file_exists(BTRFS_SNAP_CFG_FILE)) {
        $lines = file(BTRFS_SNAP_CFG_FILE, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        foreach ($lines as $line) {
            $line = trim($line);
            if ($line === '' || $line[0] === '#') continue;
            if (strpos($line, '=') !== false) {
                list($key, $val) = explode('=', $line, 2);
                $cfg[trim($key)] = trim(trim($val), '"\'');
            }
        }
    }
    return array_merge($defaults, $cfg);
}

/**
 * Read per-share configuration. Returns defaults merged with saved overrides.
 */
function get_share_config(string $share): array {
    $share = sanitize_share_name($share);
    $defaults = [
        'ENABLED'                  => 'yes',
        'SNAPDIR'                  => '.snapshots',
        'SMB_SHADOW_COPY'          => 'no',
        'SCHEDULE_HOURLY_ENABLED'  => 'global',
        'SCHEDULE_HOURLY_MINUTE'   => '',
        'SCHEDULE_HOURLY_RETAIN'   => '',
        'SCHEDULE_DAILY_ENABLED'   => 'global',
        'SCHEDULE_DAILY_HOUR'      => '',
        'SCHEDULE_DAILY_MINUTE'    => '',
        'SCHEDULE_DAILY_RETAIN'    => '',
        'SCHEDULE_WEEKLY_ENABLED'  => 'global',
        'SCHEDULE_WEEKLY_DAY'      => '',
        'SCHEDULE_WEEKLY_HOUR'     => '',
        'SCHEDULE_WEEKLY_MINUTE'   => '',
        'SCHEDULE_WEEKLY_RETAIN'   => '',
        'SCHEDULE_MONTHLY_ENABLED' => 'global',
        'SCHEDULE_MONTHLY_DAY'     => '',
        'SCHEDULE_MONTHLY_HOUR'    => '',
        'SCHEDULE_MONTHLY_MINUTE'  => '',
        'SCHEDULE_MONTHLY_RETAIN'  => '',
    ];
    $cfg_file = BTRFS_SNAP_SHARES_DIR . '/' . $share . '.cfg';
    $cfg = [];
    if (file_exists($cfg_file)) {
        $lines = file($cfg_file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        foreach ($lines as $line) {
            $line = trim($line);
            if ($line === '' || $line[0] === '#') continue;
            if (strpos($line, '=') !== false) {
                list($key, $val) = explode('=', $line, 2);
                $cfg[trim($key)] = trim(trim($val), '"\'');
            }
        }
    }
    return array_merge($defaults, $cfg);
}

/**
 * Save per-share configuration to disk.
 */
function save_share_config(string $share, array $config): bool {
    $share = sanitize_share_name($share);
    if ($share === '') return false;
    @mkdir(BTRFS_SNAP_SHARES_DIR, 0755, true);
    $cfg_file = BTRFS_SNAP_SHARES_DIR . '/' . $share . '.cfg';
    $lines = [];
    $allowed_keys = [
        'ENABLED', 'SNAPDIR', 'SMB_SHADOW_COPY',
        'SCHEDULE_HOURLY_ENABLED', 'SCHEDULE_HOURLY_MINUTE', 'SCHEDULE_HOURLY_RETAIN',
        'SCHEDULE_DAILY_ENABLED',   'SCHEDULE_DAILY_HOUR',   'SCHEDULE_DAILY_MINUTE',   'SCHEDULE_DAILY_RETAIN',
        'SCHEDULE_WEEKLY_ENABLED',  'SCHEDULE_WEEKLY_DAY',   'SCHEDULE_WEEKLY_HOUR',    'SCHEDULE_WEEKLY_MINUTE',  'SCHEDULE_WEEKLY_RETAIN',
        'SCHEDULE_MONTHLY_ENABLED', 'SCHEDULE_MONTHLY_DAY',  'SCHEDULE_MONTHLY_HOUR',   'SCHEDULE_MONTHLY_MINUTE', 'SCHEDULE_MONTHLY_RETAIN',
    ];
    foreach ($allowed_keys as $key) {
        if (isset($config[$key])) {
            $val = preg_replace('/["\'\n\r]/', '', $config[$key]);
            $lines[] = $key . '="' . $val . '"';
        }
    }
    return file_put_contents($cfg_file, implode("\n", $lines) . "\n") !== false;
}

/**
 * List all Unraid user shares.
 * Returns array of share names found in /mnt/user/.
 */
function get_all_shares(): array {
    $shares = [];
    $user_dir = '/mnt/user';
    if (!is_dir($user_dir)) return $shares;
    $entries = scandir($user_dir);
    foreach ($entries as $entry) {
        if ($entry === '.' || $entry === '..') continue;
        $path = $user_dir . '/' . $entry;
        if (is_dir($path) && $entry[0] !== '.') {
            $shares[] = $entry;
        }
    }
    sort($shares, SORT_NATURAL | SORT_FLAG_CASE);
    return $shares;
}

/**
 * Check if a given mount path resides on a BTRFS filesystem.
 */
function is_btrfs_disk(string $path): bool {
    if (!validate_mount_path($path)) return false;
    $escaped = escapeshellarg($path);
    $out = trim(@shell_exec("stat -f -c '%T' {$escaped} 2>/dev/null") ?: '');
    if (strtolower($out) === 'btrfs') return true;
    // Fallback: check /proc/mounts
    $mounts = @file_get_contents('/proc/mounts') ?: '';
    foreach (explode("\n", $mounts) as $line) {
        $parts = preg_split('/\s+/', $line);
        if (count($parts) >= 3 && strpos($path, $parts[1]) === 0 && $parts[2] === 'btrfs') {
            return true;
        }
    }
    return false;
}

/**
 * Check if a path is a BTRFS subvolume.
 */
function is_btrfs_subvolume(string $path): bool {
    if (!validate_mount_path($path)) return false;
    $escaped = escapeshellarg($path);
    $ret = -1;
    @exec("btrfs subvolume show {$escaped} >/dev/null 2>&1", $output, $ret);
    return ($ret === 0);
}

/**
 * Get all BTRFS mount points under /mnt/ from /proc/mounts.
 * Returns array of mount paths (e.g., ['/mnt/cache', '/mnt/ssd', '/mnt/disk1']).
 * Results are cached for the duration of the request.
 */
function get_btrfs_mounts(): array {
    static $mounts = null;
    if ($mounts !== null) return $mounts;
    $mounts = [];
    $proc = @file_get_contents('/proc/mounts') ?: '';
    foreach (explode("\n", $proc) as $line) {
        $parts = preg_split('/\s+/', $line);
        if (count($parts) >= 3 && strpos($parts[1], '/mnt/') === 0 && $parts[2] === 'btrfs') {
            // Skip Docker overlay, nested mounts, etc.
            $mount = $parts[1];
            if (substr_count($mount, '/') <= 2) {
                $mounts[] = $mount;
            }
        }
    }
    return $mounts;
}

/**
 * Get disks/pools where a share has data.
 * Dynamically discovers all mount points under /mnt/ (BTRFS and non-BTRFS).
 * Returns array of disk paths (e.g., ['/mnt/disk1', '/mnt/cache', '/mnt/ssd']).
 */
function get_share_disks(string $share): array {
    $share = sanitize_share_name($share);
    if ($share === '') return [];
    $disks = [];
    $skip = ['user', 'user0', 'remotes', 'addons', 'disks', 'rootshare'];
    $mnt_entries = @scandir('/mnt') ?: [];
    foreach ($mnt_entries as $entry) {
        if ($entry === '.' || $entry === '..' || in_array($entry, $skip)) continue;
        $path = '/mnt/' . $entry . '/' . $share;
        if (is_dir($path)) {
            $disks[] = '/mnt/' . $entry;
        }
    }
    return $disks;
}

/**
 * Count total snapshots for a share across all disks.
 */
function count_snapshots(string $share): int {
    $share = sanitize_share_name($share);
    if ($share === '') return 0;
    $count = 0;
    $share_cfg = get_share_config($share);
    $snapdir = $share_cfg['SNAPDIR'] ?: '.snapshots';
    $disks = get_share_disks($share);
    foreach ($disks as $disk) {
        $snap_path = $disk . '/' . $share . '/' . $snapdir;
        if (is_dir($snap_path)) {
            $entries = @scandir($snap_path) ?: [];
            foreach ($entries as $entry) {
                if ($entry !== '.' && $entry !== '..' && is_dir($snap_path . '/' . $entry)) {
                    $count++;
                }
            }
        }
    }
    return $count;
}

/**
 * Parse a @GMT-YYYY.MM.DD-HH.MM.SS snapshot name into a UTC epoch integer.
 * Returns 0 if the name doesn't match the expected format.
 */
function gmt_name_to_epoch(string $name): int {
    if (preg_match('/@GMT-(\d{4})\.(\d{2})\.(\d{2})-(\d{2})\.(\d{2})\.(\d{2})/', $name, $m)) {
        $epoch = gmmktime((int)$m[4], (int)$m[5], (int)$m[6], (int)$m[2], (int)$m[3], (int)$m[1]);
        return $epoch !== false ? (int)$epoch : 0;
    }
    return 0;
}

/**
 * Get the most recent snapshot timestamp for a share.
 * Returns UTC date string or null if no snapshots.
 */
function get_last_snapshot(string $share): ?string {
    $share = sanitize_share_name($share);
    if ($share === '') return null;
    $share_cfg = get_share_config($share);
    $snapdir = $share_cfg['SNAPDIR'] ?: '.snapshots';
    $latest = 0;
    $disks = get_share_disks($share);
    foreach ($disks as $disk) {
        $snap_path = $disk . '/' . $share . '/' . $snapdir;
        if (!is_dir($snap_path)) continue;
        $entries = @scandir($snap_path) ?: [];
        foreach ($entries as $entry) {
            if ($entry === '.' || $entry === '..') continue;
            if (!is_dir($snap_path . '/' . $entry)) continue;
            $epoch = gmt_name_to_epoch($entry);
            if ($epoch > $latest) $latest = $epoch;
        }
    }
    return $latest > 0 ? gmdate('Y-m-d H:i:s', $latest) . ' UTC' : null;
}

/**
 * List all snapshots for a share with metadata.
 * Returns array of [name, path, disk, created, size_estimate].
 */
function list_share_snapshots(string $share): array {
    $share = sanitize_share_name($share);
    if ($share === '') return [];
    $snapshots = [];
    $share_cfg = get_share_config($share);
    $snapdir = $share_cfg['SNAPDIR'] ?: '.snapshots';
    $disks = get_share_disks($share);
    foreach ($disks as $disk) {
        $snap_path = $disk . '/' . $share . '/' . $snapdir;
        if (!is_dir($snap_path)) continue;
        $entries = @scandir($snap_path) ?: [];
        foreach ($entries as $entry) {
            if ($entry === '.' || $entry === '..') continue;
            $full = $snap_path . '/' . $entry;
            if (!is_dir($full)) continue;
            $epoch = gmt_name_to_epoch($entry);
            $created = $epoch > 0
                ? gmdate('Y-m-d H:i:s', $epoch) . ' UTC'
                : date('Y-m-d H:i:s', filemtime($full));
            // Get snapshot size via btrfs if available
            $size = '—';
            $escaped = escapeshellarg($full);
            $info = @shell_exec("btrfs subvolume show {$escaped} 2>/dev/null");
            if ($info && preg_match('/Exclusive\s*:\s*(.+)/i', $info, $m)) {
                $size = trim($m[1]);
            }
            $snapshots[] = [
                'name'    => $entry,
                'path'    => $full,
                'disk'    => basename($disk),
                'created' => $created,
                'epoch'   => $epoch,
                'size'    => $size,
            ];
        }
    }
    // Sort by epoch descending (newest first)
    usort($snapshots, function ($a, $b) {
        return $b['epoch'] <=> $a['epoch'];
    });
    return $snapshots;
}

/**
 * Format bytes into human-readable string.
 */
function format_bytes(int $bytes, int $precision = 2): string {
    if ($bytes <= 0) return '0 B';
    $units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    $pow = floor(log($bytes, 1024));
    $pow = min($pow, count($units) - 1);
    return round($bytes / pow(1024, $pow), $precision) . ' ' . $units[$pow];
}

/**
 * Sanitize a share name: allow only alphanumeric, dash, underscore, space, period.
 */
function sanitize_share_name(string $name): string {
    $name = trim($name);
    $name = preg_replace('/[^a-zA-Z0-9_\-\. ]/', '', $name);
    // Prevent directory traversal
    while (strpos($name, '..') !== false) {
        $name = str_replace('..', '', $name);
    }
    return trim($name);
}

/**
 * Validate that a mount path starts with an allowed prefix.
 */
function validate_mount_path(string $path): bool {
    $path = realpath($path) ?: $path;
    foreach (get_valid_mount_prefixes() as $prefix) {
        if (strpos($path, $prefix) === 0) return true;
    }
    return false;
}

/**
 * Validate a snapshot path: must be under a valid mount, inside a snapdir, and must exist.
 */
function validate_snapshot_path(string $path): bool {
    // Must not contain traversal
    if (strpos($path, '..') !== false) return false;
    // Must start with a valid mount prefix
    if (!validate_mount_path($path)) return false;
    // Must exist as a directory
    if (!is_dir($path)) return false;
    // Must be a btrfs subvolume (snapshots are subvolumes)
    return is_btrfs_subvolume($path);
}

/**
 * Verify Unraid CSRF token for POST requests.
 *
 * Note: Unraid's auto_prepend (local_prepend.php) already validates
 * the CSRF token on all POST requests and unsets $_POST['csrf_token'].
 * Invalid tokens are terminated before this code runs. This function
 * is kept as a no-op for safety in case it's called elsewhere.
 */
function verify_csrf(): void {
    // Handled by Unraid's local_prepend.php — no additional check needed.
}

/**
 * Send a JSON response and exit.
 */
function json_response(array $data, int $code = 200): void {
    http_response_code($code);
    header('Content-Type: application/json');
    echo json_encode($data, JSON_UNESCAPED_SLASHES);
    exit;
}

/**
 * Log a message to the plugin log file.
 */
function btrfs_snap_log(string $message, string $level = 'INFO'): void {
    $ts = date('Y-m-d H:i:s');
    $line = "[{$ts}] [{$level}] {$message}\n";
    @file_put_contents(BTRFS_SNAP_LOG, $line, FILE_APPEND | LOCK_EX);
}
