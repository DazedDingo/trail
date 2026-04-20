import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/home_location_service.dart';

/// Loads the saved home location from SharedPreferences. `null` when
/// the user hasn't set one. Invalidate after `HomeLocationService.set`
/// / `.clear` so the UI picks up the change without a restart.
final homeLocationProvider = FutureProvider<HomeLocation?>((ref) async {
  return HomeLocationService.get();
});
