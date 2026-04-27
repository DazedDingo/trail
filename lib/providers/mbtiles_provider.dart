import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/mbtiles_service.dart';

/// List of every `.pmtiles` region installed in the app documents dir.
///
/// Invalidate after install/delete to refresh the Regions screen.
final installedRegionsProvider = FutureProvider<List<TilesRegion>>((ref) {
  return TilesService.listInstalled();
});

/// Currently active region, or `null` when the user hasn't chosen one
/// (or the file is missing from disk). When null, the map viewer renders
/// a "install a region" placeholder rather than mounting MapLibreMap —
/// the app is offline-only so there's no online tile fallback.
final activeRegionProvider = FutureProvider<TilesRegion?>((ref) {
  return TilesService.getActive();
});
