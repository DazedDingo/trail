import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart';
import '../db/ping_dao.dart';
import '../services/stats/places_service.dart';

/// Places the Google Timeline import recorded, most-visited first.
///
/// One DAO read (`PingDao.importedVisits`, imports only — thousands of
/// rows at most) plus the pure `buildPlaces` roll-up. Non-autoDispose so
/// leaving and re-entering the screen doesn't re-read; invalidated by
/// `invalidateAfterImport` (import + undo are the only writes that can
/// change it).
final placesProvider = FutureProvider<List<PlaceSummary>>((ref) async {
  final db = await TrailDatabase.shared();
  return buildPlaces(await PingDao(db).importedVisits());
});

/// Every visit to one place ([PlaceSummary.key]), oldest-first — the
/// detail sheet's list.
///
/// Deliberately a second read rather than a cached row→visit map: the
/// sheet is an explicit tap, the read is the same bounded query, and
/// keeping the raw rows alive for the whole session to save it would
/// cost more memory than it saves work. `autoDispose` so the list dies
/// with the sheet.
final placeVisitsProvider =
    FutureProvider.autoDispose.family<List<Visit>, String>((ref, key) async {
  final db = await TrailDatabase.shared();
  return visitsForPlace(await PingDao(db).importedVisits(), key);
});
