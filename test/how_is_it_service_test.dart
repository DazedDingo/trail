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
      expect(await HowIsItService().getFrequency(),
          HowIsItFrequency.everyPing);
    });

    test('setEnabled(false) clears the flag', () async {
      await HowIsItService().setEnabled(true);
      await HowIsItService().setEnabled(false);
      expect(await HowIsItService().isEnabled(), isFalse);
      expect(await HowIsItService().getFrequency(), HowIsItFrequency.off);
    });

    test('getFrequency defaults to off on a clean install', () async {
      expect(await HowIsItService().getFrequency(), HowIsItFrequency.off);
    });

    test('setFrequency round-trips each enum value', () async {
      for (final f in HowIsItFrequency.values) {
        await HowIsItService().setFrequency(f);
        expect(await HowIsItService().getFrequency(), f);
      }
    });

    test('legacy v1 boolean=true migrates to everyPing on v2 read',
        () async {
      SharedPreferences.setMockInitialValues({
        'trail_how_is_it_enabled_v1': true,
      });
      expect(await HowIsItService().getFrequency(),
          HowIsItFrequency.everyPing);
    });

    test('legacy v1 boolean=false migrates to off on v2 read', () async {
      SharedPreferences.setMockInitialValues({
        'trail_how_is_it_enabled_v1': false,
      });
      expect(await HowIsItService().getFrequency(), HowIsItFrequency.off);
    });

    test('setFrequency removes the legacy v1 key (no resurrection)',
        () async {
      SharedPreferences.setMockInitialValues({
        'trail_how_is_it_enabled_v1': true,
      });
      await HowIsItService().setFrequency(HowIsItFrequency.daily);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('trail_how_is_it_enabled_v1'), isFalse);
    });

    test('lastPostedAt round-trips with UTC fidelity', () async {
      final t = DateTime.utc(2026, 5, 17, 9, 5);
      await HowIsItService().setLastPostedAt(t);
      final got = await HowIsItService().getLastPostedAt();
      expect(got, isNotNull);
      expect(got!.isUtc, isTrue);
      expect(got.millisecondsSinceEpoch, t.millisecondsSinceEpoch);
    });

    test('lastPostedAt is null on a clean install', () async {
      expect(await HowIsItService().getLastPostedAt(), isNull);
    });
  });

  group('HowIsItFrequency.fromString', () {
    test('round-trips every enum value through .name', () {
      for (final f in HowIsItFrequency.values) {
        expect(HowIsItFrequency.fromString(f.name), f);
      }
    });
    test('unknown / null → off (safe default)', () {
      expect(HowIsItFrequency.fromString(null), HowIsItFrequency.off);
      expect(HowIsItFrequency.fromString('garbage'), HowIsItFrequency.off);
    });
  });

  group('HowIsItFrequency.minInterval', () {
    test('off and everyPing are zero (rate limit moot)', () {
      expect(HowIsItFrequency.off.minInterval, Duration.zero);
      expect(HowIsItFrequency.everyPing.minInterval, Duration.zero);
    });
    test('hourly, every4h, daily map to their named durations', () {
      expect(HowIsItFrequency.hourly.minInterval, const Duration(hours: 1));
      expect(HowIsItFrequency.every4h.minInterval, const Duration(hours: 4));
      expect(HowIsItFrequency.daily.minInterval, const Duration(hours: 24));
    });
  });

  group('shouldPostHowIsIt (pure rate limiter)', () {
    final now = DateTime.utc(2026, 5, 17, 12, 0);

    test('off → never posts, even with no lastPostedAt', () {
      expect(
        shouldPostHowIsIt(
          frequency: HowIsItFrequency.off,
          lastPostedAt: null,
          now: now,
        ),
        isFalse,
      );
    });

    test('everyPing → always posts', () {
      expect(
        shouldPostHowIsIt(
          frequency: HowIsItFrequency.everyPing,
          lastPostedAt: now.subtract(const Duration(seconds: 1)),
          now: now,
        ),
        isTrue,
      );
    });

    test('hourly: first prompt always allowed (lastPostedAt=null)', () {
      expect(
        shouldPostHowIsIt(
          frequency: HowIsItFrequency.hourly,
          lastPostedAt: null,
          now: now,
        ),
        isTrue,
      );
    });

    test('hourly: 59 min elapsed → blocked', () {
      expect(
        shouldPostHowIsIt(
          frequency: HowIsItFrequency.hourly,
          lastPostedAt: now.subtract(const Duration(minutes: 59)),
          now: now,
        ),
        isFalse,
      );
    });

    test('hourly: exactly 60 min elapsed → allowed (>= boundary)', () {
      expect(
        shouldPostHowIsIt(
          frequency: HowIsItFrequency.hourly,
          lastPostedAt: now.subtract(const Duration(minutes: 60)),
          now: now,
        ),
        isTrue,
      );
    });

    test('every4h: 3 h elapsed → blocked', () {
      expect(
        shouldPostHowIsIt(
          frequency: HowIsItFrequency.every4h,
          lastPostedAt: now.subtract(const Duration(hours: 3)),
          now: now,
        ),
        isFalse,
      );
    });

    test('every4h: 4h+1min elapsed → allowed', () {
      expect(
        shouldPostHowIsIt(
          frequency: HowIsItFrequency.every4h,
          lastPostedAt: now.subtract(const Duration(hours: 4, minutes: 1)),
          now: now,
        ),
        isTrue,
      );
    });

    test('daily: 23h59m → blocked, 24h → allowed', () {
      expect(
        shouldPostHowIsIt(
          frequency: HowIsItFrequency.daily,
          lastPostedAt: now.subtract(const Duration(hours: 23, minutes: 59)),
          now: now,
        ),
        isFalse,
      );
      expect(
        shouldPostHowIsIt(
          frequency: HowIsItFrequency.daily,
          lastPostedAt: now.subtract(const Duration(hours: 24)),
          now: now,
        ),
        isTrue,
      );
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
