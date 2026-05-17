import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';

import '../db/database.dart';
import '../db/ping_dao.dart';
import '../models/ping.dart';
import 'how_is_it_service.dart';

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

  /// Channel for the post-ping "How is it?" prompts. Lower importance
  /// than panic — these are quiet questions, not alerts; bonking the
  /// phone every 4h with high-priority sound would be hostile.
  static const _quickCommentChannelId = 'trail_quick_comments';
  static const _quickCommentChannelName = '"How is it?" prompts';
  static const _quickCommentChannelDesc =
      'Quick comment prompts after each scheduled ping (opt-in).';
  /// Notification action id — matches what the dart side uses to
  /// recognise a reply on `onDidReceive[Background]NotificationResponse`.
  static const quickCommentActionId = 'quick_comment_reply';
  /// Action-input key — the payload's `Map<String, String>` returns
  /// the user's typed text under this key.
  static const quickCommentInputKey = 'comment_input';

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// Idempotent. Safe to call from both the UI isolate (on startup) and
  /// the WorkManager background isolate (when dispatching a background
  /// panic task needs to post a receipt).
  static Future<void> initialize() async {
    if (_initialized) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidInit);
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: handleQuickCommentResponse,
      onDidReceiveBackgroundNotificationResponse:
          backgroundQuickCommentResponseHandler,
    );
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _panicChannelId,
        _panicChannelName,
        description: _panicChannelDesc,
        importance: Importance.high,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _quickCommentChannelId,
        _quickCommentChannelName,
        description: _quickCommentChannelDesc,
        importance: Importance.defaultImportance,
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

  /// Post the "How is it?" prompt for [pingId]. The notification carries
  /// a single text-input action so the user can reply inline; the reply
  /// routes through [handleQuickCommentResponse] (or its background
  /// twin), which writes the comment via `PingDao.attachComment`.
  ///
  /// Notification id is derived from `pingId` so a fresh prompt for the
  /// next ping replaces (not stacks) the previous one — multiple
  /// pending prompts in the tray would invite confusion about which
  /// ping the reply attaches to.
  static Future<void> postHowIsItPrompt(Ping ping) async {
    if (ping.id == null) return; // can't route a reply without an id
    try {
      await initialize();
      final fmt = formatHowIsItPrompt(ping.timestampUtc.toLocal());
      await _plugin.show(
        _quickCommentNotificationId,
        fmt.title,
        fmt.body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _quickCommentChannelId,
            _quickCommentChannelName,
            channelDescription: _quickCommentChannelDesc,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            category: AndroidNotificationCategory.message,
            actions: [
              AndroidNotificationAction(
                quickCommentActionId,
                'Reply',
                showsUserInterface: false,
                cancelNotification: true,
                inputs: [
                  AndroidNotificationActionInput(
                    label: 'How is it?',
                  ),
                ],
              ),
            ],
          ),
        ),
        // payload carries the ping id so the reply handler knows which
        // row to update without re-querying for "latest" (which could
        // drift if a panic ping landed between prompt and reply).
        payload: 'ping_id:${ping.id}',
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[notifications] how-is-it post failed: $e');
      }
    }
  }

  /// Notification id slot for "How is it?" prompts — one slot so a
  /// fresh prompt replaces the previous one in the tray.
  static const int _quickCommentNotificationId = 43001;
}

// ─── Reply action handlers (top-level for the background isolate) ────

/// Dart-side handler for the "Reply" action on a "How is it?" prompt.
/// Lives at the top level + decorated with `@pragma('vm:entry-point')`
/// so the platform plugin can invoke it from the background isolate
/// (where there's no `Workmanager` callback, just the notification
/// reply event).
///
/// Reads the ping id from the payload, sanitizes the reply text,
/// opens a fresh DB handle (no UI provider access in this isolate),
/// and writes the comment.
@pragma('vm:entry-point')
Future<void> backgroundQuickCommentResponseHandler(
  NotificationResponse response,
) async {
  await handleQuickCommentResponse(response);
}

/// Shared logic for both background + foreground reply handlers. The
/// foreground hook (`onDidReceiveNotificationResponse`) routes here
/// too so an open-app reply doesn't go through a different code path
/// than a killed-app reply (different code paths = different bugs).
Future<void> handleQuickCommentResponse(NotificationResponse response) async {
  if (response.actionId != NotificationService.quickCommentActionId) return;
  final raw = response.input;
  final comment = sanitizeQuickComment(raw);
  if (comment == null) return;
  final pingId = _parsePingIdPayload(response.payload);
  if (pingId == null) return;
  try {
    final db = await TrailDatabase.open();
    try {
      await PingDao(db).attachComment(pingId, comment);
    } finally {
      await db.close();
    }
  } catch (e) {
    if (kDebugMode) {
      debugPrint('[notifications] attach-comment failed: $e');
    }
  }
}

/// Pure: parses `"ping_id:<int>"` payloads. Exported under a leading
/// underscore so it stays library-private but tests under the same
/// library can hit it indirectly via `handleQuickCommentResponse`.
int? _parsePingIdPayload(String? payload) {
  if (payload == null) return null;
  const prefix = 'ping_id:';
  if (!payload.startsWith(prefix)) return null;
  final id = int.tryParse(payload.substring(prefix.length));
  if (id == null || id <= 0) return null;
  return id;
}

/// Public test seam — same logic as the file-private parser. Exposed
/// so unit tests can lock the contract without spinning up the plugin.
@visibleForTesting
int? parsePingIdPayloadForTest(String? payload) =>
    _parsePingIdPayload(payload);
