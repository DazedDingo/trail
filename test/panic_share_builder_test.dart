import 'package:flutter_test/flutter_test.dart';
import 'package:trail/models/emergency_contact.dart';
import 'package:trail/models/ping.dart';
import 'package:trail/services/panic/panic_share_builder.dart';

void main() {
  // A fixed local time makes the `HH:MM` assertion deterministic across
  // machines — passing `now:` bypasses the DateFormat-on-wallclock path.
  final fixedNow = DateTime(2026, 4, 20, 14, 5);

  Ping makePing({double? lat, double? lon}) => Ping(
        timestampUtc: DateTime.utc(2026, 4, 20, 18, 5),
        lat: lat,
        lon: lon,
        source: PingSource.panic,
      );

  final alice = const EmergencyContact(
    name: 'Alice',
    phoneE164: '+14155550101',
  );
  final bob = const EmergencyContact(
    name: 'Bob',
    phoneE164: '+14155550102',
  );

  group('composeUri', () {
    test('returns null when contacts list is empty', () {
      expect(
        PanicShareBuilder.composeUri(
          contacts: const [],
          ping: makePing(lat: 37.7749, lon: -122.4194),
        ),
        isNull,
      );
    });

    test('returns null when every contact has a blank phone', () {
      final blanks = [
        const EmergencyContact(name: 'X', phoneE164: ''),
        const EmergencyContact(name: 'Y', phoneE164: ''),
      ];
      expect(
        PanicShareBuilder.composeUri(
          contacts: blanks,
          ping: makePing(lat: 37.7749, lon: -122.4194),
        ),
        isNull,
      );
    });

    test('uses sms: scheme with comma-joined recipients', () {
      final uri = PanicShareBuilder.composeUri(
        contacts: [alice, bob],
        ping: makePing(lat: 37.7749, lon: -122.4194),
        now: fixedNow,
      )!;
      expect(uri.scheme, 'sms');
      expect(uri.path, '+14155550101,+14155550102');
    });

    test('includes the composed body as the `body` query param', () {
      final uri = PanicShareBuilder.composeUri(
        contacts: [alice],
        ping: makePing(lat: 37.7749, lon: -122.4194),
        now: fixedNow,
      )!;
      final body = uri.queryParameters['body']!;
      expect(body, startsWith('PANIC at 14:05'));
      expect(body, contains('https://maps.google.com/?q=37.77490,-122.41940'));
    });

    test('drops blank phones but keeps the rest', () {
      final contacts = [
        alice,
        const EmergencyContact(name: 'Ghost', phoneE164: ''),
        bob,
      ];
      final uri = PanicShareBuilder.composeUri(
        contacts: contacts,
        ping: makePing(lat: 0.0, lon: 0.0),
        now: fixedNow,
      )!;
      expect(uri.path, '+14155550101,+14155550102');
    });
  });

  group('composeBody', () {
    test('embeds a 5-decimal maps URL when a fix is present', () {
      final body = PanicShareBuilder.composeBody(
        ping: makePing(lat: 51.5074, lon: -0.1278),
        now: fixedNow,
      );
      expect(body, 'PANIC at 14:05 — https://maps.google.com/?q=51.50740,-0.12780');
    });

    test('falls back to "(no fix yet)" when lat/lon are null', () {
      final body = PanicShareBuilder.composeBody(
        ping: makePing(),
        now: fixedNow,
      );
      expect(body, 'PANIC at 14:05 — (no fix yet)');
    });

    test('lat-only or lon-only still falls back to no-fix', () {
      // Defensive: we never expect half-a-fix from the geolocator, but if
      // something ever slips through we must not emit a broken maps URL.
      final bodyLatOnly = PanicShareBuilder.composeBody(
        ping: makePing(lat: 10.0),
        now: fixedNow,
      );
      final bodyLonOnly = PanicShareBuilder.composeBody(
        ping: makePing(lon: 10.0),
        now: fixedNow,
      );
      expect(bodyLatOnly, endsWith('(no fix yet)'));
      expect(bodyLonOnly, endsWith('(no fix yet)'));
    });

    test('formats the time in local-time HH:mm', () {
      final morning = DateTime(2026, 4, 20, 6, 3);
      final body = PanicShareBuilder.composeBody(
        ping: makePing(lat: 1.0, lon: 1.0),
        now: morning,
      );
      expect(body, startsWith('PANIC at 06:03'));
    });
  });
}
