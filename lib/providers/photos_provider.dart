import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart';
import '../db/ping_photo_dao.dart';
import '../models/ping_photo.dart';
import '../services/auto_photo_service.dart';
import '../services/online_photo_service.dart';

final autoPhotoServiceProvider =
    Provider<AutoPhotoService>((_) => AutoPhotoService());

final autoPhotosEnabledProvider = FutureProvider<bool>((ref) async {
  return ref.watch(autoPhotoServiceProvider).isEnabled();
});

final onlinePhotoServiceProvider =
    Provider<OnlinePhotoService>((_) => OnlinePhotoService());

/// Photos attached to a specific ping, ordered for display. Empty
/// list while pending auto-fetch or when the user opted out and never
/// attached anything.
final pingPhotosProvider =
    FutureProvider.family<List<PingPhoto>, int>((ref, pingId) async {
  final db = await TrailDatabase.shared();
  return PingPhotoDao(db).byPingId(pingId);
});
