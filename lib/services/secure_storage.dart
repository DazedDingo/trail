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
/// ## Why each option is pinned (release A of the 9.2.4 → 10.3.1 → 11.x
/// migration)
///
/// * `encryptedSharedPreferences: true` — **deprecated upstream but
///   required here.** 10.x's native `initialize()` only looks for
///   Jetpack-`EncryptedSharedPreferences` data (what 9.2.4 wrote) while
///   the "already migrated" marker is absent; keeping the flag `true`
///   also keeps the *fallback* branches alive, so a device whose Jetpack
///   MasterKey still resolves reads the old store instead of silently
///   presenting an empty one. Release B (the 11.x bump) removes the
///   parameter entirely — only once the on-device migration marker
///   written by `SecureStorageMigration` proves the rewrite happened.
/// * `migrateOnAlgorithmChange: true` — the actual migration switch. With
///   it off, 10.x refuses to touch the 9.2.4 data and the SQLCipher key
///   reads back as `null`.
/// * `resetOnError: false` — 10.x flipped this default to `true`, which
///   means *any* decrypt error wipes the whole secure store. That store
///   holds the only copy of the SQLCipher key for the user's encrypted
///   location log. Never enable it.
/// * `keyCipherAlgorithm` / `storageCipherAlgorithm` — pinned to the 11.x
///   survivors (RSA-OAEP + AES-GCM) so the rewrite performed under 10.x
///   lands in the format release B can still read. The 10.x defaults
///   match, but defaults are not a contract.
///
/// Honest note on cost: sharing the Dart instance is hygiene, not a
/// measured win — the native side re-runs its setup per call.
const FlutterSecureStorage secureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(
    // ignore: deprecated_member_use
    encryptedSharedPreferences: true,
    migrateOnAlgorithmChange: true,
    resetOnError: false,
    keyCipherAlgorithm:
        KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
    storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
  ),
);
