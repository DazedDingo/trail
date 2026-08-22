import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart';
import '../db/import_dao.dart';
import '../db/ping_dao.dart';
import '../services/import/timeline_import_service.dart';
import 'pings_provider.dart';

/// The Google Maps Timeline import service, bound to the shared DB
/// handle (same rule as every other DAO consumer — one SQLCipher
/// connection, see [TrailDatabase.shared]).
///
/// Deliberately NOT `autoDispose`: the import screen holds the service
/// across a long-running commit, and an autoDispose provider would kill
/// the worker isolate the moment a rebuild dropped the last listener.
/// The screen calls `dispose()` itself when it leaves, and the service
/// re-spawns its isolate on the next preview.
final timelineImportServiceProvider =
    FutureProvider<TimelineImportService>((ref) async {
  final db = await TrailDatabase.shared();
  final service = TimelineImportService(
    pingDao: PingDao(db),
    importDao: ImportDao(db),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Past imports, newest first — the Settings "Timeline imports" sheet.
/// Invalidate after a commit or an undo.
final importHistoryProvider = FutureProvider<List<ImportRecord>>((ref) async {
  final db = await TrailDatabase.shared();
  return ImportDao(db).all();
});

/// Refresh every read that an import (or an undo) just invalidated.
///
/// CLAUDE.md gotcha 29: a path that writes `pings` must invalidate the
/// whole `pingsByRangeProvider` family, not just one range. Imported
/// rows are excluded from `recent`/`allPings`/`latestSuccessful` at the
/// DAO layer, but those providers still cache a list that was read
/// before the write, and `historyPingsProvider` (the one list that DOES
/// show imports) has to re-read.
void invalidateAfterImport(WidgetRef ref) {
  ref
    ..invalidate(recentPingsProvider)
    ..invalidate(historyPingsProvider)
    ..invalidate(allPingsProvider)
    ..invalidate(pingsByRangeProvider)
    ..invalidate(lastSuccessfulPingProvider)
    ..invalidate(heartbeatHealthyProvider)
    ..invalidate(pingCountProvider)
    // The import may have added years the map's chip row has never
    // shown (that is the case this feature exists for); an undo may
    // have taken the only fix in one away again.
    ..invalidate(pingYearsProvider)
    ..invalidate(importHistoryProvider);
}
