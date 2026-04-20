import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../db/database.dart';
import '../services/scheduler/worker_run_log.dart';

/// Deep-diagnostics surface — not linked from the home screen, only
/// reachable from Settings → Diagnostics. Surfaces the things a user
/// hands to a developer when reporting "my pings stopped firing":
///
///   1. **Permission matrix** — every permission the app needs, side by
///      side with its current runtime status. Battery-opt whitelist
///      included (the biggest silent-killer on OEM Android).
///   2. **DB integrity check** — `PRAGMA integrity_check` run against
///      the encrypted DB. Button-gated because it can take several
///      seconds on a busy trail.
///   3. **Worker run log** — last 20 WorkManager dispatcher runs with
///      task, outcome, and note. Mirrors the exact-alarm events on the
///      Settings screen but for the WorkManager pipeline.
///   4. **Copy all** — bundles every signal into one blob for pasting
///      into a bug report.
class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() =>
      _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen>
    with WidgetsBindingObserver {
  Map<String, PermissionStatus> _perms = const {};
  List<WorkerRun> _runs = const [];
  bool _loading = true;
  String? _integrityResult;
  bool _integrityRunning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    // Read permissions + runs in parallel — nothing cross-depends.
    final results = await Future.wait([
      Permission.location.status,
      Permission.locationAlways.status,
      Permission.ignoreBatteryOptimizations.status,
      Permission.notification.status,
      Permission.scheduleExactAlarm.status,
      WorkerRunLog.recent(),
    ]);
    if (!mounted) return;
    setState(() {
      _perms = {
        'Fine location': results[0] as PermissionStatus,
        'Background location': results[1] as PermissionStatus,
        'Ignore battery opt': results[2] as PermissionStatus,
        'Notifications': results[3] as PermissionStatus,
        'Exact alarms': results[4] as PermissionStatus,
      };
      _runs = results[5] as List<WorkerRun>;
      _loading = false;
    });
  }

  Future<void> _runIntegrity() async {
    setState(() {
      _integrityRunning = true;
      _integrityResult = null;
    });
    try {
      final rows = await TrailDatabase.integrityCheck();
      if (!mounted) return;
      setState(() {
        _integrityRunning = false;
        // A healthy DB returns exactly one 'ok' row.
        _integrityResult = rows.length == 1 && rows.single == 'ok'
            ? 'OK — no corruption detected.'
            : rows.join('\n');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _integrityRunning = false;
        _integrityResult = 'Failed: $e';
      });
    }
  }

  Future<void> _copyAll() async {
    final buf = StringBuffer()
      ..writeln('Trail diagnostics — ${DateTime.now().toUtc().toIso8601String()}')
      ..writeln('')
      ..writeln('Permissions:');
    for (final e in _perms.entries) {
      buf.writeln('  ${e.key}: ${_label(e.value)}');
    }
    buf
      ..writeln('')
      ..writeln('DB integrity: ${_integrityResult ?? "not run"}')
      ..writeln('')
      ..writeln('Worker runs (newest first):');
    if (_runs.isEmpty) {
      buf.writeln('  (none)');
    } else {
      for (final r in _runs) {
        buf.writeln(
          '  ${r.timestamp.toIso8601String()} · ${r.task} · ${r.outcome}'
          '${r.note != null ? " · ${r.note}" : ""}',
        );
      }
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Diagnostics copied to clipboard.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/settings'),
        ),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: _loading ? null : _copyAll,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const _SectionHeader('Permission matrix'),
                for (final e in _perms.entries)
                  _PermissionRow(label: e.key, status: e.value),
                const Divider(),
                const _SectionHeader('DB integrity'),
                ListTile(
                  leading: _integrityRunning
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.shield_outlined),
                  title: const Text('Run integrity check'),
                  subtitle: Text(
                    _integrityResult ??
                        'PRAGMA integrity_check — verifies the encrypted '
                            'DB has no corruption. Can take several seconds.',
                  ),
                  onTap: _integrityRunning ? null : _runIntegrity,
                ),
                const Divider(),
                const _SectionHeader('Worker runs (last 20)'),
                if (_runs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Nothing logged yet. WorkManager records events '
                      'only after its first run in this install — '
                      'trigger "Run ping now" from Settings if you want '
                      'to prime the log.',
                    ),
                  )
                else
                  for (final run in _runs) _WorkerRunRow(run: run),
              ],
            ),
    );
  }

  String _label(PermissionStatus s) {
    if (s.isGranted) return 'GRANTED';
    if (s.isPermanentlyDenied) return 'BLOCKED';
    if (s.isLimited) return 'LIMITED';
    if (s.isRestricted) return 'RESTRICTED';
    if (s.isDenied) return 'NOT GRANTED';
    return s.toString();
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

class _PermissionRow extends StatelessWidget {
  final String label;
  final PermissionStatus status;
  const _PermissionRow({required this.label, required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ok = status.isGranted;
    return ListTile(
      dense: true,
      leading: Icon(
        ok ? Icons.check_circle_outline : Icons.highlight_off,
        color: ok ? scheme.primary : scheme.error,
      ),
      title: Text(label),
      trailing: Text(_short(status)),
    );
  }

  String _short(PermissionStatus s) {
    if (s.isGranted) return 'granted';
    if (s.isPermanentlyDenied) return 'blocked';
    if (s.isLimited) return 'limited';
    if (s.isRestricted) return 'restricted';
    if (s.isDenied) return 'denied';
    return 'unknown';
  }
}

class _WorkerRunRow extends StatelessWidget {
  final WorkerRun run;
  const _WorkerRunRow({required this.run});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(_iconFor(run.outcome), size: 18),
      title: Text('${_humanTask(run.task)} · ${_humanOutcome(run.outcome)}'),
      subtitle: Text(
        [
          DateFormat.yMd().add_Hms().format(run.timestamp.toLocal()),
          if (run.note != null) run.note,
        ].whereType<String>().join(' · '),
      ),
    );
  }

  IconData _iconFor(String outcome) => switch (outcome) {
        'ok' => Icons.check_circle_outline,
        'no_fix' => Icons.location_off_outlined,
        'low_battery_skip' => Icons.battery_alert_outlined,
        'awaiting_passphrase' => Icons.lock_outline,
        'error' => Icons.error_outline,
        _ => Icons.circle_outlined,
      };

  String _humanTask(String t) => switch (t) {
        'trail_scheduled_ping' => 'Scheduled',
        'trail_retry_ping' => 'Retry',
        'trail_boot_ping' => 'Boot',
        'trail_panic' => 'Panic',
        _ => t,
      };

  String _humanOutcome(String o) => switch (o) {
        'ok' => 'ok',
        'no_fix' => 'no fix',
        'low_battery_skip' => 'skipped (battery)',
        'awaiting_passphrase' => 'skipped (locked)',
        'error' => 'error',
        _ => o,
      };
}
