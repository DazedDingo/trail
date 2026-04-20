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
import '../widgets/trail_map.dart';
import 'export_dialog.dart';

/// The app's primary screen.
///
/// Layout (top → bottom):
/// 1. "Last successful ping" card — timestamp + coords, red stripe if > 5h.
/// 2. Heartbeat / total pings summary.
/// 3. Export actions (GPX + CSV) feeding into share_plus.
/// 4. History list (recent 200 — longer history lives on /history).
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

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
          IconButton(
            tooltip: 'Refresh',
            onPressed: () {
              ref.invalidate(lastSuccessfulPingProvider);
              ref.invalidate(heartbeatHealthyProvider);
              ref.invalidate(pingCountProvider);
              ref.invalidate(recentPingsProvider);
            },
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(lastSuccessfulPingProvider);
          ref.invalidate(heartbeatHealthyProvider);
          ref.invalidate(pingCountProvider);
          ref.invalidate(recentPingsProvider);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _LastPingCard(last: last, healthy: healthy),
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
                  'Trail',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                TextButton.icon(
                  onPressed: () => context.push('/map'),
                  icon: const Icon(Icons.open_in_full, size: 16),
                  label: const Text('Full map'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            recent.when(
              data: (pings) => TrailMap(
                pings: pings,
                activeRegion: activeRegion.valueOrNull,
              ),
              loading: () => const SizedBox(
                height: 180,
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => const SizedBox.shrink(),
            ),
            const SizedBox(height: 20),
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
            recent.when(
              data: (pings) => Column(
                children: pings.take(20).map((p) => _PingTile(ping: p)).toList(),
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, st) => _DbErrorCard(error: e, stack: st),
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

  /// Auto-send path: show a 5-second undo SnackBar. If the user taps
  /// Undo, cancel the pending send. If the SnackBar times out or is
  /// dismissed any other way, fire the native SMS. Falls back to the
  /// compose-intent path if the native send returns 0.
  Future<void> _shareWithUndoGrace({
    required List<EmergencyContact> contacts,
    required Ping ping,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
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
          onPressed: () {/* closed reason = action */},
        ),
      ),
    );
    final reason = await controller.closed;
    if (!mounted) return;
    if (reason == SnackBarClosedReason.action) {
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
              child: Stack(
                alignment: Alignment.center,
                children: [
                  OutlinedButton.icon(
                    // Tap does nothing — the long-press gesture above is
                    // the only arming path. Button exists for visual
                    // affordance + to provide the disabled/working state.
                    onPressed: _working ? null : () {},
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.error,
                      side: BorderSide(color: scheme.error, width: 1.5),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    icon: _working
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.warning_amber_rounded),
                    label: Text(_working ? 'Logging…' : 'Hold to panic'),
                  ),
                  // Fill-progress overlay during hold. AnimatedBuilder on
                  // the controller's value so the fraction tracks the
                  // hold duration; ignored when idle.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedBuilder(
                        animation: _hold,
                        builder: (_, __) {
                          if (_hold.value == 0) return const SizedBox.shrink();
                          return FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: _hold.value,
                            child: Container(
                              decoration: BoxDecoration(
                                color:
                                    scheme.error.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
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

class _PingTile extends StatelessWidget {
  final Ping ping;
  const _PingTile({required this.ping});

  @override
  Widget build(BuildContext context) {
    final isNoFix = ping.source == PingSource.noFix;
    return ListTile(
      dense: true,
      leading: Icon(
        _iconFor(ping.source),
        color: isNoFix ? Theme.of(context).colorScheme.error : null,
      ),
      title: Text(
        ping.lat != null && ping.lon != null
            ? '${ping.lat!.toStringAsFixed(4)}, ${ping.lon!.toStringAsFixed(4)}'
            : (ping.note ?? ping.source.dbValue),
      ),
      subtitle: Text(
        DateFormat.MMMd().add_Hms().format(ping.timestampUtc.toLocal()),
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
