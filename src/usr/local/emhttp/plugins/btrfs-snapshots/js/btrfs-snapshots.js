/**
 * BTRFS Snapshots Plugin - Client-Side JavaScript
 *
 * jQuery-based (Unraid bundles jQuery). Handles AJAX communication with
 * the PHP API, table rendering, confirmation dialogs, and auto-refresh.
 */

var BtrfsSnapshots = (function ($) {
    'use strict';

    // ─── Configuration ───────────────────────────────────────────────
    var API_URL = '/plugins/btrfs-snapshots/php/snapshot_api.php';
    var REFRESH_INTERVAL = 5000; // 5 seconds (only used during active operations)
    var refreshTimer = null;
    var operationInProgress = false;
    var csrfToken = '';

    // ─── Initialization ──────────────────────────────────────────────
    function init(csrf) {
        csrfToken = csrf || '';
        loadShares();
        // No auto-refresh on load — only refreshes during active operations
    }

    // ─── AJAX Helpers ────────────────────────────────────────────────
    function apiGet(action, params, callback) {
        params = params || {};
        params.action = action;
        $.ajax({
            url: API_URL,
            method: 'GET',
            data: params,
            dataType: 'json',
            success: function (data) {
                if (callback) callback(null, data);
            },
            error: function (xhr) {
                var msg = 'Request failed';
                try {
                    var resp = JSON.parse(xhr.responseText);
                    msg = resp.error || msg;
                } catch (e) {}
                if (callback) callback(msg, null);
            }
        });
    }

    function apiPost(action, params, callback) {
        params = params || {};
        params.action = action;
        params.csrf_token = csrfToken;
        $.ajax({
            url: API_URL,
            method: 'POST',
            data: params,
            dataType: 'json',
            success: function (data) {
                if (callback) callback(null, data);
            },
            error: function (xhr) {
                var msg = 'Request failed';
                try {
                    var resp = JSON.parse(xhr.responseText);
                    msg = resp.error || msg;
                } catch (e) {}
                if (callback) callback(msg, null);
            }
        });
    }

    // ─── Load Shares Table ───────────────────────────────────────────
    function loadShares() {
        var $table = $('#snap-shares-tbody');
        var $status = $('#snap-status-area');

        if (!$table.length) return;

        $table.html('<tr><td colspan="7" class="snap-loading"><span class="snap-spinner"></span> Loading shares...</td></tr>');

        apiGet('list_shares', {}, function (err, data) {
            if (err) {
                $table.html('<tr><td colspan="7" class="snap-empty"><i class="fa fa-exclamation-triangle"></i><p>' + escapeHtml(err) + '</p></td></tr>');
                return;
            }

            var shares = data.shares || [];
            if (shares.length === 0) {
                $table.html('<tr><td colspan="7" class="snap-empty"><i class="fa fa-folder-open-o"></i><p>No shares found.</p></td></tr>');
                return;
            }

            var html = '';
            for (var i = 0; i < shares.length; i++) {
                html += renderShareRow(shares[i]);
            }
            $table.html(html);
        });

        // Also refresh status cards
        refreshStatus();
    }

    function renderShareRow(share) {
        var name = escapeHtml(share.name);
        var diskTags = '';
        for (var d = 0; d < share.disks.length; d++) {
            var disk = share.disks[d];
            var cls = disk.is_btrfs ? 'btrfs-yes' : 'btrfs-no';
            diskTags += '<span class="snap-disk-tag ' + cls + '">' + escapeHtml(disk.disk) + '</span> ';
        }
        if (diskTags === '') diskTags = '<span class="snap-disk-tag btrfs-no">—</span>';

        var btrfsStatus;
        if (share.all_btrfs) {
            btrfsStatus = '<span class="badge-ok">Yes</span>';
        } else if (share.has_btrfs) {
            btrfsStatus = '<span class="badge-warning" title="Some disks are not BTRFS — data on non-BTRFS disks will NOT be snapshotted">Partial</span>';
        } else {
            btrfsStatus = '<span class="badge-error">No</span>';
        }

        var subvolStatus;
        if (!share.has_btrfs) {
            subvolStatus = '<span class="badge-info">N/A</span>';
        } else if (share.is_subvolume) {
            if (share.all_btrfs) {
                subvolStatus = '<span class="badge-ok">Yes</span>';
            } else {
                subvolStatus = '<span class="badge-warning" title="Only BTRFS disks are snapshotted — non-BTRFS disks are unprotected">Partial</span>';
            }
        } else {
            subvolStatus = '<span class="badge-warning">No</span>';
        }

        var snapCount = share.snap_count || 0;
        var lastSnap = share.last_snapshot || '—';

        // Actions
        var actions = '';
        if (share.has_btrfs && share.is_subvolume) {
            actions += '<button class="snap-btn snap-btn-success" onclick="BtrfsSnapshots.createSnapshot(\'' + escapeAttr(share.name) + '\')" title="Create Snapshot Now"><i class="fa fa-camera"></i></button> ';
            actions += '<button class="snap-btn snap-btn-primary" onclick="BtrfsSnapshots.loadSnapshots(\'' + escapeAttr(share.name) + '\')" title="View Snapshots"><i class="fa fa-list"></i></button> ';
        }
        if (share.needs_convert) {
            actions += '<button class="snap-btn snap-btn-warning" onclick="BtrfsSnapshots.convertSubvolume(\'' + escapeAttr(share.name) + '\')" title="Convert to Subvolume"><i class="fa fa-exchange"></i></button> ';
        }
        actions += '<a class="snap-btn snap-btn-primary" href="/Utilities/BtrfsSnapshotsShare?share=' + encodeURIComponent(share.name) + '" title="Configure"><i class="fa fa-cog"></i></a>';

        return '<tr>' +
            '<td><strong>' + name + '</strong></td>' +
            '<td>' + diskTags + '</td>' +
            '<td>' + btrfsStatus + '</td>' +
            '<td>' + subvolStatus + '</td>' +
            '<td>' + snapCount + '</td>' +
            '<td>' + escapeHtml(lastSnap) + '</td>' +
            '<td class="col-actions">' + actions + '</td>' +
            '</tr>';
    }

    // ─── Refresh Status Cards ────────────────────────────────────────
    function refreshStatus() {
        apiGet('get_status', {}, function (err, data) {
            if (err) return;
            $('#snap-stat-enabled').text(data.enabled ? 'Enabled' : 'Disabled')
                .closest('.snap-status-card')
                .removeClass('status-enabled status-disabled')
                .addClass(data.enabled ? 'status-enabled' : 'status-disabled');
            $('#snap-stat-shares').text(data.btrfs_shares || 0);
            $('#snap-stat-snapshots').text(data.total_snapshots || 0);
            $('#snap-stat-schedule').text(formatSchedule(data.schedule));
        });
    }

    // ─── Load Snapshots (Modal) ──────────────────────────────────────
    function loadSnapshots(share) {
        // Build and show modal
        var modalHtml =
            '<div class="snap-modal-overlay" id="snap-modal-overlay">' +
            '<div class="snap-modal">' +
            '<div class="snap-modal-header">' +
            '<h3><i class="fa fa-camera-retro"></i> Snapshots: ' + escapeHtml(share) + '</h3>' +
            '<button class="snap-modal-close" onclick="BtrfsSnapshots.closeModal()">&times;</button>' +
            '</div>' +
            '<div class="snap-modal-body" id="snap-modal-body">' +
            '<div class="snap-loading"><span class="snap-spinner"></span> Loading snapshots...</div>' +
            '</div>' +
            '<div class="snap-modal-footer">' +
            '<button class="snap-btn snap-btn-success" onclick="BtrfsSnapshots.createSnapshot(\'' + escapeAttr(share) + '\')"><i class="fa fa-camera"></i> Create Snapshot</button> ' +
            '<button class="snap-btn" onclick="BtrfsSnapshots.closeModal()">Close</button>' +
            '</div>' +
            '</div></div>';

        // Remove existing modal if any
        $('#snap-modal-overlay').remove();
        $('body').append(modalHtml);

        apiGet('list_snapshots', { share: share }, function (err, data) {
            var $body = $('#snap-modal-body');
            if (err) {
                $body.html('<div class="snap-empty"><i class="fa fa-exclamation-triangle"></i><p>' + escapeHtml(err) + '</p></div>');
                return;
            }

            var snapshots = data.snapshots || [];
            if (snapshots.length === 0) {
                $body.html('<div class="snap-empty"><i class="fa fa-camera-retro"></i><p>No snapshots found for this share.</p></div>');
                return;
            }

            var html = '<div class="snap-table-wrap"><table class="tablesorter snap-table">' +
                '<thead><tr><th>Name</th><th>Disk</th><th>Created</th><th>Size</th><th>Actions</th></tr></thead><tbody>';

            for (var i = 0; i < snapshots.length; i++) {
                var s = snapshots[i];
                html += '<tr>' +
                    '<td>' + escapeHtml(s.name) + '</td>' +
                    '<td><span class="snap-disk-tag btrfs-yes">' + escapeHtml(s.disk) + '</span></td>' +
                    '<td>' + escapeHtml(s.created) + '</td>' +
                    '<td>' + escapeHtml(s.size) + '</td>' +
                    '<td class="col-actions">' +
                    '<button class="snap-btn snap-btn-danger" onclick="BtrfsSnapshots.deleteSnapshot(\'' + escapeAttr(s.path) + '\', \'' + escapeAttr(share) + '\')" title="Delete Snapshot"><i class="fa fa-trash"></i></button>' +
                    '</td></tr>';
            }

            html += '</tbody></table></div>';
            $body.html(html);
        });
    }

    function closeModal() {
        $('#snap-modal-overlay').remove();
    }

    // ─── Create Snapshot ─────────────────────────────────────────────
    function createSnapshot(share) {
        confirmDialog(
            'Create Snapshot',
            'Create a new snapshot for share "' + share + '"?',
            'info',
            function () {
                showNotification('Creating snapshot for "' + share + '"...', 'info');
                startAutoRefresh();
                apiPost('create_snapshot', { share: share }, function (err, data) {
                    stopAutoRefresh();
                    if (err) {
                        showNotification('Failed to create snapshot: ' + err, 'error');
                        return;
                    }
                    showNotification(data.message || 'Snapshot created', 'success');
                    loadShares();
                    // Refresh modal if open
                    if ($('#snap-modal-overlay').length) {
                        loadSnapshots(share);
                    }
                });
            }
        );
    }

    // ─── Delete Snapshot ─────────────────────────────────────────────
    function deleteSnapshot(path, share) {
        confirmDialog(
            'Delete Snapshot',
            'Are you sure you want to permanently delete this snapshot?\n\n' + path + '\n\nThis action cannot be undone.',
            'warning',
            function () {
                showNotification('Deleting snapshot...', 'info');
                startAutoRefresh();
                apiPost('delete_snapshot', { path: path }, function (err, data) {
                    stopAutoRefresh();
                    if (err) {
                        showNotification('Failed to delete snapshot: ' + err, 'error');
                        return;
                    }
                    showNotification('Snapshot deleted', 'success');
                    loadShares();
                    if (share && $('#snap-modal-overlay').length) {
                        loadSnapshots(share);
                    }
                });
            }
        );
    }

    // ─── Convert to Subvolume ────────────────────────────────────────
    function convertSubvolume(share) {
        confirmDialog(
            'Convert to Subvolume',
            'WARNING: This will convert the share "' + share + '" directory to a BTRFS subvolume on all eligible disks.\n\n' +
            'This process involves:\n' +
            '1. Renaming the existing directory\n' +
            '2. Creating a BTRFS subvolume at the original path\n' +
            '3. Copying all data back using reflink (CoW)\n' +
            '4. Verifying and cleaning up\n\n' +
            'This operation may take a long time for large shares and should not be interrupted.\n' +
            'The share should NOT be actively written to during conversion.\n\n' +
            'Do you want to proceed?',
            'warning',
            function () {
                showNotification('Converting "' + share + '" to subvolume...', 'info');
                startAutoRefresh();
                apiPost('convert_subvolume', { share: share }, function (err, data) {
                    stopAutoRefresh();
                    if (err) {
                        showNotification('Conversion failed: ' + err, 'error');
                    } else {
                        showNotification(data.message || 'Conversion complete', 'success');
                    }
                    loadShares();
                });
            }
        );
    }

    // ─── Auto Refresh ────────────────────────────────────────────────
    function startAutoRefresh() {
        stopAutoRefresh();
        refreshTimer = setInterval(function () {
            // Only refresh if no modal is open
            if (!$('#snap-modal-overlay').length) {
                loadShares();
            }
        }, REFRESH_INTERVAL);
    }

    function stopAutoRefresh() {
        if (refreshTimer) {
            clearInterval(refreshTimer);
            refreshTimer = null;
        }
    }

    // ─── Confirmation Dialog ─────────────────────────────────────────
    function confirmDialog(title, message, type, onConfirm) {
        // Use SweetAlert if available (Unraid 6.12+), fallback to native confirm
        if (typeof swal === 'function') {
            swal({
                title: title,
                text: message,
                type: type || 'warning',
                showCancelButton: true,
                confirmButtonText: 'Yes, proceed',
                cancelButtonText: 'Cancel'
            }, function (confirmed) {
                if (confirmed && onConfirm) onConfirm();
            });
        } else if (typeof Swal === 'object' && typeof Swal.fire === 'function') {
            // SweetAlert2 (Unraid 7.x)
            Swal.fire({
                title: title,
                text: message,
                icon: type || 'warning',
                showCancelButton: true,
                confirmButtonText: 'Yes, proceed',
                cancelButtonText: 'Cancel'
            }).then(function (result) {
                if (result.isConfirmed && onConfirm) onConfirm();
            });
        } else {
            if (confirm(title + '\n\n' + message)) {
                if (onConfirm) onConfirm();
            }
        }
    }

    // ─── Notifications ──────────────────────────────────────────────
    function showNotification(msg, type) {
        type = type || 'info';
        var toastClass = 'toast-' + type;

        // Remove existing toasts
        $('.snap-toast').remove();

        var $toast = $('<div class="snap-toast ' + toastClass + '"></div>').text(msg);
        $('body').append($toast);

        // Trigger reflow for animation
        $toast[0].offsetHeight;
        $toast.addClass('visible');

        // Auto-dismiss
        setTimeout(function () {
            $toast.removeClass('visible');
            setTimeout(function () { $toast.remove(); }, 300);
        }, 4000);
    }

    // ─── Utility Functions ───────────────────────────────────────────
    function escapeHtml(str) {
        if (str === null || str === undefined) return '';
        return String(str)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#039;');
    }

    function escapeAttr(str) {
        return escapeHtml(str).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
    }

    function formatSchedule(schedule) {
        var map = {
            'disabled':     'Disabled',
            'every15min':   'Every 15 Min',
            'hourly':       'Hourly',
            'every6hours':  'Every 6 Hours',
            'daily':        'Daily',
            'weekly':       'Weekly',
            'global':       'Global Default'
        };
        return map[schedule] || schedule || '—';
    }

    // ─── Share Config Page ───────────────────────────────────────────
    function loadShareSnapshots(share) {
        var $table = $('#snap-share-snapshots-tbody');
        if (!$table.length) return;

        $table.html('<tr><td colspan="5" class="snap-loading"><span class="snap-spinner"></span> Loading...</td></tr>');

        apiGet('list_snapshots', { share: share }, function (err, data) {
            if (err) {
                $table.html('<tr><td colspan="5" class="snap-empty"><p>' + escapeHtml(err) + '</p></td></tr>');
                return;
            }

            var snapshots = data.snapshots || [];
            if (snapshots.length === 0) {
                $table.html('<tr><td colspan="5" class="snap-empty"><i class="fa fa-camera-retro"></i><p>No snapshots yet.</p></td></tr>');
                return;
            }

            var html = '';
            for (var i = 0; i < snapshots.length; i++) {
                var s = snapshots[i];
                html += '<tr>' +
                    '<td>' + escapeHtml(s.name) + '</td>' +
                    '<td><span class="snap-disk-tag btrfs-yes">' + escapeHtml(s.disk) + '</span></td>' +
                    '<td>' + escapeHtml(s.created) + '</td>' +
                    '<td>' + escapeHtml(s.size) + '</td>' +
                    '<td class="col-actions">' +
                    '<button class="snap-btn snap-btn-danger" onclick="BtrfsSnapshots.deleteSnapshot(\'' + escapeAttr(s.path) + '\', \'' + escapeAttr(share) + '\')" title="Delete"><i class="fa fa-trash"></i> Delete</button>' +
                    '</td></tr>';
            }
            $table.html(html);
        });
    }

    function saveShareConfig(share) {
        var formData = {
            share: share,
            ENABLED: $('#share_ENABLED').val(),
            SCHEDULE: $('#share_SCHEDULE').val(),
            RETENTION_HOURS: $('#share_RETENTION_HOURS').val(),
            RETENTION_DAYS: $('#share_RETENTION_DAYS').val(),
            RETENTION_WEEKS: $('#share_RETENTION_WEEKS').val(),
            RETENTION_MONTHS: $('#share_RETENTION_MONTHS').val(),
            SNAPDIR: $('#share_SNAPDIR').val(),
            SMB_SHADOW_COPY: $('#share_SMB_SHADOW_COPY').val()
        };

        apiPost('save_share_config', formData, function (err, data) {
            if (err) {
                showNotification('Failed to save: ' + err, 'error');
                return;
            }
            showNotification(data.message || 'Configuration saved', 'success');
        });
    }

    // ─── Public API ──────────────────────────────────────────────────
    return {
        init: init,
        loadShares: loadShares,
        loadSnapshots: loadSnapshots,
        loadShareSnapshots: loadShareSnapshots,
        createSnapshot: createSnapshot,
        deleteSnapshot: deleteSnapshot,
        convertSubvolume: convertSubvolume,
        refreshStatus: refreshStatus,
        showNotification: showNotification,
        closeModal: closeModal,
        saveShareConfig: saveShareConfig,
        startAutoRefresh: startAutoRefresh,
        stopAutoRefresh: stopAutoRefresh,
        formatSchedule: formatSchedule
    };

})(jQuery);
