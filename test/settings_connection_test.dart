import 'package:flutter_test/flutter_test.dart';
import 'package:trail/screens/settings_screen.dart';

/// `describeConnectionTest` is the pure decision function behind the
/// "Test connection" button's snackbar (0.17.10). Extracted so the
/// health-only / no-token / token-accepted / token-rejected branches can
/// be pinned without a socket or a widget tree — same idiom as
/// `filterPingsByRange` in `export_dialog.dart`.
void main() {
  group('describeConnectionTest', () {
    test('health not ok keeps its original wording', () {
      expect(
        describeConnectionTest(healthOk: false),
        'Server reachable but not ready.',
      );
    });

    test('health not ok wins over an unset token, no URL note leaks in', () {
      // Regardless of tokenSet/planetDate, a failed health check is
      // reported the same way — the caller never even attempts /v1/planet
      // when health() says the server isn't ready.
      expect(
        describeConnectionTest(healthOk: false, tokenSet: true),
        'Server reachable but not ready.',
      );
    });

    test('healthy + no token configured reports the unauth planet date', () {
      expect(
        describeConnectionTest(healthOk: true, planetDate: '20260822'),
        'Connected — planet 20260822 · no token set',
      );
    });

    test('healthy + token accepted by /v1/planet reports token OK', () {
      expect(
        describeConnectionTest(
          healthOk: true,
          tokenSet: true,
          planetDate: '20260822',
        ),
        'Connected — planet 20260822 · token OK',
      );
    });

    test('healthy + token rejected (401) asks the user to re-enter it', () {
      expect(
        describeConnectionTest(
          healthOk: true,
          tokenSet: true,
          planetStatus: 401,
        ),
        'Server reachable, but the token was rejected — re-enter it.',
      );
    });

    test('healthy + token rejected (403) reads the same as 401', () {
      expect(
        describeConnectionTest(
          healthOk: true,
          tokenSet: true,
          planetStatus: 403,
        ),
        'Server reachable, but the token was rejected — re-enter it.',
      );
    });

    test('a missing planet date renders as an empty date, not "null"', () {
      expect(
        describeConnectionTest(healthOk: true, tokenSet: true),
        'Connected — planet  · token OK',
      );
    });
  });
}
