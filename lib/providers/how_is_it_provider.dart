import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/how_is_it_service.dart';

final howIsItServiceProvider =
    Provider<HowIsItService>((_) => HowIsItService());

/// Watches the persisted frequency. Defaults to `off` while the
/// FutureProvider's first read is in flight — matches the install-time
/// default so the Settings tile renders correctly on cold start.
final howIsItFrequencyProvider =
    FutureProvider<HowIsItFrequency>((ref) async {
  return ref.watch(howIsItServiceProvider).getFrequency();
});

/// Back-compat alias — `true` when the current frequency is anything
/// other than `off`. Kept so any consumer still keying off the old
/// boolean view doesn't break across the v1 → v2 migration.
final howIsItEnabledProvider = FutureProvider<bool>((ref) async {
  return (await ref.watch(howIsItFrequencyProvider.future)) !=
      HowIsItFrequency.off;
});
