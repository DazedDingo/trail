import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/stats/date_range_presets.dart';

/// Inline date-range picker for the map screen. Replaces the
/// `showDateRangePicker` modal that used to take over the whole screen.
///
/// Two interaction modes:
///   1. Tap a preset chip → range applied immediately, panel closes.
///      Since 0.16.1 a second chip row lists the calendar YEARS the
///      pings table actually covers (newest first) — a Timeline import
///      can drop a decade of history in, and "2024" is one tap where
///      the system picker was five.
///   2. Tap "Custom range…" → falls through to the system date-range
///      picker for granular start/end selection (we use the system
///      picker here rather than embedding a CalendarDatePicker because
///      MaterialDateRangePicker is much more compact for selecting
///      two-ended ranges than the standalone CalendarDatePicker, which
///      only picks a single date — embedding it would require building
///      two-end selection logic from scratch).
///
/// The panel sits between the control row and the map body. Animated
/// in/out via [AnimatedSize] — `open=false` collapses to 0 height.
class InlineDateFilterPanel extends StatelessWidget {
  final bool open;
  final DateTimeRange? currentRange;
  final DateTime now;
  final DateTime earliestPing;
  final DateTime latestPing;

  /// Calendar years with at least one fix, newest-first
  /// (`pingYearsProvider`). Empty = no year row, which is also what a
  /// still-loading provider renders.
  final List<int> years;

  final ValueChanged<DateTimeRange?> onApply;
  final VoidCallback onClose;

  const InlineDateFilterPanel({
    super.key,
    required this.open,
    required this.currentRange,
    required this.now,
    required this.earliestPing,
    required this.latestPing,
    this.years = const [],
    required this.onApply,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: open
          ? _PanelBody(
              scheme: scheme,
              currentRange: currentRange,
              now: now,
              earliestPing: earliestPing,
              latestPing: latestPing,
              years: years,
              onApply: onApply,
              onClose: onClose,
            )
          : const SizedBox(width: double.infinity, height: 0),
    );
  }
}

class _PanelBody extends StatelessWidget {
  final ColorScheme scheme;
  final DateTimeRange? currentRange;
  final DateTime now;
  final DateTime earliestPing;
  final DateTime latestPing;
  final List<int> years;
  final ValueChanged<DateTimeRange?> onApply;
  final VoidCallback onClose;

  const _PanelBody({
    required this.scheme,
    required this.currentRange,
    required this.now,
    required this.earliestPing,
    required this.latestPing,
    required this.years,
    required this.onApply,
    required this.onClose,
  });

  /// How many year chips fit before the row starts wrapping into a wall
  /// of numbers. Beyond this the oldest ones collapse into "Older…".
  static const maxYearChips = 12;

  /// The year row is noise on a fresh install (one year, and it's this
  /// one — every preset already lands inside it). It earns its space as
  /// soon as there are two years, or one that isn't the current one
  /// (which is exactly the "I just imported 2015–2019" case).
  bool get _showYears =>
      years.length >= 2 || (years.length == 1 && years.first != now.year);

  @override
  Widget build(BuildContext context) {
    final presets = dateRangePresets(now);
    final activeId = presetIdMatching(currentRange, now);
    final fmt = DateFormat.yMMMd();
    final currentLabel = currentRange == null
        ? 'No filter (showing every ping)'
        : '${fmt.format(currentRange!.start)} – ${fmt.format(currentRange!.end)}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.date_range_outlined,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  currentLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close, size: 18),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: onClose,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final preset in presets)
                _PresetChip(
                  label: preset.label,
                  selected: preset.id == activeId,
                  onTap: () => onApply(preset.range),
                ),
              _CustomRangeChip(
                onTap: () async {
                  final picked = await _showSystemPicker(context);
                  if (picked != null) onApply(picked);
                },
              ),
              if (currentRange != null)
                _ClearChip(onTap: () => onApply(null)),
            ],
          ),
          if (_showYears) ...[
            const SizedBox(height: 6),
            _yearRow(context),
          ],
        ],
      ),
    );
  }

  /// Second chip row: one chip per calendar year with data, newest
  /// first. A year tap is an ordinary custom range
  /// ([rangeForYear]) pushed through the SAME `onApply` the presets
  /// use, so the map's explicit-refresh behaviour is untouched.
  Widget _yearRow(BuildContext context) {
    final selectedYear = yearOfRange(currentRange);
    // More years than fit: keep the newest, and fold the tail into one
    // "Older…" chip that opens the system picker on the newest hidden
    // year (so the user lands next to what they were reaching for).
    final overflowing = years.length > maxYearChips;
    final shown = overflowing ? years.take(maxYearChips - 1) : years;
    final olderSeedYear = overflowing ? years[maxYearChips - 1] : null;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final year in shown)
          _PresetChip(
            label: '$year',
            selected: year == selectedYear,
            onTap: () => onApply(rangeForYear(year)),
          ),
        if (olderSeedYear != null)
          _CustomRangeChip(
            label: 'Older…',
            onTap: () async {
              final picked = await _showSystemPicker(
                context,
                seed: rangeForYear(olderSeedYear),
              );
              if (picked != null) onApply(picked);
            },
          ),
      ],
    );
  }

  /// Oldest date the system picker will offer. Normally the earliest
  /// fix in the CURRENT filter, widened to 1 Jan of the oldest year in
  /// [years] — without that, filtering to "Today" and then reaching for
  /// "Older…" would be clamped to today and the picker could not travel
  /// back at all (and would assert on an out-of-range initial range).
  DateTime get _pickerFirstDate {
    final base = earliestPing.toLocal().subtract(const Duration(days: 1));
    if (years.isEmpty) return base;
    final oldest = DateTime(years.last, 1, 1);
    return oldest.isBefore(base) ? oldest : base;
  }

  DateTime get _pickerLastDate {
    final base = latestPing.toLocal().add(const Duration(days: 1));
    if (years.isEmpty) return base;
    final newest = DateTime(years.first, 12, 31);
    return newest.isAfter(base) ? newest : base;
  }

  Future<DateTimeRange?> _showSystemPicker(
    BuildContext context, {
    DateTimeRange? seed,
  }) async {
    final firstDate = _pickerFirstDate;
    final lastDate = _pickerLastDate;
    final initial = seed ??
        currentRange ??
        DateTimeRange(
          start: latestPing
              .toLocal()
              .subtract(const Duration(days: 7)),
          end: latestPing.toLocal(),
        );
    var start = initial.start.isBefore(firstDate) ? firstDate : initial.start;
    var end = initial.end.isAfter(lastDate) ? lastDate : initial.end;
    if (end.isBefore(firstDate)) end = firstDate;
    if (start.isAfter(end)) start = end;
    return showDateRangePicker(
      context: context,
      firstDate: firstDate,
      lastDate: lastDate,
      initialDateRange: DateTimeRange(start: start, end: end),
      helpText: 'Filter trail by date',
      saveText: 'Apply',
    );
  }
}

class _PresetChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PresetChip({
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

class _CustomRangeChip extends StatelessWidget {
  final VoidCallback onTap;

  /// "Custom range…" on the preset row, "Older…" on the year row — same
  /// chip, same system picker, only the seed year differs.
  final String label;

  const _CustomRangeChip({required this.onTap, this.label = 'Custom range…'});

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

class _ClearChip extends StatelessWidget {
  final VoidCallback onTap;
  const _ClearChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      label: const Text('Clear', style: TextStyle(fontSize: 12)),
      avatar:
          Icon(Icons.cancel_outlined, size: 14, color: scheme.error),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      side: BorderSide(color: scheme.error.withValues(alpha: 0.4)),
    );
  }
}
