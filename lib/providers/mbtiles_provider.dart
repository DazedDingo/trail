import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/mbtiles_service.dart';

/// List of every tile archive (`.mbtiles` / `.pmtiles`) installed in the
/// app documents dir, each tagged with its [TileRole].
///
/// Invalidate after install/delete/retag to refresh the Regions screen —
/// use [invalidateTileProviders] rather than invalidating by hand.
final installedRegionsProvider = FutureProvider<List<TilesRegion>>((ref) {
  return TilesService.listInstalled();
});

/// Currently active region-role archive, or `null` when the user hasn't
/// chosen one (or the file is missing / has been retagged). Coverage and
/// overview packs are served regardless of this — "active" only picks
/// which *region* joins the stack.
final activeRegionProvider = FutureProvider<TilesRegion?>((ref) {
  return TilesService.getActive();
});

/// The ordered archive list handed to `LocalTileServer.start` — coverage
/// packs first, then the active region, then world overviews. Empty
/// means "nothing to serve": the map viewer renders its empty state
/// rather than mounting MapLibreMap (the app is offline-only, there is
/// no online tile fallback).
final servedArchivesProvider = FutureProvider<List<TilesRegion>>((ref) {
  return TilesService.servedArchives();
});

/// Refreshes everything derived from the tile library after a mutation
/// (install, delete, set/clear active, retag). `tileServerProvider`
/// re-derives on its own because it watches [servedArchivesProvider] —
/// which is also what restarts the loopback server on a new port.
///
/// One helper rather than three call-site invalidations: forgetting
/// [servedArchivesProvider] is the failure mode that leaves the map
/// rendering the previous archive set.
void invalidateTileProviders(WidgetRef ref) {
  ref.invalidate(installedRegionsProvider);
  ref.invalidate(activeRegionProvider);
  ref.invalidate(servedArchivesProvider);
}
