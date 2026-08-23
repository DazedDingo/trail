import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The one `FlutterSecureStorage` handle for the UI isolate.
///
/// Every Keystore-backed value in the app — the onboarding flag, the
/// panic-mode prefs, the GitHub PAT, the coverage token, and the
/// SQLCipher key (`lib/db/keystore_key.dart`) — reads and writes through
/// this single instance, so the `AndroidOptions` live in exactly one
/// place and no call site can drift to a differently-configured store (a
/// mismatch in namespace / prefix / cipher would silently read a
/// *different* preferences file and report every key as missing).
///
/// ## Why each option is pinned (release B: `flutter_secure_storage` 11.x)
///
/// Release A (0.17.3+105) ran on 10.3.1 with `encryptedSharedPreferences:
/// true` and rewrote every secret through the new ciphers, recording
/// `SecureStorageMigration.markerKey` on success. 11.x **removed** the
/// parameter — and with it every branch that could read 9.2.4's
/// Jetpack-`EncryptedSharedPreferences` data — so the marker is now the
/// gate: `computeStartupKeyState` refuses to mint a key on a device that
/// never ran A (`StartupKeyState.notMigrated` → `/recover`).
///
/// * `migrateOnAlgorithmChange: true` — still present in 11.x. It is what
///   re-encrypts data in place if the saved algorithm markers ever differ
///   from the pair below; with it off, 11.x's `handleKeyMismatch` has
///   only `resetOnError` (i.e. `deleteAll()`) left to offer.
/// * `resetOnError: false` — 10.x flipped this default to `true` and 11.x
///   keeps that default, which means *any* decrypt error wipes the whole
///   secure store. That store holds the only copy of the SQLCipher key
///   for the user's encrypted location log. Never enable it.
/// * `keyCipherAlgorithm` / `storageCipherAlgorithm` — RSA-OAEP + AES-GCM,
///   the only pair 11.x still ships, and the pair release A wrote with.
///   The 11.x defaults match, but defaults are not a contract.
/// * `storageNamespace` / `preferencesKeyPrefix` — deliberately unset. Both
///   would move the prefs file / key names away from what 9.2.4 and 10.3.1
///   used and orphan every installed user.
///
/// Honest note on cost: sharing the Dart instance is hygiene, not a
/// measured win — the native side re-runs its setup per call.
const FlutterSecureStorage secureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(
    migrateOnAlgorithmChange: true,
    resetOnError: false,
    keyCipherAlgorithm:
        KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
    storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
  ),
);
