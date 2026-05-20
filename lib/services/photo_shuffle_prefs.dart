import 'package:shared_preferences/shared_preferences.dart';

/// User-controlled shuffle salt for the area-photo rotation. Bumping it
/// reassigns every ping's photo slice from the same cached pool without
/// hitting Wikimedia. Persisted across both isolates (UI + dispatcher)
/// via SharedPreferences — the dispatcher reads salt at ping-time so
/// newly-logged pings join the current shuffle automatically.
class PhotoShufflePrefs {
  static const _saltKey = 'trail_photo_shuffle_salt_v1';

  static Future<int> getSalt() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_saltKey) ?? 0;
  }

  /// Atomically advances the salt by 1, returning the new value.
  /// Two re-shuffle taps within the same tick are still well-defined:
  /// each tap moves the salt forward by 1 (the second read sees the
  /// first write, since SharedPreferences serializes within process).
  static Future<int> bumpSalt() async {
    final p = await SharedPreferences.getInstance();
    final next = (p.getInt(_saltKey) ?? 0) + 1;
    await p.setInt(_saltKey, next);
    return next;
  }
}
