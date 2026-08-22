import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_tile_server.dart';
import '../services/mbtiles_service.dart';
import '../services/tiles/tile_schema.dart';
import 'mbtiles_provider.dart';

/// Runs [LocalTileServer.instance] over the archives
/// [servedArchivesProvider] selects, and exposes everything the map
/// needs to build a style: the bound port, the served paths, their
/// zoom union and which schema's style to draw them with.
/// `null` means "no map" — nothing installed, everything failed to
/// open, or the diagnostic remote-demo sentinel is active.
///
/// MapLibre Native 13.0.x silently fails to render tiles via
/// `mbtiles://` and `pmtiles://file://` on Android even when the file
/// is present and the style parses, so every archive — both formats —
/// goes over the HTTP loopback. MapLibre's standard remote-tile path is
/// in good shape; we proved it with the Protomaps demo URL diagnostic,
/// which is what the sentinel below still exercises.
///
/// The port is deliberately *unstable*: an identical archive list gets
/// the running port back, any change gets a fresh one, which is the
/// only cache invalidation available to us (tiles are served
/// `immutable` and MapLibre keys its cache on the URL). The map panel
/// keys its platform view on the port for the same reason.
///
/// The singleton server is NOT stopped on dispose — it outlives any one
/// widget and is only ever reconfigured by the next `start`/`stop`.
final tileServerProvider = FutureProvider<TileServerState?>((ref) async {
  final served = await ref.watch(servedArchivesProvider.future);
  final server = LocalTileServer.instance;
  // Diagnostic mode: the style points at the public Protomaps demo over
  // the real internet, so there is nothing for the loopback to serve.
  if (served.any((r) => r.path == TilesService.diagnosticRemoteSentinel)) {
    await server.stop();
    return null;
  }
  if (served.isEmpty) {
    await server.stop();
    return null;
  }
  try {
    final port = await server.start(
      served.map((r) => r.path).toList(growable: false),
    );
    final schemas = server.servedSchemas;
    final known = schemas.values
        .where((s) => s != TileSchema.unknown)
        .toSet();
    return TileServerState(
      port: port,
      servedPaths: server.servedPaths,
      minZoom: server.servedMinZoom,
      maxZoom: server.servedMaxZoom,
      schema: pickStyleSchema(served, schemas),
      mixedSchemas: known.length > 1,
    );
  } on StateError catch (e) {
    // Every archive failed to open (corrupt sideload, deleted from
    // under us). One bad file must not throw on the map's build path.
    debugPrint('tileServerProvider: no archive could be opened — $e');
    return null;
  }
});

/// What the loopback is serving right now, as the map panel needs it.
///
/// Immutable, and equal when the *style inputs* are equal: port, path
/// list and schema. The zoom union is derived from the same archives
/// (so it can't differ without one of those differing) and
/// [mixedSchemas] is a UI hint only, so neither joins the identity.
class TileServerState {
  TileServerState({
    required this.port,
    required List<String> servedPaths,
    required this.minZoom,
    required this.maxZoom,
    required this.schema,
    required this.mixedSchemas,
  }) : servedPaths = List<String>.unmodifiable(servedPaths);

  /// Loopback port. Fresh on every archive-set change — the only cache
  /// invalidation available to us, and the map's remount key.
  final int port;

  /// Archive paths actually open, in priority order.
  final List<String> servedPaths;

  /// Lowest / highest zoom over the served archives, or `null` when
  /// undeclared. Rewritten into the style's vector source.
  final int? minZoom;
  final int? maxZoom;

  /// Which bundled style draws these archives (see [pickStyleSchema]).
  final TileSchema schema;

  /// True when archives of more than one known schema are being served
  /// — only [schema] draws fully, so the regions screen says so.
  final bool mixedSchemas;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TileServerState) return false;
    if (other.port != port || other.schema != schema) return false;
    if (other.servedPaths.length != servedPaths.length) return false;
    for (var i = 0; i < servedPaths.length; i++) {
      if (other.servedPaths[i] != servedPaths[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(port, Object.hashAll(servedPaths), schema);
}
