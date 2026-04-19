import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';
import 'package:trail/services/geocoding_service.dart';

Placemark _placemark({
  String? locality,
  String? subLocality,
  String? subAdministrativeArea,
  String? administrativeArea,
  String? country,
}) =>
    Placemark(
      locality: locality,
      subLocality: subLocality,
      subAdministrativeArea: subAdministrativeArea,
      administrativeArea: administrativeArea,
      country: country,
    );

void main() {
  group('GeocodingService.reverseLookup', () {
    test('returns "locality, region" when both are present', () async {
      final svc = GeocodingService(
        lookup: (_, __) async => [
          _placemark(locality: 'Cambridge', administrativeArea: 'MA'),
        ],
      );
      expect(await svc.reverseLookup(42.37, -71.10), 'Cambridge, MA');
    });

    test('falls back to sub-locality when locality is blank', () async {
      final svc = GeocodingService(
        lookup: (_, __) async => [
          _placemark(
            locality: '',
            subLocality: 'Brookline',
            administrativeArea: 'MA',
          ),
        ],
      );
      expect(await svc.reverseLookup(42.33, -71.12), 'Brookline, MA');
    });

    test('uses country when no regional admin area is returned', () async {
      final svc = GeocodingService(
        lookup: (_, __) async => [
          _placemark(locality: 'Inverness', country: 'Scotland'),
        ],
      );
      expect(await svc.reverseLookup(57.47, -4.22), 'Inverness, Scotland');
    });

    test('collapses to a single token when primary == region', () async {
      final svc = GeocodingService(
        lookup: (_, __) async => [
          _placemark(
            locality: 'Singapore',
            administrativeArea: 'Singapore',
          ),
        ],
      );
      expect(await svc.reverseLookup(1.29, 103.85), 'Singapore');
    });

    test('returns null when no placemarks come back', () async {
      final svc = GeocodingService(lookup: (_, __) async => const []);
      expect(await svc.reverseLookup(0, 0), isNull);
    });

    test('swallows platform errors (offline with no cache)', () async {
      final svc = GeocodingService(
        lookup: (_, __) async => throw Exception('no internet'),
      );
      expect(await svc.reverseLookup(42.0, -71.0), isNull);
    });

    test('returns null when every candidate field is blank', () async {
      final svc = GeocodingService(
        lookup: (_, __) async => [_placemark()],
      );
      expect(await svc.reverseLookup(0, 0), isNull);
    });

    test('trims whitespace-padded fields before formatting', () async {
      final svc = GeocodingService(
        lookup: (_, __) async => [
          _placemark(locality: '  Cambridge  ', administrativeArea: ' MA '),
        ],
      );
      expect(await svc.reverseLookup(42.37, -71.10), 'Cambridge, MA');
    });
  });
}
