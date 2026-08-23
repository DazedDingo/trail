import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/startup_gates.dart';

/// Non-null when `runStartupGates` (or the `runZonedGuarded` /
/// `FlutterError.onError` pair around `main`) could not get Trail as far
/// as its first real screen.
///
/// Read synchronously by `startupRedirect`, exactly like the other
/// startup flags, and hard-gates every route on `/startup-failed`. The
/// failure screen's "Try again" clears it after a successful re-probe.
final startupFailureProvider = StateProvider<StartupFailure?>((ref) => null);

/// Seam for the failure screen's "Try again" button, mirroring
/// `startupKeyStateProbeProvider` in `backup_provider.dart`. Overridden
/// in widget tests so both outcomes can be driven without a Keystore.
final startupGatesProbeProvider =
    Provider<Future<StartupOutcome> Function()>((ref) {
  return runStartupGates;
});
