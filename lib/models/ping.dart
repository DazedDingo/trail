/// Source of a ping row. Logged so the history/export can disambiguate a
/// normal scheduled fix from a panic burst or a post-boot marker.
enum PingSource {
  scheduled,
  panic,
  boot,
  noFix;

  String get dbValue {
    switch (this) {
      case PingSource.scheduled:
        return 'scheduled';
      case PingSource.panic:
        return 'panic';
      case PingSource.boot:
        return 'boot';
      case PingSource.noFix:
        return 'no_fix';
    }
  }

  static PingSource fromDb(String v) {
    switch (v) {
      case 'panic':
        return PingSource.panic;
      case 'boot':
        return PingSource.boot;
      case 'no_fix':
        return PingSource.noFix;
      case 'scheduled':
      default:
        return PingSource.scheduled;
    }
  }
}

/// Single row logged per fix attempt.
///
/// `lat`/`lon`/`accuracy` are nullable because we still record rows for
/// `no_fix` and `boot` events where we don't yet have a location. Never
/// silently drop — gaps must be visible in the history so staleness alerting
/// is honest.
class Ping {
  final int? id;
  final DateTime timestampUtc;
  final double? lat;
  final double? lon;
  final double? accuracy;
  final double? altitude;
  final double? heading;
  final double? speed;
  final int? batteryPct;
  final String? networkState; // e.g. "wifi", "mobile", "none"
  final String? cellId;
  final String? wifiSsid;
  final PingSource source;
  final String? note;
  /// Free-form quick comment attached to the ping after-the-fact via the
  /// "How is it?" notification reply (schema v2, shipped 0.12.0). Distinct
  /// from [note], which carries system-generated text only (e.g. "no_fix"
  /// reasons). Reads as `null` on every legacy row inserted before v2.
  final String? comment;

  const Ping({
    this.id,
    required this.timestampUtc,
    this.lat,
    this.lon,
    this.accuracy,
    this.altitude,
    this.heading,
    this.speed,
    this.batteryPct,
    this.networkState,
    this.cellId,
    this.wifiSsid,
    required this.source,
    this.note,
    this.comment,
  });

  /// Returns a copy with the named fields overridden. Used by the
  /// `attachComment` path so the comment is preserved across re-reads
  /// without re-querying the DB.
  Ping copyWith({String? comment}) => Ping(
        id: id,
        timestampUtc: timestampUtc,
        lat: lat,
        lon: lon,
        accuracy: accuracy,
        altitude: altitude,
        heading: heading,
        speed: speed,
        batteryPct: batteryPct,
        networkState: networkState,
        cellId: cellId,
        wifiSsid: wifiSsid,
        source: source,
        note: note,
        comment: comment ?? this.comment,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'ts_utc': timestampUtc.toUtc().millisecondsSinceEpoch,
        'lat': lat,
        'lon': lon,
        'accuracy': accuracy,
        'altitude': altitude,
        'heading': heading,
        'speed': speed,
        'battery_pct': batteryPct,
        'network_state': networkState,
        'cell_id': cellId,
        'wifi_ssid': wifiSsid,
        'source': source.dbValue,
        'note': note,
        'comment': comment,
      };

  factory Ping.fromMap(Map<String, Object?> m) => Ping(
        id: m['id'] as int?,
        timestampUtc: DateTime.fromMillisecondsSinceEpoch(
          m['ts_utc'] as int,
          isUtc: true,
        ),
        lat: (m['lat'] as num?)?.toDouble(),
        lon: (m['lon'] as num?)?.toDouble(),
        accuracy: (m['accuracy'] as num?)?.toDouble(),
        altitude: (m['altitude'] as num?)?.toDouble(),
        heading: (m['heading'] as num?)?.toDouble(),
        speed: (m['speed'] as num?)?.toDouble(),
        batteryPct: (m['battery_pct'] as num?)?.toInt(),
        networkState: m['network_state'] as String?,
        cellId: m['cell_id'] as String?,
        wifiSsid: m['wifi_ssid'] as String?,
        source: PingSource.fromDb(m['source'] as String? ?? 'scheduled'),
        note: m['note'] as String?,
        comment: m['comment'] as String?,
      );
}
