import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/import/import_file_hash.dart';

/// The Timeline import identifies a file by `sha256(first 1 MiB) + length`
/// rather than by hashing 200 MB on a phone (docs/TIMELINE_IMPORT.md).
/// These tests pin both halves of that bargain: stable for the same file,
/// different when the length differs — and, deliberately, identical when
/// two files agree on both prefix and length.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('trail_hash_test');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  Future<String> writeFile(String name, List<int> bytes) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  Uint8List filler(int length, {int seed = 7}) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = (i * 31 + seed) & 0xFF;
    }
    return out;
  }

  test('is stable across repeated reads of the same file', () async {
    final path = await writeFile('a.json', filler(4096));
    expect(await importFileHash(path), await importFileHash(path));
  });

  test('is lower-case hex sha256 (64 chars)', () async {
    final path = await writeFile('a.json', filler(10));
    final hash = await importFileHash(path);
    expect(hash, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test('differs when the content differs inside the first MiB', () async {
    final a = await writeFile('a.json', filler(2048, seed: 1));
    final b = await writeFile('b.json', filler(2048, seed: 2));
    expect(await importFileHash(a), isNot(await importFileHash(b)));
  });

  test('differs when only the length differs beyond the first MiB',
      () async {
    final prefix = filler(kImportHashPrefixBytes);
    final a = await writeFile('a.json', <int>[...prefix, ...filler(10)]);
    final b = await writeFile('b.json', <int>[...prefix, ...filler(11)]);
    expect(await importFileHash(a), isNot(await importFileHash(b)));
  });

  test('identical prefix AND length hash the same, tail ignored', () async {
    final prefix = filler(kImportHashPrefixBytes);
    final a = await writeFile(
      'a.json',
      <int>[...prefix, ...List<int>.filled(64, 0x41)],
    );
    final b = await writeFile(
      'b.json',
      <int>[...prefix, ...List<int>.filled(64, 0x42)],
    );
    expect(await importFileHash(a), await importFileHash(b));
  });

  test('handles an empty file', () async {
    final path = await writeFile('empty.json', const <int>[]);
    expect(await importFileHash(path), matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test('throws FileSystemException for a missing file', () async {
    expect(
      () => importFileHash('${dir.path}/nope.json'),
      throwsA(isA<FileSystemException>()),
    );
  });
}
