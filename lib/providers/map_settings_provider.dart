import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _liveLocationKey = 'trail_map_show_live_loc_v1';

/// User toggle for maplibre_gl's native blue-dot live-location
/// indicator on the full-screen map. Some users find the dot
/// disproportionately large on phones with high-DPI screens — it
/// dominates the trail at zoom 14+. Off by user preference, on by
/// default (matches every shipped build before this toggle existed,
/// so existing installs get unchanged behaviour).
///
/// The mini-map on the home screen ignores this entirely — it has
/// had `myLocationEnabled: false` since 0.9.1+58 because the native
/// dot caused a white-render regression at the platform-view's small
/// size.
final liveLocationDotEnabledProvider =
    AsyncNotifierProvider<LiveLocationDotNotifier, bool>(
  LiveLocationDotNotifier.new,
);

class LiveLocationDotNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Absent key → default true so installs that predate the toggle
      // keep the behaviour they had.
      return prefs.getBool(_liveLocationKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> set(bool enabled) async {
    state = AsyncData(enabled);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_liveLocationKey, enabled);
    } catch (_) {
      // In-memory state is still correct; the user can retry the
      // toggle from Settings if persistence failed transiently. No
      // need to surface this to the UI.
    }
  }
}
