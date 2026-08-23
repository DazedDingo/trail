import 'dart:async';

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

  group('geocodeKey', () {
    test('rounds lat/lon to 4 dp as exact ints', () {
      expect(geocodeKey(51.50001, -0.12345), (lat4: 515000, lon4: -1235));
      expect(geocodeKey(0, 0), (lat4: 0, lon4: 0));
    });

    test('GPS jitter inside one ~11 m cell collapses to the same key', () {
      expect(geocodeKey(51.50001, -0.10001), geocodeKey(51.50004, -0.10004));
      expect(geocodeKey(51.5, -0.1), isNot(geocodeKey(51.5001, -0.1)));
      expect(geocodeKey(51.5, -0.1), isNot(geocodeKey(51.5, -0.1001)));
    });

    test('rounding is symmetric about zero (no hemisphere bias)', () {
      // Decimal "halves" aren't exact in binary, so don't pin which way
      // 0.00005 goes — pin that +x and −x always land on mirrored cells,
      // which is what `round()` (half away from zero) guarantees.
      for (final x in [0.00005, 0.00015, 0.12345, 51.50005, 179.99995]) {
        final k = geocodeKey(x, -x);
        expect(k.lat4, -k.lon4, reason: 'x = $x');
      }
      expect(geocodeKey(0.00004, -0.00004), (lat4: 0, lon4: 0));
    });

    test('lat / lon getters return the cell centre', () {
      final k = geocodeKey(51.50004, -0.10004);
      expect(k.lat, closeTo(51.5, 1e-9));
      expect(k.lon, closeTo(-0.1, 1e-9));
    });
  });

  group('GeocodingService LRU', () {
    test('a second lookup in the same cell is served from memory', () async {
      var calls = 0;
      final svc = GeocodingService(lookup: (_, __) async {
        calls++;
        return [_placemark(locality: 'Bristol', country: 'England')];
      });
      expect(await svc.reverseLookup(51.4545, -2.5879), 'Bristol, England');
      expect(await svc.reverseLookup(51.45452, -2.58791), 'Bristol, England');
      expect(calls, 1);
      expect(svc.cachedLabels, 1);
    });

    test('different cells are separate lookups', () async {
      var calls = 0;
      final svc = GeocodingService(lookup: (lat, _) async {
        calls++;
        return [_placemark(locality: 'L$lat', country: 'C')];
      });
      expect(await svc.reverseLookup(1.0, 0), 'L1.0, C');
      expect(await svc.reverseLookup(1.001, 0), 'L1.001, C');
      expect(calls, 2);
    });

    test('null results are NOT cached — retried on the next call', () async {
      var calls = 0;
      final svc = GeocodingService(lookup: (_, __) async {
        calls++;
        return const [];
      });
      expect(await svc.reverseLookup(1, 1), isNull);
      expect(await svc.reverseLookup(1, 1), isNull);
      expect(calls, 2);
      expect(svc.cachedLabels, 0);
    });

    test('a throwing lookup caches nothing and frees the in-flight slot',
        () async {
      var calls = 0;
      final svc = GeocodingService(lookup: (_, __) async {
        calls++;
        throw Exception('offline');
      });
      expect(await svc.reverseLookup(5, 5), isNull);
      expect(await svc.reverseLookup(5, 5), isNull);
      expect(calls, 2);
      expect(svc.cachedLabels, 0);
    });

    test('concurrent lookups for one cell share a single platform call',
        () async {
      final gate = Completer<List<Placemark>>();
      var calls = 0;
      final svc = GeocodingService(lookup: (_, __) {
        calls++;
        return gate.future;
      });
      final a = svc.reverseLookup(1, 1);
      final b = svc.reverseLookup(1.00001, 1.00001);
      gate.complete([_placemark(locality: 'X', country: 'Y')]);
      expect(await Future.wait([a, b]), ['X, Y', 'X, Y']);
      expect(calls, 1);
    });

    test('evicts least-recently-used beyond capacity', () async {
      var calls = 0;
      final svc = GeocodingService(
        cacheCapacity: 2,
        lookup: (lat, _) async {
          calls++;
          return [_placemark(locality: 'L$lat', country: 'C')];
        },
      );
      await svc.reverseLookup(1, 0); // cache: [1]
      await svc.reverseLookup(2, 0); // cache: [1, 2]
      await svc.reverseLookup(1, 0); // hit → [2, 1]
      await svc.reverseLookup(3, 0); // evicts 2 → [1, 3]
      expect(calls, 3);
      await svc.reverseLookup(1, 0); // hit
      expect(calls, 3);
      await svc.reverseLookup(2, 0); // miss → refetch
      expect(calls, 4);
      expect(svc.cachedLabels, 2);
    });

    test('default capacity is 512', () {
      expect(GeocodingService.defaultCacheCapacity, 512);
    });
  });

  group('GeocodingService concurrency limiter', () {
    /// A lookup that counts how many calls overlap and answers after a
    /// short delay, so the peak is observable without hand-driving
    /// completers.
    ({
      GeocodingService svc,
      int Function() peak,
      int Function() calls,
    }) counting({
      int maxConcurrent = GeocodingService.defaultMaxConcurrent,
      Duration Function(double lat)? delay,
    }) {
      var inFlight = 0, peak = 0, calls = 0;
      final svc = GeocodingService(
        maxConcurrent: maxConcurrent,
        lookup: (lat, _) async {
          calls++;
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await Future<void>.delayed(
            delay?.call(lat) ?? const Duration(milliseconds: 2),
          );
          inFlight--;
          return [_placemark(locality: 'P${lat.toInt()}', country: 'C')];
        },
      );
      return (svc: svc, peak: () => peak, calls: () => calls);
    }

    test('20 misses fired at once never put more than 4 in flight',
        () async {
      final h = counting();
      final labels = await Future.wait([
        for (var i = 0; i < 20; i++) h.svc.reverseLookup(i.toDouble(), 0),
      ]);
      expect(labels, [for (var i = 0; i < 20; i++) 'P$i, C']);
      expect(h.peak(), GeocodingService.defaultMaxConcurrent);
      expect(h.calls(), 20);
      // Everything drained: no slot or waiter left behind.
      expect(h.svc.activeLookups, 0);
      expect(h.svc.queuedLookups, 0);
    });

    test('the order the platform answers in does not matter', () async {
      // Later coordinates answer FIRST, so slots free out of order.
      final h = counting(
        delay: (lat) => Duration(milliseconds: (20 - lat).toInt()),
      );
      final labels = await Future.wait([
        for (var i = 0; i < 20; i++) h.svc.reverseLookup(i.toDouble(), 0),
      ]);
      expect(labels, [for (var i = 0; i < 20; i++) 'P$i, C']);
      expect(h.peak(), lessThanOrEqualTo(4));
      expect(h.svc.activeLookups, 0);
      expect(h.svc.queuedLookups, 0);
    });

    test('a cache hit never waits for a slot', () async {
      final gate = Completer<List<Placemark>>();
      var calls = 0;
      final svc = GeocodingService(lookup: (lat, _) {
        calls++;
        if (lat == 99) {
          return Future.value([_placemark(locality: 'Home', country: 'C')]);
        }
        return gate.future;
      });
      // Warm the cache, then jam every slot with pending misses.
      expect(await svc.reverseLookup(99, 0), 'Home, C');
      final jammed = [
        for (var i = 0; i < 6; i++) svc.reverseLookup(i.toDouble(), 0),
      ];
      expect(svc.activeLookups, 4);
      expect(svc.queuedLookups, 2);

      String? hit;
      unawaited(svc.reverseLookup(99, 0).then((v) => hit = v));
      await Future<void>.delayed(Duration.zero); // flush microtasks only

      expect(hit, 'Home, C', reason: 'served from memory, not the queue');
      expect(calls, 5, reason: 'no extra platform call for the cached cell');

      gate.complete([_placemark(locality: 'X', country: 'C')]);
      await Future.wait(jammed);
      expect(svc.activeLookups, 0);
      expect(svc.queuedLookups, 0);
    });

    test('a second caller for an in-flight cell takes no second slot',
        () async {
      final gate = Completer<List<Placemark>>();
      var calls = 0;
      final svc = GeocodingService(lookup: (_, __) {
        calls++;
        return gate.future;
      });
      final first = [
        for (var i = 0; i < 4; i++) svc.reverseLookup(i.toDouble(), 0),
      ];
      expect(svc.activeLookups, 4);

      final piggyback = svc.reverseLookup(0.00001, 0);
      expect(svc.queuedLookups, 0, reason: 'deduped, never queued');
      expect(calls, 4);

      gate.complete([_placemark(locality: 'X', country: 'C')]);
      expect(await piggyback, 'X, C');
      await Future.wait(first);
      expect(calls, 4);
      expect(svc.activeLookups, 0);
    });

    test('a throwing lookup hands its slot on', () async {
      final gate = Completer<List<Placemark>>();
      var calls = 0;
      final svc = GeocodingService(lookup: (lat, _) {
        calls++;
        if (lat < 4) return Future<List<Placemark>>.error(Exception('boom'));
        return gate.future;
      });
      final failures = [
        for (var i = 0; i < 4; i++) svc.reverseLookup(i.toDouble(), 0),
      ];
      final queued = svc.reverseLookup(9, 0);
      expect(await Future.wait(failures), [null, null, null, null]);

      gate.complete([_placemark(locality: 'X', country: 'C')]);
      expect(await queued, 'X, C');
      expect(calls, 5);
      expect(svc.activeLookups, 0);
      expect(svc.queuedLookups, 0);
    });

    test('maxConcurrent: 1 serialises the platform calls', () async {
      final h = counting(maxConcurrent: 1);
      await Future.wait([
        for (var i = 0; i < 5; i++) h.svc.reverseLookup(i.toDouble(), 0),
      ]);
      expect(h.peak(), 1);
    });

    test('the cap holds across callers — a batch plus loose lookups',
        () async {
      final h = counting();
      await Future.wait([
        h.svc.reverseLookupAll([
          for (var i = 0; i < 8; i++) (lat: i.toDouble(), lon: 0.0),
        ]),
        for (var i = 8; i < 20; i++) h.svc.reverseLookup(i.toDouble(), 0),
      ]);
      expect(h.peak(), GeocodingService.defaultMaxConcurrent);
      expect(h.svc.activeLookups, 0);
      expect(h.svc.queuedLookups, 0);
    });
  });

  group('GeocodingService.reverseLookupAll', () {
    test('preserves input order and caps in-flight calls at 4', () async {
      var inFlight = 0, peak = 0;
      final svc = GeocodingService(lookup: (lat, _) async {
        inFlight++;
        if (inFlight > peak) peak = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        inFlight--;
        return [_placemark(locality: 'P${lat.toInt()}', country: 'C')];
      });
      final coords = [for (var i = 0; i < 12; i++) (lat: i.toDouble(), lon: 0.0)];
      final labels = await svc.reverseLookupAll(coords);
      expect(labels, [for (var i = 0; i < 12; i++) 'P$i, C']);
      expect(peak, GeocodingService.defaultMaxConcurrent);
      expect(GeocodingService.defaultMaxConcurrent, 4);
    });

    test('nulls land in place for cells the geocoder cannot name', () async {
      final svc = GeocodingService(lookup: (lat, _) async {
        if (lat == 1) return const [];
        return [_placemark(locality: 'P${lat.toInt()}', country: 'C')];
      });
      final labels = await svc.reverseLookupAll([
        (lat: 0.0, lon: 0.0),
        (lat: 1.0, lon: 0.0),
        (lat: 2.0, lon: 0.0),
      ]);
      expect(labels, ['P0, C', null, 'P2, C']);
    });

    test('empty input never touches the geocoder', () async {
      var calls = 0;
      final svc = GeocodingService(lookup: (_, __) async {
        calls++;
        return const [];
      });
      expect(await svc.reverseLookupAll(const []), isEmpty);
      expect(calls, 0);
    });
  });
}
