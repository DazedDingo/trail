import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

/// The user's self-declared home location.
///
/// Not sensitive enough to warrant the encrypted DB — it's a UX
/// preference (the home screen shows "X km from home" on the last-fix
/// card). Storing it in SharedPreferences also lets the user clear it
/// from Settings without touching the ping history.
class HomeLocation {
  final double lat;
  final double lon;
  final String? label;
  final DateTime savedAtUtc;

  const HomeLocation({
    required this.lat,
    required this.lon,
    required this.savedAtUtc,
    this.label,
  });

  /// Great-circle distance (metres) from this home to (lat, lon).
  /// Haversine — accurate to ~0.5 % which is far more than the user
  /// needs for "am I near home".
  double distanceMetersTo(double otherLat, double otherLon) {
    const earthRadiusM = 6371000.0;
    final dLat = _toRad(otherLat - lat);
    final dLon = _toRad(otherLon - lon);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRad(lat)) *
            math.cos(_toRad(otherLat)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusM * c;
  }

  static double _toRad(double deg) => deg * (math.pi / 180);
}

class HomeLocationService {
  static const _keyLat = 'trail_home_lat_v1';
  static const _keyLon = 'trail_home_lon_v1';
  static const _keyLabel = 'trail_home_label_v1';
  static const _keySavedAt = 'trail_home_saved_at_v1';

  static Future<HomeLocation?> get() async {
    final prefs = await SharedPreferences.getInstance();
    final lat = prefs.getDouble(_keyLat);
    final lon = prefs.getDouble(_keyLon);
    final saved = prefs.getInt(_keySavedAt);
    if (lat == null || lon == null || saved == null) return null;
    return HomeLocation(
      lat: lat,
      lon: lon,
      label: prefs.getString(_keyLabel),
      savedAtUtc: DateTime.fromMillisecondsSinceEpoch(saved, isUtc: true),
    );
  }

  static Future<void> set({
    required double lat,
    required double lon,
    String? label,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyLat, lat);
    await prefs.setDouble(_keyLon, lon);
    if (label == null || label.isEmpty) {
      await prefs.remove(_keyLabel);
    } else {
      await prefs.setString(_keyLabel, label);
    }
    await prefs.setInt(
      _keySavedAt,
      DateTime.now().toUtc().millisecondsSinceEpoch,
    );
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyLat);
    await prefs.remove(_keyLon);
    await prefs.remove(_keyLabel);
    await prefs.remove(_keySavedAt);
  }
}
