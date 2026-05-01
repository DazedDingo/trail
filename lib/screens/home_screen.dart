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
import '../providers/mbtiles_provider.dart';
import '../providers/panic_provider.dart';
import '../providers/pings_provider.dart';
import '../services/panic/panic_service.dart';
import '../widgets/help_button.dart';
import '../widgets/trail_map.dart';
import 'export_dialog.dart';

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
    final activeRegion = ref.watch(activeRegionProvider);

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
                title: 'Map preview',
                body:
                    'Mini map below the export row shows recent fixes on '
                    'your active offline region. "Full map" opens the '
                    'playback / filter / heatmap screen. Install a region '
                    'in Settings → Offline map → Regions if the map is '
                    'empty.',
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
        // list. The map preview was the bulk of the pinned height —
        // dropped it from the home screen so the Expanded list has
        // room to breathe. "Map" tile in the export/quick-actions row
        // and the AppBar back-flow still take you to the full map
        // screen in one tap.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _LastPingCard(last: last, healthy: healthy),
            const SizedBox(height: 12),
            // Mini map sits above the panic button (per user
            // preference) — gives an at-a-glance "where am I" before
            // the safety/quick-action affordances. Trimmed to 140 px
            // (down from the original 180 px) so the inner Recent
            // pings scroller still has visible vertical space on
            // typical phone viewports. Tap to open the full map
            // screen via the "Map" link in the Recent-pings header.
            recent.when(
              data: (pings) => TrailMap(
                pings: pings,
                activeRegion: activeRegion.valueOrNull,
                height: 140,
              ),
              loading: () => const SizedBox(
                height: 140,
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => const SizedBox.shrink(),
            ),
            const SizedBox(height: 12),
            const _PanicButton(),
            const SizedBox(height: 12),
            _SummaryCard(count: count),
            const SizedBox(height: 12),
            _ExportRow(),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Recent pings',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => context.push('/map'),
                      icon: const Icon(Icons.map_outlined, size: 16),
                      label: const Text('Map'),
                    ),
                    TextButton(
                      onPressed: () => context.push('/history'),
                      child: const Text('View all'),
                    ),
                  ],
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
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isHealthy
              ? Colors.transparent
              : Theme.of(context).colorScheme.error,
          width: 2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isHealthy ? Icons.favorite : Icons.warning_amber_rounded,
                  color: isHealthy
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 8),
                Text(
                  isHealthy ? 'Heartbeat healthy' : 'No ping in 5+ hours',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (p == null)
              const Text('No successful pings yet.')
            else ...[
              Text(
                DateFormat.yMMMd().add_Hms().format(p.timestampUtc.toLocal()),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
              Text(
                '${p.lat!.toStringAsFixed(5)}, ${p.lon!.toStringAsFixed(5)}'
                '${p.accuracy != null ? "  ±${p.accuracy!.toStringAsFixed(0)}m" : ""}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              _ApproxLocationLine(lat: p.lat!, lon: p.lon!),
              _HomeDistanceLine(lat: p.lat!, lon: p.lon!),
            ],
          ],
        ),
      ),
    );
  }
}

/// Reverse-geocoded city/region label under the raw coordinates.
///
/// Silent while loading (we'd rather the number pop in cold than the card
/// flicker a "Resolving…" placeholder for 200ms). Silent on null too —
/// offline with no cached geocoder data is a normal state, not an error.
class _ApproxLocationLine extends ConsumerWidget {
  final double lat;
  final double lon;
  const _ApproxLocationLine({required this.lat, required this.lon});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = ref.watch(approxLocationProvider((lat: lat, lon: lon)));
    return label.when(
      data: (name) {
        if (name == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Icon(
                Icons.place_outlined,
                size: 14,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  name,
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

/// "X km from home" annotation under the coords. Silent when the user
/// hasn't set a home location (Settings → Home location), so the card
/// reads identically for users who never opt in.
class _HomeDistanceLine extends ConsumerWidget {
  final double lat;
  final double lon;
  const _HomeDistanceLine({required this.lat, required this.lon});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(homeLocationProvider);
    final h = home.asData?.value;
    if (h == null) return const SizedBox.shrink();
    final metres = h.distanceMetersTo(lat, lon);
    final label = metres < 1000
        ? '${metres.round()} m from home'
        : '${(metres / 1000).toStringAsFixed(metres < 10000 ? 1 : 0)} km from home';
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Icon(
            Icons.home_outlined,
            size: 14,
            color: Theme.of(context).colorScheme.secondary,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Panic card on the home screen.
///
/// De-emphasised by design (0.6.1+16): a single outlined hold-to-trigger
/// button + a smaller continuous-mode action. The "big red button" of
/// pre-0.6.1 fired on a single tap and was racking up accidental panics
/// from pocket taps and UI mis-touches. Now the user must hold for
/// [_holdDuration]; the progress ring fills during the hold so they can
/// see it's armed. After fire, if `panicAutoSendProvider` is on, the SMS
/// goes out *after* an additional 5-second on-screen undo grace.
class _PanicButton extends ConsumerStatefulWidget {
  const _PanicButton();

  @override
  ConsumerState<_PanicButton> createState() => _PanicButtonState();
}

class _PanicButtonState extends ConsumerState<_PanicButton>
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

  Future<void> _startContinuous() async {
    final duration = await ref.read(panicDurationProvider.future);
    final ok = await PanicService.startContinuous(duration);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Continuous panic started (${duration.label}). Tap Stop '
                  'in the notification to end early.'
              : 'Continuous-mode service unavailable — logging a single '
                  'panic ping instead.',
        ),
      ),
    );
    if (!ok) {
      await _panicNow();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      // Lighter tint than pre-0.6.1 so the card no longer dominates the
      // screen. Red border still marks its intent.
      color: scheme.errorContainer.withValues(alpha: 0.15),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.error.withValues(alpha: 0.45)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              onLongPressStart: (_) => _startHold(),
              onLongPressEnd: (_) => _cancelHold(),
              onLongPressCancel: _cancelHold,
              // Fixed height + explicit full-width makes the Stack and the
              // button share identical bounds — previously the OutlinedButton
              // was intrinsic-width while the Positioned.fill overlay
              // stretched to the Stack's (Column.stretch) full width, so the
              // red fill visibly spilled past the button's sides on release.
              child: SizedBox(
                height: 52,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    OutlinedButton(
                      // Tap does nothing — the long-press gesture above is
                      // the only arming path. Button exists for visual
                      // affordance + to provide the disabled/working state.
                      onPressed: _working ? null : () {},
                      style: OutlinedButton.styleFrom(
                        foregroundColor: scheme.error,
                        side: BorderSide(color: scheme.error, width: 1.5),
                        // Border radius must match the fill overlay below
                        // so the animated fill clips cleanly against the
                        // button's corners.
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(Radius.circular(8)),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        textStyle: Theme.of(context)
                            .textTheme
                            .labelLarge
                            ?.copyWith(letterSpacing: 1.4),
                      ),
                      child: _working
                          ? const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                ),
                                SizedBox(width: 8),
                                Text('LOGGING…'),
                              ],
                            )
                          : const FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text('HOLD TO PANIC'),
                            ),
                    ),
                    // Fill-progress overlay during hold. Wrapped in a
                    // ClipRRect matching the button's shape so the fill
                    // can't escape the rounded corners.
                    IgnorePointer(
                      child: ClipRRect(
                        borderRadius:
                            const BorderRadius.all(Radius.circular(8)),
                        child: AnimatedBuilder(
                          animation: _hold,
                          builder: (_, __) {
                            if (_hold.value == 0) {
                              return const SizedBox.shrink();
                            }
                            return FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: _hold.value,
                              child: Container(
                                color:
                                    scheme.error.withValues(alpha: 0.18),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _working ? null : _startContinuous,
              icon: const Icon(Icons.timer_outlined, size: 18),
              label: const Text('Start continuous panic'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final AsyncValue<int> count;
  const _SummaryCard({required this.count});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.pin_drop_outlined),
        title: const Text('Total pings logged'),
        trailing: Text(
          count.asData?.value.toString() ?? '…',
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
    );
  }
}

class _ExportRow extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return OutlinedButton.icon(
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => const ExportDialog(),
      ),
      icon: const Icon(Icons.ios_share),
      label: const Text('Export…'),
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

class _PingTile extends ConsumerWidget {
  final Ping ping;
  const _PingTile({required this.ping});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isNoFix = ping.source == PingSource.noFix;
    final hasFix = ping.lat != null && ping.lon != null;
    final approx = hasFix
        ? ref
            .watch(approxLocationProvider((lat: ping.lat!, lon: ping.lon!)))
            .asData
            ?.value
        : null;
    final ts = DateFormat.MMMd().add_Hms().format(ping.timestampUtc.toLocal());
    return ListTile(
      dense: true,
      leading: Icon(
        _iconFor(ping.source),
        color: isNoFix ? Theme.of(context).colorScheme.error : null,
      ),
      title: Text(
        hasFix
            ? '${ping.lat!.toStringAsFixed(4)}, ${ping.lon!.toStringAsFixed(4)}'
            : (ping.note ?? ping.source.dbValue),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (approx != null && approx.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.place_outlined,
                    size: 12,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      approx,
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          Text(ts),
        ],
      ),
      trailing: Text(ping.source.dbValue),
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
