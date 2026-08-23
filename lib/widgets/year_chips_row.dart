import 'package:flutter/material.dart';

/// The "2026 · 2025 · 2024 …" chip row, shared by the map's inline date
/// filter panel and the History screen (0.16.2).
///
/// It is deliberately dumb: it renders the years it is handed (newest
/// first — that is the order `pingYearsProvider` / `yearsCovering`
/// produce) and reports taps. What a tap *means* differs per caller —
/// the map turns it into a `rangeForYear` filter, History pages that
/// calendar year out of `PingDao.pageByRange` — so no range maths lives
/// here.
///
/// Optional leading "All" chip: rendered only when [onAll] is supplied
/// (the map panel already has "All time" on its preset row, so it
/// passes null and gets exactly the row it had before the extraction).
/// It renders selected whenever [selectedYear] is null.
class YearChipsRow extends StatelessWidget {
  /// Calendar years with data, newest first. Empty renders an empty row
  /// — callers gate on [shouldShowYearChips].
  final List<int> years;

  /// The year currently in effect, or null for "All".
  final int? selectedYear;

  final ValueChanged<int> onYear;

  /// Tapped "Older…" — receives the years that did NOT get a chip
  /// (newest first), so the caller can seed a picker at `hidden.first`
  /// or list them all. Null = the chip is still shown when the row
  /// overflows but does nothing; pass a handler or the tail is
  /// unreachable.
  final ValueChanged<List<int>>? onOlder;

  /// Non-null adds a leading "All" chip with this callback.
  final VoidCallback? onAll;

  /// Label for that leading chip.
  final String allLabel;

  const YearChipsRow({
    super.key,
    required this.years,
    required this.selectedYear,
    required this.onYear,
    this.onOlder,
    this.onAll,
    this.allLabel = 'All',
  });

  /// How many year chips fit before the row starts wrapping into a wall
  /// of numbers. Beyond this the oldest ones collapse into "Older…".
  static const maxYearChips = 12;

  @override
  Widget build(BuildContext context) {
    // More years than fit: keep the newest, and fold the tail into one
    // "Older…" chip (the caller decides what that opens).
    final overflowing = years.length > maxYearChips;
    final shown = overflowing ? years.take(maxYearChips - 1) : years;
    final hidden = overflowing ? years.skip(maxYearChips - 1).toList() : null;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (onAll != null)
          FilterPresetChip(
            label: allLabel,
            selected: selectedYear == null,
            onTap: onAll!,
          ),
        for (final year in shown)
          FilterPresetChip(
            label: '$year',
            selected: year == selectedYear,
            onTap: () => onYear(year),
          ),
        if (hidden != null)
          FilterActionChip(
            label: 'Older…',
            onTap: () => onOlder?.call(hidden),
          ),
      ],
    );
  }
}

/// Is a year row worth its vertical space? It is noise on a fresh
/// install (one year, and it's this one — every preset already lands
/// inside it). It earns its space as soon as there are two years, or
/// one that isn't the current one (exactly the "I just imported
/// 2015–2019" case).
bool shouldShowYearChips(List<int> years, int currentYear) =>
    years.length >= 2 || (years.length == 1 && years.first != currentYear);

/// Selectable chip used by the year row and by the date filter panel's
/// preset row. Lives here (rather than in the panel) so the extracted
/// [YearChipsRow] and its old home render byte-identical chips.
class FilterPresetChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const FilterPresetChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: (_) => onTap(),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      selectedColor: scheme.primary.withValues(alpha: 0.30),
      side: BorderSide(
        color: selected
            ? scheme.primary.withValues(alpha: 0.6)
            : scheme.outlineVariant.withValues(alpha: 0.4),
      ),
    );
  }
}

/// Action-style sibling of [FilterPresetChip]: "Custom range…" on the
/// panel's preset row, "Older…" on the year row — same chip, only the
/// label and what it opens differ.
class FilterActionChip extends StatelessWidget {
  final VoidCallback onTap;
  final String label;

  const FilterActionChip({
    super.key,
    required this.onTap,
    this.label = 'Custom range…',
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      avatar: Icon(Icons.tune, size: 14, color: scheme.onSurfaceVariant),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      side: BorderSide(
        color: scheme.outlineVariant.withValues(alpha: 0.4),
      ),
    );
  }
}
