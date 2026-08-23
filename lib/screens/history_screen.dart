import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/ping.dart';
import '../providers/pings_provider.dart';
import '../widgets/help_button.dart';
import '../widgets/year_chips_row.dart';

/// One calendar month's worth of History rows, newest month first.
class HistorySection {
  /// LOCAL midnight on the 1st of the month — the header's label
  /// (`DateFormat.yMMMM`) and the grouping key in one value.
  final DateTime monthStart;

  /// The month's pings, in the order they arrived (newest first, which
  /// is what every History read produces).
  final List<Ping> pings;

  const HistorySection({required this.monthStart, required this.pings});
}

/// Groups a newest-first ping list into month sections (0.16.2).
///
/// Pure so `history_grouping_test.dart` can pin it without a DB or a
/// widget tree — the same reason `filterPingsByRange` sits outside
/// `export_dialog.dart` (gotcha 13).
///
/// Months are keyed on the LOCAL calendar month (timestamps are stored
/// UTC but every label on this screen is local, and a ping logged at
/// 00:30 on 1 Sep local belongs to September). Section order follows
/// first appearance, so a newest-first input yields newest-first
/// sections; rows of the same month that arrive out of order still land
/// in one section rather than opening a duplicate header.
List<HistorySection> groupByMonth(List<Ping> pings) {
  final byMonth = <DateTime, List<Ping>>{};
  for (final p in pings) {
    final local = p.timestampUtc.toLocal();
    final key = DateTime(local.year, local.month);
    (byMonth[key] ??= <Ping>[]).add(p);
  }
  return [
    for (final entry in byMonth.entries)
      HistorySection(monthStart: entry.key, pings: entry.value),
  ];
}

/// A single row of the flattened History list: a month header, a ping,
/// or the footer (load-more / cap note). Flattening lets one
/// `ListView.builder` render headers and rows with a fixed extent each
/// — no third-party sticky-header sliver, and `itemExtentBuilder` can
/// answer without laying anything out (PERF_PLAN #15).
sealed class HistoryItem {
  const HistoryItem();
}

class HistoryMonthHeaderItem extends HistoryItem {
  final DateTime monthStart;
  final int count;
  const HistoryMonthHeaderItem({required this.monthStart, required this.count});
}

class HistoryPingItem extends HistoryItem {
  final Ping ping;
  const HistoryPingItem(this.ping);
}

class HistoryFooterItem extends HistoryItem {
  const HistoryFooterItem();
}

/// `[header, row, row, header, row, …]` — the list the builder walks.
/// Pure; tested alongside [groupByMonth].
List<HistoryItem> flattenSections(List<HistorySection> sections) => [
      for (final s in sections) ...[
        HistoryMonthHeaderItem(monthStart: s.monthStart, count: s.pings.length),
        for (final p in s.pings) HistoryPingItem(p),
      ],
    ];

/// Fixed extents (logical px at text scale 1.0). Every row of a kind is
/// the same height on purpose so `itemExtentBuilder` can hand the sliver
/// a scroll offset without building anything — the difference between a
/// smooth fling and a 20 000-row jank fest.
const double kHistoryHeaderExtent = 34;
const double kHistoryRowExtent = 76;
const double kHistoryFooterExtent = 72;

/// The extent of [item], scaled by the user's text scale so a
/// large-font device grows the box with the text instead of overflowing
/// it. Pure.
double historyItemExtent(HistoryItem item, TextScaler scaler) {
  final factor = (scaler.scale(14) / 14).clamp(1.0, 3.0);
  final base = switch (item) {
    HistoryMonthHeaderItem() => kHistoryHeaderExtent,
    HistoryPingItem() => kHistoryRowExtent,
    HistoryFooterItem() => kHistoryFooterExtent,
  };
  return base * factor;
}

/// Full ping history. "All" shows the most recent
/// [historyPageSize] rows (what this screen has always done); picking a
/// year pages through that whole calendar year, 200 rows at a time
/// (0.16.2 — a Timeline import can make "the newest 200" one afternoon
/// deep).
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  /// null = the "All" chip (recent-N, no paging).
  int? _year;

  Future<void> _pickOlderYear(List<int> hidden) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              dense: true,
              title: Text('Older years'),
            ),
            for (final year in hidden)
              ListTile(
                title: Text('$year'),
                onTap: () => Navigator.of(context).pop(year),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _year = picked);
  }

  @override
  Widget build(BuildContext context) {
    final years = ref.watch(pingYearsProvider).valueOrNull ?? const <int>[];
    final showYears = shouldShowYearChips(years, DateTime.now().year);
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: const [
          HelpButton(
            screenTitle: 'History',
            sections: [
              HelpSection(
                icon: Icons.list_alt,
                title: 'Every ping, newest first',
                body:
                    '"All" shows the 200 most-recent fixes. Tap a year '
                    'chip to page through that whole calendar year — 200 '
                    'rows at a time, oldest reachable with "Load more" at '
                    'the bottom. Rows are grouped under a month heading. '
                    'To shrink the database itself, use the Archive flow '
                    'in Settings to export-and-delete a cutoff window.',
              ),
              HelpSection(
                icon: Icons.report_outlined,
                title: 'Sources',
                body:
                    '"scheduled" rows are the periodic worker. "panic" '
                    'are hold-to-panic fires. "boot" rows mark device '
                    'reboots. "no_fix" rows mean the worker tried but '
                    'GPS didn\'t respond in 2 minutes — the gap is still '
                    'visible so silent failures can\'t hide. "import" '
                    'rows came from a Google Maps Timeline import (they '
                    'carry an "import" tag) — they show on the map but '
                    'never count as your last ping or in stats.',
              ),
            ],
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showYears)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: YearChipsRow(
                years: years,
                selectedYear: _year,
                onYear: (year) => setState(() => _year = year),
                onAll: () => setState(() => _year = null),
                onOlder: _pickOlderYear,
              ),
            ),
          Expanded(
            child: _year == null
                ? _AllHistoryList(canPickYear: showYears)
                : _YearHistoryList(year: _year!),
          ),
        ],
      ),
    );
  }
}

/// "All" — the pre-0.16.2 behaviour: the newest [historyPageSize] rows
/// including imports, no paging (the year chips are the way further
/// back).
class _AllHistoryList extends ConsumerWidget {
  final bool canPickYear;
  const _AllHistoryList({required this.canPickYear});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(historyPingsProvider);
    return recent.when(
      data: (pings) {
        if (pings.isEmpty) {
          return const Center(child: Text('No pings yet.'));
        }
        final capped = pings.length >= historyPageSize;
        return _HistoryListView(
          items: [
            ...flattenSections(groupByMonth(pings)),
            if (capped) const HistoryFooterItem(),
          ],
          footer: capped
              ? _FooterNote(
                  text: canPickYear
                      ? 'Showing the $historyPageSize most recent pings — '
                          'pick a year above for older ones.'
                      : 'Showing the $historyPageSize most recent pings.',
                )
              : null,
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Failed: $e')),
    );
  }
}

/// One calendar year, keyset-paginated through
/// [historyYearProvider] with a "Load more" footer.
class _YearHistoryList extends ConsumerWidget {
  final int year;
  const _YearHistoryList({required this.year});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(historyYearProvider(year));
    return page.when(
      data: (data) {
        if (data.pings.isEmpty) {
          return Center(child: Text('No pings in $year.'));
        }
        return _HistoryListView(
          items: [
            ...flattenSections(groupByMonth(data.pings)),
            if (data.hasMore) const HistoryFooterItem(),
          ],
          footer: data.hasMore
              ? _LoadMoreFooter(
                  loading: data.loadingMore,
                  onPressed: () =>
                      ref.read(historyYearProvider(year).notifier).loadMore(),
                )
              : null,
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Failed: $e')),
    );
  }
}

/// The one list builder both modes share: flattened items, fixed
/// extents, headers rendered opaque so rows scroll under them.
class _HistoryListView extends StatelessWidget {
  final List<HistoryItem> items;

  /// Rendered in place of the trailing [HistoryFooterItem].
  final Widget? footer;

  const _HistoryListView({required this.items, this.footer});

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return ListView.builder(
      itemCount: items.length,
      itemExtentBuilder: (index, _) => historyItemExtent(items[index], scaler),
      itemBuilder: (context, index) {
        final item = items[index];
        return switch (item) {
          HistoryMonthHeaderItem() => _MonthHeader(item: item),
          HistoryPingItem() => _HistoryRow(ping: item.ping),
          HistoryFooterItem() => footer ?? const SizedBox.shrink(),
        };
      },
    );
  }
}

class _MonthHeader extends StatelessWidget {
  final HistoryMonthHeaderItem item;
  const _MonthHeader({required this.item});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      // Opaque-ish: rows scroll UNDER the heading rather than through
      // it, which is as sticky as a plain ListView gets without a
      // third-party sliver.
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.95),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Expanded(
            child: Text(
              DateFormat.yMMMM().format(item.monthStart),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            '${item.count}',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _HistoryRow extends ConsumerWidget {
  final Ping ping;
  const _HistoryRow({required this.ping});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final ts = DateFormat.yMMMd().add_Hms().format(ping.timestampUtc.toLocal());
    final hasFix = ping.lat != null && ping.lon != null;
    final coords = hasFix
        ? '${ping.lat!.toStringAsFixed(5)}, ${ping.lon!.toStringAsFixed(5)}'
        : (ping.note ?? ping.source.dbValue);

    // Only geocode rows that carry a real fix. The provider family is
    // keyed on the 4-dp-rounded cell (`geocodeKey`, ~11 m) so repeated
    // pings at the same spot — the common case at 4h cadence, GPS jitter
    // included — share one member and never re-request.
    final approx = hasFix
        ? ref.watch(approxLocationProvider(geocodeKey(ping.lat!, ping.lon!)))
        : const AsyncValue<String?>.data(null);

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    coords,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  _ApproxLine(state: approx),
                  Text(
                    '$ts  ·  ${ping.source.dbValue}'
                    '${ping.batteryPct != null ? "  ·  batt ${ping.batteryPct}%" : ""}'
                    '${ping.networkState != null ? "  ·  ${ping.networkState}" : ""}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (ping.source == PingSource.imported) ...[
              const SizedBox(width: 8),
              const _ImportChip(),
            ],
          ],
        ),
      ),
    );
  }
}

/// Marks a row that came from a Google Maps Timeline import — the same
/// fact the `source` label carries, hoisted out where it is visible at
/// a glance in a list where imports can outnumber live pings 100:1.
class _ImportChip extends StatelessWidget {
  const _ImportChip();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.6),
        ),
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      ),
      child: Text(
        'import',
        style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

class _LoadMoreFooter extends StatelessWidget {
  final bool loading;
  final VoidCallback onPressed;
  const _LoadMoreFooter({required this.loading, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: loading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : OutlinedButton.icon(
              icon: const Icon(Icons.expand_more, size: 18),
              label: const Text('Load more'),
              onPressed: onPressed,
            ),
    );
  }
}

class _FooterNote extends StatelessWidget {
  final String text;
  const _FooterNote({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          maxLines: 3,
          style: Theme.of(context).textTheme.bodySmall,
        ),
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
