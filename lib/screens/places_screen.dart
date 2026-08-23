import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/pings_provider.dart';
import '../providers/places_provider.dart';
import '../services/stats/places_service.dart';

/// Places the user's Google Timeline import recorded — one row per
/// place, ranked by how often they went there.
///
/// Everything here comes from the imported `gmaps:visit:…` rows and
/// nothing else (CLAUDE.md gotchas 34/35): no live ping ever produces a
/// "visit", so the screen is empty until a Timeline import lands. The
/// roll-up + every string is a pure function in
/// `services/stats/places_service.dart` (gotcha 18).
///
/// Duplicate rows for one real place are collapsed twice over (0.17.5):
/// `buildPlaces` merges what is within ~120 m before the screen sees
/// it, and `mergeByLabel` collapses whatever the reverse geocoder then
/// gives the same name within a kilometre — the second pass re-runs on
/// every build as labels land.
class PlacesScreen extends ConsumerStatefulWidget {
  const PlacesScreen({super.key});

  @override
  ConsumerState<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends ConsumerState<PlacesScreen> {
  PlaceSort _sort = PlaceSort.visits;

  @override
  Widget build(BuildContext context) {
    final placesAsync = ref.watch(placesProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Places')),
      body: placesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error loading places: $e')),
        data: (places) {
          if (places.isEmpty) return const _EmptyState();
          // Watched here rather than inside the tile because the label
          // is an INPUT to the merge: two rows can only collapse once
          // both names have resolved. Each member is a memoised ~11 m
          // cell shared with every other screen (gotcha 29), and the
          // list is one entry per place, not per ping.
          final labels = {
            for (final p in places)
              p.key: ref
                  .watch(approxLocationProvider(geocodeKey(p.lat, p.lon)))
                  .valueOrNull,
          };
          final sorted = sortPlaces(mergeByLabel(places, labels), _sort);
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: SegmentedButton<PlaceSort>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: PlaceSort.visits,
                      label: Text('Visits'),
                    ),
                    ButtonSegment(
                      value: PlaceSort.recent,
                      label: Text('Recent'),
                    ),
                    ButtonSegment(
                      value: PlaceSort.longest,
                      label: Text('Longest'),
                    ),
                  ],
                  selected: {_sort},
                  onSelectionChanged: (s) => setState(() => _sort = s.first),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: sorted.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    color: scheme.outlineVariant.withValues(alpha: 0.4),
                  ),
                  itemBuilder: (_, i) => _PlaceTile(
                    place: sorted[i],
                    title: placeTitle(sorted[i], labels[sorted[i].key]),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The row's headline: the reverse-geocoded name once it lands, else
/// the semantic type, else raw coordinates. Top-level so the screen can
/// compute it next to the merge and hand it to the tile.
String placeTitle(PlaceSummary place, String? label) =>
    label ?? place.semanticType ?? _coords(place);

class _PlaceTile extends StatelessWidget {
  final PlaceSummary place;
  final String title;
  const _PlaceTile({required this.place, required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // A chip only earns its space when it says something the title
    // doesn't — a "Home" row with no geocoded name is already labelled.
    // A merged row carries every member's type, usually still one.
    final spots = formatSpotsHint(place);
    final chips = [
      for (final type in place.semanticTypes)
        if (type != title) type,
      if (spots != null) spots,
    ];
    return ListTile(
      onTap: () => showPlaceVisitsSheet(context, place, title),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.primary.withValues(alpha: 0.3)),
        ),
        alignment: Alignment.center,
        child: Icon(_iconFor(place.semanticType), color: scheme.primary),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          for (final chip in chips) ...[
            const SizedBox(width: 8),
            _TypeChip(label: chip),
          ],
        ],
      ),
      subtitle: Text(formatPlaceSubtitle(place)),
      trailing: const Icon(Icons.chevron_right, size: 18),
    );
  }
}

/// Home / Work get their own glyph; everything else is a generic place.
IconData _iconFor(String? semanticType) {
  switch (semanticType) {
    case 'Home':
    case 'Home (inferred)':
      return Icons.home_outlined;
    case 'Work':
    case 'Work (inferred)':
      return Icons.work_outline;
  }
  return Icons.place_outlined;
}

String _coords(PlaceSummary p) =>
    '${p.lat.toStringAsFixed(4)}, ${p.lon.toStringAsFixed(4)}';

class _TypeChip extends StatelessWidget {
  final String label;
  const _TypeChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSecondaryContainer,
            ),
      ),
    );
  }
}

/// Bottom sheet: every visit to one place, newest first. Tapping a visit
/// opens the map filtered to that visit's local day(s).
Future<void> showPlaceVisitsSheet(
  BuildContext context,
  PlaceSummary place,
  String title,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PlaceVisitsSheet(place: place, title: title),
  );
}

class _PlaceVisitsSheet extends ConsumerWidget {
  final PlaceSummary place;
  final String title;
  const _PlaceVisitsSheet({required this.place, required this.title});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final visitsAsync = ref.watch(placeVisitsProvider(place.visitsKey));
    final merged = formatMergedPlaces(place);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  formatPlaceSubtitle(place),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (merged != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    merged,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (place.longestVisit > Duration.zero) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Longest stay ${formatPlaceDuration(place.longestVisit)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 16),
          Expanded(
            child: visitsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error loading visits: $e')),
              data: (visits) {
                if (visits.isEmpty) {
                  return const Center(child: Text('No visits left here.'));
                }
                final newestFirst = visits.reversed.toList(growable: false);
                return ListView.builder(
                  itemCount: newestFirst.length,
                  itemBuilder: (_, i) {
                    final visit = newestFirst[i];
                    return ListTile(
                      dense: true,
                      title: Text(formatVisitRange(visit)),
                      subtitle: Text(formatVisitDuration(visit)),
                      trailing: IconButton(
                        icon: const Icon(Icons.map_outlined),
                        tooltip: 'Show on map',
                        onPressed: () => _showOnMap(context, visit),
                      ),
                      onTap: () => _showOnMap(context, visit),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showOnMap(BuildContext context, Visit visit) {
    Navigator.of(context).pop();
    context.push('/map', extra: visitDayRange(visit));
  }
}

/// The map filter for one visit: whole local days from the start's day
/// to the end's day. `mapRangeUtcBounds` widens the end to 23:59:59.999
/// of its day, so a same-day visit lands on exactly that day — the same
/// local-midnight idiom the stats heatmap and trip cards use.
DateTimeRange visitDayRange(Visit visit) {
  final start = DateTime.fromMillisecondsSinceEpoch(visit.startMs).toLocal();
  final end =
      DateTime.fromMillisecondsSinceEpoch(visit.endMs ?? visit.startMs)
          .toLocal();
  return DateTimeRange(
    start: DateTime(start.year, start.month, start.day),
    end: DateTime(end.year, end.month, end.day),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.place_outlined, size: 48, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            'No places yet',
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'Import a Google Timeline to see the places it recorded.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => context.push('/import-timeline'),
            child: const Text('Import Google Timeline'),
          ),
        ],
      ),
    );
  }
}
