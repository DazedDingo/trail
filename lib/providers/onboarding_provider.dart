import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
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
  /// A `'1'` in the store is the hot answer, and the only one that writes
  /// nothing. Every other outcome — a `null`, an unexpected value, or a
  /// *thrown* read — falls through to two independent fallbacks rather
  /// than being reported as a first run:
  ///
  ///   1. [mirrorKey] in SharedPreferences, and
  ///   2. an existing encrypted `trail.db` — a log on disk is proof that
  ///      onboarding happened, whatever the Keystore says.
  ///
  /// A throw used to propagate instead, on the reasoning that reporting
  /// "not onboarded" would walk a user with years of history back through
  /// the first-run flow; `runStartupGates` then turned it into
  /// `/startup-failed`. In the 2026-08-23 incident that is exactly what
  /// happened — the very first thing startup asks for is this flag, and
  /// `flutter_secure_storage` 11 threw on it at every launch, so the user
  /// never got past the crash screen to the passphrase they *do* have.
  /// Hence the fallbacks (0.17.8).
  ///
  /// A plain `null` now takes the same route. Until 0.17.10 it
  /// short-circuited to `false` unless the one-shot legacy migration had
  /// recorded a failure for this key, because on an upgrade launch a null
  /// could still mean "`flutter_secure_storage` refused to be read". With
  /// that library gone there is one store, it reports an unreadable entry
  /// by *throwing*, and consulting the fallbacks on a null costs one prefs
  /// read and one `stat` — on a genuine first run both answer "no" anyway,
  /// and on a store that quietly lost the flag the DB on disk is the right
  /// answer.
  ///
  /// Anything the fallbacks answer `true` is written back into the store
  /// (and the mirror) — otherwise the next launch would ask the same
  /// question and get the same `null`.
  ///
  /// Only when neither fallback can vouch for it does the read come back
  /// `false`. Nothing is lost by that: the key-state gate
  /// (`computeStartupKeyState`) still rethrows the same failure, so a
  /// genuinely broken store still reaches `/startup-failed` — just with
  /// the accurate stage on it.
  static Future<bool> isComplete() async {
    try {
      if (await secureStorage.read(key: storageKey) == '1') return true;
    } catch (e) {
      debugPrint('[OnboardingGate] secure storage read failed: $e');
    }
    if (await _readMirror()) return _healAndAccept();
    try {
      if (await KeystoreKey.dbFileExists()) return await _healAndAccept();
    } catch (e2) {
      // "I could not look" — the key-state gate owns that diagnosis.
      debugPrint('[OnboardingGate] db probe failed too: $e2');
    }
    return false;
  }

  /// A fallback said yes. Record that in both durable homes so the next
  /// launch never has to ask a fallback again, then answer `true`.
  /// Best-effort throughout: this runs inside a startup gate.
  static Future<bool> _healAndAccept() async {
    try {
      await secureStorage.write(key: storageKey, value: '1');
    } catch (e) {
      debugPrint('[OnboardingGate] re-seed failed: $e');
    }
    await writeMirror();
    return true;
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
