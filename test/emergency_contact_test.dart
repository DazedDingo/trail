import 'package:flutter_test/flutter_test.dart';
import 'package:trail/models/emergency_contact.dart';

void main() {
  group('EmergencyContact serialization', () {
    test('toMap / fromMap round-trip preserves fields', () {
      final c =
          const EmergencyContact(id: 7, name: 'Ada', phoneE164: '+447700900123');
      final round = EmergencyContact.fromMap(c.toMap());
      expect(round.id, 7);
      expect(round.name, 'Ada');
      expect(round.phoneE164, '+447700900123');
    });

    test('toMap exposes id so callers can strip it for insert()', () {
      final c = const EmergencyContact(name: 'n', phoneE164: '+100');
      final m = c.toMap();
      expect(m.containsKey('id'), isTrue);
      expect(m['id'], isNull);
    });

    test('fromMap keeps the exact phone string — no mutation, no parsing', () {
      final round = EmergencyContact.fromMap(const {
        'id': 1,
        'name': 'n',
        'phone_e164': '+447911123456',
      });
      expect(round.phoneE164, '+447911123456');
    });
  });
}
