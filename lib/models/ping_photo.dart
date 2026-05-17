/// Provenance of a photo attached to a ping. Persisted as a TEXT column,
/// so the strings here are part of the on-disk contract — don't rename.
enum PingPhotoSource {
  /// Auto-fetched from Wikimedia Commons GeoSearch by lat/lon.
  wikimedia,

  /// User took a photo through Trail's "Add your photo" → Camera flow.
  userCamera,

  /// User picked an existing image from the device gallery.
  userGallery;

  String get dbValue {
    switch (this) {
      case PingPhotoSource.wikimedia:
        return 'wikimedia';
      case PingPhotoSource.userCamera:
        return 'user_camera';
      case PingPhotoSource.userGallery:
        return 'user_gallery';
    }
  }

  bool get isUserSupplied =>
      this == PingPhotoSource.userCamera ||
      this == PingPhotoSource.userGallery;

  static PingPhotoSource fromDb(String v) {
    switch (v) {
      case 'user_camera':
        return PingPhotoSource.userCamera;
      case 'user_gallery':
        return PingPhotoSource.userGallery;
      case 'wikimedia':
      default:
        return PingPhotoSource.wikimedia;
    }
  }
}

/// One photo attached to a [Ping] (schema v2, table `ping_photos`).
///
/// `uri` is the resolvable URL — `https://...` for online sources, a
/// `file://...` or content-URI for user-captured/picked photos.
/// `attribution` + `license` are required for online sources (Wikimedia
/// Commons license terms); user photos store empty strings.
class PingPhoto {
  final int? id;
  final int pingId;
  final String uri;
  final PingPhotoSource source;
  final String attribution;
  final String license;
  final String? thumbUri;
  final DateTime fetchedAt;
  final int ordinal;

  const PingPhoto({
    this.id,
    required this.pingId,
    required this.uri,
    required this.source,
    this.attribution = '',
    this.license = '',
    this.thumbUri,
    required this.fetchedAt,
    required this.ordinal,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'ping_id': pingId,
        'uri': uri,
        'source': source.dbValue,
        'attribution': attribution,
        'license': license,
        'thumb_uri': thumbUri,
        'fetched_at': fetchedAt.toUtc().millisecondsSinceEpoch,
        'ordinal': ordinal,
      };

  factory PingPhoto.fromMap(Map<String, Object?> m) => PingPhoto(
        id: m['id'] as int?,
        pingId: (m['ping_id'] as num).toInt(),
        uri: m['uri'] as String? ?? '',
        source: PingPhotoSource.fromDb(m['source'] as String? ?? 'wikimedia'),
        attribution: m['attribution'] as String? ?? '',
        license: m['license'] as String? ?? '',
        thumbUri: m['thumb_uri'] as String?,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(
          (m['fetched_at'] as num?)?.toInt() ?? 0,
          isUtc: true,
        ),
        ordinal: (m['ordinal'] as num?)?.toInt() ?? 0,
      );
}
