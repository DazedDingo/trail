import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:workmanager/workmanager.dart';

import '../../db/database.dart';
import '../../db/ping_dao.dart';
import '../../models/emergency_contact.dart';
import '../../models/ping.dart';
import '../location_service.dart';
import '../notification_service.dart';
import 'panic_share_builder.dart';

/// Continuous-panic duration options shown in Settings. 15/30/60 min is the
/// PLAN.md spec; anything longer risks the user forgetting the session is
/// running and wasting battery.
enum PanicDuration {
  min15(Duration(minutes: 15)),
  min30(Duration(minutes: 30)),
  min60(Duration(minutes: 60));

  final Duration value;
  const PanicDuration(this.value);

  String get label => '${value.inMinutes} min';
}

/// Panic orchestration — one-shot and continuous modes.
///
/// **One-shot** (home button, quick-tile, widget): acquires a best-accuracy
/// fix, writes a `panic` row via the existing DAO, posts a visible
/// notification, and hands off a pre-filled SMS intent to the user's
/// default messaging app. Runs entirely in the UI isolate.
///
/// **Continuous** (1–2 min cadence for 15/30/60 min): kicks a native
/// foreground service (`PanicForegroundService.kt`) that owns the visible
/// notification + the timer. Each tick enqueues a one-off WorkManager task
/// that re-enters the Flutter dispatcher and writes another panic row — so
/// all DB access stays in the Flutter isolate, matching the rest of the
/// pipeline.
class PanicService {
  static const _channel = MethodChannel('com.dazeddingo.trail/panic');
  static const panicTaskName = 'trail_panic_ping';
  static const tagPanic = 'trail:panic';

  /// Fire a single panic ping immediately. Returns the row that was
  /// written, including a fresh high-accuracy fix when available.
  ///
  /// Uses `LocationAccuracy.best` (not `.high` like scheduled pings) — the
  /// battery cost only happens on user-initiated panics, which are rare
  /// and safety-critical. See PLAN.md "battery budget § panic burst".
  static Future<Ping> triggerOnce() async {
    final location = LocationService();
    final ping = await location.getScheduledPing(
      source: PingSource.panic,
      accuracy: LocationAccuracy.best,
      // Panic gets a tighter budget than scheduled — a lukewarm fix is
      // better than making the user stare at a spinner for 2 minutes
      // while an emergency unfolds.
      timeout: const Duration(seconds: 45),
    );
    final db = await TrailDatabase.shared();
    await PingDao(db).insert(ping);
    await NotificationService.postPanicReceipt(ping);
    return ping;
  }

  /// Open the user's default SMS app pre-filled with every configured
  /// emergency contact + a "PANIC at HH:MM — maps URL" body.
  ///
  /// No-op if no contacts are configured. Returns `false` in that case so
  /// the caller can surface a "configure contacts first" message instead
  /// of silently doing nothing.
  static Future<bool> openPanicSms({
    required List<EmergencyContact> contacts,
    required Ping ping,
  }) async {
    final uri = PanicShareBuilder.composeUri(contacts: contacts, ping: ping);
    if (uri == null) return false;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    return ok;
  }

  /// Silently send the panic SMS via native [SmsManager] — no user tap
  /// required. Gated behind the `panicAutoSendProvider` toggle and always
  /// called *after* the 5-second on-screen undo grace window elapses, so
  /// an accidental panic tap can still be rescued. Requires `SEND_SMS`
  /// permission; requests it at the call site if not already granted.
  ///
  /// Returns the number of recipients the native side reported as sent.
  /// Returns `0` on any failure (missing permission, no plugin, native
  /// error) — callers should fall back to [openPanicSms] so the user can
  /// still ship the alert manually.
  static Future<int> autoSendSms({
    required List<EmergencyContact> contacts,
    required Ping ping,
  }) async {
    if (contacts.isEmpty) return 0;
    // Runtime permission — SEND_SMS is a dangerous permission, so even
    // with the manifest declaration the user sees a system prompt the
    // first time.
    final status = await Permission.sms.request();
    if (!status.isGranted) return 0;
    final body = PanicShareBuilder.composeBody(ping: ping);
    final recipients = contacts
        .map((c) => c.phoneE164)
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    if (recipients.isEmpty) return 0;
    try {
      final sent = await _channel.invokeMethod<int>(
        'sendSms',
        {'recipients': recipients, 'body': body},
      );
      return sent ?? 0;
    } on MissingPluginException {
      return 0;
    } on PlatformException {
      return 0;
    }
  }

  /// Start the native continuous-panic foreground service for [duration].
  /// Returns `true` when the platform reported the service was started;
  /// `false` when the channel isn't wired (e.g. unit test) so callers can
  /// downgrade gracefully to the one-shot path.
  static Future<bool> startContinuous(PanicDuration duration) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'startContinuous',
        {'durationMinutes': duration.value.inMinutes},
      );
      return result ?? true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Mirror the user's chosen continuous-panic duration to a native
  /// SharedPreferences file so the Phase 3 quick-tile and home widget can
  /// read it. Non-fatal on failure — the Flutter-side secure-storage copy
  /// is still authoritative for in-app panic.
  static Future<void> syncDurationToNative(PanicDuration d) async {
    try {
      await _channel.invokeMethod(
        'setContinuousDurationMinutes',
        {'minutes': d.value.inMinutes},
      );
    } on MissingPluginException {
      // Test context — nothing to mirror to.
    } on PlatformException {
      // Native write failed; tile/widget will fall back to the 30-min
      // default which is safe.
    }
  }

  /// Stop an in-progress continuous-panic session. Idempotent.
  static Future<void> stopContinuous() async {
    try {
      await _channel.invokeMethod('stopContinuous');
    } on MissingPluginException {
      // Test context — nothing to stop.
    } on PlatformException {
      // Service wasn't running — same outcome as stopping.
    }
  }

  /// Enqueue a one-off panic ping via WorkManager. Called by the native
  /// continuous-service timer on every tick; the Flutter dispatcher picks
  /// it up and runs [triggerOnce]-equivalent logic in the background
  /// isolate (see `_handlePanic` in `workmanager_scheduler.dart`).
  ///
  /// Separate from [triggerOnce] because the native service can't reach
  /// into the UI isolate directly — WorkManager's fresh-isolate callback
  /// is the supported cross-boundary path.
  static Future<void> enqueueBackgroundPanic() async {
    await Workmanager().registerOneOffTask(
      '${panicTaskName}_${DateTime.now().millisecondsSinceEpoch}',
      panicTaskName,
      existingWorkPolicy: ExistingWorkPolicy.append,
      tag: tagPanic,
    );
  }
}
