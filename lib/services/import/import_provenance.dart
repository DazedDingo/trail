/// Human-readable provenance for a `gmaps:…` import note.
///
/// `timeline_mappers.dart` stamps every imported row's [Ping.note] with a
/// machine-readable token (`gmaps:path`, `gmaps:visit:<TYPE>:<placeId>`,
/// `gmaps:activity:<TYPE>:<metres>m`, `gmaps:raw:<SOURCE>`) — the prefix
/// is what "undo last import" and the thinning pass match on, so it must
/// never be prettified at the source. This is the read side: one pure
/// function that turns those tokens into the line the pin detail sheet
/// shows under the timestamp.
///
/// Pure + top-level so it is unit-testable without a widget tree
/// (CLAUDE.md gotcha 18) — see `test/import_provenance_test.dart`.
library;

/// Prefix shared by every description — the pin sheet's own "why is this
/// row here" answer.
const String kImportProvenancePrefix = 'Imported from Google Timeline';

/// Note prefix written by `timeline_mappers.dart` (gotcha 35).
const String _kNotePrefix = 'gmaps:';

/// Describes a `gmaps:…` note, or `null` when [note] is null, empty or
/// not an import note at all (a user comment, a legacy marker) — the
/// caller renders nothing in that case rather than a bare prefix.
///
/// A `gmaps:`-prefixed note whose shape we don't recognise (a future
/// export kind, a truncated token) still returns the bare prefix: the
/// row IS an import, and saying so beats saying nothing.
String? describeImportNote(String? note) {
  if (note == null || !note.startsWith(_kNotePrefix)) return null;
  final parts = note.split(':');
  // parts[0] == 'gmaps'. Tokens are sanitised at write time to
  // [A-Za-z0-9_-] (`sanitizeNoteToken`), so a colon can only ever be a
  // real field separator.
  final kind = parts.length > 1 ? parts[1] : '';
  switch (kind) {
    case 'path':
      return '$kImportProvenancePrefix · path';
    case 'visit':
      return _withDetail('visit', [
        _visitTypeLabel(parts.length > 2 ? parts[2] : ''),
        // placeId (parts[3]) is deliberately omitted — an opaque
        // `ChIJ…` string is noise in a detail sheet.
      ]);
    case 'activity':
      return _withDetail('activity', [
        _humanToken(parts.length > 2 ? parts[2] : ''),
        _distanceLabel(parts.length > 3 ? parts[3] : ''),
      ]);
    case 'raw':
      final source = _rawSourceLabel(parts.length > 2 ? parts[2] : '');
      return source == null
          ? '$kImportProvenancePrefix · raw'
          : '$kImportProvenancePrefix · raw $source';
    default:
      return kImportProvenancePrefix;
  }
}

/// `<prefix> · <kind> · <detail, detail>`, dropping the detail clause
/// entirely when nothing survived parsing.
String _withDetail(String kind, List<String?> details) {
  final kept = details.whereType<String>().toList(growable: false);
  if (kept.isEmpty) return '$kImportProvenancePrefix · $kind';
  return '$kImportProvenancePrefix · $kind · ${kept.join(', ')}';
}

/// Timeline's `semanticType` enum. HOME/WORK read better than the
/// enum spelling, and the INFERRED_* variants are worth surfacing —
/// Google guessed those, so a pin sitting on "home" may not be.
String? _visitTypeLabel(String token) {
  switch (token.toUpperCase()) {
    case 'HOME':
      return 'Home';
    case 'WORK':
      return 'Work';
    case 'INFERRED_HOME':
      return 'Home (inferred)';
    case 'INFERRED_WORK':
      return 'Work (inferred)';
  }
  return _humanToken(token);
}

/// `rawSignals` position source. GPS keeps its capitals, Wi-Fi its
/// hyphen; anything else falls through lowercased so an unseen future
/// source still reads as a sentence.
String? _rawSourceLabel(String token) {
  switch (token.toUpperCase()) {
    case 'GPS':
      return 'GPS';
    case 'WIFI':
      return 'Wi-Fi';
    case 'CELL':
      return 'cell';
  }
  final cleaned = _cleanToken(token);
  return cleaned?.toLowerCase();
}

/// `IN_PASSENGER_VEHICLE` → `In passenger vehicle`. Null for an empty or
/// placeholder (`-`) token.
String? _humanToken(String token) {
  final cleaned = _cleanToken(token);
  if (cleaned == null) return null;
  final lower = cleaned.toLowerCase();
  return lower[0].toUpperCase() + lower.substring(1);
}

String? _cleanToken(String token) {
  final cleaned = token.replaceAll('_', ' ').trim();
  if (cleaned.isEmpty || cleaned == '-') return null;
  return cleaned;
}

/// `1200m` → `1.2 km`, `850m` → `850 m`, `-m` (mapper's "no distance"
/// placeholder) → null.
String? _distanceLabel(String token) {
  if (token.length < 2 || !token.endsWith('m')) return null;
  final metres = int.tryParse(token.substring(0, token.length - 1));
  if (metres == null || metres < 0) return null;
  if (metres < 1000) return '$metres m';
  return '${(metres / 1000).toStringAsFixed(1)} km';
}
