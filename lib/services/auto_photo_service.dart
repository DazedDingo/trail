import 'package:shared_preferences/shared_preferences.dart';

/// Persists the user's opt-in/out for the online auto-photo feature.
///
/// **Default is ON** per the product brief — the auto-fetch is the
/// headline UX for the photo-per-pin feature. The Settings tile
/// surfaces a clear privacy explainer (lat/lon leaks to Wikimedia
/// Commons when this is on) so the default isn't a silent leak.
///
/// First-launch users see the default until they toggle it. We persist
/// the flag rather than read the absence as ON because (a) post-toggle
/// "off" must survive an uninstall→restore cycle and (b) a future
/// migration that re-defaults the value can detect existing installs
/// vs fresh by the key's presence alone.
class AutoPhotoService {
  static const _kKey = 'trail_auto_photos_enabled_v1';
  /// True means "default on". Bake the default into the read path so
  /// the value-from-disk is null only on a truly never-touched install.
  static const _kDefault = true;

  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kKey) ?? _kDefault;
  }

  Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kKey, value);
  }

  /// Whether the user has explicitly chosen a value (either on or off),
  /// distinguishing first-launch users (who should see the privacy
  /// explainer once) from settled installs.
  Future<bool> hasExplicitChoice() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_kKey);
  }
}
