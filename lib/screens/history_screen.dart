import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/ping.dart';
import '../providers/pings_provider.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentPingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: recent.when(
        data: (pings) {
          if (pings.isEmpty) {
            return const Center(child: Text('No pings yet.'));
          }
          return ListView.separated(
            itemCount: pings.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) => _HistoryTile(ping: pings[i]),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed: $e')),
      ),
    );
  }
}

class _HistoryTile extends ConsumerWidget {
  final Ping ping;
  const _HistoryTile({required this.ping});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ts = DateFormat.yMMMd().add_Hms().format(ping.timestampUtc.toLocal());
    final hasFix = ping.lat != null && ping.lon != null;
    final coords = hasFix
        ? '${ping.lat!.toStringAsFixed(5)}, ${ping.lon!.toStringAsFixed(5)}'
        : (ping.note ?? ping.source.dbValue);

    // Only geocode rows that carry a real fix. The FutureProvider.family is
    // keyed on (lat, lon) so repeated pings at the same spot — the common
    // case at 4h cadence — are cache hits and never re-request.
    final approx = hasFix
        ? ref.watch(approxLocationProvider((lat: ping.lat!, lon: ping.lon!)))
        : const AsyncValue<String?>.data(null);

    return ListTile(
      title: Text(coords),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ApproxLine(state: approx),
          Text(
            '$ts  ·  ${ping.source.dbValue}'
            '${ping.batteryPct != null ? "  ·  batt ${ping.batteryPct}%" : ""}'
            '${ping.networkState != null ? "  ·  ${ping.networkState}" : ""}',
          ),
        ],
      ),
    );
  }
}

/// Subtle, optional line: present when reverse geocoding returned a label,
/// collapsed when it didn't. Keeps the history tile honest about gaps in
/// geocoder coverage rather than reserving a second row that stays empty.
class _ApproxLine extends StatelessWidget {
  final AsyncValue<String?> state;
  const _ApproxLine({required this.state});

  @override
  Widget build(BuildContext context) {
    final label = state.asData?.value;
    if (label == null || label.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.place_outlined,
            size: 13,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
