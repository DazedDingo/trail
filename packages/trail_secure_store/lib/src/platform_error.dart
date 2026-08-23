import 'package:flutter/services.dart';

/// One-line description of a platform failure.
///
/// The native side's contract is `result.error(<exception class simple
/// name>, message, null)`, so the code alone is usually the diagnosis
/// ("AEADBadTagException" vs "KeyPermanentlyInvalidatedException"). A
/// `MissingPluginException` is named explicitly because it means
/// something categorically different: this engine has no handler at all.
String describeStoreError(Object e) {
  if (e is PlatformException) {
    final message = e.message;
    return message == null || message.isEmpty ? e.code : '${e.code}: $message';
  }
  if (e is MissingPluginException) return 'MissingPluginException';
  return '$e';
}
