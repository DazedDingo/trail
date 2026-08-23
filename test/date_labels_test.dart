import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/date_labels.dart';

void main() {
  // Local time throughout: every caller hands these functions an
  // already-`toLocal()`ed DateTime, so the tests build local ones too.
  final aug = DateTime(2024, 8, 11, 14, 5, 3);

  group('formatPinTime', () {
    test('day before month, four-digit year, 24 h clock', () {
      expect(formatPinTime(aug), '11 Aug 2024, 14:05');
    });

    test('single-digit day is not zero-padded', () {
      expect(formatPinTime(DateTime(2019, 1, 2, 9, 7)), '2 Jan 2019, 09:07');
    });

    test('the year is what separates two same-day fixes years apart', () {
      expect(formatPinTime(DateTime(2019, 8, 11, 14, 5)),
          isNot(formatPinTime(DateTime(2026, 8, 11, 14, 5))));
    });

    test('midnight renders 00:00, not 12:00', () {
      expect(formatPinTime(DateTime(2024, 12, 31)), '31 Dec 2024, 00:00');
    });
  });

  group('formatHudTime', () {
    test('same order as the pin time but without the comma', () {
      expect(formatHudTime(aug), '11 Aug 2024 14:05');
    });

    test('carries the year on every playback frame', () {
      expect(formatHudTime(DateTime(2015, 3, 1, 23, 59)), '1 Mar 2015 23:59');
    });
  });

  group('formatPinTimeWithWeekday', () {
    test('weekday, date with year, seconds', () {
      expect(formatPinTimeWithWeekday(aug), 'Sun 11 Aug 2024, 14:05:03');
    });

    test('seconds are zero-padded', () {
      expect(formatPinTimeWithWeekday(DateTime(2026, 5, 4, 8, 9, 7)),
          'Mon 4 May 2026, 08:09:07');
    });
  });

  group('formatPhotoCaptionTime', () {
    test('middle-dot separator, still year-bearing', () {
      expect(formatPhotoCaptionTime(aug), '11 Aug 2024 · 14:05');
    });
  });

  group('shared formats', () {
    test('every label contains the four-digit year', () {
      for (final s in [
        formatPinTime(aug),
        formatHudTime(aug),
        formatPinTimeWithWeekday(aug),
        formatPhotoCaptionTime(aug),
      ]) {
        expect(s, contains('2024'), reason: s);
      }
    });

    test('day precedes month in every label (UK reading order)', () {
      for (final s in [
        formatPinTime(aug),
        formatHudTime(aug),
        formatPinTimeWithWeekday(aug),
        formatPhotoCaptionTime(aug),
      ]) {
        expect(s.indexOf('11'), lessThan(s.indexOf('Aug')), reason: s);
      }
    });

    test('the DateFormat instances are hoisted, not rebuilt per call', () {
      expect(identical(kPinTimeFormat, kPinTimeFormat), isTrue);
      expect(kPinTimeFormat.pattern, 'd MMM yyyy, HH:mm');
      expect(kHudTimeFormat.pattern, 'd MMM yyyy HH:mm');
      expect(kPinTimeWithWeekdayFormat.pattern, 'EEE d MMM yyyy, HH:mm:ss');
      expect(kPhotoCaptionTimeFormat.pattern, 'd MMM yyyy · HH:mm');
    });
  });
}
