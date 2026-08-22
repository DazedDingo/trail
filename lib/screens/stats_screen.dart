import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../providers/home_location_provider.dart';
import '../providers/pings_provider.dart';
import '../providers/stats_provider.dart';
import '../services/stats/stats_service.dart';
import '../widgets/help_button.dart';
import '../widgets/stats/calendar_heatmap.dart';
import '../widgets/stats/clock_chart.dart';

/// "Stats & reflection" — derived views of the ping history that live
/// in the existing DB columns, no new schema. Four sections:
///
///   1. **Calendar heatmap** — 12 weeks of pings-per-day, tap to open
///      the full map filtered to that day.
///   2. **Top places** — 1 km lat/lon buckets ranked by ping count,
///      reverse-geocoded for a label.
///   3. **Time of day** — 24-hour radial chart of when in the day
///      pings happen (motion-aware skips show as gaps).
///   4. **Trips** — runs of pings > 10 km from home for ≥ 6 h.
///
/// All four computations are pure functions in [StatsService] so the
/// screen is mostly composition + presentation.
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pingsAsync = ref.watch(allPingsProvider);
    final homeAsync = ref.watch(homeLocationProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stats'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/settings'),
        ),
        actions: const [
          HelpButton(
            screenTitle: 'Stats',
            sections: [
              HelpSection(
                icon: Icons.calendar_view_month,
                title: 'Calendar heatmap',
                body:
                    'Last 12 weeks × 7 days; cell intensity scales to '
                    'the busiest day in the window. Tap a day to open '
                    'the map filtered to that date.',
              ),
              HelpSection(
                icon: Icons.location_city,
                title: 'Top places',
                body:
                    'Pings bucketed on a 1 km lat/lon grid, sorted by '
                    'visit count. Buckets sharing a reverse-geocoded '
                    'label are merged so a single city doesn\'t appear '
                    'as five rows. Top 10.',
              ),
              HelpSection(
                icon: Icons.access_time,
                title: 'Time of day',
                body:
                    '24-hour radial chart of successful fixes by local '
                    'hour. no_fix rows are excluded so motion-aware '
                    'skips don\'t flatten the pattern.',
              ),
              HelpSection(
                icon: Icons.flight_takeoff,
                title: 'Trips',
                body:
                    'Auto-detected stretches > 10 km from home for '
                    '≥ 6 h. Tap a card to open the map filtered to the '
                    'trip\'s date range. Needs a home location set.',
              ),
            ],
          ),
        ],
      ),
      body: pingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error loading pings: $e')),
        data: (pings) {
          if (pings.isEmpty) {
            return const _EmptyAll();
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _Header('Calendar', 'Last 12 weeks. Tap a day to open the map.'),
              const SizedBox(height: 12),
              CalendarHeatmap(
                counts: StatsService.dailyCounts(pings),
                onDayTap: (day, count) {
                  if (count == 0) return;
                  context.push(
                    '/map',
                    extra: DateTimeRange(start: day, end: day),
                  );
                },
              ),
              const SizedBox(height: 28),
              _Header(
                'Top places',
                'Pings grouped on a ~1 km grid then merged by place '
                'name. Most-visited first.',
              ),
              const SizedBox(height: 8),
              const _TopPlacesList(),
              const SizedBox(height: 28),
              _Header(
                'Time of day',
                'When in the day you ping most. Local time.',
              ),
              const SizedBox(height: 8),
              _TimeOfDaySection(counts: StatsService.hourlyCounts(pings)),
              const SizedBox(height: 28),
              _Header('Trips', 'Stretches > 10 km from home for ≥ 6 h.'),
              const SizedBox(height: 8),
              homeAsync.when(
                loading: () => const SizedBox.shrink(),
                error: (e, _) => Text('Couldn\'t load home: $e'),
                data: (home) => home == null
                    ? const _NoHomeForTrips()
                    : _TripsList(
                        trips: StatsService.detectTrips(pings, home),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final String subtitle;
  const _Header(this.title, this.subtitle);
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _EmptyAll extends StatelessWidget {
  const _EmptyAll();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'No pings yet. Stats appear once Trail has logged a few fixes.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _NoHomeForTrips extends ConsumerWidget {
  const _NoHomeForTrips();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Set a home location to see trips. Trips are detected as runs '
              'of pings far from home, so the screen needs to know where '
              'home is.',
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: () => context.push('/home-location'),
                icon: const Icon(Icons.home_outlined),
                label: const Text('Set home'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopPlacesList extends ConsumerWidget {
  const _TopPlacesList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ranked = ref.watch(topPlacesProvider);
    return ranked.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (e, _) => _smallEmpty(context, 'Couldn\'t compute top places: $e'),
      data: (places) {
        if (places.isEmpty) {
          return _smallEmpty(context, 'No fixes with coordinates yet.');
        }
        final maxCount = places.first.count;
        return Column(
          children: [
            for (var i = 0; i < places.length; i++)
              _TopPlaceTile(
                rank: i + 1,
                place: places[i],
                maxCount: maxCount,
              ),
          ],
        );
      },
    );
  }
}

class _TopPlaceTile extends StatelessWidget {
  final int rank;
  final RankedPlace place;
  final int maxCount;

  const _TopPlaceTile({
    required this.rank,
    required this.place,
    required this.maxCount,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coords =
        '${place.lat.toStringAsFixed(3)}, ${place.lon.toStringAsFixed(3)}';
    final fraction = maxCount == 0 ? 0.0 : place.count / maxCount;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '#$rank',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  place.label ?? coords,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 4,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${place.count}',
            style: theme.textTheme.labelLarge,
          ),
        ],
      ),
    );
  }
}

class _TimeOfDaySection extends StatelessWidget {
  final List<int> counts;
  const _TimeOfDaySection({required this.counts});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = counts.fold<int>(0, (a, b) => a + b);
    if (total == 0) {
      return _smallEmpty(context, 'No timestamps yet.');
    }
    var peakHour = 0;
    var peakCount = 0;
    for (var h = 0; h < 24; h++) {
      if (counts[h] > peakCount) {
        peakCount = counts[h];
        peakHour = h;
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: ClockChart(counts: counts),
        ),
        const SizedBox(height: 8),
        Text(
          'Peak hour: ${peakHour.toString().padLeft(2, '0')}:00 '
          '($peakCount of $total).',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _TripsList extends StatelessWidget {
  final List<Trip> trips;
  const _TripsList({required this.trips});

  @override
  Widget build(BuildContext context) {
    if (trips.isEmpty) {
      return _smallEmpty(
        context,
        'No trips detected. Trips show up after a stretch of pings ≥ 10 km '
        'from home for ≥ 6 h.',
      );
    }
    return Column(
      children: [
        for (final t in trips) _TripCard(trip: t),
      ],
    );
  }
}

class _TripCard extends ConsumerWidget {
  final Trip trip;
  const _TripCard({required this.trip});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final fmt = DateFormat.yMMMd();
    final geoAsync = ref.watch(approxLocationProvider(
      geocodeKey(trip.centroidLat, trip.centroidLon),
    ));
    final start = trip.startUtc.toLocal();
    final end = trip.endUtc.toLocal();
    final daysSpan = end.difference(start).inDays + 1;
    final maxKm = (trip.maxDistanceMeters / 1000).round();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () {
          // Pad to whole local days so the map filter catches the
          // entire trip rather than clipping the first/last day.
          final startDay = DateTime(start.year, start.month, start.day);
          final endDay = DateTime(end.year, end.month, end.day);
          context.push(
            '/map',
            extra: DateTimeRange(start: startDay, end: endDay),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              geoAsync.when(
                loading: () => const Text('…'),
                error: (_, __) => Text(_coords(trip)),
                data: (label) => Text(
                  label ?? _coords(trip),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${fmt.format(start)} → ${fmt.format(end)} '
                '($daysSpan day${daysSpan == 1 ? '' : 's'})',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$maxKm km max from home · ${trip.pingCount} pings',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _coords(Trip t) =>
      '${t.centroidLat.toStringAsFixed(3)}, ${t.centroidLon.toStringAsFixed(3)}';
}

Widget _smallEmpty(BuildContext context, String text) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
    ),
  );
}
