import 'package:trail_secure_store/trail_secure_store.dart';

/// Every key Trail keeps in secure storage. **Add new secrets here** — a
/// key that is not listed is never verified by `SecureStorageMigration`.
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

/// The one handle every Trail secret goes through: Trail's own
/// Keystore-backed store (`packages/trail_secure_store/`).
///
/// ## Why it is not `flutter_secure_storage` (0.17.9)
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
/// layer, in a prefs file nothing else writes. That is the same primitive
/// `KeyEscrow` has been running on the same device, on the same Keystore,
/// without a single failure since 0.17.7 — the evidence that the problem
/// was the plugin's RSA path and not the hardware.
///
/// Being a real plugin rather than a `MainActivity` channel also fixes
/// the escrow's old blind spot: `GeneratedPluginRegistrant` runs for
/// every `FlutterEngine`, so the WorkManager background isolate can read
/// the DB key too (gotcha 38's `key_unavailable` skip).
///
/// 0.17.9/0.17.10 wrapped this store in a one-shot `MigratingSecureStore`
/// that read each secret out of `flutter_secure_storage` once and copied
/// it across; 0.17.10 is confirmed healthy on the device it exists for, so
/// this release drops the wrapper and the dependency outright. There is no
/// legacy read left anywhere. `SecureStorageRescue` still reads the old
/// plugin's *files* and Keystore aliases natively — a read-only path that
/// never links the library — and remains the last way to get bytes off an
/// install that never ran the migration.
const TrailSecureStore secureStorage = TrailSecureStore();

/// The Diagnostics line for [TrailSecureStore.status] — the store's own
/// health, independent of the verify-and-rewrite marker
/// ([SecureStorageMigration.describeMarker]) and the key escrow
/// ([describeKeyEscrow]). Pure so it can be pinned by a unit test; the
/// Diagnostics screen only renders it.
String describeSecureStore(SecureStoreStatus? status) {
  if (status == null) return 'Trail secure store: reading…';
  if (status.error != null) {
    return 'Trail secure store: unavailable (${status.error})';
  }
  final n = status.entryCount;
  return 'Trail secure store: $n ${n == 1 ? 'entry' : 'entries'} · '
      '${status.aliasExists ? 'Keystore alias present' : 'alias MISSING'}';
}
