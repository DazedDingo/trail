import 'package:intl/intl.dart';
import 'package:trail_secure_store/trail_secure_store.dart';

/// Trail's own second copy of the SQLCipher DB key.
///
/// The class itself moved to `packages/trail_secure_store` in 0.17.9 so
/// its Kotlin handler could become a real `FlutterPlugin` and be
/// registered in the WorkManager background engine as well as the UI one
/// (gotcha 38's `key_unavailable` skip). Nothing about the alias, the
/// prefs file or the blob format changed — the escrow on a phone in the
/// field is a live copy of the only key that opens that user's log.
///
/// This file stays as the app's import point (every `import
/// '../services/key_escrow.dart'` still works) and keeps
/// [describeKeyEscrow], which is Diagnostics copy rather than plugin API.
export 'package:trail_secure_store/trail_secure_store.dart'
    show EscrowResult, EscrowStatus, KeyEscrow;

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
