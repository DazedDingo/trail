import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:trail/services/how_is_it_service.dart';
import 'package:trail/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HowIsItService persistence', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('isEnabled defaults to false on a clean install', () async {
      expect(await HowIsItService().isEnabled(), isFalse);
    });

    test('setEnabled(true) round-trips through isEnabled()', () async {
      await HowIsItService().setEnabled(true);
      expect(await HowIsItService().isEnabled(), isTrue);
    });

    test('setEnabled(false) clears the flag', () async {
      await HowIsItService().setEnabled(true);
      await HowIsItService().setEnabled(false);
      expect(await HowIsItService().isEnabled(), isFalse);
    });
  });

  group('formatHowIsItPrompt', () {
    test('title is the canonical "How is it?" question', () {
      final out =
          formatHowIsItPrompt(DateTime(2026, 5, 17, 9, 5));
      expect(out.title, 'How is it?');
    });

    test('body embeds the ping time as zero-padded HH:MM', () {
      final out =
          formatHowIsItPrompt(DateTime(2026, 5, 17, 9, 5));
      expect(out.body, contains('09:05'));
      expect(out.body.toLowerCase(), contains('comment'));
    });

    test('midnight renders as 00:00, not 0:0', () {
      final out =
          formatHowIsItPrompt(DateTime(2026, 5, 17, 0, 0));
      expect(out.body, contains('00:00'));
    });
  });

  group('sanitizeQuickComment', () {
    test('null input returns null', () {
      expect(sanitizeQuickComment(null), isNull);
    });

    test('blank / whitespace-only input returns null', () {
      expect(sanitizeQuickComment(''), isNull);
      expect(sanitizeQuickComment('   '), isNull);
      expect(sanitizeQuickComment('\n\t  \n'), isNull);
    });

    test('strips leading + trailing whitespace', () {
      expect(sanitizeQuickComment('  rainy out  '), 'rainy out');
    });

    test('collapses inline newlines + repeated whitespace to one space',
        () {
      expect(
          sanitizeQuickComment('first line\nsecond line'),
          'first line second line');
      expect(sanitizeQuickComment('a   b\tc'), 'a b c');
    });

    test('preserves emoji + punctuation untouched', () {
      expect(sanitizeQuickComment('🌧️ rainy, gusty.'),
          '🌧️ rainy, gusty.');
    });

    test('clips comments longer than 280 chars with an ellipsis', () {
      final long = 'a' * 400;
      final out = sanitizeQuickComment(long)!;
      expect(out.length, 280);
      expect(out.endsWith('…'), isTrue);
    });

    test('exactly 280 chars survive untrimmed', () {
      final exact = 'a' * 280;
      expect(sanitizeQuickComment(exact), exact);
    });
  });

  group('parsePingIdPayloadForTest', () {
    test('valid payload returns the int', () {
      expect(parsePingIdPayloadForTest('ping_id:42'), 42);
    });

    test('null payload returns null', () {
      expect(parsePingIdPayloadForTest(null), isNull);
    });

    test('wrong prefix returns null', () {
      expect(parsePingIdPayloadForTest('something_else:5'), isNull);
    });

    test('non-numeric suffix returns null (forward-compat against drift)',
        () {
      expect(parsePingIdPayloadForTest('ping_id:abc'), isNull);
    });

    test('zero or negative ids return null (rowids are 1+)', () {
      expect(parsePingIdPayloadForTest('ping_id:0'), isNull);
      expect(parsePingIdPayloadForTest('ping_id:-5'), isNull);
    });
  });
}
