import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

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
///
/// **Deferred by one microtask, deliberately (Riverpod 3).** `invalidate`
/// now routes through the scheduler, which calls `setState` on the
/// enclosing `UncontrolledProviderScope`. `State.dispose` runs inside
/// `BuildOwner.lockState` (via `finalizeTree`), where marking anything as
/// needing build throws "setState() or markNeedsBuild() called when
/// widget tree was locked" — so the pre-3 code that invalidated straight
/// from `dispose` now blows up on the swipe-away path. A microtask lands
/// after the lock is released. The container outlives the widget, but not
/// necessarily the test or the app, hence the [ProviderContainer.disposed]
/// guard below: invalidating a disposed container throws in Riverpod 3,
/// and `ProviderContainer.disposed` lives on an `@internal` extension, so
/// catching is the only guard available through the public API.
void invalidateAfterPhotoWriteIn(ProviderContainer container) {
  Future.microtask(() {
    try {
      _invalidatePhotoReads(container.invalidate);
    } catch (e) {
      // The container was torn down before the microtask ran — app exit,
      // or a test's tearDown. Nothing is caching photo reads any more, so
      // there is genuinely nothing to refresh; this is not a swallowed bug.
      debugPrint('photo read invalidation skipped (container gone): $e');
    }
  });
}

void _invalidatePhotoReads(void Function(ProviderOrFamily) invalidate) {
  invalidate(pingPhotosProvider);
  invalidate(photoLibraryRevisionProvider);
}
