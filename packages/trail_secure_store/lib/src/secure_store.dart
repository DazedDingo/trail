import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/services.dart';

import 'platform_error.dart';

/// Trail's own Keystore-backed secret store (`trail/secure_store`).
///
/// ## Why this exists
///
/// Every Trail secret used to live in `flutter_secure_storage`. On
/// 2026-08-23 that plugin became unusable on a real device: Android
/// Keystore refused its RSA-OAEP unwrap (`KeyStoreException
/// UNKNOWN_ERROR -1000`) on every launch, and the plugin's
/// `createRSAKeysIfNeeded` regenerates its RSA pair whenever the Keystore
/// reports the alias missing — which would orphan every stored secret for
/// good. One library's cipher choice was a single point of failure for
/// the SQLCipher key, the onboarding flag and every setting behind it.
///
/// This store is the same primitive `KeyEscrow` already proved on that
/// device: a plain AES-256-GCM key in AndroidKeyStore, our alias, our
/// prefs file, our blob format. No key wrapping, no RSA, no Jetpack
/// master key, no third-party migration path.
///
/// ## Registered in every engine
///
/// It is a real `FlutterPlugin` in a local plugin package rather than a
/// channel registered by `MainActivity`, because `GeneratedPluginRegistrant`
/// runs for *every* `FlutterEngine` — including the one
/// `workmanager_android`'s `BackgroundWorker` constructs for a scheduled
/// tick. The escrow's UI-isolate-only limitation is what forced the
/// worker's `key_unavailable` skip; this store has no such limitation.
///
/// ## API shape
///
/// The named parameters are deliberately identical to
/// `flutter_secure_storage`'s, so every `read(key: …)` / `write(key: …,
/// value: …)` call site in the app compiles unchanged.
///
/// Deliberately NOT `@immutable`: `MigratingSecureStore` implements this
/// interface and has to carry the one-shot migration's state.
class TrailSecureStore {
  /// [channel] is injectable so tests can point at a fake without going
  /// through the binary messenger's global mock table.
  const TrailSecureStore({MethodChannel channel = TrailSecureStore.channel})
      : _channel = channel;

  /// The platform channel the Kotlin `TrailSecureStorePlugin` answers.
  static const channel = MethodChannel('trail/secure_store');

  final MethodChannel _channel;

  /// The decrypted value, or `null` when nothing is stored under [key].
  ///
  /// **Throws** when an entry exists but cannot be decrypted (a bad GCM
  /// tag, an invalidated alias). That is deliberate and is the whole
  /// difference this store buys: "there is nothing here" and "there is
  /// something here that I cannot read" must never look the same, because
  /// the caller that mints a fresh SQLCipher key branches on exactly that.
  Future<String?> read({required String key}) =>
      _channel.invokeMethod<String>('read', <String, Object?>{'key': key});

  /// Encrypts and stores [value] under [key].
  ///
  /// A `null` [value] deletes the entry — same contract as
  /// `flutter_secure_storage`, so call sites can be moved verbatim.
  Future<void> write({required String key, required String? value}) async {
    if (value == null) return delete(key: key);
    await _channel.invokeMethod<void>(
      'write',
      <String, Object?>{'key': key, 'value': value},
    );
  }

  /// Removes [key]. Idempotent — deleting an absent key is a no-op.
  Future<void> delete({required String key}) =>
      _channel.invokeMethod<void>('delete', <String, Object?>{'key': key});

  /// Whether an entry exists, without decrypting it.
  Future<bool> containsKey({required String key}) async =>
      await _channel.invokeMethod<bool>(
        'containsKey',
        <String, Object?>{'key': key},
      ) ??
      false;

  /// Every entry that decrypts. Entries that do not are **skipped**, not
  /// thrown for: one corrupt blob must not blank the whole store for a
  /// caller that only wanted the other five. Use [read] when you need to
  /// know that a specific key failed.
  Future<Map<String, String>> readAll() async =>
      await _channel.invokeMapMethod<String, String>('readAll') ??
      <String, String>{};

  /// Removes every entry. Leaves the AndroidKeyStore alias alone — the
  /// key is not the data, and deleting it would break nothing but would
  /// help nothing either.
  Future<void> deleteAll() => _channel.invokeMethod<void>('deleteAll');

  /// Never throws — a platform failure comes back as
  /// [SecureStoreStatus.error]. Same contract as `KeyEscrow.status`, and
  /// for the same reason: Diagnostics must render *something*.
  Future<SecureStoreStatus> status() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('status');
      if (map == null) return const SecureStoreStatus();
      return SecureStoreStatus(
        aliasExists: map['aliasExists'] == true,
        entryCount: map['entryCount'] is int ? map['entryCount']! as int : 0,
      );
    } catch (e) {
      return SecureStoreStatus(error: describeStoreError(e));
    }
  }
}

/// Outcome of [TrailSecureStore.status] — what Diagnostics renders.
@immutable
class SecureStoreStatus {
  const SecureStoreStatus({
    this.aliasExists = false,
    this.entryCount = 0,
    this.error,
  });

  /// Whether the AndroidKeyStore alias that encrypts the entries exists.
  /// `!aliasExists && entryCount > 0` is the "unreadable store" state.
  final bool aliasExists;

  /// How many entries are on disk (encrypted; not a decrypt attempt).
  final int entryCount;

  /// Non-null when the status could not be read at all.
  final String? error;

  @override
  String toString() => 'SecureStoreStatus(aliasExists: $aliasExists, '
      'entryCount: $entryCount, error: $error)';
}
