import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_tile_server.dart';
import '../services/mbtiles_service.dart';
import 'mbtiles_provider.dart';

/// Runs [LocalTileServer.instance] over the archives
/// [servedArchivesProvider] selects, and exposes the bound port.
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
final tileServerProvider = FutureProvider<int?>((ref) async {
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
    return await server.start(
      served.map((r) => r.path).toList(growable: false),
    );
  } on StateError catch (e) {
    // Every archive failed to open (corrupt sideload, deleted from
    // under us). One bad file must not throw on the map's build path.
    debugPrint('tileServerProvider: no archive could be opened — $e');
    return null;
  }
});
