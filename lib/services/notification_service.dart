import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';

import '../models/ping.dart';

/// Thin wrapper around `flutter_local_notifications` for the panic channel.
///
/// Rules (PLAN.md § Panic):
/// - Scheduled pings are SILENT — posting a notification every 4h would be
///   noise nobody reads. Only the panic path uses this service.
/// - Visible notification on panic-receipt: "Panic ping logged at HH:MM —
///   lat,lon". High importance so it survives Doze and isn't suppressed
///   in quiet hours.
/// - The continuous-panic session's persistent notification is owned by
///   the native `PanicForegroundService.kt` (foreground services must own
///   their own notification on Android). This service only posts the
///   one-shot receipts.
class NotificationService {
  static const _panicChannelId = 'trail_panic';
  static const _panicChannelName = 'Panic receipts';
  static const _panicChannelDesc =
      'Visible confirmation that a panic ping was logged.';
  static const _panicReceiptId = 42001;

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// Idempotent. Safe to call from both the UI isolate (on startup) and
  /// the WorkManager background isolate (when dispatching a background
  /// panic task needs to post a receipt).
  static Future<void> initialize() async {
    if (_initialized) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidInit);
    await _plugin.initialize(settings);
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _panicChannelId,
            _panicChannelName,
            description: _panicChannelDesc,
            importance: Importance.high,
          ),
        );
    _initialized = true;
  }

  /// Post the "panic ping logged" receipt. No-op in test environments
  /// where the plugin channel isn't wired.
  static Future<void> postPanicReceipt(Ping panic) async {
    try {
      await initialize();
      final ts = DateFormat.Hm().format(panic.timestampUtc.toLocal());
      final loc = (panic.lat != null && panic.lon != null)
          ? '${panic.lat!.toStringAsFixed(5)}, '
              '${panic.lon!.toStringAsFixed(5)}'
          : (panic.note ?? 'no fix');
      await _plugin.show(
        _panicReceiptId,
        'Panic ping logged',
        '$ts — $loc',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _panicChannelId,
            _panicChannelName,
            channelDescription: _panicChannelDesc,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.alarm,
          ),
        ),
      );
    } catch (e) {
      // Never let a failed notification swallow the actual panic write —
      // the DB row is what matters; the notification is the UX layer.
      if (kDebugMode) {
        debugPrint('[notifications] panic receipt failed: $e');
      }
    }
  }
}
