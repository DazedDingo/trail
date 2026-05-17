import 'package:flutter/material.dart';

/// Named quick-pick date ranges the inline calendar panel renders as
/// tappable chips above the "Custom range…" expander. The names are the
/// chip labels; the ranges resolve against the caller-supplied `now` so
/// tests can fix the clock without monkey-patching DateTime.
enum DateRangePresetId { today, yesterday, last7, last30, all }

class DateRangePreset {
  final DateRangePresetId id;
  final String label;
  /// `null` for [DateRangePresetId.all] — Trail's filter pipeline treats
  /// a null range as "no filter / show everything".
  final DateTimeRange? range;

  const DateRangePreset({
    required this.id,
    required this.label,
    required this.range,
  });
}

/// Returns the canonical preset list anchored at [now] (LOCAL time —
/// the calendar UI is local-day; the filter provider converts to UTC at
/// the SQL boundary). Order is fixed: Today → Yesterday → Last 7 days
/// → Last 30 days → All time. Order is part of the contract so tests
/// can pin chip placement.
///
/// "Last 7 days" includes today (so it spans 7 calendar days ending on
/// `now`), matching how every other tracker labels it. Same for Last 30.
List<DateRangePreset> dateRangePresets(DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  return [
    DateRangePreset(
      id: DateRangePresetId.today,
      label: 'Today',
      range: DateTimeRange(start: today, end: today),
    ),
    DateRangePreset(
      id: DateRangePresetId.yesterday,
      label: 'Yesterday',
      range: DateTimeRange(
        start: today.subtract(const Duration(days: 1)),
        end: today.subtract(const Duration(days: 1)),
      ),
    ),
    DateRangePreset(
      id: DateRangePresetId.last7,
      label: 'Last 7 days',
      range: DateTimeRange(
        start: today.subtract(const Duration(days: 6)),
        end: today,
      ),
    ),
    DateRangePreset(
      id: DateRangePresetId.last30,
      label: 'Last 30 days',
      range: DateTimeRange(
        start: today.subtract(const Duration(days: 29)),
        end: today,
      ),
    ),
    const DateRangePreset(
      id: DateRangePresetId.all,
      label: 'All time',
      range: null,
    ),
  ];
}

/// Reverse lookup: given a current filter range, which preset (if any)
/// matches exactly? Used to highlight the currently-selected chip when
/// the panel opens. `null` range → "All time" preset.
DateRangePresetId? presetIdMatching(DateTimeRange? current, DateTime now) {
  for (final preset in dateRangePresets(now)) {
    if (_rangesEqualByDay(preset.range, current)) return preset.id;
  }
  return null;
}

bool _rangesEqualByDay(DateTimeRange? a, DateTimeRange? b) {
  if (a == null && b == null) return true;
  if (a == null || b == null) return false;
  return _sameLocalDay(a.start, b.start) && _sameLocalDay(a.end, b.end);
}

bool _sameLocalDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
