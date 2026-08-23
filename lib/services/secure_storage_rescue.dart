import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:flutter/services.dart';

/// Dart face of `SecureStorageRescuePlugin`
/// (`android/app/src/main/kotlin/.../SecureStorageRescuePlugin.kt`) — the
/// last-resort reader for `flutter_secure_storage`'s own store.
///
/// Used by exactly one flow (`PassphraseRecoveryService`) on exactly one
/// condition: the DB key has just been verified against the real log, and
/// writing it back into secure storage still threw. At that point the
/// plugin is the broken component, not the data, and this channel goes at
/// the bytes underneath it.
///
/// **All three methods are total.** They are called from a recovery path
/// where a throw would lose an unlock the user has already earned, so a
/// platform failure comes back as [RescueResult.error] /
/// [SetAsideResult.error] / [RescueStatus.error] rather than as an
/// exception. That is the same reasoning as `KeyEscrow.load`/`status`,
/// applied to every method here.
class SecureStorageRescue {
  static const channel = MethodChannel('trail/secure_storage_rescue');

  const SecureStorageRescue({MethodChannel channel = SecureStorageRescue.channel})
      : _channel = channel;

  final MethodChannel _channel;

  /// The instance the recovery flow uses. Swappable via
  /// [setInstanceForTest], same seam as `KeyEscrow.instance`.
  static SecureStorageRescue instance = const SecureStorageRescue();

  @visibleForTesting
  static void setInstanceForTest(SecureStorageRescue? rescue) {
    instance = rescue ?? const SecureStorageRescue();
  }

  /// Read-only by contract on both sides of the channel: it decrypts, it
  /// never writes and never deletes. Safe to call speculatively.
  Future<RescueResult> rescue() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('rescue');
      if (map == null) return const RescueResult(error: 'no result');
      return RescueResult(
        ok: map['ok'] == true,
        method: map['method'] as String?,
        values: _stringMap(map['values']),
        attempts: _stringList(map['attempts']),
      );
    } catch (e) {
      return RescueResult(error: describeChannelError(e));
    }
  }

  /// The mutating call: copies the store's XML aside, empties the live
  /// files and drops the plugin's Keystore aliases. **Only call after a
  /// [rescue] has returned** — it makes the old wrapped AES key
  /// unrecoverable forever.
  Future<SetAsideResult> setAside() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('setAside');
      if (map == null) return const SetAsideResult(error: 'no result');
      return SetAsideResult(
        stamp: map['stamp'] as String?,
        movedFiles: _stringList(map['movedFiles']),
        deletedAliases: _stringList(map['deletedAliases']),
      );
    } catch (e) {
      return SetAsideResult(error: describeChannelError(e));
    }
  }

  /// What is on disk right now. Rendered by the Diagnostics tile.
  Future<RescueStatus> status() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('status');
      if (map == null) return const RescueStatus(error: 'no result');
      return RescueStatus(
        storeFileExists: map['storeFileExists'] == true,
        wrappedKeyPresent: map['wrappedKeyPresent'] == true,
        aliasExists: map['aliasExists'] == true,
        brokenCopies: _stringList(map['brokenCopies']),
      );
    } catch (e) {
      return RescueStatus(error: describeChannelError(e));
    }
  }

  /// `PlatformException` carries the Kotlin exception's simple name as its
  /// code — same native error contract as `KeyEscrowPlugin`.
  static String describeChannelError(Object e) {
    if (e is PlatformException) {
      final message = e.message;
      return message == null || message.isEmpty ? e.code : '${e.code}: $message';
    }
    if (e is MissingPluginException) return 'MissingPluginException';
    return '$e';
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const [];
    return List.unmodifiable(raw.map((e) => '$e'));
  }

  static Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map) return const {};
    return Map.unmodifiable(<String, String>{
      for (final entry in raw.entries)
        if (entry.key != null && entry.value != null)
          '${entry.key}': '${entry.value}',
    });
  }
}

/// Outcome of [SecureStorageRescue.rescue].
@immutable
class RescueResult {
  const RescueResult({
    this.ok = false,
    this.method,
    this.values = const {},
    this.attempts = const [],
    this.error,
  });

  /// Whether the 256-bit AES key came back and the values were decrypted.
  final bool ok;

  /// Which attempt worked, e.g. `decrypt OAEP SHA-256/MGF1-SHA1`.
  final String? method;

  /// Trail's own key (`trail_github_pat_v1`, …) → plaintext value.
  final Map<String, String> values;

  /// `<attempt> → <ExceptionClass>` for every combination tried, in order.
  /// The whole point of a failed rescue: it is a bug report.
  final List<String> attempts;

  /// Non-null when the channel itself could not answer.
  final String? error;

  @override
  String toString() => 'RescueResult(ok: $ok, method: $method, '
      'values: ${values.length}, attempts: ${attempts.length}, error: $error)';
}

/// Outcome of [SecureStorageRescue.setAside].
@immutable
class SetAsideResult {
  const SetAsideResult({
    this.stamp,
    this.movedFiles = const [],
    this.deletedAliases = const [],
    this.error,
  });

  /// `yyyyMMdd-HHmm` infix of the kept copies.
  final String? stamp;

  /// The `<name>.broken-<stamp>.xml` copies that now exist. Nothing was
  /// deleted to make them.
  final List<String> movedFiles;

  /// Keystore aliases removed so the plugin mints a fresh RSA pair.
  final List<String> deletedAliases;

  final String? error;

  bool get ok => error == null;
}

/// Outcome of [SecureStorageRescue.status].
@immutable
class RescueStatus {
  const RescueStatus({
    this.storeFileExists = false,
    this.wrappedKeyPresent = false,
    this.aliasExists = false,
    this.brokenCopies = const [],
    this.error,
  });

  final bool storeFileExists;
  final bool wrappedKeyPresent;
  final bool aliasExists;
  final List<String> brokenCopies;
  final String? error;
}
