/// "Set your home location from Google" — the pure rules behind the
/// offer the Timeline import surface makes (docs/TIMELINE_IMPORT.md).
///
/// A Timeline export carries `userLocationProfile.frequentPlaces[]`,
/// parsed into [ImportFrequentPlace] by `timeline_import_service.dart`.
/// One of those entries is usually the address the user typed into
/// Google years ago — exactly what Trail's home-distance header wants,
/// and far more accurate than dropping a pin from memory.
///
/// Nothing here reads SharedPreferences, the database or the network, so
/// the picking + "is it worth offering" rules are unit-testable on their
/// own (`test/google_home_test.dart`). The screen does the saving.
library;

import '../home_location_service.dart';
import 'timeline_models.dart';

/// A Google home closer than this to the home already saved is not worth
/// offering — the user would be tapping a button to move their home by a
/// few metres. 100 m is comfortably inside "same house/street" while
/// still catching a genuinely different address.
const double kGoogleHomeThresholdM = 100;

/// Label stamped on a home taken from an export, so Settings → Home
/// location shows where the coordinate came from.
const String kGoogleHomeLabel = 'Home (from Google)';

/// The frequent place to offer as home, or `null` when the export has
/// none.
///
/// `HOME` (the user told Google) wins over `INFERRED_HOME` (Google
/// guessed) no matter which order the export lists them in; everything
/// else (`WORK`, `INFERRED_WORK`, unknown future labels) is ignored.
/// Labels are compared case-insensitively and trimmed — the mapper
/// passes the export's string through untouched, including its
/// `'UNKNOWN'` fallback.
ImportFrequentPlace? pickGoogleHome(List<ImportFrequentPlace> places) {
  ImportFrequentPlace? inferred;
  for (final place in places) {
    final label = place.label.trim().toUpperCase();
    if (label == 'HOME') return place;
    if (inferred == null && label == 'INFERRED_HOME') inferred = place;
  }
  return inferred;
}

/// Whether [place] is worth offering as the home location: `true` when
/// no home is saved yet, or when the saved one sits more than
/// [thresholdM] away.
///
/// Haversine via [HomeLocation.distanceMetersTo] — the same maths the
/// home-distance header uses, rather than a second copy of it.
bool homeDiffers(
  HomeLocation? current,
  ImportFrequentPlace place, {
  double thresholdM = kGoogleHomeThresholdM,
}) {
  if (current == null) return true;
  return current.distanceMetersTo(place.lat, place.lon) > thresholdM;
}

/// `'51.3821, -2.3601'` — the coordinate as the offer card prints it.
/// Four decimals is ~11 m: precise enough to recognise the address,
/// coarse enough not to look like a surveillance readout.
String formatGoogleHome(ImportFrequentPlace place) =>
    '${place.lat.toStringAsFixed(4)}, ${place.lon.toStringAsFixed(4)}';
