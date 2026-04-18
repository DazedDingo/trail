import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../db/database.dart';
import '../db/ping_dao.dart';
import '../models/ping.dart';
import '../providers/pings_provider.dart';
import '../services/export/csv_exporter.dart';
import '../services/export/gpx_exporter.dart';

/// The app's primary screen.
///
/// Layout (top → bottom):
/// 1. "Last successful ping" card — timestamp + coords, red stripe if > 5h.
/// 2. Heartbeat / total pings summary.
/// 3. Export actions (GPX + CSV) feeding into share_plus.
/// 4. History list (recent 200 — longer history lives on /history).
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final last = ref.watch(lastSuccessfulPingProvider);
    final healthy = ref.watch(heartbeatHealthyProvider);
    final count = ref.watch(pingCountProvider);
    final recent = ref.watch(recentPingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trail'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () {
              ref.invalidate(lastSuccessfulPingProvider);
              ref.invalidate(heartbeatHealthyProvider);
              ref.invalidate(pingCountProvider);
              ref.invalidate(recentPingsProvider);
            },
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(lastSuccessfulPingProvider);
          ref.invalidate(heartbeatHealthyProvider);
          ref.invalidate(pingCountProvider);
          ref.invalidate(recentPingsProvider);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _LastPingCard(last: last, healthy: healthy),
            const SizedBox(height: 12),
            _SummaryCard(count: count),
            const SizedBox(height: 12),
            _ExportRow(),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Recent pings',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                TextButton(
                  onPressed: () => context.push('/history'),
                  child: const Text('View all'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            recent.when(
              data: (pings) => Column(
                children: pings.take(20).map((p) => _PingTile(ping: p)).toList(),
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, st) => _DbErrorCard(error: e, stack: st),
            ),
          ],
        ),
      ),
    );
  }
}

class _LastPingCard extends StatelessWidget {
  final AsyncValue<Ping?> last;
  final AsyncValue<bool> healthy;
  const _LastPingCard({required this.last, required this.healthy});

  @override
  Widget build(BuildContext context) {
    final isHealthy = healthy.asData?.value ?? true;
    final p = last.asData?.value;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isHealthy
              ? Colors.transparent
              : Theme.of(context).colorScheme.error,
          width: 2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isHealthy ? Icons.favorite : Icons.warning_amber_rounded,
                  color: isHealthy
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 8),
                Text(
                  isHealthy ? 'Heartbeat healthy' : 'No ping in 5+ hours',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (p == null)
              const Text('No successful pings yet.')
            else ...[
              Text(
                DateFormat.yMMMd().add_Hms().format(p.timestampUtc.toLocal()),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
              Text(
                '${p.lat!.toStringAsFixed(5)}, ${p.lon!.toStringAsFixed(5)}'
                '${p.accuracy != null ? "  ±${p.accuracy!.toStringAsFixed(0)}m" : ""}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final AsyncValue<int> count;
  const _SummaryCard({required this.count});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.pin_drop_outlined),
        title: const Text('Total pings logged'),
        trailing: Text(
          count.asData?.value.toString() ?? '…',
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
    );
  }
}

class _ExportRow extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _export(context, gpx: true),
            icon: const Icon(Icons.map_outlined),
            label: const Text('Export GPX'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _export(context, gpx: false),
            icon: const Icon(Icons.table_view_outlined),
            label: const Text('Export CSV'),
          ),
        ),
      ],
    );
  }

  Future<void> _export(BuildContext context, {required bool gpx}) async {
    // Uses the UI-isolate shared handle — do NOT close; see TrailDatabase.
    final db = await TrailDatabase.shared();
    final all = await PingDao(db).all();
    final path = gpx
        ? await GpxExporter().export(all)
        : await CsvExporter().export(all);
    await Share.shareXFiles(
      [XFile(path)],
      subject: 'Trail export (${gpx ? "GPX" : "CSV"})',
    );
  }
}

/// Surfaces a DB load failure with copyable detail. The previous single-line
/// `Text('Failed to load: $e')` truncated exception text off-screen, which
/// made field diagnosis impossible when 0.1.3 hit a first-install DB race.
class _DbErrorCard extends StatelessWidget {
  final Object error;
  final StackTrace stack;
  const _DbErrorCard({required this.error, required this.stack});

  @override
  Widget build(BuildContext context) {
    final detail = '$error\n\n$stack';
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline,
                    color: Theme.of(context).colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Failed to load pings',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Copy error',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: detail)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              detail,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _PingTile extends StatelessWidget {
  final Ping ping;
  const _PingTile({required this.ping});

  @override
  Widget build(BuildContext context) {
    final isNoFix = ping.source == PingSource.noFix;
    return ListTile(
      dense: true,
      leading: Icon(
        _iconFor(ping.source),
        color: isNoFix ? Theme.of(context).colorScheme.error : null,
      ),
      title: Text(
        ping.lat != null && ping.lon != null
            ? '${ping.lat!.toStringAsFixed(4)}, ${ping.lon!.toStringAsFixed(4)}'
            : (ping.note ?? ping.source.dbValue),
      ),
      subtitle: Text(
        DateFormat.MMMd().add_Hms().format(ping.timestampUtc.toLocal()),
      ),
      trailing: Text(ping.source.dbValue),
    );
  }

  IconData _iconFor(PingSource s) {
    switch (s) {
      case PingSource.panic:
        return Icons.priority_high;
      case PingSource.boot:
        return Icons.power_settings_new;
      case PingSource.noFix:
        return Icons.signal_cellular_off;
      case PingSource.scheduled:
        return Icons.pin_drop;
    }
  }
}
