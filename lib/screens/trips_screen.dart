import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../providers/home_location_provider.dart';
import '../providers/trips_provider.dart';
import '../services/stats/stats_service.dart';

/// Auto-detected trips — Timeline-style list, most-recent-first.
///
/// A "trip" is a run of ≥6 h of pings strictly farther than 10 km from
/// home. Detection is shared with the stats screen via
/// `StatsService.detectTrips` and the `tripsProvider` wrapper.
///
/// Tap a trip → open the full map, pre-filtered to that trip's date
/// window (uses go_router's `extra` arg to pass the range).
class TripsScreen extends ConsumerWidget {
  const TripsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trips = ref.watch(tripsProvider);
    final hasHome = ref.watch(homeLocationProvider).valueOrNull != null;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Trips')),
      body: !hasHome
          ? _EmptyState(
              icon: Icons.home_outlined,
              title: 'Set a home location first',
              subtitle: 'Trips are runs of pings ≥6 h, ≥10 km from home. '
                  'Without a home, we can\'t compute "away".',
              actionLabel: 'Set home',
              onAction: () => context.push('/settings/home'),
            )
          : trips.isEmpty
              ? _EmptyState(
                  icon: Icons.explore_off_outlined,
                  title: 'No trips yet',
                  subtitle:
                      'A trip needs ≥6 h of pings ≥10 km from home. '
                      'Local errands and short outings don\'t count.',
                )
              : ListView.separated(
                  itemCount: trips.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    color: scheme.outlineVariant.withValues(alpha: 0.4),
                  ),
                  itemBuilder: (_, i) => _TripTile(trip: trips[i]),
                ),
    );
  }
}

class _TripTile extends StatelessWidget {
  final Trip trip;
  const _TripTile({required this.trip});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: () => context.push(
        '/map',
        extra: DateTimeRange(
          start: trip.startUtc.toLocal(),
          end: trip.endUtc.toLocal(),
        ),
      ),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: scheme.primary.withValues(alpha: 0.3),
          ),
        ),
        alignment: Alignment.center,
        child: Icon(Icons.explore_outlined, color: scheme.primary),
      ),
      title: Text(formatTripDateRange(trip)),
      subtitle: Text(formatTripSubtitle(trip)),
      trailing: const Icon(Icons.chevron_right, size: 18),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
            textAlign: TextAlign.center,
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

// ─── Pure formatters (exported so the test suite can hit them) ──────────

String formatTripDateRange(Trip trip) {
  final start = trip.startUtc.toLocal();
  final end = trip.endUtc.toLocal();
  final sameDay = start.year == end.year &&
      start.month == end.month &&
      start.day == end.day;
  if (sameDay) {
    return DateFormat.yMMMd().format(start);
  }
  final sameMonth = start.year == end.year && start.month == end.month;
  if (sameMonth) {
    final dayFmt = DateFormat.d();
    final monthYear = DateFormat.yMMMM().format(start); // "May 2026"
    return '${dayFmt.format(start)}–${dayFmt.format(end)} $monthYear';
  }
  final fmt = DateFormat.yMMMd();
  return '${fmt.format(start)} – ${fmt.format(end)}';
}

String formatTripSubtitle(Trip trip) {
  final hours = trip.duration.inMinutes / 60;
  final durStr = hours < 1
      ? '${trip.duration.inMinutes} min'
      : hours < 24
          ? '${hours.toStringAsFixed(hours < 10 ? 1 : 0)} h'
          : '${(hours / 24).toStringAsFixed(1)} d';
  final distKm = (trip.maxDistanceMeters / 1000).toStringAsFixed(
    trip.maxDistanceMeters < 100000 ? 1 : 0,
  );
  return '$durStr · up to $distKm km from home · '
      '${trip.pingCount} ping${trip.pingCount == 1 ? '' : 's'}';
}
