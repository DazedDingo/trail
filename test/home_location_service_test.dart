import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail/services/home_location_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('HomeLocationService', () {
    test('returns null on a fresh install', () async {
      expect(await HomeLocationService.get(), isNull);
    });

    test('set + get round-trips lat/lon/label', () async {
      await HomeLocationService.set(
        lat: 51.50734,
        lon: -0.12776,
        label: 'Flat',
      );
      final h = (await HomeLocationService.get())!;
      expect(h.lat, closeTo(51.50734, 1e-9));
      expect(h.lon, closeTo(-0.12776, 1e-9));
      expect(h.label, 'Flat');
      // savedAt is UTC and within the last second.
      expect(h.savedAtUtc.isUtc, isTrue);
      expect(
        DateTime.now().toUtc().difference(h.savedAtUtc).inSeconds,
        lessThan(2),
      );
    });

    test('empty-string label stores as null (not as "")', () async {
      await HomeLocationService.set(lat: 1, lon: 2, label: '');
      final h = (await HomeLocationService.get())!;
      expect(h.label, isNull);
    });

    test('clear wipes every key, next get() returns null', () async {
      await HomeLocationService.set(lat: 1, lon: 2, label: 'x');
      await HomeLocationService.clear();
      expect(await HomeLocationService.get(), isNull);
    });

    test('set twice overwrites the previous value', () async {
      await HomeLocationService.set(lat: 1, lon: 2, label: 'Old');
      await HomeLocationService.set(lat: 10, lon: 20, label: 'New');
      final h = (await HomeLocationService.get())!;
      expect(h.lat, 10);
      expect(h.lon, 20);
      expect(h.label, 'New');
    });

    test('overwrite with no label clears the previous label', () async {
      await HomeLocationService.set(lat: 1, lon: 2, label: 'Keep?');
      await HomeLocationService.set(lat: 3, lon: 4);
      final h = (await HomeLocationService.get())!;
      expect(h.label, isNull);
    });
  });

  group('HomeLocation.distanceMetersTo', () {
    test('zero distance for the same point', () {
      final h = HomeLocation(
        lat: 51.5,
        lon: -0.1,
        savedAtUtc: DateTime.utc(2026, 1, 1),
      );
      expect(h.distanceMetersTo(51.5, -0.1), closeTo(0, 0.01));
    });

    test('London ↔ Paris ≈ 344 km (Haversine sanity check)', () {
      final london = HomeLocation(
        lat: 51.50734,
        lon: -0.12776,
        savedAtUtc: DateTime.utc(2026, 1, 1),
      );
      // Paris, Notre-Dame coords. Accepted reference value ~343.6 km.
      final metres = london.distanceMetersTo(48.8530, 2.3498);
      expect(metres / 1000, closeTo(343.6, 2.0));
    });

    test('100 m step at the equator is ~0.0009°', () {
      final h = HomeLocation(
        lat: 0,
        lon: 0,
        savedAtUtc: DateTime.utc(2026, 1, 1),
      );
      // Moving 0.0009° north ≈ 100 m; checking the function scales linearly.
      final metres = h.distanceMetersTo(0.0009, 0);
      expect(metres, closeTo(100, 5));
    });

    test('antipodal points ≈ half-circumference (~20 015 km)', () {
      final h = HomeLocation(
        lat: 0,
        lon: 0,
        savedAtUtc: DateTime.utc(2026, 1, 1),
      );
      // 180° opposite. Earth's half-circumference along a great circle.
      final metres = h.distanceMetersTo(0, 180);
      expect(metres / 1000, closeTo(20015, 5));
    });
  });
}
