# BTRFS Snapshots for Unraid

Automated BTRFS snapshot management for Unraid with Windows Previous Versions support.

## Description

BTRFS Snapshots is an Unraid plugin that automates the creation and lifecycle management of BTRFS snapshots across your array shares. Snapshots are surfaced to Windows clients as "Previous Versions" through Samba's `shadow_copy2` VFS module -- no client-side configuration required.

## Features

- **Scheduled Snapshots** -- Hourly, daily, weekly, or monthly snapshot creation via cron
- **Configurable Retention** -- Independent retention policies per time interval (e.g., keep 24 hourly, 7 daily, 4 weekly, 6 monthly)
- **Windows Previous Versions** -- Automatic Samba `shadow_copy2` integration; right-click any file in Windows Explorer to restore
- **Per-Share Configuration** -- Enable/disable snapshots and set schedules independently for each BTRFS share
- **Web UI** -- Manage everything from Unraid's Settings page
- **Event Hooks** -- Automatically re-applies configuration after array start, Samba restart, or array stop
- **UTC Timestamps** -- Snapshot names use `@GMT` format required by Windows Previous Versions
- **On-Demand Snapshots** -- Create manual snapshots from the web UI at any time
- **Safe Defaults** -- Ships disabled for auto-subvolume conversion; won't modify existing data layouts without explicit opt-in

## Requirements

- **Unraid 6.9.2 or later** (required for `smb-extra.conf` ordering support)
- **BTRFS formatted disks** -- Snapshots only work on BTRFS filesystems. XFS is not supported.
- Shares must be on BTRFS-formatted cache pools or array disks formatted as BTRFS

## Installation

### Community Applications (Recommended)

1. Install the **Community Applications** plugin if you haven't already
2. Go to the **Apps** tab in Unraid
3. Search for "BTRFS Snapshots"
4. Click **Install**

### Manual Installation

1. Download the `.plg` file from the [releases page](https://github.com/AuraFross/btrfs_snapshots/releases)
2. In Unraid, go to **Plugins > Install Plugin**
3. Paste the URL to the `.plg` file or upload it directly
4. Click **Install**

## Configuration

After installation, go to **Settings > BTRFS Snapshots** in the Unraid web UI.

### Global Settings

| Setting | Default | Description |
|---------|---------|-------------|
| Enabled | Yes | Master enable/disable for the plugin |
| Default Schedule | Daily | Default snapshot schedule for new shares |
| Retention (Hours) | 24 | Number of hourly snapshots to keep |
| Retention (Days) | 7 | Number of daily snapshots to keep |
| Retention (Weeks) | 4 | Number of weekly snapshots to keep |
| Retention (Months) | 6 | Number of monthly snapshots to keep |
| Snapshot Format | `@GMT-%Y.%m.%d-%H.%M.%S` | Timestamp format (must start with `@GMT` for Windows compatibility) |
| Use UTC | Yes | Use UTC timestamps (required for Windows Previous Versions) |
| Auto Convert Subvolumes | No | Automatically convert share root to BTRFS subvolume if needed |
| Hide Snapshot Directory | Yes | Hide the `.snapshots` directory from directory listings |
| Log Level | Info | Logging verbosity (debug, info, warn, error) |

### Per-Share Settings

Each BTRFS share can be configured independently with its own:
- Enable/disable toggle
- Snapshot schedule (hourly, daily, weekly, monthly, or custom cron expression)
- Retention policy overrides
- Snapshot directory location

## Windows Previous Versions

### How It Works

The plugin configures Samba's `shadow_copy2` VFS module for each enabled share. This module presents BTRFS snapshots as "Previous Versions" to Windows clients using the standard Volume Shadow Copy protocol.

### Using Previous Versions on Windows

No client-side setup is required. To access previous versions of a file or folder:

1. Right-click the file or folder on the network share
2. Select **Properties**
3. Click the **Previous Versions** tab
4. Select a version from the list and click **Open**, **Restore**, or **Copy**

Snapshots appear as dates/times in the Previous Versions list. You can browse the entire share as it existed at that point in time.

### macOS and Linux

macOS and Linux clients cannot natively browse Previous Versions through Samba. Users on these platforms can access snapshots directly by navigating to the `.snapshots` directory at the root of each share (if `HIDE_SNAPDIR` is set to `no`).

## Troubleshooting

### No Previous Versions showing in Windows

1. Verify the share is on a BTRFS-formatted disk: check **Main > Array Devices** for the filesystem type
2. Confirm snapshots exist: go to **Settings > BTRFS Snapshots** and check the share's snapshot list
3. Check that `smb-extra.conf` contains the `shadow_copy2` configuration: **Settings > SMB > SMB Extra Configuration**
4. Restart Samba: **Settings > SMB > Apply**
5. On the Windows client, disconnect and reconnect the mapped drive, or run `net use \\server\share /delete` then reconnect
6. Check the plugin log at `/var/log/btrfs-snapshots/btrfs-snapshots.log`

### Snapshots not being created

1. Ensure the plugin is enabled in **Settings > BTRFS Snapshots**
2. Verify cron is running: `cat /etc/cron.d/btrfs-snapshots`
3. Check logs: `tail -50 /var/log/btrfs-snapshots/btrfs-snapshots.log`
4. Manually test snapshot creation: `/usr/local/emhttp/plugins/btrfs-snapshots/scripts/snapshot.sh create <share_name>`

### Snapshots consuming too much space

1. Reduce retention values in **Settings > BTRFS Snapshots**
2. Manually prune old snapshots: `/usr/local/emhttp/plugins/btrfs-snapshots/scripts/snapshot.sh prune <share_name>`
3. Check space usage with `btrfs filesystem usage /mnt/<disk>`

### Configuration lost after reboot

This should not happen -- configuration is stored on the USB flash drive at `/boot/config/plugins/btrfs-snapshots/`. However, cron jobs and Samba config are re-applied automatically via the `disks_mounted` event hook. If issues persist, check that the event scripts are executable:

```bash
chmod +x /usr/local/emhttp/plugins/btrfs-snapshots/event/*
```

## FAQ

**Can I use this with XFS-formatted disks?**
No. BTRFS snapshots are a BTRFS filesystem feature. XFS does not support snapshots. You must format your disk(s) as BTRFS to use this plugin.

**What about the "Enhanced macOS Interoperability" setting?**
The "Enhanced macOS Interoperability" Samba setting (`fruit:time machine = yes`) must be **disabled** for shares where you want Previous Versions to work. The `fruit` VFS module conflicts with `shadow_copy2`. The plugin will warn you if this setting is detected on a configured share.

**Will snapshots slow down my server?**
BTRFS snapshots are copy-on-write and nearly instantaneous to create. They have minimal performance impact. However, a large number of snapshots (hundreds) on a single subvolume can slow down certain BTRFS operations like balance and scrub.

**Can I take a snapshot before a major file operation?**
Yes. Use the "Create Snapshot" button in the web UI or run:
```bash
/usr/local/emhttp/plugins/btrfs-snapshots/scripts/snapshot.sh create <share_name>
```

**How much space do snapshots use?**
Snapshots are copy-on-write, so they initially use zero additional space. They only consume space as the original files are modified or deleted, since the snapshot retains the old data blocks. Use `btrfs filesystem usage /mnt/<disk>` to see actual space usage.

**Can I restore an entire share from a snapshot?**
Yes, but this is a manual operation. You can browse the snapshot directory and copy files back, or use `btrfs subvolume snapshot` commands to replace the current subvolume with a snapshot.

## License

MIT License. See [LICENSE](LICENSE) for details.
