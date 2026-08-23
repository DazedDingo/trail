import 'package:flutter_test/flutter_test.dart';
import 'package:trail/app.dart';

/// The router's `redirect` rule is the only thing standing between a
/// half-initialised app and a screen that would touch the encrypted DB
/// before it can be opened. Extracted from `app.dart`'s closure as a pure
/// function so the whole truth table can be asserted without mounting a
/// GoRouter, a ProviderScope, or MapLibre.
///
/// Four flags × the locations that matter. The rules, in the order the
/// function applies them:
///   0. startupFailed                     → /startup-failed (outermost)
///   1. not onboarded                     → /onboarding (hard gate)
///   2. onboarded, on onboarding          → the right gate for the key state
///   3. keyMissing OR notMigrated         → /recover (beats needsUnlock)
///   4. needsUnlock                       → /unlock
///   5. otherwise                         → null (allow)
///
/// `notMigrated` (flutter_secure_storage 11 reading a store release A
/// never rewrote) gates identically to `keyMissing`; only the copy on
/// `KeyRecoveryScreen` differs.
String? redirect(
  String location, {
  bool onboarded = true,
  bool needsUnlock = false,
  bool keyMissing = false,
  bool notMigrated = false,
  bool startupFailed = false,
}) =>
    startupRedirect(
      location: location,
      onboarded: onboarded,
      needsUnlock: needsUnlock,
      keyMissing: keyMissing,
      notMigrated: notMigrated,
      startupFailed: startupFailed,
    );

/// Every route a user can land on that is not itself a gate.
const _ordinaryRoutes = [
  '/lock',
  '/home',
  '/history',
  '/settings',
  '/map',
  '/diagnostics',
];

void main() {
  group('onboarding is a hard gate', () {
    test('not onboarded → /onboarding from everywhere', () {
      for (final loc in _ordinaryRoutes) {
        expect(redirect(loc, onboarded: false), '/onboarding', reason: loc);
      }
    });

    test('not onboarded → stays on /onboarding and its sub-paths', () {
      expect(redirect('/onboarding', onboarded: false), isNull);
      expect(redirect('/onboarding/permissions', onboarded: false), isNull);
    });

    test('onboarding beats every other gate', () {
      // A restored install that has not onboarded yet must still see the
      // flow first — /unlock and /recover both touch the DB story, and
      // the lock screen would pop a system dialog before consent.
      expect(
        redirect('/home',
            onboarded: false, needsUnlock: true, keyMissing: true),
        '/onboarding',
      );
      expect(
        redirect('/recover', onboarded: false, keyMissing: true),
        '/onboarding',
      );
      expect(
        redirect('/recover', onboarded: false, notMigrated: true),
        '/onboarding',
      );
      expect(
        redirect('/unlock', onboarded: false, needsUnlock: true),
        '/onboarding',
      );
    });

    test('onboarded but still on /onboarding → the right gate', () {
      expect(redirect('/onboarding'), '/lock');
      expect(redirect('/onboarding', needsUnlock: true), '/unlock');
      expect(redirect('/onboarding', keyMissing: true), '/recover');
      expect(
        redirect('/onboarding', needsUnlock: true, keyMissing: true),
        '/recover',
        reason: 'keyMissing wins on the way out of onboarding too',
      );
      expect(redirect('/onboarding', notMigrated: true), '/recover');
    });
  });

  group('keyMissing → /recover', () {
    test('bounces every other route', () {
      for (final loc in [..._ordinaryRoutes, '/unlock']) {
        expect(redirect(loc, keyMissing: true), '/recover', reason: loc);
      }
    });

    test('already on /recover → stays', () {
      expect(redirect('/recover', keyMissing: true), isNull);
    });

    test('beats needsUnlock — /recover is the screen that can reach /unlock',
        () {
      expect(
        redirect('/home', needsUnlock: true, keyMissing: true),
        '/recover',
      );
      expect(
        redirect('/unlock', needsUnlock: true, keyMissing: true),
        '/recover',
      );
      // On /recover with BOTH flags the unlock rule wins and hands off
      // to /unlock. Unreachable in practice (`computeStartupKeyState`
      // returns one state, never two) and harmless: /unlock is where a
      // user with a salt file wants to be anyway.
      expect(
        redirect('/recover', needsUnlock: true, keyMissing: true),
        '/unlock',
      );
    });

    test('cleared → /recover releases to /lock', () {
      // What the recovery screen's "Try again" / "Start a new log" do:
      // flip the flag, then navigate.
      expect(redirect('/recover'), '/lock');
      // The passphrase hand-off converges in two hops rather than one:
      // /recover → /lock (keyMissing cleared) → /unlock (needsUnlock).
      // No loop, and the screen itself navigates straight to /unlock, so
      // the user never sees the intermediate step.
      expect(redirect('/recover', needsUnlock: true), '/lock');
      expect(redirect('/lock', needsUnlock: true), '/unlock');
    });
  });

  group('notMigrated → /recover (the fss 11 gate)', () {
    test('bounces every other route, exactly like keyMissing', () {
      for (final loc in [..._ordinaryRoutes, '/unlock']) {
        expect(redirect(loc, notMigrated: true), '/recover', reason: loc);
      }
    });

    test('already on /recover → stays', () {
      expect(redirect('/recover', notMigrated: true), isNull);
    });

    test('beats needsUnlock too', () {
      expect(
        redirect('/home', needsUnlock: true, notMigrated: true),
        '/recover',
      );
    });

    test('both flags at once still means one screen', () {
      expect(
        redirect('/home', keyMissing: true, notMigrated: true),
        '/recover',
      );
      expect(
        redirect('/recover', keyMissing: true, notMigrated: true),
        isNull,
      );
    });

    test('cleared → /recover releases to /lock', () {
      // What "Try again" does once the user comes back from 0.17.3.
      expect(redirect('/recover'), '/lock');
    });

    test('clearing only one of the two flags keeps the gate shut', () {
      // The recovery screen re-points the diagnosis without opening the
      // gate: keyMissing false + notMigrated true is still /recover.
      expect(redirect('/home', keyMissing: false, notMigrated: true),
          '/recover');
      expect(redirect('/home', keyMissing: true, notMigrated: false),
          '/recover');
    });
  });

  group('needsUnlock → /unlock', () {
    test('bounces every other route', () {
      for (final loc in _ordinaryRoutes) {
        expect(redirect(loc, needsUnlock: true), '/unlock', reason: loc);
      }
    });

    test('already on /unlock → stays', () {
      expect(redirect('/unlock', needsUnlock: true), isNull);
    });

    test('cleared → /unlock releases to /lock', () {
      expect(redirect('/unlock'), '/lock');
    });
  });

  group('startupFailed → /startup-failed (the outermost gate)', () {
    test('bounces every other route, gates included', () {
      for (final loc in [
        ..._ordinaryRoutes.where((r) => r != '/diagnostics'),
        '/unlock',
        '/recover',
        '/onboarding',
      ]) {
        expect(redirect(loc, startupFailed: true), '/startup-failed',
            reason: loc);
      }
    });

    test('already on /startup-failed → stays (no redirect loop)', () {
      expect(redirect('/startup-failed', startupFailed: true), isNull);
    });

    test('beats every other gate — the flags below it are defaults, '
        'not readings', () {
      expect(
        redirect('/home',
            startupFailed: true,
            onboarded: false,
            needsUnlock: true,
            keyMissing: true,
            notMigrated: true),
        '/startup-failed',
      );
      expect(
        redirect('/onboarding', startupFailed: true, onboarded: false),
        '/startup-failed',
      );
    });

    test('/diagnostics is the one exemption', () {
      // The failure screen's "Open diagnostics" button would be a dead
      // control otherwise. Diagnostics opens neither the DB nor secure
      // storage on load; the integrity check is behind its own button.
      expect(redirect('/diagnostics', startupFailed: true), isNull);
    });

    test('cleared → /startup-failed releases to /lock', () {
      // What "Try again" does. Symmetric with /unlock and /recover:
      // clearing the provider alone releases the app, so a missed
      // `context.go` cannot strand the user on the failure screen.
      expect(redirect('/startup-failed'), '/lock');
      expect(redirect('/startup-failed', onboarded: false), '/onboarding');
      expect(redirect('/startup-failed', needsUnlock: true), '/unlock');
      expect(redirect('/startup-failed', keyMissing: true), '/recover');
    });
  });

  group('happy path allows everything', () {
    test('onboarded, key present → null everywhere', () {
      for (final loc in _ordinaryRoutes) {
        expect(redirect(loc), isNull, reason: loc);
      }
    });

    test('the gate screens are the only ones that redirect when idle', () {
      // /unlock and /recover are not places to linger once their reason
      // is gone; everything else is.
      expect(redirect('/unlock'), '/lock');
      expect(redirect('/recover'), '/lock');
      expect(redirect('/onboarding'), '/lock');
      expect(redirect('/lock'), isNull);
    });

    test('is idempotent — redirecting to the target returns null', () {
      // A rule that bounced its own target would spin GoRouter forever.
      expect(redirect('/onboarding', onboarded: false), isNull);
      expect(redirect('/recover', keyMissing: true), isNull);
      expect(redirect('/recover', notMigrated: true), isNull);
      expect(redirect('/unlock', needsUnlock: true), isNull);
      expect(redirect('/lock'), isNull);
    });
  });
}
