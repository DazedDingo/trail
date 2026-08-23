import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _statsIncludeImportsKey = 'trail_stats_include_imports_v1';

/// Opt-in: does Stats (heatmap, top places, time-of-day, trips) also
/// count imported Google Timeline history?
///
/// Default is **false** — the commander's decision is that Timeline
/// imports are map-only (CLAUDE.md gotcha 34, docs/TIMELINE_IMPORT.md
/// exclusions); a user with a decade of imported history shouldn't have
/// their "top places" or "time of day" silently swamped by it. Flipping
/// this on is a deliberate per-user choice, not a new default.
///
/// Persisted in plain SharedPreferences (not secure storage) — this is
/// a display preference, not sensitive data, same tier as
/// `homeMapHeightProvider`.
final statsIncludeImportsProvider =
    AsyncNotifierProvider<StatsIncludeImportsNotifier, bool>(
  StatsIncludeImportsNotifier.new,
);

class StatsIncludeImportsNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_statsIncludeImportsKey) ?? false;
    } catch (_) {
      // Transient prefs read failure — fall back to the safer default
      // (map-only) rather than surfacing imported history unasked.
      return false;
    }
  }

  Future<void> set(bool value) async {
    state = AsyncData(value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_statsIncludeImportsKey, value);
    } catch (_) {
      // In-memory state is still correct; user can retry from Settings
      // if persistence failed transiently.
    }
  }
}
