import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// Dart face of `KeyEscrowPlugin` (`android/app/src/main/kotlin/.../
/// KeyEscrowPlugin.kt`) — Trail's own second copy of the SQLCipher DB key.
///
/// Rationale in one line: before 0.17.6 the key existed only inside
/// `flutter_secure_storage`, so that one plugin's cipher was a single
/// point of failure for the whole encrypted log. The escrow is an
/// independent copy under an alias, a prefs file and a blob format that
/// nothing but Trail writes.
///
/// **Two of the four methods are total** — [load] and [status] never
/// throw, because they are called from the DB read/open paths where a
/// throw is the failure mode we are hedging against (and because the
/// WorkManager isolate has no handler at all for this channel, so every
/// call there raises `MissingPluginException`; see the class comment on
/// [mirrorAfterOpen]). [store] and [clear] are explicit user/caller
/// actions and do surface their platform errors.
class KeyEscrow {
  /// The platform channel. Handler is installed by `MainActivity`, i.e.
  /// **the UI isolate only** — see [mirrorAfterOpen].
  static const channel = MethodChannel('trail/key_escrow');

  /// [channel] is injectable so tests can point at a fake without going
  /// through the binary messenger's global mock table.
  const KeyEscrow({MethodChannel channel = KeyEscrow.channel})
      : _channel = channel;

  final MethodChannel _channel;

  /// The instance the DB layer uses. Swappable via [setInstanceForTest].
  static KeyEscrow instance = const KeyEscrow();

  @visibleForTesting
  static void setInstanceForTest(KeyEscrow? escrow) {
    instance = escrow ?? const KeyEscrow();
  }

  /// Encrypts [key] under the AndroidKeyStore alias and persists it.
  /// Idempotent — re-storing the same key leaves `storedAt` alone.
  ///
  /// Throws whatever the platform reports; callers on the DB open path
  /// go through [mirrorAfterOpen], which swallows.
  Future<void> store(String key) async {
    await _channel.invokeMethod<void>('store', <String, Object?>{
      'bytes': Uint8List.fromList(utf8.encode(key)),
    });
  }

  /// Never throws. `EscrowResult(key: null, error: null)` means "nothing
  /// is escrowed"; a non-null [EscrowResult.error] means the escrow
  /// exists but could not be read (bad tag, invalidated alias, no
  /// handler in this isolate) — a very different thing, and the reason
  /// the caller must not treat it as "no key".
  Future<EscrowResult> load() async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('load');
      if (bytes == null || bytes.isEmpty) return const EscrowResult();
      return EscrowResult(key: utf8.decode(bytes));
    } catch (e) {
      return EscrowResult(error: _describeError(e));
    }
  }

  /// Removes the blob **and** the Keystore alias. The only destructive
  /// path in the escrow; nothing else ever deletes.
  Future<void> clear() => _channel.invokeMethod<void>('clear');

  /// Never throws — a platform failure comes back as
  /// [EscrowStatus.error] with `present: false`.
  Future<EscrowStatus> status() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('status');
      if (map == null) return const EscrowStatus();
      final storedAt = map['storedAt'];
      return EscrowStatus(
        present: map['present'] == true,
        aliasExists: map['aliasExists'] == true,
        storedAt: storedAt is int
            ? DateTime.fromMillisecondsSinceEpoch(storedAt)
            : null,
        keySha256: map['keySha256'] as String?,
      );
    } catch (e) {
      return EscrowStatus(error: _describeError(e));
    }
  }

  /// The DB open path's hook: mirror [key] into the escrow **after** the
  /// database actually opened, which is the only proof we have that the
  /// key is the right one. Cheap-exits when the escrow already holds this
  /// key — the comparison is a SHA-256 fingerprint carried in the same
  /// prefs file, so a warm open costs one prefs read rather than a
  /// Keystore decrypt.
  ///
  /// Never throws and is never awaited on the open path. In the
  /// WorkManager isolate every call here fails with
  /// `MissingPluginException` (no `MainActivity`, so no handler) and is
  /// swallowed — the UI isolate does the mirroring for both.
  Future<void> mirrorAfterOpen(String key) async {
    try {
      if (key.isEmpty) return;
      final current = await status();
      if (current.error != null) return;
      if (current.present &&
          current.keySha256 == fingerprintOf(key) &&
          current.aliasExists) {
        return;
      }
      await store(key);
    } catch (e) {
      debugPrint('key escrow mirror failed: $e');
    }
  }

  /// Hex SHA-256 of the key's UTF-8 bytes — the same digest
  /// `KeyEscrowPlugin` writes next to the blob.
  static String fingerprintOf(String key) =>
      sha256.convert(utf8.encode(key)).toString();

  /// `PlatformException` carries the Kotlin exception's simple name as its
  /// code, which is the whole point of the native error contract.
  static String _describeError(Object e) {
    if (e is PlatformException) {
      final message = e.message;
      return message == null || message.isEmpty
          ? e.code
          : '${e.code}: $message';
    }
    if (e is MissingPluginException) return 'MissingPluginException';
    return '$e';
  }
}

/// Outcome of [KeyEscrow.load]. Exactly one of three shapes:
/// nothing stored (both null), a key, or an error.
class EscrowResult {
  const EscrowResult({this.key, this.error});

  final String? key;

  /// Platform error code (the Kotlin exception's simple name), plus its
  /// message when there is one.
  final String? error;

  /// Nothing is escrowed — as opposed to "escrowed but unreadable".
  bool get isEmpty => key == null && error == null;

  @override
  String toString() => 'EscrowResult(key: ${key == null ? 'null' : '<set>'}, '
      'error: $error)';
}

/// Outcome of [KeyEscrow.status].
class EscrowStatus {
  const EscrowStatus({
    this.present = false,
    this.aliasExists = false,
    this.storedAt,
    this.keySha256,
    this.error,
  });

  /// Whether an encrypted blob is on disk.
  final bool present;

  /// Whether the AndroidKeyStore alias that would decrypt it still exists.
  /// `present && !aliasExists` is the "unwrappable blob" state.
  final bool aliasExists;

  final DateTime? storedAt;

  /// Hex SHA-256 of the escrowed key's plaintext bytes, used by
  /// [KeyEscrow.mirrorAfterOpen] to skip a redundant re-store.
  final String? keySha256;

  /// Non-null when the status could not be read at all.
  final String? error;
}

final DateFormat _escrowDateFormat = DateFormat('d MMM yyyy');

/// The Diagnostics line, e.g.
/// `Key escrow: present since 23 Aug 2026 · last read from: escrow
/// (error: PlatformException: ...)`.
///
/// Pure so it can be pinned by a unit test — the tile that renders it
/// lives in `lib/widgets/key_escrow_tile.dart`.
String describeKeyEscrow({
  required EscrowStatus status,
  String? lastReadSource,
  String? lastSecureStorageError,
}) {
  final buf = StringBuffer('Key escrow: ');
  if (status.error != null) {
    buf.write('unavailable (${status.error})');
  } else if (!status.present) {
    buf.write('not stored yet');
  } else if (!status.aliasExists) {
    buf.write('stored but its Keystore alias is gone');
  } else if (status.storedAt != null) {
    buf.write('present since '
        '${_escrowDateFormat.format(status.storedAt!.toLocal())}');
  } else {
    buf.write('present');
  }
  buf.write(' · last read from: ${lastReadSource ?? 'not read yet'}');
  if (lastSecureStorageError != null) {
    buf.write(' (error: $lastSecureStorageError)');
  }
  return buf.toString();
}
