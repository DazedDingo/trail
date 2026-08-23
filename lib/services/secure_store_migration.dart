import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail_secure_store/trail_secure_store.dart';

/// A [TrailSecureStore] that lifts Trail's existing secrets out of
/// `flutter_secure_storage` on the way past, once, and then forgets that
/// the old plugin ever existed.
///
/// ## The shape of the problem
///
/// 0.17.9 moves every secret to a store Trail owns
/// (`packages/trail_secure_store/`). On the upgrade launch that store is
/// empty and the old one holds everything — or, on the phone this release
/// exists for, holds everything and refuses to hand any of it back
/// (`KeyStoreException UNKNOWN_ERROR -1000`). Both outcomes have to be
/// survivable, and neither may add an `await` before `runApp`
/// (CLAUDE.md gotcha 30).
///
/// So the migration is lazy and per-key rather than a startup pass:
///
/// * [read] answers from the new store. A hit costs one AES-GCM decrypt
///   and nothing else — the legacy plugin is not touched.
/// * A miss consults the legacy store **once for that key**, inside a
///   try/catch and a [legacyTimeout] (the 0.17.5 incident included reads
///   that never returned, and a hang before the first frame is the worst
///   failure mode this app has). A value found there is copied into the
///   new store and returned.
/// * Once every key in `knownKeys` has been tried, [markerKey] goes into
///   SharedPreferences and the legacy plugin is never called again — on
///   this launch or any later one. [migrateLegacySecrets] does the same
///   pass eagerly, post-first-frame, for the keys nothing happened to ask
///   for.
///
/// A legacy read that fails is *recorded*, not thrown: the caller asked
/// for a value, and "the old plugin is broken" is not an answer to that
/// question. It is, however, exactly what
/// `OnboardingGate.isComplete` and `PassphraseRecoveryService` need to
/// know, so [legacyFailedFor] and [lastLegacyError] expose it.
class MigratingSecureStore implements TrailSecureStore {
  MigratingSecureStore({
    required TrailSecureStore store,
    required FlutterSecureStorage legacy,
    required List<String> knownKeys,
    SharedPreferences? prefs,
    this.legacyTimeout = const Duration(seconds: 3),
  })  : _store = store,
        _legacy = legacy,
        _knownKeys = List.unmodifiable(knownKeys),
        _prefs = prefs;

  /// SharedPreferences flag: every known secret has been offered the
  /// chance to come across, so the legacy plugin is done with.
  static const markerKey = 'trail_secure_store_migrated_v1';

  final TrailSecureStore _store;
  final FlutterSecureStorage _legacy;
  final List<String> _knownKeys;
  final SharedPreferences? _prefs;

  /// Cap on a single legacy read. A hung platform channel used to mean a
  /// frozen Android splash; the startup gate's own 15 s timeout is the
  /// backstop, but paying it six times over is not a startup.
  final Duration legacyTimeout;

  final Set<String> _attempted = <String>{};
  final Map<String, String> _legacyErrors = <String, String>{};

  bool _migrated = false;
  bool _markerChecked = false;

  /// Whether the legacy store is finished with (this process, or a marker
  /// from an earlier launch).
  bool get migrated => _migrated;

  /// The most recent legacy failure, or `null` if the old plugin has not
  /// misbehaved. `PassphraseRecoveryService` uses it to decide whether
  /// the plugin is the broken part and the rescue flow is warranted.
  String? get lastLegacyError => _lastLegacyError;
  String? _lastLegacyError;

  /// Whether the one legacy read for [key] failed (threw, or timed out).
  ///
  /// The difference this answers is the important one: a `null` from
  /// [read] means "no such secret" on a healthy device but "I could not
  /// look" on a broken one, and `OnboardingGate` must not walk a user
  /// with years of history back through the first-run flow because of
  /// the second.
  bool legacyFailedFor(String key) => _legacyErrors.containsKey(key);

  @override
  Future<String?> read({required String key}) async {
    final value = await _store.read(key: key);
    if (value != null) return value;
    if (await _legacyIsDone()) return null;
    return _pullFromLegacy(key);
  }

  @override
  Future<void> write({required String key, required String? value}) async {
    // Whatever the legacy store holds for this key is now stale; never
    // let a later miss pull it back over the top.
    _attempted.add(key);
    await _store.write(key: key, value: value);
  }

  @override
  Future<void> delete({required String key}) async {
    _attempted.add(key);
    await _store.delete(key: key);
  }

  /// Migration-aware, so it agrees with [read] rather than with the raw
  /// store during the one launch where the two can differ.
  @override
  Future<bool> containsKey({required String key}) async =>
      await read(key: key) != null;

  /// The new store only — [readAll] is a diagnostic, not a migration
  /// path, and enumerating the legacy store means calling it once per
  /// launch forever.
  @override
  Future<Map<String, String>> readAll() => _store.readAll();

  @override
  Future<void> deleteAll() async {
    _attempted.addAll(_knownKeys);
    await _store.deleteAll();
  }

  @override
  Future<SecureStoreStatus> status() => _store.status();

  /// The eager pass, run post-first-frame from `main()`.
  ///
  /// Tries every key the lazy path has not already handled, then records
  /// [markerKey] **whatever happened** — a legacy store that cannot be
  /// read will not read any better tomorrow, and re-calling it on every
  /// launch is the exact risk (`createRSAKeysIfNeeded`) this release
  /// exists to stop taking. Never throws.
  Future<void> migrateLegacySecrets() async {
    if (await _legacyIsDone()) return;
    for (final key in _knownKeys) {
      if (_attempted.contains(key)) continue;
      try {
        if (await _store.read(key: key) != null) {
          _attempted.add(key);
          continue;
        }
      } catch (e) {
        // Our own store is unhappy for this key. Nothing to migrate into,
        // so leave the legacy value where it is.
        debugPrint('[secure store] pre-migration read of $key failed: $e');
        _attempted.add(key);
        continue;
      }
      await _pullFromLegacy(key);
    }
    await _finish();
  }

  /// One best-effort read of the legacy store. Returns what it found, or
  /// `null` for both "nothing there" and "could not look" — the caller
  /// tells them apart with [legacyFailedFor].
  Future<String?> _pullFromLegacy(String key) async {
    if (_attempted.contains(key)) return null;
    _attempted.add(key);

    String? value;
    try {
      value = await _legacy.read(key: key).timeout(legacyTimeout);
    } catch (e) {
      _legacyErrors[key] = '$e';
      _lastLegacyError = '$e';
      debugPrint('[secure store] legacy read of $key failed: $e');
    }

    if (value != null && value.isNotEmpty) {
      try {
        await _store.write(key: key, value: value);
      } catch (e) {
        // The value is still returned — a store that will not take the
        // copy is not a reason to withhold the answer.
        debugPrint('[secure store] copying $key across failed: $e');
      }
    }

    if (_attempted.containsAll(_knownKeys)) await _finish();
    return value;
  }

  Future<bool> _legacyIsDone() async {
    if (_migrated) return true;
    if (_markerChecked) return false;
    _markerChecked = true;
    try {
      final store = _prefs ?? await SharedPreferences.getInstance();
      _migrated = store.getBool(markerKey) ?? false;
    } catch (e) {
      // No prefs backend (unit tests, a broken install): treat it as "not
      // migrated" and let the pass run again. Re-reading the legacy store
      // is wasteful, never destructive.
      debugPrint('[secure store] migration marker unreadable: $e');
    }
    return _migrated;
  }

  Future<void> _finish() async {
    // In-memory first: even if prefs refuses, this process is done asking.
    _migrated = true;
    try {
      final store = _prefs ?? await SharedPreferences.getInstance();
      await store.setBool(markerKey, true);
    } catch (e) {
      debugPrint('[secure store] could not record the migration marker: $e');
    }
  }

  /// The keys whose legacy read has already been attempted this process.
  @visibleForTesting
  Set<String> get attemptedKeys => Set.unmodifiable(_attempted);

  /// Forgets that the migration ever ran. The app-wide [MigratingSecureStore]
  /// is a top-level `final`, so without this a test that pulls a key from
  /// the legacy fake leaks "already attempted" into every test after it.
  @visibleForTesting
  void resetForTest() {
    _attempted.clear();
    _legacyErrors.clear();
    _lastLegacyError = null;
    _migrated = false;
    _markerChecked = false;
  }
}
