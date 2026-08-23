import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_storage.dart';

/// What one [SecureStorageMigration.verifyAndRewrite] pass found.
///
/// Deliberately additive-only: nothing here deletes, and a key that reads
/// back `null` is simply "not present on this install" (most users never
/// set a GitHub PAT or a coverage token).
class MigrationReport {
  /// Keys that read back a non-null value before the rewrite.
  final List<String> present;

  /// Keys that were written back and verified byte-identical.
  final List<String> rewritten;

  /// Keys whose re-read did NOT match what we wrote. Never observed in
  /// practice; if it ever happens the marker is withheld so release B
  /// refuses to upgrade.
  final List<String> mismatched;

  /// Key → error string for reads/writes that threw.
  final Map<String, String> errors;

  /// Whether the success marker is now on disk (either just written or
  /// already there from an earlier pass).
  final bool markerWritten;

  const MigrationReport({
    required this.present,
    required this.rewritten,
    required this.mismatched,
    required this.errors,
    required this.markerWritten,
  });

  /// Every key we could see round-tripped cleanly.
  bool get ok => mismatched.isEmpty && errors.isEmpty;

  /// One line, for `debugPrint` and bug reports.
  String get summary => 'secure storage: ${present.length}/'
      '${SecureStorageMigration.knownKeys.length} present, '
      '${rewritten.length} rewritten, ${mismatched.length} mismatched, '
      '${errors.length} errors, marker=$markerWritten';
}

/// The persisted "10.x rewrite verified" marker.
class MigrationMarker {
  final DateTime at;
  final List<String> present;
  const MigrationMarker({required this.at, required this.present});
}

/// `22 Aug 2026` — matches the day-before-month house style in
/// `date_labels.dart` without pulling its pin-specific patterns in.
final DateFormat _markerDateFormat = DateFormat('d MMM yyyy');

/// Verifies that every Trail secret survived the `flutter_secure_storage`
/// 9.2.4 → 10.3.1 cipher migration, and re-writes each one so it is
/// stored under the new (11.x-compatible) ciphers.
///
/// Why a rewrite and not just a read: 10.x migrates lazily and its
/// fallback branches can leave a value readable through the *old* Jetpack
/// store while never re-encrypting it. Writing the identical value back
/// forces the value through `storageCipher.encrypt` on the current
/// algorithm pair, so the bytes on disk are ones release B (11.x, which
/// dropped every legacy cipher) can still read. Writing an identical
/// value is safe: worst case it is a no-op.
///
/// Runs post-first-frame from `main()` and **never throws** — a failure
/// here must not take down an app that has already painted. The absence
/// of [markerKey] is itself the signal release B gates on.
class SecureStorageMigration {
  /// SharedPreferences key holding `{at: epochMs, present: [...]}` once a
  /// full pass succeeded. Public because release B (the 11.x bump) must
  /// read it before it dares open the store.
  static const markerKey = 'trail_secure_storage_v10_ok_v1';

  /// Every key Trail keeps in secure storage. **Add new secrets here** —
  /// a key that is not listed is never verified and never counted.
  static const knownKeys = <String>[
    // The SQLCipher key for trail.db. Losing this loses the log.
    'trail_db_passphrase_v1',
    'trail_onboarded_v1',
    'trail_panic_duration_v1',
    'trail_panic_auto_send_v1',
    'trail_github_pat_v1',
    'trail_coverage_token_v1',
  ];

  /// Read → write-back → re-read every key in [knownKeys].
  static Future<MigrationReport> verifyAndRewrite({
    FlutterSecureStorage storage = secureStorage,
    SharedPreferences? prefs,
  }) async {
    final present = <String>[];
    final rewritten = <String>[];
    final mismatched = <String>[];
    final errors = <String, String>{};

    for (final key in knownKeys) {
      try {
        final before = await storage.read(key: key);
        if (before == null) continue;
        present.add(key);
        await storage.write(key: key, value: before);
        final after = await storage.read(key: key);
        if (after == before) {
          rewritten.add(key);
        } else {
          mismatched.add(key);
        }
      } catch (e) {
        errors[key] = e.toString();
      }
    }

    var markerWritten = false;
    if (mismatched.isEmpty && errors.isEmpty) {
      try {
        final store = prefs ?? await SharedPreferences.getInstance();
        // Keep the FIRST verified timestamp — the diagnostics line reads
        // "migrated <date>", which should name the upgrade, not today.
        final existing = parseMarker(store.getString(markerKey));
        final at = existing?.at ?? DateTime.now();
        markerWritten = await store.setString(
          markerKey,
          jsonEncode({
            'at': at.millisecondsSinceEpoch,
            'present': present,
          }),
        );
      } catch (e) {
        errors['<marker>'] = e.toString();
      }
    }

    final report = MigrationReport(
      present: List.unmodifiable(present),
      rewritten: List.unmodifiable(rewritten),
      mismatched: List.unmodifiable(mismatched),
      errors: Map.unmodifiable(errors),
      markerWritten: markerWritten,
    );
    debugPrint('[SecureStorageMigration] ${report.summary}');
    return report;
  }

  /// The persisted marker, or `null` if no pass has fully succeeded yet.
  static Future<MigrationMarker?> readMarker({SharedPreferences? prefs}) async {
    try {
      final store = prefs ?? await SharedPreferences.getInstance();
      return parseMarker(store.getString(markerKey));
    } catch (_) {
      return null;
    }
  }

  /// Pure: decode the marker JSON. Malformed / missing → `null` (a
  /// garbage pref should read as "not yet verified", never throw).
  static MigrationMarker? parseMarker(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final at = decoded['at'];
      if (at is! int) return null;
      final present = (decoded['present'] as List?)
              ?.whereType<String>()
              .toList(growable: false) ??
          const <String>[];
      return MigrationMarker(
        at: DateTime.fromMillisecondsSinceEpoch(at),
        present: present,
      );
    } catch (_) {
      return null;
    }
  }

  /// Pure: the diagnostics-screen line for [marker].
  static String describeMarker(MigrationMarker? marker) {
    if (marker == null) return 'Secure storage: not yet verified';
    final when = _markerDateFormat.format(marker.at.toLocal());
    return 'Secure storage: migrated $when · '
        '${marker.present.length}/${knownKeys.length} secrets present';
  }
}
