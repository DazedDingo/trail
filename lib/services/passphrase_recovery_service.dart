import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/database.dart';
import '../db/keystore_key.dart';
import '../providers/onboarding_provider.dart';
import 'key_escrow.dart';
import 'passphrase_service.dart';
import 'secure_storage.dart';
import 'secure_storage_migration.dart';
import 'secure_storage_rescue.dart';
import 'secure_store_migration.dart';
import 'startup_gates.dart';

/// SharedPreferences key holding the last [SecureStorageRescueSummary].
/// Read by the Diagnostics tile; plain prefs, because the whole scenario
/// is "secure storage cannot be read".
const secureStorageRescueKey = 'trail_secure_storage_rescue_v1';

/// `23 Aug 2026` — the day-before-month house style, as everywhere else.
final DateFormat _rescueDateFormat = DateFormat('d MMM yyyy');

/// Human name for one of `SecureStorageMigration.knownKeys`. Unknown keys
/// pass through verbatim — a future secret that nobody added here should
/// still be nameable in the result sheet.
String secureStorageKeyLabel(String key) => switch (key) {
      'trail_db_passphrase_v1' => 'database key',
      'trail_onboarded_v1' => 'onboarding flag',
      'trail_panic_duration_v1' => 'panic duration',
      'trail_panic_auto_send_v1' => 'panic auto-send',
      'trail_github_pat_v1' => 'GitHub token',
      'trail_coverage_token_v1' => 'map-detail server token',
      _ => key,
    };

/// What one secure-storage rebuild did, as a value: persisted for
/// Diagnostics and rendered in the result sheet.
@immutable
class SecureStorageRescueSummary {
  const SecureStorageRescueSummary({
    required this.at,
    required this.rebuilt,
    this.method,
    this.recovered = const [],
    this.missing = const [],
    this.attempts = const [],
    this.error,
  });

  final DateTime at;

  /// Whether the old store was set aside and a fresh one seeded. `false`
  /// means the native call refused — the unlock still stands (the DB key
  /// is in Trail's own escrow), but the store is still broken.
  final bool rebuilt;

  /// Which unwrap combination read the old AES key, if any.
  final String? method;

  /// Secure-storage keys that are back in the store afterwards.
  final List<String> recovered;

  /// The `knownKeys` that are not. Some were never set by this user;
  /// the sheet says "re-enter them in Settings" rather than guessing.
  final List<String> missing;

  /// `<attempt> → <ExceptionClass>` from the native side, for bug reports.
  final List<String> attempts;

  /// Non-fatal problems, joined. Non-null does not mean the unlock failed.
  final String? error;

  int get knownKeyCount => SecureStorageMigration.knownKeys.length;

  String toJson() => jsonEncode({
        'at': at.millisecondsSinceEpoch,
        'rebuilt': rebuilt,
        'method': method,
        'recovered': recovered,
        'missing': missing,
        'attempts': attempts,
        'error': error,
      });

  /// Malformed / missing → `null`, never a throw (same rule as every
  /// other persisted record in this app).
  static SecureStorageRescueSummary? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final at = decoded['at'];
      if (at is! int) return null;
      List<String> list(Object? v) => (v as List?)
              ?.whereType<String>()
              .toList(growable: false) ??
          const <String>[];
      return SecureStorageRescueSummary(
        at: DateTime.fromMillisecondsSinceEpoch(at),
        rebuilt: decoded['rebuilt'] == true,
        method: decoded['method'] as String?,
        recovered: list(decoded['recovered']),
        missing: list(decoded['missing']),
        attempts: list(decoded['attempts']),
        error: decoded['error'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Pure: the result sheet's body after a rebuild.
String describeRescueOutcome(SecureStorageRescueSummary summary) {
  final buf = StringBuffer('Log unlocked. ');
  if (!summary.rebuilt) {
    buf.write('Secure storage could not be rebuilt');
    if (summary.error != null) buf.write(' (${summary.error})');
    buf.write(' — your log is safe and its key is in Trail\'s own escrow, '
        'but stored settings stay unreadable until this is fixed.');
    return buf.toString();
  }
  final recovered =
      summary.recovered.map(secureStorageKeyLabel).join(', ');
  buf.write('Secure storage was rebuilt — recovered '
      '${summary.recovered.length} of ${summary.knownKeyCount} settings');
  if (recovered.isNotEmpty) buf.write(' ($recovered)');
  buf.write('.');
  if (summary.missing.isNotEmpty) {
    final missing = summary.missing.map(secureStorageKeyLabel).join(', ');
    buf.write(' Could not recover: $missing — re-enter them in Settings.');
  }
  return buf.toString();
}

/// Pure: the Diagnostics line for the last rebuild.
String describeSecureStorageRescue(SecureStorageRescueSummary? summary) {
  if (summary == null) return 'Secure storage rescue: never run';
  final buf = StringBuffer('Secure storage rescue: ')
    ..write(_rescueDateFormat.format(summary.at.toLocal()))
    ..write(' · ${summary.recovered.length}/${summary.knownKeyCount} '
        'recovered');
  if (!summary.rebuilt) buf.write(' · not rebuilt');
  if (summary.method != null) buf.write(' · ${summary.method}');
  if (summary.error != null) buf.write(' · ${summary.error}');
  return buf.toString();
}

/// Pure: the Diagnostics line for the store file itself.
String describeSecureStorageStoreFile(RescueStatus status) {
  if (status.error != null) {
    return 'Secure storage store file: unavailable (${status.error})';
  }
  final buf = StringBuffer('Secure storage store file: ')
    ..write(status.storeFileExists ? 'present' : 'missing');
  final copies = status.brokenCopies;
  if (copies.isNotEmpty) {
    final at = parseBrokenCopyStamp(copies.last);
    buf.write(' · set aside on ');
    buf.write(at == null ? copies.last : _rescueDateFormat.format(at));
  }
  return buf.toString();
}

/// Pure: the `yyyyMMdd-HHmm` stamp out of `FlutterSecureStorage
/// .broken-20260823-1030.xml`. `null` for anything that does not match —
/// the caller falls back to printing the file name.
DateTime? parseBrokenCopyStamp(String fileName) {
  final match =
      RegExp(r'\.broken-(\d{8})-(\d{4})\.xml$').firstMatch(fileName);
  if (match == null) return null;
  final d = match.group(1)!;
  final t = match.group(2)!;
  return DateTime.tryParse('${d.substring(0, 4)}-${d.substring(4, 6)}-'
      '${d.substring(6, 8)} ${t.substring(0, 2)}:${t.substring(2, 4)}:00');
}

/// Outcome of [PassphraseRecoveryService.unlock].
@immutable
class PassphraseRecoveryResult {
  const PassphraseRecoveryResult.unlocked({this.rescue})
      : ok = true,
        error = null;

  const PassphraseRecoveryResult.failed(String this.error)
      : ok = false,
        rescue = null;

  final bool ok;

  /// User-facing text for the entry screen's error slot. Non-null iff
  /// [ok] is false; nothing was written in that case.
  final String? error;

  /// Non-null when secure storage had to be rebuilt on the way in — the
  /// entry screen shows a result sheet for it.
  final SecureStorageRescueSummary? rescue;
}

/// The unlock-and-repair flow behind `/unlock`.
///
/// Ordering is the whole design, because one step is irreversible and
/// another is booby-trapped:
///
/// 1. **Derive** the key from the passphrase + the on-disk salt.
/// 2. **Verify** it by actually opening `trail.db`
///    ([TrailDatabase.openWithKeyForVerification]). A wrong passphrase
///    stops here with nothing written anywhere.
/// 3. **Escrow it, and only it** — `KeyEscrow.store`, no secure-storage
///    call yet. Every `flutter_secure_storage` call is another run of the
///    plugin's `createRSAKeysIfNeeded`, which regenerates the RSA pair
///    the moment Android reports the alias missing (gotcha 38) — and that
///    would orphan the very wrapped AES key step 5 is about to read. So
///    the plugin is not touched at all until the rescue has had its look.
/// 4. **Diagnose**: is the plugin broken? Either the startup read already
///    failed ([KeystoreKey.lastSecureStorageError]) or
///    [SecureStorageRescue.status] shows a wrapped key whose Keystore
///    alias is gone. A healthy store skips to [KeystoreKey.persist] and
///    that is the end of it.
/// 5. **Rescue** ([SecureStorageRescue.rescue], read-only) to lift the old
///    secrets out from underneath the library, **then**
/// 6. **Set aside** ([SecureStorageRescue.setAside]) — which deletes the
///    plugin's Keystore aliases and so makes the old wrapped AES key
///    unrecoverable forever — **then**
/// 7. **Persist + re-seed** the now-fresh store, then the markers.
///
/// Nothing irreversible happens before a verified key is safely escrowed
/// and the rescue has had its one chance; `setAside` is never called on
/// its own, and never at all when the escrow refused the key.
class PassphraseRecoveryService {
  PassphraseRecoveryService({
    Future<void> Function(String key)? verifyKey,
    SecureStorageRescue? rescue,
    MigratingSecureStore? storage,
    SharedPreferences? prefs,
    DateTime Function()? now,
  })  : _verifyKey = verifyKey ?? TrailDatabase.openWithKeyForVerification,
        _rescue = rescue ?? SecureStorageRescue.instance,
        _storage = storage ?? secureStorage,
        _prefs = prefs,
        _now = now ?? DateTime.now;

  final Future<void> Function(String key) _verifyKey;
  final SecureStorageRescue _rescue;
  final MigratingSecureStore _storage;
  final SharedPreferences? _prefs;
  final DateTime Function() _now;

  static const wrongPassphraseMessage =
      'Wrong passphrase — that did not unlock your log. Try again.';
  static const saltMissingMessage =
      'Salt file missing — backup data is incomplete. Reset DB in settings.';

  /// Pure: is [e] SQLCipher's way of saying "that key is wrong"? A wrong
  /// key is not detected at open time — the first query is what fails.
  static bool isWrongPassphrase(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('file is not a database') ||
        s.contains('file is encrypted') ||
        s.contains('not a database');
  }

  Future<PassphraseRecoveryResult> unlock(String passphrase) async {
    if (passphrase.isEmpty) {
      return const PassphraseRecoveryResult.failed(
        'Enter your backup passphrase.',
      );
    }
    final Uint8List? salt;
    try {
      salt = await PassphraseService.readSalt();
    } catch (e) {
      return PassphraseRecoveryResult.failed('Could not read the salt: $e');
    }
    if (salt == null) {
      return const PassphraseRecoveryResult.failed(saltMissingMessage);
    }
    final key = PassphraseService.deriveKey(passphrase, salt);

    try {
      await _verifyKey(key);
    } catch (e) {
      return PassphraseRecoveryResult.failed(
        isWrongPassphrase(e) ? wrongPassphraseMessage : 'Unlock failed: $e',
      );
    }

    // Verified against the real log — this key is the truth. Into the
    // escrow it goes, and ONLY the escrow: see step 3 on the class doc
    // for why secure storage must not be called before the rescue has
    // read the store.
    Object? escrowError;
    try {
      await KeyEscrow.instance.store(key);
    } catch (e) {
      escrowError = e;
      KeystoreKey.lastEscrowError = '$e';
      debugPrint('[recovery] key escrow store failed: $e');
    }

    final broken = await _pluginLooksBroken();
    if (broken && escrowError != null) {
      // Nowhere left to put it: the escrow refused and the one other home
      // is the thing that is broken. Refuse loudly rather than set a store
      // aside with no surviving copy of the key.
      return PassphraseRecoveryResult.failed(
        'Your log unlocked, but Trail could not save the key anywhere on '
        'this device, so it cannot stay unlocked. Escrow: $escrowError',
      );
    }

    SecureStorageRescueSummary? summary;
    if (broken) {
      summary = await _rebuildSecureStorage(key);
    } else {
      try {
        await KeystoreKey.persist(key);
      } on KeyPersistException catch (e) {
        return PassphraseRecoveryResult.failed(
          'Your log unlocked, but Trail could not save the key anywhere on '
          'this device, so it cannot stay unlocked. $e',
        );
      } catch (e) {
        return PassphraseRecoveryResult.failed('Could not save the key: $e');
      }
      // The store looked healthy a moment ago and refused anyway — the
      // one case the diagnosis in step 4 cannot see coming. Repair it in
      // the same safe order; the key is already escrowed.
      if (KeystoreKey.lastSecureStorageError != null) {
        summary = await _rebuildSecureStorage(key);
      }
    }

    await TrailDatabase.invalidateShared();
    await SecureStorageMigration.markVerified(
      present: summary?.recovered ?? const [KeystoreKey.storageKey],
      prefs: _prefs,
    );
    // The worker may run again: startup's key read will succeed from the
    // escrow even if secure storage is still unhappy.
    await setStartupBlocked(false, prefs: _prefs);
    return PassphraseRecoveryResult.unlocked(rescue: summary);
  }

  /// Is `flutter_secure_storage` itself the broken part?
  ///
  /// Three independent tells, none of which writes anything:
  ///
  ///   * [MigratingSecureStore.lastLegacyError] — the one-shot migration
  ///     read of the legacy store failed this launch. Since 0.17.9 that
  ///     is the *primary* signal: the app's own reads now go to Trail's
  ///     store, so a broken `flutter_secure_storage` no longer announces
  ///     itself by taking startup down;
  ///   * [KeystoreKey.lastSecureStorageError] — the DB-key read or write
  ///     threw this launch, or
  ///   * [SecureStorageRescue.status] reports a wrapped AES key sitting in
  ///     the legacy store with no Keystore alias left to unwrap it, which
  ///     is the same dead end one launch earlier.
  ///
  /// A `status` the channel cannot answer (no handler, off-device) reads
  /// as "not broken" — the healthy path then just calls
  /// [KeystoreKey.persist] and finds out for itself.
  Future<bool> _pluginLooksBroken() async {
    if (_storage.lastLegacyError != null) return true;
    if (KeystoreKey.lastSecureStorageError != null) return true;
    final status = await _rescue.status();
    return status.wrappedKeyPresent && !status.aliasExists;
  }

  /// Read the old store, set it aside, seed the new one. Only ever called
  /// once [dbKey] is in the escrow, so the destructive step always has a
  /// surviving copy behind it. Never throws: every failure becomes part
  /// of the summary, because by this point the user's log is already
  /// unlocked and reporting an exception would undo nothing.
  Future<SecureStorageRescueSummary> _rebuildSecureStorage(String dbKey) async {
    final problems = <String>[];
    // READ-ONLY, and it must happen before setAside: afterwards the
    // wrapped AES key can never be unwrapped again.
    final rescued = await _rescue.rescue();
    if (rescued.error != null) problems.add('rescue: ${rescued.error}');
    final setAside = await _rescue.setAside();
    if (setAside.error != null) problems.add('set aside: ${setAside.error}');

    final recovered = <String>[];
    Future<void> write(String key, String value) async {
      try {
        await _storage.write(key: key, value: value);
        recovered.add(key);
      } catch (e) {
        debugPrint('[rescue] re-persist of $key failed: $e');
        problems.add('$key: $e');
      }
    }

    if (setAside.ok) {
      // The one value that needs no rescue: freshly derived and verified.
      // Through `persist`, so the escrow copy is re-confirmed (idempotent)
      // and `lastSecureStorageError` is cleared once the fresh store takes
      // the write.
      try {
        await KeystoreKey.persist(dbKey);
      } catch (e) {
        debugPrint('[rescue] re-persist of the DB key failed: $e');
      }
      if (KeystoreKey.lastSecureStorageError == null) {
        recovered.add(KeystoreKey.storageKey);
      } else {
        problems.add(
          '${KeystoreKey.storageKey}: ${KeystoreKey.lastSecureStorageError}',
        );
      }
      // True by construction — the user is unlocking an existing log.
      await write(OnboardingGate.storageKey, '1');
      for (final entry in rescued.values.entries) {
        if (entry.key == KeystoreKey.storageKey ||
            entry.key == OnboardingGate.storageKey) {
          continue;
        }
        await write(entry.key, entry.value);
      }
    }
    await OnboardingGate.writeMirror(prefs: _prefs);

    final summary = SecureStorageRescueSummary(
      at: _now(),
      rebuilt: setAside.ok,
      method: rescued.method,
      recovered: List.unmodifiable(recovered),
      missing: List.unmodifiable(
        SecureStorageMigration.knownKeys
            .where((k) => !recovered.contains(k))
            .toList(growable: false),
      ),
      attempts: rescued.attempts,
      error: problems.isEmpty ? null : problems.join('; '),
    );
    await _persistSummary(summary);
    return summary;
  }

  Future<void> _persistSummary(SecureStorageRescueSummary summary) async {
    try {
      final store = _prefs ?? await SharedPreferences.getInstance();
      await store.setString(secureStorageRescueKey, summary.toJson());
    } catch (e) {
      debugPrint('[rescue] could not persist the summary: $e');
    }
  }

  /// The persisted summary, or `null` if no rebuild has ever run here.
  static Future<SecureStorageRescueSummary?> readSummary({
    SharedPreferences? prefs,
  }) async {
    try {
      final store = prefs ?? await SharedPreferences.getInstance();
      return SecureStorageRescueSummary.parse(
        store.getString(secureStorageRescueKey),
      );
    } catch (_) {
      return null;
    }
  }
}
