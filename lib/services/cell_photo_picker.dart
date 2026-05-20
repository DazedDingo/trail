import 'dart:math' as math;

import '../models/area_photo.dart';

/// Picks [k] photos from [allCellPhotos] for a single ping using a
/// deterministic-but-rotated permutation seeded on [pingId] + [salt].
///
/// **Why a rotation, not a random sample**: the same ping should always
/// resolve to the same photos across app restarts, app reinstalls,
/// re-backfills — otherwise the user's slideshow scrubs through
/// different images on every replay. Determinism is the contract.
///
/// **Why variety across pings**: pings 1, 2, 3, … at the same cell
/// should NOT get the same photos. Otherwise repeat visits to a coffee
/// shop all show the same five images. The rotation indexes into the
/// cell's photo list at `(pingId + salt) % len`, then takes [k] in
/// order — pings at the same place see overlapping-but-shifted slices.
///
/// **The re-shuffle salt** lets a user opt into a fresh shuffle without
/// touching Wikimedia. Bumping the salt by 1 changes everyone's
/// rotation start point, so the slideshow refreshes deterministically
/// — and is still stable across restarts at that new salt.
List<AreaPhoto> pickRotatedPhotos({
  required List<AreaPhoto> allCellPhotos,
  required int pingId,
  required int k,
  int salt = 0,
}) {
  if (allCellPhotos.isEmpty || k <= 0) return const [];
  final n = allCellPhotos.length;
  // Rotation start: spread across the cell's pool by ping id + salt.
  // Use a hashed mix so consecutive pings don't all land within a
  // narrow window of indices (pings logged minutes apart often share
  // a cell and tend to have consecutive ids).
  final mixed = _mix32(pingId, salt);
  final start = mixed.abs() % n;
  final take = math.min(k, n);
  final out = <AreaPhoto>[];
  for (var i = 0; i < take; i++) {
    out.add(allCellPhotos[(start + i) % n]);
  }
  return out;
}

/// Pure 32-bit integer mixer (xorshift-ish). Avoids a `Random()`
/// allocation per call and keeps the output stable across Dart VM
/// versions — `Random(seed)`'s sequence is not part of the language
/// spec, so a future runtime upgrade could shift the rotation index.
int _mix32(int a, int b) {
  var h = (a * 0x27d4eb2d) & 0xffffffff;
  h ^= b * 0x165667b1;
  h ^= (h >> 16);
  h = (h * 0x7feb352d) & 0xffffffff;
  h ^= (h >> 15);
  h = (h * 0x846ca68b) & 0xffffffff;
  h ^= (h >> 16);
  return h.toSigned(32);
}
