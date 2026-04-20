import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static checks against `android/app/src/main/AndroidManifest.xml` and
/// `MainActivity.kt`.
///
/// These are NOT integration tests — no emulator, no plugin code runs. They
/// just catch the platform-config misses that are otherwise invisible until
/// you install the APK on a real device:
///
///   - **v0.1.2 bug** — `USE_BIOMETRIC` missing → `canCheckBiometrics`
///     returned `false` and the lock screen offered no fingerprint UI.
///   - **v0.1.2 bug** — `MainActivity` extended `FlutterActivity` instead of
///     `FlutterFragmentActivity`, so `local_auth.authenticate()` threw and
///     the lock screen flashed a generic "Authentication failed".
///
/// Both bugs would have been caught by these tests. Cheap, no flake, runs
/// in the normal `flutter test` step.
const _manifestPath = 'android/app/src/main/AndroidManifest.xml';
const _mainActivityPath =
    'android/app/src/main/kotlin/com/dazeddingo/trail/MainActivity.kt';

String _manifest() => File(_manifestPath).readAsStringSync();
String _mainActivity() => File(_mainActivityPath).readAsStringSync();

bool _hasPermission(String name) =>
    _manifest().contains('android:name="android.permission.$name"');

void main() {
  group('AndroidManifest — biometric perms', () {
    // Both must be declared. USE_BIOMETRIC covers API 28+; USE_FINGERPRINT
    // is the legacy path for API 23-27. Without these,
    // `LocalAuthentication.canCheckBiometrics` returns false on the
    // affected devices and no fingerprint UI is offered (the v0.1.2 bug).
    test('declares USE_BIOMETRIC (API 28+ biometric prompt)', () {
      expect(_hasPermission('USE_BIOMETRIC'), isTrue,
          reason:
              'Missing USE_BIOMETRIC → canCheckBiometrics returns false on '
              'API 28+ and the lock screen offers no fingerprint UI.');
    });

    test('declares USE_FINGERPRINT (legacy API 23-27)', () {
      // minSdk is 23, so we MUST cover the legacy path too.
      expect(_hasPermission('USE_FINGERPRINT'), isTrue,
          reason:
              'minSdk 23 → must also declare the legacy USE_FINGERPRINT '
              'or pre-API-28 devices get no biometric path.');
    });
  });

  group('AndroidManifest — location perms (4h scheduled pings)', () {
    test('declares ACCESS_FINE_LOCATION', () {
      expect(_hasPermission('ACCESS_FINE_LOCATION'), isTrue);
    });

    test('declares ACCESS_BACKGROUND_LOCATION', () {
      // The whole point of the app — without this the 4h worker can't get
      // a fix when the user isn't actively in the app.
      expect(_hasPermission('ACCESS_BACKGROUND_LOCATION'), isTrue);
    });

    test('declares COARSE as a fine-location fallback', () {
      // Some users deny fine but allow coarse; the app degrades gracefully.
      expect(_hasPermission('ACCESS_COARSE_LOCATION'), isTrue);
    });
  });

  group('AndroidManifest — boot + scheduling perms', () {
    test('declares RECEIVE_BOOT_COMPLETED for the BootReceiver', () {
      expect(_hasPermission('RECEIVE_BOOT_COMPLETED'), isTrue,
          reason:
              'BootReceiver listens for ACTION_BOOT_COMPLETED — without '
              'this perm Android silently drops the broadcast and the app '
              'never re-arms after reboot.');
    });

    test('declares the exact-alarm pair (Phase 5 toggle)', () {
      expect(_hasPermission('SCHEDULE_EXACT_ALARM'), isTrue);
      expect(_hasPermission('USE_EXACT_ALARM'), isTrue);
    });

    test('declares REQUEST_IGNORE_BATTERY_OPTIMIZATIONS', () {
      // Required to ask the user to opt out of OEM doze for the 4h cadence
      // to actually fire on time.
      expect(_hasPermission('REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'), isTrue);
    });
  });

  group('AndroidManifest — telemetry perms', () {
    test('declares NEARBY_WIFI_DEVICES (Wi-Fi SSID on Android 13+)', () {
      expect(_hasPermission('NEARBY_WIFI_DEVICES'), isTrue);
    });

    test('declares READ_PHONE_STATE (cell tower ID)', () {
      expect(_hasPermission('READ_PHONE_STATE'), isTrue);
    });

    test('declares POST_NOTIFICATIONS (Android 13+ runtime perm)', () {
      expect(_hasPermission('POST_NOTIFICATIONS'), isTrue);
    });
  });

  group('AndroidManifest — encrypted-DB invariants', () {
    test('android:allowBackup is true and points at backup_rules', () {
      // Flipped in 0.1.7+8 so users can opt into the "set a backup
      // passphrase" flow — PBKDF2-derived key means the DB survives
      // uninstall/new-device restore without the Keystore-bound problem
      // the old design had.
      expect(_manifest().contains('android:allowBackup="true"'), isTrue,
          reason:
              'allowBackup must be true so Android auto-backs the encrypted '
              'DB + salt file to Google Drive. The passphrase-derived key '
              'stays off-device — backup alone is useless without it.');
      expect(
        _manifest().contains('android:fullBackupContent="@xml/backup_rules"'),
        isTrue,
        reason:
            'Must point at backup_rules.xml — the selective rules that '
            'include the DB + salt but exclude Keystore-bound sharedpref.',
      );
    });

    test('backup_rules.xml and data_extraction_rules.xml both exist', () {
      expect(
        File('android/app/src/main/res/xml/backup_rules.xml').existsSync(),
        isTrue,
        reason: 'Referenced from AndroidManifest — build fails without it.',
      );
      expect(
        File('android/app/src/main/res/xml/data_extraction_rules.xml')
            .existsSync(),
        isTrue,
      );
    });

    test('backup rules include file domain but exclude FlutterSecureStorage',
        () {
      final rules =
          File('android/app/src/main/res/xml/backup_rules.xml').readAsStringSync();
      expect(rules.contains('<include domain="file"'), isTrue,
          reason: 'Must include file domain — that\'s where trail.db lives.');
      expect(rules.contains('FlutterSecureStorage'), isTrue,
          reason:
              'Must explicitly exclude FlutterSecureStorage — it\'s Keystore-'
              'wrapped and can\'t roundtrip through a backup.');
    });

    test('NEARBY_WIFI_DEVICES is flagged neverForLocation', () {
      // We use the Wi-Fi SSID for telemetry, not for re-deriving location
      // beyond what GPS already gave us. The neverForLocation flag tells
      // Android we're not abusing it — required so Play Store policy
      // doesn't escalate the perm to a location-class disclosure.
      expect(_manifest().contains('neverForLocation'), isTrue);
    });
  });

  group('MainActivity — local_auth host requirement', () {
    test('extends FlutterFragmentActivity, NOT FlutterActivity', () {
      // local_auth's biometric prompt is a Fragment and needs a
      // FragmentActivity host. Plain FlutterActivity makes
      // `authenticate()` throw with no UI ever shown — this was the v0.1.2
      // "Authentication failed on sign in" bug.
      final src = _mainActivity();
      expect(src.contains('FlutterFragmentActivity'), isTrue,
          reason: 'MainActivity must extend FlutterFragmentActivity for '
              'local_auth to work.');
      expect(src.contains(': FlutterActivity()'), isFalse,
          reason: 'Must NOT extend FlutterActivity — local_auth will throw.');
      expect(
        src.contains(
            'import io.flutter.embedding.android.FlutterFragmentActivity'),
        isTrue,
        reason: 'Import must match the superclass.',
      );
    });
  });
}
