import 'package:intl/intl.dart';

import '../../models/emergency_contact.dart';
import '../../models/ping.dart';

/// Composes the panic SMS intent for hand-off to the user's default SMS app.
///
/// Design rules (PLAN.md § Panic):
/// - No `SEND_SMS` permission. We only open the compose view pre-filled;
///   the user taps Send in their SMS app. Keeps us out of Play Store's
///   restricted-perms review pipeline and keeps the user in control.
/// - Single recipient-list URI (`sms:+44…;+44…`) so the default app opens
///   with all contacts already in the To: field.
/// - Body includes a Google-Maps URL that resolves to a shareable pin; the
///   caller-phone's default browser handles the link (even without the
///   Google Maps app installed).
class PanicShareBuilder {
  static const _bodyHeader = 'PANIC';

  /// Compose the full `sms:` URI. Returns `null` if there are no contacts —
  /// caller should short-circuit and surface a "no contacts configured"
  /// notice instead of opening an SMS app with an empty recipient list.
  static Uri? composeUri({
    required List<EmergencyContact> contacts,
    required Ping ping,
    DateTime? now,
  }) {
    if (contacts.isEmpty) return null;
    final recipients = contacts
        .map((c) => c.phoneE164)
        .where((p) => p.isNotEmpty)
        .join(',');
    if (recipients.isEmpty) return null;

    final body = composeBody(ping: ping, now: now);
    // Android accepts both `sms:` and `smsto:`; `sms:` with comma-separated
    // recipients is the most portable. Using `Uri` builders avoids manual
    // encoding mistakes around the `+` and spaces.
    return Uri(
      scheme: 'sms',
      path: recipients,
      queryParameters: {'body': body},
    );
  }

  /// Public so callers (tests, widgets, diagnostics) can preview the body
  /// without going through the full URI assembly.
  static String composeBody({required Ping ping, DateTime? now}) {
    final when = (now ?? DateTime.now()).toLocal();
    final hhmm = DateFormat.Hm().format(when);
    final locPart = (ping.lat != null && ping.lon != null)
        ? 'https://maps.google.com/?q=${_fmt(ping.lat!)},${_fmt(ping.lon!)}'
        : '(no fix yet)';
    return '$_bodyHeader at $hhmm — $locPart';
  }

  /// 5-decimal precision is ~1m at the equator. Plenty for a panic pin
  /// and keeps the URL short enough to survive SMS-segment limits.
  static String _fmt(double v) => v.toStringAsFixed(5);
}
