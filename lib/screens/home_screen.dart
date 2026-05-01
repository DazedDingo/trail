import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../models/emergency_contact.dart';
import '../models/ping.dart';
import '../providers/contacts_provider.dart';
import '../providers/home_location_provider.dart';
import '../providers/panic_provider.dart';
import '../providers/pings_provider.dart';
import '../services/panic/panic_service.dart';
import '../widgets/full_map_panel.dart';
import '../widgets/help_button.dart';

/// The app's primary screen.
///
/// Layout: the top block (last-ping card, panic button, summary, export,
/// map preview) is pinned. The "Recent pings" list is the only scrollable
/// section — that's the part that grows unboundedly as pings accumulate,
/// and keeping the heartbeat + panic button always visible matters more
/// than letting the map scroll off the top of the viewport.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  void _refreshAll(WidgetRef ref) {
    ref.invalidate(lastSuccessfulPingProvider);
    ref.invalidate(heartbeatHealthyProvider);
    ref.invalidate(pingCountProvider);
    ref.invalidate(recentPingsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final last = ref.watch(lastSuccessfulPingProvider);
    final healthy = ref.watch(heartbeatHealthyProvider);
    final count = ref.watch(pingCountProvider);
    final recent = ref.watch(recentPingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trail'),
        actions: [
          const HelpButton(
            screenTitle: 'Home',
            sections: [
              HelpSection(
                icon: Icons.access_time,
                title: 'Last successful ping',
                body:
                    'Shows the timestamp, location, and "X km from home" of '
                    'the most recent fix. The dot is green if Trail logged '
                    'a row in the last 5 hours, red otherwise — that\'s the '
                    'heartbeat. A red dot means the worker stopped firing.',
              ),
              HelpSection(
                icon: Icons.touch_app_outlined,
                title: 'Hold to panic',
                body:
                    'Press and hold the panic button for 600 ms to fire a '
                    'panic ping. If you have emergency contacts and Auto-'
                    'send SMS off (default), your SMS app opens pre-filled. '
                    'With Auto-send on, the SMS fires after a 5-second undo.',
              ),
              HelpSection(
                icon: Icons.format_list_numbered,
                title: 'Recent pings',
                body:
                    'Last 100 fixes shown most-recent first. Each tile has '
                    'the timestamp, source (scheduled / panic / boot), and '
                    'a reverse-geocoded place name where available. Tap '
                    '"View all" for the full paginated history.',
              ),
              HelpSection(
                icon: Icons.map_outlined,
                title: 'Inline map',
                body:
                    'The map between the heartbeat card and the recent-'
                    'pings list has the full playback / filter / heatmap '
                    'controls — same as the dedicated /map screen, just '
                    'embedded inline. Install a region in Settings → '
                    'Offline map → Regions if the map is empty.',
              ),
              HelpSection(
                icon: Icons.refresh,
                title: 'Refresh',
                body:
                    'Re-reads everything from the encrypted DB. Pull-to-'
                    'refresh on the recent-pings list does the same. Use '
                    'this if you just ran a manual ping or imported data.',
              ),
            ],
          ),
          // Compact total-pings indicator in the header — replaces
          // the full-width "Total pings logged" card that used to sit
          // in the pinned block. Tooltip keeps the original phrasing
          // for accessibility.
          _PingCountChip(count: count),
          // Hold-to-panic icon in the header. Same 600 ms hold + auto-
          // send-grace flow as the old card, just compact. Icon stays
          // red regardless of theme so it reads as urgent.
          const _PanicHeaderAction(),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => _refreshAll(ref),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        // Pinned top block + a self-contained scrolling Recent-pings
        // list. As of 0.10.13+ the mini map preview is gone — the full
        // map panel (playback + filter + heatmap) is hosted inline at
        // 320 px, tall enough to be useful and short enough to keep
        // the heartbeat card + a couple of recent rows above the
        // fold. "View all" still opens the paginated history.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _LastPingCard(last: last, healthy: healthy),
            const SizedBox(height: 12),
            FullMapPanel(
              height: 320,
              onExpand: () => context.push('/map'),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Recent pings',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                TextButton(
                  onPressed: () => context.push('/history'),
                  child: const Text('View all'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async => _refreshAll(ref),
                child: recent.when(
                  data: (pings) {
                    if (pings.isEmpty) {
                      return ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: Text('No pings yet.')),
                          ),
                        ],
                      );
                    }
                    final visible = pings.take(100).toList(growable: false);
                    return ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: visible.length,
                      itemBuilder: (_, i) => _PingTile(ping: visible[i]),
                    );
                  },
                  loading: () => const Center(
                    child: CircularProgressIndicator(),
                  ),
                  error: (e, st) => ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [_DbErrorCard(error: e, stack: st)],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LastPingCard extends ConsumerWidget {
  final AsyncValue<Ping?> last;
  final AsyncValue<bool> healthy;
  const _LastPingCard({required this.last, required this.healthy});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isHealthy = healthy.asData?.value ?? true;
    final p = last.asData?.value;
    final scheme = Theme.of(context).colorScheme;
    // 1.5 px error-coloured border when not healthy, transparent
    // otherwise. The pre-0.10.13 card wrapped this in an outer
    // RoundedRectangleBorder + side: 2 — drop both, the Card's own
    // outline is enough.
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isHealthy ? Colors.transparent : scheme.error,
          width: 1.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _HeartbeatLine(isHealthy: isHealthy, ping: p),
            if (p != null) ...[
              const SizedBox(height: 2),
              _LastPingDetailLine(ping: p),
            ],
          ],
        ),
      ),
    );
  }
}

class _HeartbeatLine extends StatelessWidget {
  final bool isHealthy;
  final Ping? ping;
  const _HeartbeatLine({required this.isHealthy, required this.ping});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tsFmt = DateFormat.MMMd().add_Hms();
    final ts = ping == null
        ? null
        : tsFmt.format(ping!.timestampUtc.toLocal());
    final title = isHealthy ? 'Heartbeat healthy' : 'No ping in 5+ hours';
    final body = ts == null
        ? title
        // Middle-dot separator matches the convention in the
        // map-screen HUD + recent-tile bottom row.
        : '$title  ·  $ts';
    return Row(
      children: [
        Icon(
          isHealthy ? Icons.favorite : Icons.warning_amber_rounded,
          size: 16,
          color: isHealthy ? scheme.primary : scheme.error,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            body,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
          ),
        ),
      ],
    );
  }
}

/// Single-line detail row: coords + accuracy + reverse-geocoded place
/// name + km-from-home, with middle-dot separators between non-empty
/// segments. Drops segments cleanly when geocoding has nothing or the
/// user hasn't set a home location, so the line renders identically
/// for users who never opted in.
class _LastPingDetailLine extends ConsumerWidget {
  final Ping ping;
  const _LastPingDetailLine({required this.ping});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lat = ping.lat;
    final lon = ping.lon;
    if (lat == null || lon == null) {
      return Text(
        ping.note ?? 'No fix',
        style: Theme.of(context).textTheme.bodySmall,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    final approx = ref
        .watch(approxLocationProvider((lat: lat, lon: lon)))
        .asData
        ?.value;
    final home = ref.watch(homeLocationProvider).asData?.value;

    final segments = <String>[];
    final coordSeg = StringBuffer(
      '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}',
    );
    if (ping.accuracy != null) {
      coordSeg.write(' ±${ping.accuracy!.toStringAsFixed(0)}m');
    }
    segments.add(coordSeg.toString());
    if (approx != null && approx.isNotEmpty) segments.add(approx);
    if (home != null) {
      final metres = home.distanceMetersTo(lat, lon);
      final label = metres < 1000
          ? '${metres.round()} m from home'
          : '${(metres / 1000).toStringAsFixed(metres < 10000 ? 1 : 0)} km from home';
      segments.add(label);
    }
    return Text(
      segments.join('  ·  '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
    );
  }
}

/// Panic action in the AppBar.
///
/// Pre-0.10.13 this was a full-width card in the home body. The user
/// asked to demote it to a header icon for a less obtrusive home
/// screen. Same hold-to-trigger UX (600 ms) and same auto-send-grace
/// flow — only the chrome is different. The icon's background fills
/// red as you hold so the arming is still visually obvious. The
/// "Start continuous panic" affordance moved to Settings → Panic.
class _PanicHeaderAction extends ConsumerStatefulWidget {
  const _PanicHeaderAction();

  @override
  ConsumerState<_PanicHeaderAction> createState() =>
      _PanicHeaderActionState();
}

class _PanicHeaderActionState extends ConsumerState<_PanicHeaderAction>
    with SingleTickerProviderStateMixin {
  /// How long the user must hold before panic fires. 600 ms is the
  /// sweet spot — long enough that a stray pocket-tap won't cross it,
  /// short enough that in a real emergency the user doesn't feel the UI
  /// is fighting them.
  static const _holdDuration = Duration(milliseconds: 600);

  /// Grace window between "panic logged" and "SMS sent" when auto-send
  /// is on. Tuned to match Android's default SnackBar timeout so the
  /// visual countdown and the send fire together.
  static const _autoSendGrace = Duration(seconds: 5);

  late final AnimationController _hold;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _hold = AnimationController(vsync: this, duration: _holdDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && !_working) {
          _panicNow();
          _hold.reset();
        }
      });
  }

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  void _startHold() {
    if (_working) return;
    _hold.forward(from: 0);
  }

  void _cancelHold() {
    if (_hold.status == AnimationStatus.forward) _hold.reverse();
  }

  Future<void> _panicNow() async {
    setState(() => _working = true);
    Ping? result;
    Object? error;
    try {
      result = await PanicService.triggerOnce();
    } catch (e) {
      error = e;
    }
    if (!mounted) return;
    setState(() => _working = false);
    ref.invalidate(lastSuccessfulPingProvider);
    ref.invalidate(heartbeatHealthyProvider);
    ref.invalidate(pingCountProvider);
    ref.invalidate(recentPingsProvider);

    if (error != null || result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Panic failed: ${error ?? "unknown"}')),
      );
      return;
    }

    final contacts = await ref.read(emergencyContactsProvider.future);
    if (!mounted) return;
    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Panic logged — add emergency contacts in Settings to SMS them.',
          ),
        ),
      );
      return;
    }

    final autoSend = await ref.read(panicAutoSendProvider.future);
    if (!mounted) return;
    if (autoSend) {
      await _shareWithUndoGrace(contacts: contacts, ping: result);
    } else {
      final opened =
          await PanicService.openPanicSms(contacts: contacts, ping: result);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            opened
                ? 'Panic logged + SMS app opened with ${contacts.length} '
                    'contact${contacts.length == 1 ? "" : "s"}.'
                : 'Panic logged. SMS hand-off failed — send manually.',
          ),
        ),
      );
    }
  }

  /// Auto-send path: show a 5-second undo SnackBar AND start an
  /// independent send timer. Flutter's SnackBar duration is advisory —
  /// under accessibility services (TalkBack, Switch Access, Select-to-
  /// Speak) the framework pins the SnackBar open until the user
  /// manually dismisses it, which would previously block the send
  /// indefinitely because we keyed the fire on `controller.closed`.
  /// The timer fires regardless; UNDO cancels it directly.
  Future<void> _shareWithUndoGrace({
    required List<EmergencyContact> contacts,
    required Ping ping,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final completer = Completer<bool>();
    Timer? sendTimer;

    void resolve(bool send) {
      if (completer.isCompleted) return;
      sendTimer?.cancel();
      completer.complete(send);
    }

    final controller = messenger.showSnackBar(
      SnackBar(
        duration: _autoSendGrace,
        content: Text(
          'Panic logged. Sending SMS to ${contacts.length} '
          'contact${contacts.length == 1 ? "" : "s"} in '
          '${_autoSendGrace.inSeconds}s…',
        ),
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () => resolve(false),
        ),
      ),
    );
    sendTimer = Timer(_autoSendGrace, () => resolve(true));
    // Still honour manual dismissal: a swipe-away mid-countdown resolves
    // as "send" (user saw the warning, didn't undo); UNDO already
    // resolved above before the SnackBar actually closes.
    unawaited(controller.closed.then((_) => resolve(true)));

    final shouldSend = await completer.future;
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    if (!shouldSend) {
      messenger.showSnackBar(
        const SnackBar(content: Text('SMS cancelled. Panic still logged.')),
      );
      return;
    }
    final sent =
        await PanicService.autoSendSms(contacts: contacts, ping: ping);
    if (!mounted) return;
    if (sent > 0) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Panic SMS sent to $sent '
            'contact${sent == 1 ? "" : "s"}.',
          ),
        ),
      );
    } else {
      final opened =
          await PanicService.openPanicSms(contacts: contacts, ping: ping);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            opened
                ? 'Auto-send unavailable — SMS app opened instead.'
                : 'Panic logged. SMS send failed — send manually.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: _working ? 'Logging panic…' : 'Hold to panic (600 ms)',
      child: GestureDetector(
        onLongPressStart: (_) => _startHold(),
        onLongPressEnd: (_) => _cancelHold(),
        onLongPressCancel: _cancelHold,
        child: AnimatedBuilder(
          animation: _hold,
          builder: (context, _) {
            // Background fills red as the user holds. At 0% it's a
            // soft tint; at 100% (just before fire) it's the full
            // error tone. After fire, the indicator goes back to 0
            // automatically because we reset the controller.
            final fill = _hold.value;
            final bg = Color.lerp(
              Colors.transparent,
              scheme.error.withValues(alpha: 0.7),
              fill,
            )!;
            return Container(
              width: 40,
              height: 40,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: bg,
                shape: BoxShape.circle,
                border: Border.all(
                  color: scheme.error.withValues(alpha: 0.6),
                  width: 1.5,
                ),
              ),
              child: _working
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation(scheme.error),
                      ),
                    )
                  : Icon(
                      Icons.warning_rounded,
                      // Switch to the high-contrast colour once the
                      // fill is dark enough to obscure the red icon.
                      color: fill > 0.5
                          ? scheme.onError
                          : scheme.error,
                      size: 20,
                    ),
            );
          },
        ),
      ),
    );
  }
}

/// Compact "pin + count" chip for the AppBar. Shows the same value
/// the `Total pings logged` card used to surface, in a fraction of
/// the vertical space — frees up the home screen for the recent-
/// pings scroller. Static; not tappable. Renders "…" while the
/// count provider is still resolving.
class _PingCountChip extends StatelessWidget {
  final AsyncValue<int> count;
  const _PingCountChip({required this.count});

  @override
  Widget build(BuildContext context) {
    final value = count.asData?.value;
    final label = value == null ? '…' : value.toString();
    return Tooltip(
      message: 'Total pings logged',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.pin_drop_outlined, size: 18),
            const SizedBox(width: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Surfaces a DB load failure with copyable detail. The previous single-line
/// `Text('Failed to load: $e')` truncated exception text off-screen, which
/// made field diagnosis impossible when 0.1.3 hit a first-install DB race.
class _DbErrorCard extends StatelessWidget {
  final Object error;
  final StackTrace stack;
  const _DbErrorCard({required this.error, required this.stack});

  @override
  Widget build(BuildContext context) {
    final detail = '$error\n\n$stack';
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline,
                    color: Theme.of(context).colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Failed to load pings',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Copy error',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: detail)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              detail,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// One row in the recent-pings list.
///
/// Pre-0.10.13 this was a `ListTile(dense: true)` with a 2-line
/// subtitle — comfortable but ate ~64 px per row. Now it's a flat
/// `Padding + Row` at ~36 px so 4–5 rows fit in the visible space
/// below the inline map. Density is fully under our control instead
/// of subject to ListTile's internal min-height.
class _PingTile extends ConsumerWidget {
  final Ping ping;
  const _PingTile({required this.ping});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isNoFix = ping.source == PingSource.noFix;
    final hasFix = ping.lat != null && ping.lon != null;
    final approx = hasFix
        ? ref
            .watch(approxLocationProvider((lat: ping.lat!, lon: ping.lon!)))
            .asData
            ?.value
        : null;
    final time = DateFormat.Hms().format(ping.timestampUtc.toLocal());
    final coordsOrNote = hasFix
        ? '${ping.lat!.toStringAsFixed(4)}, ${ping.lon!.toStringAsFixed(4)}'
        : (ping.note ?? 'No fix');

    final tabularSmall = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        );
    final placeStyle = Theme.of(context).textTheme.bodySmall;
    final sourceStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
        );

    return InkWell(
      onTap: () {/* tap-to-inspect lives on /map for now */},
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(
              _iconFor(ping.source),
              size: 16,
              color: isNoFix ? scheme.error : null,
            ),
            const SizedBox(width: 8),
            Text(time, style: tabularSmall),
            const SizedBox(width: 8),
            Text(coordsOrNote, style: tabularSmall),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                approx ?? '',
                style: placeStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Text(ping.source.dbValue, style: sourceStyle),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(PingSource s) {
    switch (s) {
      case PingSource.panic:
        return Icons.priority_high;
      case PingSource.boot:
        return Icons.power_settings_new;
      case PingSource.noFix:
        return Icons.signal_cellular_off;
      case PingSource.scheduled:
        return Icons.pin_drop;
    }
  }
}
