import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/keystore_key.dart';
import '../services/secure_storage.dart';

/// Whether the user has completed the first-run onboarding flow.
///
/// Stored in secure storage so it survives app upgrades but not reinstall.
/// A `ValueNotifier` wrapped via `StateProvider` so the router can
/// synchronously read it inside `redirect` without async plumbing.
final onboardingCompleteProvider = StateProvider<bool>((ref) => false);

class OnboardingGate {
  /// The secure-storage key holding the flag. Public so
  /// `PassphraseRecoveryService` can re-seed it by name when it rebuilds
  /// the store from scratch.
  static const storageKey = 'trail_onboarded_v1';

  /// SharedPreferences mirror of [storageKey], written alongside it by
  /// [markComplete]. Plain prefs on purpose: the whole point is that it
  /// is readable when the Keystore-backed store is not. It holds no
  /// secret — "this user finished onboarding" is not sensitive.
  static const mirrorKey = 'trail_onboarded_mirror_v1';

  /// Whether onboarding has been completed on this install.
  ///
  /// A missing key (`null`) is a genuine "no" — that is a first run.
  ///
  /// A *thrown* read is not, and since 0.17.8 it is no longer fatal
  /// either. It used to propagate, on the reasoning that reporting "not
  /// onboarded" would walk a user with years of history back through the
  /// first-run flow; `runStartupGates` then turned it into
  /// `/startup-failed`. In the 2026-08-23 incident that is exactly what
  /// happened — the very first thing startup asks for is this flag, and
  /// `flutter_secure_storage` 11 threw on it at every launch, so the
  /// user never got past the crash screen to the passphrase they *do*
  /// have. Two independent fallbacks answer it instead:
  ///
  ///   1. [mirrorKey] in SharedPreferences, and
  ///   2. an existing encrypted `trail.db` — a log on disk is proof that
  ///      onboarding happened, whatever the Keystore says.
  ///
  /// Only when neither can vouch for it does a thrown read read as
  /// `false`. Nothing is lost by that: the key-state gate
  /// (`computeStartupKeyState`) still rethrows the same plugin failure,
  /// so a genuinely broken store still reaches `/startup-failed` — just
  /// with the accurate stage on it.
  static Future<bool> isComplete() async {
    try {
      return await secureStorage.read(key: storageKey) == '1';
    } catch (e) {
      debugPrint('[OnboardingGate] secure storage read failed: $e');
      if (await _readMirror()) return true;
      try {
        if (await KeystoreKey.dbFileExists()) return true;
      } catch (e2) {
        // "I could not look" — the key-state gate owns that diagnosis.
        debugPrint('[OnboardingGate] db probe failed too: $e2');
      }
      return false;
    }
  }

  /// Writes both copies. Each is best-effort and independent: onboarding
  /// must not be un-completable because one store is unhappy.
  static Future<void> markComplete({SharedPreferences? prefs}) async {
    try {
      await secureStorage.write(key: storageKey, value: '1');
    } catch (e) {
      debugPrint('[OnboardingGate] persist failed: $e');
    }
    await writeMirror(prefs: prefs);
  }

  /// Best-effort write of [mirrorKey] alone. Called by [markComplete] and
  /// by `PassphraseRecoveryService` after it rebuilds secure storage, so
  /// a store that breaks again later still has the plain-prefs answer.
  static Future<void> writeMirror({SharedPreferences? prefs}) async {
    try {
      final store = prefs ?? await SharedPreferences.getInstance();
      await store.setBool(mirrorKey, true);
    } catch (e) {
      debugPrint('[OnboardingGate] mirror persist failed: $e');
    }
  }

  static Future<bool> _readMirror({SharedPreferences? prefs}) async {
    try {
      final store = prefs ?? await SharedPreferences.getInstance();
      return store.getBool(mirrorKey) ?? false;
    } catch (e) {
      debugPrint('[OnboardingGate] mirror read failed: $e');
      return false;
    }
  }
}
