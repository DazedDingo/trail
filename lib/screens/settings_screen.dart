import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:go_router/go_router.dart';

import '../db/database.dart';
import '../db/keystore_key.dart';
import '../models/ping.dart';
import '../providers/backup_provider.dart';
import '../providers/home_location_provider.dart';
import '../providers/panic_provider.dart';
import '../providers/pings_provider.dart';
import '../providers/scheduler_provider.dart';
import '../services/panic/panic_service.dart';
import '../services/passphrase_service.dart';
import '../services/permissions_service.dart';
import '../services/scheduler/scheduler_mode.dart';
import '../services/scheduler/workmanager_scheduler.dart';

/// Diagnostics + permissions console.
///
/// Two questions the user should be able to answer from this screen without
/// plugging into adb or guessing:
///   1. Is the pipeline broken, or is the OS just throttling my worker?
///      → "Run ping now" exercises the scheduled handler end-to-end.
///   2. Why might my 4h worker be deferred?
///      → Battery-optimisation status is shown live (not just a request
///        link), so a revoked whitelist is visible before it silently
///        kills the next ping.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with WidgetsBindingObserver {
  final _perms = PermissionsService();
  PermissionStatus? _batteryStatus;
  PermissionStatus? _locationStatus;
  PermissionStatus? _backgroundStatus;
  bool _runningNow = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshStatuses();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-read statuses when the user returns from system settings — without
    // this the page stale-reads whatever was granted on initState.
    if (state == AppLifecycleState.resumed) {
      _refreshStatuses();
    }
  }

  Future<void> _refreshStatuses() async {
    final battery = await Permission.ignoreBatteryOptimizations.status;
    final location = await Permission.location.status;
    final background = await Permission.locationAlways.status;
    if (!mounted) return;
    setState(() {
      _batteryStatus = battery;
      _locationStatus = location;
      _backgroundStatus = background;
    });
  }

  Future<void> _runNow() async {
    setState(() => _runningNow = true);
    Ping? result;
    Object? error;
    try {
      result = await WorkmanagerScheduler.runNow();
    } catch (e) {
      error = e;
    }
    if (!mounted) return;
    setState(() => _runningNow = false);
    ref.invalidate(lastSuccessfulPingProvider);
    ref.invalidate(heartbeatHealthyProvider);
    ref.invalidate(pingCountProvider);
    ref.invalidate(recentPingsProvider);

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(_pingNowMessage(result: result, error: error)),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  String _pingNowMessage({required Ping? result, required Object? error}) {
    if (error != null) return 'Ping failed: $error';
    if (result == null) return 'Ping ran but returned no row.';
    if (result.source == PingSource.noFix) {
      return 'Logged a no-fix row — ${result.note ?? "unknown reason"}.';
    }
    final ts = DateFormat.Hms().format(result.timestampUtc.toLocal());
    return 'Ping logged at $ts (${result.lat?.toStringAsFixed(4)}, ${result.lon?.toStringAsFixed(4)}).';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
      ),
      body: ListView(
        children: [
          const _SectionHeader('Diagnostics'),
          ListTile(
            leading: _runningNow
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.flash_on_outlined),
            title: const Text('Run ping now'),
            subtitle: const Text(
              'Exercise the scheduled handler to confirm the pipeline works.',
            ),
            enabled: !_runningNow,
            onTap: _runningNow ? null : _runNow,
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('Re-enqueue 4h periodic worker'),
            subtitle: const Text(
              'Useful after force-stop or uninstall/reinstall.',
            ),
            onTap: () async {
              await WorkmanagerScheduler.enqueuePeriodic();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Worker re-enqueued.')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.analytics_outlined),
            title: const Text('Diagnostics'),
            subtitle: const Text(
              'Permission matrix, DB integrity check, last 20 worker runs.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/diagnostics'),
          ),
          const Divider(),
          const _SectionHeader('Scheduling'),
          const _SchedulerModeTile(),
          const _SchedulerEventsTile(),
          const Divider(),
          const _SectionHeader('Permissions'),
          _PermissionTile(
            icon: Icons.battery_saver_outlined,
            title: 'Battery optimisation',
            status: _batteryStatus,
            grantedSubtitle: 'Whitelisted — worker will survive Doze.',
            deniedSubtitle:
                'Not whitelisted — OS may defer pings for hours. Tap to request.',
            onTap: () async {
              await _perms.requestIgnoreBatteryOptimizations();
              await _refreshStatuses();
            },
          ),
          _PermissionTile(
            icon: Icons.location_on_outlined,
            title: 'Fine location',
            status: _locationStatus,
            grantedSubtitle: 'Granted.',
            deniedSubtitle: 'Required for every ping.',
            onTap: () async {
              await _perms.openSettings();
            },
          ),
          _PermissionTile(
            icon: Icons.explore_outlined,
            title: 'Background location',
            status: _backgroundStatus,
            grantedSubtitle: 'Granted — background pings allowed.',
            deniedSubtitle: 'Scheduled pings will fail. Tap for settings.',
            onTap: () async {
              await _perms.openSettings();
            },
          ),
          const Divider(),
          const _SectionHeader('Panic'),
          ListTile(
            leading: const Icon(Icons.contacts_outlined),
            title: const Text('Emergency contacts'),
            subtitle:
                const Text('People the panic button should SMS with a location pin.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/contacts'),
          ),
          const _ContinuousDurationTile(),
          const _AutoSendToggleTile(),
          const Divider(),
          const _SectionHeader('Home'),
          const _HomeLocationTile(),
          const Divider(),
          const _SectionHeader('Offline map'),
          ListTile(
            leading: const Icon(Icons.map_outlined),
            title: const Text('Regions'),
            subtitle: const Text(
              'Install sideloaded .mbtiles for an offline viewer. '
              'See docs/TILES.md for build pipeline.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/regions'),
          ),
          const Divider(),
          const _SectionHeader('History'),
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: const Text('Archive older pings'),
            subtitle: const Text(
              'Export to GPX/CSV and delete from the app. Retention is '
              'otherwise forever (PLAN.md).',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/archive'),
          ),
          const Divider(),
          const _SectionHeader('Cloud backup'),
          _BackupTile(onChanged: () => ref.invalidate(backupEnabledProvider)),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Trail'),
            subtitle: Text('by DazedDingo'),
          ),
          FutureBuilder<String>(
            future: _appVersionLabel(),
            builder: (context, snap) => ListTile(
              leading: const Icon(Icons.verified_outlined),
              title: const Text('App version'),
              subtitle: Text(snap.data ?? '…'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              letterSpacing: 1.2,
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final PermissionStatus? status;
  final String grantedSubtitle;
  final String deniedSubtitle;
  final VoidCallback onTap;

  const _PermissionTile({
    required this.icon,
    required this.title,
    required this.status,
    required this.grantedSubtitle,
    required this.deniedSubtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final granted = status?.isGranted ?? false;
    final label = _statusLabel(status);
    final subtitle = granted ? grantedSubtitle : deniedSubtitle;
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: (granted ? scheme.primaryContainer : scheme.errorContainer)
              .withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color:
                    granted ? scheme.onPrimaryContainer : scheme.onErrorContainer,
              ),
        ),
      ),
      onTap: onTap,
    );
  }

  String _statusLabel(PermissionStatus? s) {
    if (s == null) return '…';
    if (s.isGranted) return 'GRANTED';
    if (s.isPermanentlyDenied) return 'BLOCKED';
    if (s.isRestricted) return 'RESTRICTED';
    if (s.isLimited) return 'LIMITED';
    return 'NOT GRANTED';
  }
}

/// Scheduler-mode toggle.
///
/// Two modes (PLAN.md Phase 5):
///   - **Battery saver (WorkManager, default)**: system-batched periodic
///     job; 4h cadence drops to 8h below 20% battery, skipped below 5%.
///     Punctuality is "within a window" — Doze can stretch 4h to 6–8h.
///   - **Precise (exact alarms)**: `setExactAndAllowWhileIdle` per ping
///     at a fixed 4h cadence, regardless of battery. More frequent
///     standalone wakeups = slightly higher battery cost.
///
/// The Precise toggle requires the `SCHEDULE_EXACT_ALARM` permission on
/// API 31+. If the user flips to Precise without granting it, we flip
/// back and show a SnackBar that deep-links to system settings via
/// [ExactAlarmBridge.openExactAlarmSettings].
class _SchedulerModeTile extends ConsumerWidget {
  const _SchedulerModeTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(schedulerModeProvider);
    return ListTile(
      leading: const Icon(Icons.access_time_outlined),
      title: const Text('Scheduling mode'),
      subtitle: Text(
        mode.asData?.value == SchedulerMode.exact
            ? 'Precise — exact 4h alarms (slight battery cost).'
            : 'Battery saver — WorkManager periodic (may stretch past 4h under Doze).',
      ),
      trailing: DropdownButton<SchedulerMode>(
        value: mode.asData?.value,
        onChanged: (v) async {
          if (v == null) return;
          if (v == SchedulerMode.exact) {
            final can = await ExactAlarmBridge.canScheduleExactAlarms();
            if (!can) {
              await ExactAlarmBridge.openExactAlarmSettings();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Grant "Alarms & reminders", then try again.',
                  ),
                ),
              );
              return;
            }
          }
          final ok = await switchSchedulerMode(v);
          ref.invalidate(schedulerModeProvider);
          ref.invalidate(schedulerEventsProvider);
          ref.invalidate(exactAlarmPermissionProvider);
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                ok
                    ? 'Scheduling: ${v == SchedulerMode.exact ? "Precise" : "Battery saver"}.'
                    : 'Could not switch — exact-alarm permission denied.',
              ),
            ),
          );
        },
        items: const [
          DropdownMenuItem(
            value: SchedulerMode.workmanager,
            child: Text('Battery saver'),
          ),
          DropdownMenuItem(
            value: SchedulerMode.exact,
            child: Text('Precise'),
          ),
        ],
      ),
    );
  }
}

/// Expandable "last 20 scheduler events" panel — the observability
/// surface for "did my 4h alarm actually fire?". Native code logs
/// events on every schedule/fire/cancel (see
/// `SchedulerEventsLog.kt`); we render them newest-first.
class _SchedulerEventsTile extends ConsumerWidget {
  const _SchedulerEventsTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(schedulerEventsProvider);
    return ExpansionTile(
      leading: const Icon(Icons.history_toggle_off),
      title: const Text('Recent scheduling events'),
      subtitle: Text(
        events.asData?.value.isEmpty ?? true
            ? 'None yet.'
            : '${events.asData!.value.length} event(s), newest first.',
      ),
      children: [
        events.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(12),
            child: Text('Error: $e'),
          ),
          data: (list) {
            if (list.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Empty — switch to Precise to start logging exact-alarm '
                  'scheduling activity.',
                ),
              );
            }
            return Column(
              children: [
                for (final e in list)
                  ListTile(
                    dense: true,
                    leading: Icon(_iconFor(e.kind), size: 18),
                    title: Text(_humanKind(e.kind)),
                    subtitle: Text(
                      [
                        DateFormat.yMd().add_Hms().format(e.timestamp.toLocal()),
                        if (e.note != null) e.note,
                      ].whereType<String>().join(' · '),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  IconData _iconFor(String kind) => switch (kind) {
        'exact_scheduled' => Icons.alarm_add,
        'exact_fired' => Icons.alarm_on,
        'exact_cancelled' => Icons.alarm_off,
        'exact_permission_denied' => Icons.block,
        'mode_changed' => Icons.swap_horiz,
        'workmanager_enqueued' => Icons.playlist_add,
        _ => Icons.circle_outlined,
      };

  String _humanKind(String kind) => switch (kind) {
        'exact_scheduled' => 'Exact alarm scheduled',
        'exact_fired' => 'Exact alarm fired',
        'exact_cancelled' => 'Exact alarm cancelled',
        'exact_permission_denied' => 'Exact alarm permission denied',
        'mode_changed' => 'Scheduling mode changed',
        'workmanager_enqueued' => 'WorkManager task enqueued',
        _ => kind,
      };
}

/// Entry point to the home-location screen. Shows the currently-set
/// home beneath the tile so the user can see at a glance whether the
/// feature is active.
class _HomeLocationTile extends ConsumerWidget {
  const _HomeLocationTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(homeLocationProvider);
    final h = home.asData?.value;
    return ListTile(
      leading: const Icon(Icons.home_outlined),
      title: const Text('Home location'),
      subtitle: Text(
        h == null
            ? 'Not set — tap to add a reference point for "km from home".'
            : h.label != null
                ? '${h.label} (${h.lat.toStringAsFixed(3)}, '
                    '${h.lon.toStringAsFixed(3)})'
                : '${h.lat.toStringAsFixed(5)}, '
                    '${h.lon.toStringAsFixed(5)}',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push('/home-location'),
    );
  }
}

/// Duration picker for the continuous-panic foreground service. Defaults
/// to 30 min; persisted via [panicDurationProvider] so the choice sticks
/// across app restarts.
/// Toggle for silent panic-SMS sending (0.6.1+16). When off, the panic
/// button opens the user's SMS app pre-filled; when on, the SMS is sent
/// natively via `SmsManager` after a 5-second on-screen undo grace.
///
/// The runtime `SEND_SMS` prompt fires at toggle-on time — not at panic
/// time. If the user denied an earlier prompt, hitting panic would
/// otherwise silently fall through to the compose-intent path and leave
/// the user thinking auto-send was broken. Requesting up-front means the
/// toggle only commits to `on` when the permission is actually granted.
class _AutoSendToggleTile extends ConsumerWidget {
  const _AutoSendToggleTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(panicAutoSendProvider);
    final enabled = state.asData?.value ?? false;
    return SwitchListTile(
      secondary: const Icon(Icons.send_outlined),
      title: const Text('Auto-send panic SMS'),
      subtitle: const Text(
        'Send the SMS automatically after a 5-second undo window. '
        'Requires SEND_SMS permission (asked when you enable this). '
        'Off = opens your SMS app to confirm.',
      ),
      value: enabled,
      onChanged: state.isLoading
          ? null
          : (v) => _onToggle(context, ref, v),
    );
  }

  Future<void> _onToggle(BuildContext context, WidgetRef ref, bool v) async {
    final messenger = ScaffoldMessenger.of(context);
    if (v) {
      final status = await Permission.sms.request();
      if (!status.isGranted) {
        // Don't persist — the toggle would look on but silently fall
        // back to compose-intent, which is the very bug this flow is
        // fixing. Surface the denial so the user knows to retry.
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              status.isPermanentlyDenied
                  ? 'SMS permission blocked. Enable it in App settings to '
                      'turn on auto-send.'
                  : 'SMS permission denied. Toggle again to retry.',
            ),
            action: status.isPermanentlyDenied
                ? SnackBarAction(
                    label: 'SETTINGS',
                    onPressed: openAppSettings,
                  )
                : null,
          ),
        );
        return;
      }
    }
    await ref.read(panicAutoSendProvider.notifier).set(v);
  }
}

class _ContinuousDurationTile extends ConsumerWidget {
  const _ContinuousDurationTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(panicDurationProvider);
    return ListTile(
      leading: const Icon(Icons.timer_outlined),
      title: const Text('Continuous-panic duration'),
      subtitle: Text(
        'Foreground service pings every ~90s for the chosen window, then '
        'auto-stops. Currently: ${current.asData?.value.label ?? "…"}.',
      ),
      trailing: DropdownButton<PanicDuration>(
        value: current.asData?.value,
        onChanged: (v) {
          if (v == null) return;
          ref.read(panicDurationProvider.notifier).set(v);
        },
        items: [
          for (final d in PanicDuration.values)
            DropdownMenuItem(value: d, child: Text(d.label)),
        ],
      ),
    );
  }
}

Future<String> _appVersionLabel() async {
  // Deferred import so the synchronous build() isn't coupled to plugin
  // init — if package_info_plus fails for some weird reason, the rest of
  // the settings page still renders.
  try {
    // ignore: avoid_dynamic_calls
    final pkg = await _loadPackageInfo();
    return '${pkg.version}+${pkg.buildNumber}';
  } catch (_) {
    return 'unknown';
  }
}

Future<({String version, String buildNumber})> _loadPackageInfo() async {
  final info = await PackageInfo.fromPlatform();
  return (version: info.version, buildNumber: info.buildNumber);
}

/// Cloud-backup status tile + setup entry point.
///
/// Enabled state is read through [backupEnabledProvider] (a probe on the
/// salt file). The setup dialog takes a passphrase, derives a key via
/// PBKDF2, runs `PRAGMA rekey` to re-encrypt the DB with it, and persists
/// the derived key in the same secure-storage slot the background isolate
/// already reads — so the ping pipeline keeps working transparently.
class _BackupTile extends ConsumerWidget {
  final VoidCallback onChanged;
  const _BackupTile({required this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(backupEnabledProvider);
    return enabled.when(
      loading: () => const ListTile(
        leading: Icon(Icons.cloud_outlined),
        title: Text('Cloud backup'),
        subtitle: Text('Checking…'),
      ),
      error: (e, _) => ListTile(
        leading: const Icon(Icons.cloud_off_outlined),
        title: const Text('Cloud backup'),
        subtitle: Text('Status unavailable: $e'),
      ),
      data: (isEnabled) {
        if (isEnabled) {
          return const ListTile(
            leading: Icon(Icons.cloud_done_outlined),
            title: Text('Cloud backup'),
            subtitle: Text(
              'Enabled. History will survive uninstall via Google Drive. '
              'Lost passphrase = lost backup.',
            ),
          );
        }
        return ListTile(
          leading: const Icon(Icons.cloud_upload_outlined),
          title: const Text('Enable cloud backup'),
          subtitle: const Text(
            'Set a passphrase so history survives uninstall + device loss.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openSetup(context),
        );
      },
    );
  }

  Future<void> _openSetup(BuildContext context) async {
    final completed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _BackupSetupDialog(),
    );
    if (completed == true) onChanged();
  }
}

class _BackupSetupDialog extends ConsumerStatefulWidget {
  const _BackupSetupDialog();

  @override
  ConsumerState<_BackupSetupDialog> createState() => _BackupSetupDialogState();
}

class _BackupSetupDialogState extends ConsumerState<_BackupSetupDialog> {
  final _pass1 = TextEditingController();
  final _pass2 = TextEditingController();
  bool _obscured = true;
  bool _working = false;
  String? _error;

  @override
  void dispose() {
    _pass1.dispose();
    _pass2.dispose();
    super.dispose();
  }

  Future<void> _enable() async {
    final p1 = _pass1.text;
    final p2 = _pass2.text;
    final validation = PassphraseService.validate(p1);
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    if (p1 != p2) {
      setState(() => _error = 'Passphrases do not match.');
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final currentKey = await KeystoreKey.read();
      final salt = await PassphraseService.generateAndPersistSalt();
      final derived = PassphraseService.deriveKey(p1, salt);
      if (currentKey == null) {
        // Race: we're in keystore mode but no key yet. That means the
        // DB has never been opened on this install, so there's nothing
        // to rekey — just store the derived key so the next open creates
        // the DB encrypted with it directly.
        await TrailDatabase.invalidateShared();
        await KeystoreKey.persist(derived);
      } else {
        // Close the shared UI-isolate handle BEFORE rekey. sqflite's
        // `singleInstance: true` default means `openDatabase(path, ...)`
        // inside `rekey()` would otherwise return the exact handle the
        // home-screen providers are holding — and rekey's `finally`
        // close() would then tear it down under their feet. Closing
        // first guarantees rekey opens a fresh handle it fully owns.
        await TrailDatabase.invalidateShared();
        await TrailDatabase.rekey(currentKey: currentKey, newKey: derived);
        await KeystoreKey.persist(derived);
      }
      // Providers that cached a Database reference via shared() now point
      // at a closed handle — force them to re-fetch.
      ref.invalidate(recentPingsProvider);
      ref.invalidate(lastSuccessfulPingProvider);
      ref.invalidate(heartbeatHealthyProvider);
      ref.invalidate(pingCountProvider);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      // Clean up a partial salt on failure — leaving one orphaned would
      // route the user to the passphrase recovery screen on next launch.
      await PassphraseService.deleteSalt();
      setState(() {
        _working = false;
        _error = 'Setup failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enable cloud backup'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Your history will be end-to-end encrypted with a passphrase '
              'you choose. Android auto-backs up the encrypted file to your '
              'Google Drive; reinstall + re-enter passphrase recovers it.',
            ),
            const SizedBox(height: 12),
            const Text(
              'If you forget the passphrase, the backup is unrecoverable. '
              'Write it down somewhere safe.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pass1,
              obscureText: _obscured,
              enabled: !_working,
              decoration: InputDecoration(
                labelText: 'Backup passphrase',
                helperText:
                    '≥ ${PassphraseService.minPassphraseLength} characters',
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscured ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _obscured = !_obscured),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pass2,
              obscureText: _obscured,
              enabled: !_working,
              decoration: InputDecoration(
                labelText: 'Confirm passphrase',
                errorText: _error,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _working ? null : _enable,
          child: _working
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Enable'),
        ),
      ],
    );
  }
}
