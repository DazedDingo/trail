import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/scheduler/scheduler_mode.dart';
import '../services/scheduler/scheduler_policy.dart';

/// Current scheduling mode (WorkManager vs exact alarms).
final schedulerModeProvider = FutureProvider<SchedulerMode>((ref) {
  return SchedulerModeStore.get();
});

/// API 31+ exact-alarm permission state — `true` on API < 31 because
/// the permission didn't exist there (manifest grant covers it).
final exactAlarmPermissionProvider = FutureProvider<bool>((ref) {
  return ExactAlarmBridge.canScheduleExactAlarms();
});

/// Last 20 scheduler events, newest-first. Invalidated after every
/// mode switch and every UI-triggered ping so the Settings screen
/// always shows the freshest timeline.
final schedulerEventsProvider = FutureProvider<List<SchedulerEvent>>((ref) {
  return ExactAlarmBridge.recentEvents();
});

/// User-chosen base cadence for scheduled pings. Default [PingCadence.hour4]
/// preserves pre-0.7.0 behaviour; the picker in Settings offers 30min,
/// 1h, 2h, and 4h. Re-enqueue / re-schedule on change lives at the
/// Settings tile (see `_CadenceTile` in `settings_screen.dart`) because
/// the appropriate side-effect depends on the active [SchedulerMode].
final pingCadenceProvider =
    AsyncNotifierProvider<PingCadenceNotifier, PingCadence>(
  PingCadenceNotifier.new,
);

class PingCadenceNotifier extends AsyncNotifier<PingCadence> {
  @override
  Future<PingCadence> build() => CadenceStore.get();

  Future<void> set(PingCadence c) async {
    state = AsyncData(c);
    await CadenceStore.set(c);
  }
}
