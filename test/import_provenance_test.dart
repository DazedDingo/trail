import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/import/import_provenance.dart';

void main() {
  const prefix = kImportProvenancePrefix;

  group('not an import note', () {
    test('null → null', () {
      expect(describeImportNote(null), isNull);
    });

    test('empty string → null', () {
      expect(describeImportNote(''), isNull);
    });

    test('a user comment → null', () {
      expect(describeImportNote('Feeling good, sunny'), isNull);
    });

    test('a note that merely mentions gmaps later → null', () {
      expect(describeImportNote('note about gmaps:path'), isNull);
    });

    test('a legacy system note → null', () {
      expect(describeImportNote('boot marker'), isNull);
    });
  });

  group('path', () {
    test('gmaps:path', () {
      expect(describeImportNote('gmaps:path'), '$prefix · path');
    });
  });

  group('visit', () {
    test('HOME reads as Home and the placeId is dropped', () {
      expect(describeImportNote('gmaps:visit:HOME:ChIJdd4hrwug2EcRmSrV3Vo6llI'),
          '$prefix · visit · Home');
    });

    test('WORK', () {
      expect(describeImportNote('gmaps:visit:WORK:abc'),
          '$prefix · visit · Work');
    });

    test('INFERRED_HOME flags that Google guessed', () {
      expect(describeImportNote('gmaps:visit:INFERRED_HOME:abc'),
          '$prefix · visit · Home (inferred)');
    });

    test('INFERRED_WORK', () {
      expect(describeImportNote('gmaps:visit:INFERRED_WORK:abc'),
          '$prefix · visit · Work (inferred)');
    });

    test('UNKNOWN falls through to the capitalised token', () {
      expect(describeImportNote('gmaps:visit:UNKNOWN:-'),
          '$prefix · visit · Unknown');
    });

    test('an unseen multi-word semantic type is humanised', () {
      expect(describeImportNote('gmaps:visit:SEARCHED_ADDRESS:x'),
          '$prefix · visit · Searched address');
    });

    test('missing type → the bare kind', () {
      expect(describeImportNote('gmaps:visit'), '$prefix · visit');
    });

    test('placeholder type → the bare kind', () {
      expect(describeImportNote('gmaps:visit:-:-'), '$prefix · visit');
    });
  });

  group('activity', () {
    test('type + kilometre distance', () {
      expect(describeImportNote('gmaps:activity:WALKING:1200m'),
          '$prefix · activity · Walking, 1.2 km');
    });

    test('IN_PASSENGER_VEHICLE reads as a sentence', () {
      expect(describeImportNote('gmaps:activity:IN_PASSENGER_VEHICLE:24500m'),
          '$prefix · activity · In passenger vehicle, 24.5 km');
    });

    test('sub-kilometre distances stay in metres', () {
      expect(describeImportNote('gmaps:activity:WALKING:850m'),
          '$prefix · activity · Walking, 850 m');
    });

    test('zero metres is still a distance', () {
      expect(describeImportNote('gmaps:activity:WALKING:0m'),
          '$prefix · activity · Walking, 0 m');
    });

    test('exactly 1000 m crosses into kilometres', () {
      expect(describeImportNote('gmaps:activity:CYCLING:1000m'),
          '$prefix · activity · Cycling, 1.0 km');
    });

    test('the mapper\'s "-m" no-distance placeholder drops the distance', () {
      expect(describeImportNote('gmaps:activity:WALKING:-m'),
          '$prefix · activity · Walking');
    });

    test('missing distance field drops the distance', () {
      expect(describeImportNote('gmaps:activity:WALKING'),
          '$prefix · activity · Walking');
    });

    test('unknown type + no distance → the bare kind', () {
      expect(describeImportNote('gmaps:activity:-:-m'), '$prefix · activity');
    });

    test('distance-only (no type) still renders the distance', () {
      expect(describeImportNote('gmaps:activity:-:2500m'),
          '$prefix · activity · 2.5 km');
    });
  });

  group('raw', () {
    test('GPS keeps its capitals', () {
      expect(describeImportNote('gmaps:raw:GPS'), '$prefix · raw GPS');
    });

    test('WIFI becomes Wi-Fi', () {
      expect(describeImportNote('gmaps:raw:WIFI'), '$prefix · raw Wi-Fi');
    });

    test('CELL is lower case', () {
      expect(describeImportNote('gmaps:raw:CELL'), '$prefix · raw cell');
    });

    test('an unseen source falls through lowercased', () {
      expect(describeImportNote('gmaps:raw:BAROMETER'),
          '$prefix · raw barometer');
      expect(describeImportNote('gmaps:raw:UNKNOWN'), '$prefix · raw unknown');
    });

    test('missing source → the bare kind', () {
      expect(describeImportNote('gmaps:raw'), '$prefix · raw');
    });
  });

  group('garbage', () {
    test('an unrecognised kind still admits it is an import', () {
      expect(describeImportNote('gmaps:teleport:???'), prefix);
    });

    test('the bare prefix', () {
      expect(describeImportNote('gmaps:'), prefix);
    });

    test('prefix with a trailing pile of separators', () {
      expect(describeImportNote('gmaps::::::'), prefix);
    });

    test('a truncated activity distance is not a distance', () {
      expect(describeImportNote('gmaps:activity:WALKING:m'),
          '$prefix · activity · Walking');
      expect(describeImportNote('gmaps:activity:WALKING:12x'),
          '$prefix · activity · Walking');
      expect(describeImportNote('gmaps:activity:WALKING:-5m'),
          '$prefix · activity · Walking');
    });

    test('case in the kind is significant — the mapper only writes lower', () {
      expect(describeImportNote('gmaps:PATH'), prefix);
    });

    test('never throws on any prefix + arbitrary tail', () {
      for (final tail in [
        '',
        ':',
        'visit:',
        'activity:::',
        'raw:::::',
        'path:extra:fields',
        'raw:${'x' * 200}',
      ]) {
        expect(() => describeImportNote('gmaps:$tail'), returnsNormally,
            reason: tail);
      }
    });
  });
}
