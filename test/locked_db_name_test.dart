import 'package:flutter_test/flutter_test.dart';
import 'package:trail/db/database.dart';

/// `lockedDbName` is the naming contract for the one destructive-looking
/// action in the app that is deliberately *not* destructive: `/recover`'s
/// "Start a new log" renames `trail.db` instead of deleting it. The name
/// has to stay recognisable (so a user or a developer can find the file),
/// sortable (so the diagnostics list is newest-first), and distinct from
/// the live DB (so nothing re-opens it by accident).
void main() {
  group('lockedDbName', () {
    test('is trail.db.locked-<yyyyMMdd-HHmm>', () {
      expect(
        lockedDbName(DateTime(2026, 8, 22, 14, 35)),
        'trail.db.locked-20260822-1435',
      );
    });

    test('zero-pads month, day, hour and minute', () {
      expect(
        lockedDbName(DateTime(2026, 1, 2, 3, 4)),
        'trail.db.locked-20260102-0304',
      );
    });

    test('midnight is 0000, not blank', () {
      expect(
        lockedDbName(DateTime(2026, 12, 31, 0, 0)),
        'trail.db.locked-20261231-0000',
      );
    });

    test('seconds are dropped — minute resolution is the contract', () {
      expect(
        lockedDbName(DateTime(2026, 8, 22, 14, 35, 59)),
        lockedDbName(DateTime(2026, 8, 22, 14, 35, 1)),
      );
    });

    test('lexicographic order matches chronological order', () {
      final names = [
        lockedDbName(DateTime(2026, 8, 22, 14, 35)),
        lockedDbName(DateTime(2025, 12, 1, 9, 5)),
        lockedDbName(DateTime(2026, 8, 22, 9, 35)),
      ]..sort();
      expect(names, [
        'trail.db.locked-20251201-0905',
        'trail.db.locked-20260822-0935',
        'trail.db.locked-20260822-1435',
      ]);
    });

    test('never collides with the live DB name', () {
      final name = lockedDbName(DateTime(2026, 8, 22, 14, 35));
      expect(name, isNot(TrailDatabase.dbFileName));
      expect(name.startsWith('${TrailDatabase.dbFileName}.'), isTrue);
    });
  });

  group('isLockedDbName', () {
    test('matches what lockedDbName produces', () {
      expect(isLockedDbName(lockedDbName(DateTime(2026, 8, 22, 14, 35))),
          isTrue);
    });

    test('does not match the live DB or its journals', () {
      expect(isLockedDbName('trail.db'), isFalse);
      expect(isLockedDbName('trail.db-wal'), isFalse);
      expect(isLockedDbName('trail.db-shm'), isFalse);
      expect(isLockedDbName('trail_salt_v1.bin'), isFalse);
    });

    test('excludes the set-aside journals so diagnostics lists one line '
        'per log', () {
      final name = lockedDbName(DateTime(2026, 8, 22, 14, 35));
      expect(isLockedDbName(name), isTrue);
      expect(isLockedDbName('$name-wal'), isFalse);
      expect(isLockedDbName('$name-shm'), isFalse);
    });
  });
}
