/// Fixed date/time labels for anything that names a single fix.
///
/// **Every pin label carries the year.** Once a Google Timeline import
/// lands (0.16.0) the map holds years of history, and a HUD that reads
/// "11 Aug" is ambiguous across a decade of 11 Augusts — scrubbing the
/// slider through 2019 looked identical to scrubbing through 2026.
///
/// Day-before-month (`11 Aug 2024`) is the UK reading order, and the
/// patterns are explicit rather than locale skeletons so the map HUD,
/// the pin sheet, the delete confirmation and the slideshow can never
/// drift apart. `DateFormat.yMMMd()` stays in the locale-driven places
/// that already used it (History, trips, the date-filter chips).
///
/// Pure + top-level so it is unit-testable without a widget tree
/// (CLAUDE.md gotcha 18) — see `test/date_labels_test.dart`.
///
/// The formats are built once at first use, not per build: a
/// `DateFormat` constructed inside `build()` re-parses its pattern on
/// every frame, and the playback HUD rebuilds on every tick
/// (docs/PERF_PLAN.md §16). Callers pass an already-`toLocal()`ed
/// `DateTime`; nothing here converts time zones.
library;

import 'package:intl/intl.dart';

/// `11 Aug 2024, 14:05` — the time-slider HUD and the slideshow's
/// "photos for …" messages.
final DateFormat kPinTimeFormat = DateFormat('d MMM yyyy, HH:mm');

/// `11 Aug 2024 14:05` — the playback HUD, where the comma costs width
/// in a two-line overlay pinned over the map.
final DateFormat kHudTimeFormat = DateFormat('d MMM yyyy HH:mm');

/// `Sun 11 Aug 2024, 14:05:03` — the pin detail sheet header and the
/// delete confirmation, both of which identify one exact row.
final DateFormat kPinTimeWithWeekdayFormat =
    DateFormat('EEE d MMM yyyy, HH:mm:ss');

/// `11 Aug 2024 · 14:05` — the slideshow slide caption, which uses the
/// middle-dot separator shared with the rest of the photo furniture.
final DateFormat kPhotoCaptionTimeFormat = DateFormat('d MMM yyyy · HH:mm');

/// `11 Aug 2024, 14:05`.
String formatPinTime(DateTime local) => kPinTimeFormat.format(local);

/// `11 Aug 2024 14:05`.
String formatHudTime(DateTime local) => kHudTimeFormat.format(local);

/// `Sun 11 Aug 2024, 14:05:03`.
String formatPinTimeWithWeekday(DateTime local) =>
    kPinTimeWithWeekdayFormat.format(local);

/// `11 Aug 2024 · 14:05`.
String formatPhotoCaptionTime(DateTime local) =>
    kPhotoCaptionTimeFormat.format(local);
