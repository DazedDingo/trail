import 'package:shared_preferences/shared_preferences.dart';

/// Settings-side state for the "How is it?" quick-comment notification
/// flow. Persists a single bool to SharedPreferences so both the UI
/// isolate (Settings screen) and the WorkManager background isolate
/// (which decides whether to post the prompt after each scheduled ping)
/// read the same source of truth.
class HowIsItService {
  static const _kKey = 'trail_how_is_it_enabled_v1';

  /// True when the user has opted into the post-ping prompt. Defaults
  /// to false — the prompt is opt-in to keep notifications quiet on
  /// install (the panic channel is the only one that earns auto-on).
  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kKey) ?? false;
  }

  Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kKey, value);
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
