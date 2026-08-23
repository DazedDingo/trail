import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:trail_secure_store/trail_secure_store.dart';

import 'secure_store_migration.dart';

/// Every key Trail keeps in secure storage. **Add new secrets here** — a
/// key that is not listed is never migrated off the legacy store and
/// never verified by `SecureStorageMigration`.
///
/// Lives in this file rather than next to `SecureStorageMigration` so the
/// wiring below has no import cycle to reason about.
const trailSecretKeys = <String>[
  // The SQLCipher key for trail.db. Losing this loses the log.
  'trail_db_passphrase_v1',
  'trail_onboarded_v1',
  'trail_panic_duration_v1',
  'trail_panic_auto_send_v1',
  'trail_github_pat_v1',
  'trail_coverage_token_v1',
];

/// The one handle every Trail secret goes through.
///
/// ## Why it is no longer `flutter_secure_storage` (0.17.9)
///
/// On 2026-08-23 that plugin became unusable on the commander's phone:
/// Android Keystore refused its RSA-OAEP unwrap with
/// `KeyStoreException UNKNOWN_ERROR (-1000)`, persistently, on every
/// launch. Worse than the outage is the plugin's own repair attempt —
/// `createRSAKeysIfNeeded` regenerates the RSA pair whenever the Keystore
/// reports the alias missing, which would orphan every value it has ever
/// written, the SQLCipher key for the user's whole location log included.
///
/// So the secrets moved to a store Trail owns end to end: an AES-256-GCM
/// key in AndroidKeyStore, encrypting values directly with no wrapping
/// layer, in a prefs file nothing else writes
/// (`packages/trail_secure_store/`). That is the same primitive
/// `KeyEscrow` has been running on the same device, on the same Keystore,
/// without a single failure since 0.17.7 — the evidence that the problem
/// was the plugin's RSA path and not the hardware.
///
/// Being a real plugin rather than a `MainActivity` channel also fixes
/// the escrow's old blind spot: `GeneratedPluginRegistrant` runs for
/// every `FlutterEngine`, so the WorkManager background isolate can read
/// the DB key too (gotcha 38's `key_unavailable` skip).
///
/// [MigratingSecureStore] wraps it and consults [legacySecureStorage]
/// exactly once per key, best-effort, until every known secret has been
/// tried; after that the marker is on disk and the old plugin is never
/// called again.
final MigratingSecureStore secureStorage = MigratingSecureStore(
  store: const TrailSecureStore(),
  legacy: legacySecureStorage,
  knownKeys: trailSecretKeys,
);

/// The old `flutter_secure_storage` handle. **Migration only.**
///
/// Kept for one release so [secureStorage] can lift the existing secrets
/// across on the first launch of 0.17.9. Nothing else may call it: every
/// call is another run of the plugin's `createRSAKeysIfNeeded`, and on a
/// device where the unwrap is failing that is the call that can destroy
/// the store for good (gotcha 38). `SecureStorageRescue` still reads the
/// plugin's *files* natively, which is a different, read-only path.
///
/// ## Why each option is pinned (`flutter_secure_storage` 11.x)
///
/// * `migrateOnAlgorithmChange: true` — re-encrypts in place if the saved
///   algorithm markers ever differ from the pair below; with it off,
///   11.x's `handleKeyMismatch` has only `resetOnError` (i.e.
///   `deleteAll()`) left to offer.
/// * `resetOnError: false` — 10.x flipped this default to `true` and 11.x
///   keeps it, which means *any* decrypt error wipes the whole store.
///   Even now that the store is only a migration source, that would
///   destroy secrets we have not copied yet. Never enable it.
/// * `keyCipherAlgorithm` / `storageCipherAlgorithm` — RSA-OAEP + AES-GCM,
///   the only pair 11.x ships and the pair release A (0.17.3) wrote with.
///   The 11.x defaults match, but defaults are not a contract.
/// * `storageNamespace` / `preferencesKeyPrefix` — deliberately unset.
///   Both would move the prefs file / key names away from what 9.2.4 and
///   10.3.1 used and orphan every installed user.
const FlutterSecureStorage legacySecureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(
    migrateOnAlgorithmChange: true,
    resetOnError: false,
    keyCipherAlgorithm:
        KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
    storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
  ),
);
