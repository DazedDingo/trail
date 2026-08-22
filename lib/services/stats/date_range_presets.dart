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

/// Descending list of the calendar YEARS spanned by the pings table,
/// from the newest timestamp's local year down to the oldest one's.
/// `[minUtcMs, maxUtcMs]` are epoch-ms UTC instants (`PingDao.tsRange`);
/// either being null means "no fixes at all" → empty list.
///
/// Local time on purpose: the chips sit next to Today / Yesterday,
/// which are local-day presets, and a fix logged at 23:30 on 31 Dec
/// local belongs to the year the user remembers it in, not to the UTC
/// one. (`DateTime.toLocal()` on the parsed instant does that.)
///
/// [now] clamps the top of the range: a single row with a skewed clock
/// (or a Timeline export carrying a bogus 2099 stamp) must not spray 70
/// junk chips across the panel. Anything above the current year is
/// reachable through "All time" / the custom picker instead. The clamp
/// never cuts below the oldest year, so a wholly-future dataset still
/// yields one chip.
List<int> yearsCovering({
  required int? minUtcMs,
  required int? maxUtcMs,
  required DateTime now,
}) {
  if (minUtcMs == null || maxUtcMs == null) return const [];
  final lo = _localYear(minUtcMs <= maxUtcMs ? minUtcMs : maxUtcMs);
  final hiRaw = _localYear(minUtcMs <= maxUtcMs ? maxUtcMs : minUtcMs);
  final hi = hiRaw > now.year && now.year >= lo ? now.year : hiRaw;
  return [for (var y = hi; y >= lo; y--) y];
}

int _localYear(int utcMs) =>
    DateTime.fromMillisecondsSinceEpoch(utcMs, isUtc: true).toLocal().year;

/// The filter range for one whole calendar [year], in the same shape
/// every other range in the app uses: LOCAL midnight on the first day →
/// LOCAL midnight on the last day.
///
/// The end bound is `31 Dec 00:00`, not `23:59:59.999`, precisely so the
/// two SQL clips stay unchanged — both widen a range's end themselves:
///   * map (`mapRangeUtcBounds`): `end + 1 day − 1 ms` ⇒ inclusive
///     through 31 Dec 23:59:59.999 local;
///   * export (`exportRangeUtcBounds`): midnight of `end`'s day + 1 day,
///     exclusive ⇒ the same instant.
/// Handing them a `23:59:59.999` end would push the map a further day
/// out and leak 1 Jan of the following year into a "2024" chip. This is
/// also exactly what the system date-range picker returns for the same
/// two days, so a year chip and a hand-picked 1 Jan – 31 Dec range are
/// indistinguishable downstream (which is what [yearOfRange] relies on).
DateTimeRange rangeForYear(int year) => DateTimeRange(
      start: DateTime(year, 1, 1),
      end: DateTime(year, 12, 31),
    );

/// Reverse of [rangeForYear]: the year when [r] spans exactly one whole
/// calendar year, else null. Drives which year chip renders selected.
///
/// Compared by calendar day (like [presetIdMatching]), so a range that
/// carries a time-of-day — e.g. one restored from a previous session —
/// still lights its chip. "All time" (null) and every rolling preset
/// return null.
int? yearOfRange(DateTimeRange? r) {
  if (r == null) return null;
  if (r.start.year != r.end.year) return null;
  if (r.start.month != DateTime.january || r.start.day != 1) return null;
  if (r.end.month != DateTime.december || r.end.day != 31) return null;
  return r.start.year;
}
