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

/// Bumped whenever a *bulk* photo write lands (backfill, re-shuffle,
/// the per-import "Photos…" fetch). Every rebuild mints a fresh
/// `Object`, so an `invalidate` is always a change for listeners.
///
/// Exists for the one photo read that isn't a provider:
/// `SlideshowView._photoCache` holds `ping.id → photos` for the whole
/// visible window and is only rebuilt when that window changes — which
/// a backfill doesn't do. Widgets that cache photo rows outside Riverpod
/// watch this and re-read.
final photoLibraryRevisionProvider = Provider<Object>((ref) => Object());

/// Refresh every read that a bulk photo write just invalidated.
///
/// `pingPhotosProvider` is a non-autoDispose family: once a pin's sheet
/// has been opened, its (possibly empty) list is cached in the root
/// container for the life of the process. Before 0.17.5 nothing
/// invalidated it after a backfill, so a pin the user had already
/// looked at kept showing "no photos" until the app was restarted —
/// the "pictures don't display on pins anymore" report. Invalidate the
/// WHOLE family, not one id: a backfill touches thousands of pings.
void invalidateAfterPhotoWrite(WidgetRef ref) =>
    _invalidatePhotoReads(ref.invalidate);

/// Same refresh from a teardown path. `State.dispose` runs after the
/// element is defunct, and `WidgetRef` throws once that happens, so the
/// caller captures the container in `initState` and passes it here.
void invalidateAfterPhotoWriteIn(ProviderContainer container) =>
    _invalidatePhotoReads(container.invalidate);

void _invalidatePhotoReads(void Function(ProviderOrFamily) invalidate) {
  invalidate(pingPhotosProvider);
  invalidate(photoLibraryRevisionProvider);
}
