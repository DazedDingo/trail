import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/how_is_it_service.dart';

final howIsItServiceProvider =
    Provider<HowIsItService>((_) => HowIsItService());

/// Watches the persisted toggle. `false` while the FutureProvider's
/// first read is in flight — that matches the install-time default
/// (off) so the Settings tile renders correctly on cold start without
/// a loading shimmer.
final howIsItEnabledProvider = FutureProvider<bool>((ref) async {
  return ref.watch(howIsItServiceProvider).isEnabled();
});
