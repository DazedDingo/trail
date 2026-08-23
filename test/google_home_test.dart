import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/home_location_service.dart';
import 'package:trail/services/import/google_home.dart';
import 'package:trail/services/import/timeline_models.dart';

/// The "Google says home is at …" offer on the Timeline import screen.
/// Pure rules only — the screen does the saving, and these are what
/// decide whether the card appears at all.

ImportFrequentPlace _place(
  String label, {
  double lat = 51.3821,
  double lon = -2.3601,
}) =>
    ImportFrequentPlace(label: label, lat: lat, lon: lon);

HomeLocation _home(double lat, double lon) => HomeLocation(
      lat: lat,
      lon: lon,
      savedAtUtc: DateTime.utc(2026, 1, 1),
    );

void main() {
  group('pickGoogleHome', () {
    test('returns the HOME place', () {
      final home = _place('HOME');
      expect(pickGoogleHome([_place('WORK', lat: 51.5), home]), same(home));
    });

    test('HOME wins over INFERRED_HOME regardless of order', () {
      final home = _place('HOME');
      final inferred = _place('INFERRED_HOME', lat: 52);
      expect(pickGoogleHome([inferred, home]), same(home));
      expect(pickGoogleHome([home, inferred]), same(home));
    });

    test('falls back to INFERRED_HOME when there is no HOME', () {
      final inferred = _place('INFERRED_HOME');
      expect(
        pickGoogleHome([_place('WORK'), inferred, _place('INFERRED_WORK')]),
        same(inferred),
      );
    });

    test('takes the FIRST INFERRED_HOME when the export lists several', () {
      final first = _place('INFERRED_HOME', lat: 51);
      final second = _place('INFERRED_HOME', lat: 52);
      expect(pickGoogleHome([first, second]), same(first));
    });

    test('null when no place is a home', () {
      expect(
        pickGoogleHome([_place('WORK'), _place('UNKNOWN'), _place('GYM')]),
        isNull,
      );
    });

    test('null on an export with no frequent places at all', () {
      expect(pickGoogleHome(const []), isNull);
    });

    test('labels are trimmed and case-insensitive', () {
      expect(pickGoogleHome([_place(' home ')]), isNotNull);
      expect(pickGoogleHome([_place('Inferred_Home')]), isNotNull);
    });
  });

  group('homeDiffers', () {
    final place = _place('HOME', lat: 51.3821, lon: -2.3601);

    test('true when no home is saved yet — the offer is the whole point', () {
      expect(homeDiffers(null, place), isTrue);
    });

    test('false when the saved home is the same coordinate', () {
      expect(homeDiffers(_home(51.3821, -2.3601), place), isFalse);
    });

    test('false a few metres away (deliberately-placed pin, same house)', () {
      // ~11 m north.
      expect(homeDiffers(_home(51.3822, -2.3601), place), isFalse);
    });

    test('true a kilometre away', () {
      // ~1.1 km north.
      expect(homeDiffers(_home(51.3921, -2.3601), place), isTrue);
    });

    test('the boundary is exclusive — exactly at the threshold is "same"',
        () {
      final home = _home(51.3821, -2.3601);
      final metres = home.distanceMetersTo(51.3830, -2.3601);
      final moved = _place('HOME', lat: 51.3830, lon: -2.3601);
      expect(homeDiffers(home, moved, thresholdM: metres), isFalse);
      expect(homeDiffers(home, moved, thresholdM: metres - 0.01), isTrue);
    });

    test('honours a custom threshold in both directions', () {
      final home = _home(51.3821, -2.3601);
      final moved = _place('HOME', lat: 51.3826, lon: -2.3601); // ~56 m
      expect(homeDiffers(home, moved, thresholdM: 500), isFalse);
      expect(homeDiffers(home, moved, thresholdM: 10), isTrue);
    });

    test('default threshold is 100 m', () {
      expect(kGoogleHomeThresholdM, 100);
      final home = _home(51.3821, -2.3601);
      // ~55 m and ~166 m north of the saved home.
      expect(homeDiffers(home, _place('HOME', lat: 51.38260)), isFalse);
      expect(homeDiffers(home, _place('HOME', lat: 51.38360)), isTrue);
    });

    test('longitude-only differences count too', () {
      final home = _home(51.3821, -2.3601);
      expect(
        homeDiffers(home, _place('HOME', lat: 51.3821, lon: -2.3801)),
        isTrue,
      );
    });
  });

  group('formatGoogleHome', () {
    test('four decimals, comma-separated', () {
      expect(
        formatGoogleHome(_place('HOME', lat: 51.38214567, lon: -2.36009876)),
        '51.3821, -2.3601',
      );
    });

    test('pads short coordinates so the card never jitters', () {
      expect(formatGoogleHome(_place('HOME', lat: 51.5, lon: 0)),
          '51.5000, 0.0000');
    });
  });

  test('the saved label names its source', () {
    expect(kGoogleHomeLabel, 'Home (from Google)');
  });
}
