/// One online-photo row in the per-cell cache (schema v3,
/// `area_photos` table). A "cell" is a (lat, lon) pair quantized to
/// the precision returned by [quantizeCellLat]/[quantizeCellLon] —
/// ~110 m at the equator, ~80 m at 45° latitude.
///
/// The cache survives across pings + across sessions, so any ping
/// inside an already-known cell can attach photos without re-hitting
/// Wikimedia.
class AreaPhoto {
  final int? id;
  final double cellLat;
  final double cellLon;
  final String uri;
  final String? thumbUri;
  final String attribution;
  final String license;
  final DateTime discoveredAt;

  const AreaPhoto({
    this.id,
    required this.cellLat,
    required this.cellLon,
    required this.uri,
    this.thumbUri,
    this.attribution = '',
    this.license = '',
    required this.discoveredAt,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'cell_lat': cellLat,
        'cell_lon': cellLon,
        'uri': uri,
        'thumb_uri': thumbUri,
        'attribution': attribution,
        'license': license,
        'discovered_at': discoveredAt.toUtc().millisecondsSinceEpoch,
      };

  factory AreaPhoto.fromMap(Map<String, Object?> m) => AreaPhoto(
        id: m['id'] as int?,
        cellLat: (m['cell_lat'] as num).toDouble(),
        cellLon: (m['cell_lon'] as num).toDouble(),
        uri: m['uri'] as String? ?? '',
        thumbUri: m['thumb_uri'] as String?,
        attribution: m['attribution'] as String? ?? '',
        license: m['license'] as String? ?? '',
        discoveredAt: DateTime.fromMillisecondsSinceEpoch(
          (m['discovered_at'] as num?)?.toInt() ?? 0,
          isUtc: true,
        ),
      );
}

/// Cell quantization precision in decimal places. 3 ≈ 111 m at the
/// equator, narrower toward the poles. Public constant so the test
/// suite can assert against it without hard-coding the literal.
const int kCellDecimals = 3;

/// Pure: quantizes [lat] to the cell grid. Always returns a finite
/// double — `NaN`/`Infinity` collapse to `0.0` (defensive against a
/// degenerate fix sneaking through the dispatcher).
double quantizeCellLat(double lat) {
  if (lat.isNaN || lat.isInfinite) return 0.0;
  final factor = _pow10(kCellDecimals);
  return (lat * factor).roundToDouble() / factor;
}

double quantizeCellLon(double lon) {
  if (lon.isNaN || lon.isInfinite) return 0.0;
  final factor = _pow10(kCellDecimals);
  return (lon * factor).roundToDouble() / factor;
}

double _pow10(int n) {
  var x = 1.0;
  for (var i = 0; i < n; i++) {
    x *= 10;
  }
  return x;
}
