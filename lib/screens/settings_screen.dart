import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/ping.dart';
import '../providers/pings_provider.dart';
import '../services/permissions_service.dart';
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
      appBar: AppBar(title: const Text('Settings')),
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
