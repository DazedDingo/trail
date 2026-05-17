import 'package:shared_preferences/shared_preferences.dart';

/// How often the "How is it?" post-ping prompt is allowed to fire.
/// Persisted as the enum's `.name` so the dispatcher background isolate
/// + the UI isolate share the same source of truth via a flat string.
///
/// `off` is the install default. `everyPing` matches the original
/// boolean toggle behaviour (a prompt after every successful real-fix
/// scheduled ping). The other entries are rate-limited caps measured
/// from the last-posted timestamp.
enum HowIsItFrequency {
  off,
  everyPing,
  hourly,
  every4h,
  daily;

  String get label {
    switch (this) {
      case HowIsItFrequency.off:
        return 'Off';
      case HowIsItFrequency.everyPing:
        return 'After every ping';
      case HowIsItFrequency.hourly:
        return 'Max once per hour';
      case HowIsItFrequency.every4h:
        return 'Max once every 4 hours';
      case HowIsItFrequency.daily:
        return 'Max once per day';
    }
  }

  /// Minimum elapsed time between two prompts. `Duration.zero` for
  /// `everyPing` (no rate limit) and `off` (never fires, the limit is
  /// moot but zero is the right sentinel). Other entries cap at the
  /// natural cadence.
  Duration get minInterval {
    switch (this) {
      case HowIsItFrequency.off:
      case HowIsItFrequency.everyPing:
        return Duration.zero;
      case HowIsItFrequency.hourly:
        return const Duration(hours: 1);
      case HowIsItFrequency.every4h:
        return const Duration(hours: 4);
      case HowIsItFrequency.daily:
        return const Duration(hours: 24);
    }
  }

  static HowIsItFrequency fromString(String? raw) {
    if (raw == null) return HowIsItFrequency.off;
    for (final f in HowIsItFrequency.values) {
      if (f.name == raw) return f;
    }
    return HowIsItFrequency.off;
  }
}

/// Settings-side state for the "How is it?" quick-comment notification
/// flow. Persists the frequency enum + the last-posted timestamp so
/// both the UI isolate (Settings screen) and the WorkManager background
/// isolate (which decides whether to post the prompt after each
/// scheduled ping) share one source of truth.
class HowIsItService {
  static const _kKeyFrequency = 'trail_how_is_it_frequency_v2';
  static const _kKeyLastPostedMs = 'trail_how_is_it_last_posted_ms_v2';
  // v1 key — kept readable so existing installs migrate cleanly.
  static const _kKeyLegacyEnabled = 'trail_how_is_it_enabled_v1';

  /// Current frequency. Reads the v2 key first; falls back to the v1
  /// boolean migration path (`true` → `everyPing`, `false` → `off`) so
  /// users who toggled it on in 0.12.0 don't lose their preference.
  Future<HowIsItFrequency> getFrequency() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKeyFrequency);
    if (raw != null) return HowIsItFrequency.fromString(raw);
    final legacy = prefs.getBool(_kKeyLegacyEnabled);
    if (legacy == true) return HowIsItFrequency.everyPing;
    return HowIsItFrequency.off;
  }

  Future<void> setFrequency(HowIsItFrequency frequency) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKeyFrequency, frequency.name);
    // Drop the legacy key once the user makes an explicit v2 choice so
    // a subsequent downgrade-then-upgrade doesn't snap back to the old
    // value.
    await prefs.remove(_kKeyLegacyEnabled);
  }

  /// Last time we posted a "How is it?" prompt — used by the rate
  /// limiter. `null` when no prompt has ever fired (or after a fresh
  /// install). Stored as ms-since-epoch in UTC.
  Future<DateTime?> getLastPostedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_kKeyLastPostedMs);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  Future<void> setLastPostedAt(DateTime utc) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _kKeyLastPostedMs,
      utc.toUtc().millisecondsSinceEpoch,
    );
  }

  /// Back-compat helper for the v1 boolean toggle. Returns true when
  /// the current frequency is anything other than `off`. Kept so the
  /// existing call sites in the WorkManager dispatcher don't all
  /// need to migrate in one commit.
  Future<bool> isEnabled() async {
    return (await getFrequency()) != HowIsItFrequency.off;
  }

  /// Back-compat setter. `true` migrates a fresh install to `everyPing`
  /// (the original boolean behaviour); `false` collapses to `off`. New
  /// callers should use `setFrequency` directly.
  Future<void> setEnabled(bool value) async {
    await setFrequency(
        value ? HowIsItFrequency.everyPing : HowIsItFrequency.off);
  }
}

// ─── Pure rate-limit helper ─────────────────────────────────────────

/// Returns true when a fresh prompt is allowed under the current
/// [frequency], given the [lastPostedAt] (`null` if never) and the
/// current [now]. Off always returns false; everyPing always true;
/// the timed entries gate on `(now - lastPostedAt) >= minInterval`.
///
/// Pure — exported for unit testing without touching SharedPreferences.
bool shouldPostHowIsIt({
  required HowIsItFrequency frequency,
  required DateTime? lastPostedAt,
  required DateTime now,
}) {
  switch (frequency) {
    case HowIsItFrequency.off:
      return false;
    case HowIsItFrequency.everyPing:
      return true;
    case HowIsItFrequency.hourly:
    case HowIsItFrequency.every4h:
    case HowIsItFrequency.daily:
      if (lastPostedAt == null) return true;
      final elapsed = now.difference(lastPostedAt);
      return elapsed >= frequency.minInterval;
  }
}

// ─── Pure helpers (exported for the test suite) ─────────────────────────

/// (title, body) for the post-ping prompt. Title stays human; body
/// gives the user context for what they're commenting on (the local
/// time of the just-logged ping).
({String title, String body}) formatHowIsItPrompt(DateTime pingLocal) {
  final hh = pingLocal.hour.toString().padLeft(2, '0');
  final mm = pingLocal.minute.toString().padLeft(2, '0');
  return (
    title: 'How is it?',
    body: 'Tap to add a quick comment to your $hh:$mm ping.',
  );
}

/// Sanitizes the raw reply text from a notification action. Trims
/// whitespace, collapses multi-line input to a single line (Android
/// reply UIs let users press Enter mid-message), and bounds the length
/// at 280 chars (Twitter-era social-norm cap; longer reads as a journal
/// entry, which isn't what this surface is for). Returns `null` for
/// empty/whitespace-only input so the caller can no-op without writing
/// a stub row.
String? sanitizeQuickComment(String? raw) {
  if (raw == null) return null;
  final flat = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return null;
  const maxLen = 280;
  if (flat.length <= maxLen) return flat;
  return '${flat.substring(0, maxLen - 1)}…';
}
