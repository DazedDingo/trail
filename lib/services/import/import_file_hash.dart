/// Identity hash for a Google Maps Timeline export.
///
/// The import refuses byte-identical re-imports (docs/TIMELINE_IMPORT.md
/// "Mapping -> pings"), but hashing a 200 MB file costs a full read on a
/// phone — so the identity is the sha256 of the file's **first 1 MiB**
/// plus the file's byte length. A Timeline export's head carries the
/// export timestamp and the first segments, and the length pins the
/// tail, so two different exports collide only if they agree on both,
/// which no real pair of exports does.
///
/// The trade-off is deliberate and documented: two files with an
/// identical first 1 MiB *and* an identical length hash the same and the
/// second one is refused. `imports.file_hash` is `UNIQUE`, so this value
/// is what the DB enforces on.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// How much of the file's head goes into the digest.
const int kImportHashPrefixBytes = 1024 * 1024;

/// `sha256(first 1 MiB ‖ ':' ‖ decimal byte length)`, lower-case hex.
///
/// Throws [FileSystemException] when [path] cannot be read — callers
/// (the import service) turn that into a user-visible error rather than
/// letting it escape.
Future<String> importFileHash(String path) async {
  final file = File(path);
  final length = await file.length();
  final raf = await file.open();
  try {
    final prefix = await raf.read(math.min(length, kImportHashPrefixBytes));
    final input = BytesBuilder(copy: false)
      ..add(prefix)
      ..add(utf8.encode(':$length'));
    return sha256.convert(input.takeBytes()).toString();
  } finally {
    await raf.close();
  }
}
