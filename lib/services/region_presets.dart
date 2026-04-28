/// One-tap region builds. Bboxes are the standard published outlines
/// for each UK National Park or Area of Outstanding Natural Beauty,
/// rounded to thousandths so the GitHub Actions workflow validates
/// cleanly. Size estimates are rough — actual `.mbtiles` size depends
/// on OSM density at build time, but they're in the right order of
/// magnitude for picking.
class RegionPreset {
  final String id;
  final String name;
  final String region;
  final String bbox;
  final String area;
  final int defaultZoom;
  final int approxSizeMb;

  const RegionPreset({
    required this.id,
    required this.name,
    required this.region,
    required this.bbox,
    required this.area,
    required this.defaultZoom,
    required this.approxSizeMb,
  });

  String get sizeLabel => '~$approxSizeMb MB at zoom $defaultZoom';
}

const List<RegionPreset> kUkRegionPresets = [
  RegionPreset(
    id: 'lake-district',
    name: 'Lake District',
    region: 'Cumbria · National Park',
    bbox: '-3.535,54.296,-2.758,54.811',
    area: 'great-britain',
    defaultZoom: 14,
    approxSizeMb: 125,
  ),
  RegionPreset(
    id: 'snowdonia',
    name: 'Snowdonia (Eryri)',
    region: 'Wales · National Park',
    bbox: '-4.337,52.715,-3.495,53.231',
    area: 'great-britain',
    defaultZoom: 14,
    approxSizeMb: 112,
  ),
  RegionPreset(
    id: 'peak-district',
    name: 'Peak District',
    region: 'Derbyshire · National Park',
    bbox: '-2.060,53.130,-1.488,53.651',
    area: 'great-britain',
    defaultZoom: 14,
    approxSizeMb: 100,
  ),
  RegionPreset(
    id: 'yorkshire-dales',
    name: 'Yorkshire Dales',
    region: 'North Yorkshire · National Park',
    bbox: '-2.649,54.068,-1.732,54.495',
    area: 'great-britain',
    defaultZoom: 14,
    approxSizeMb: 112,
  ),
  RegionPreset(
    id: 'north-york-moors',
    name: 'North York Moors',
    region: 'North Yorkshire · National Park',
    bbox: '-1.385,54.235,-0.485,54.594',
    area: 'great-britain',
    defaultZoom: 14,
    approxSizeMb: 88,
  ),
  RegionPreset(
    id: 'dartmoor',
    name: 'Dartmoor',
    region: 'Devon · National Park',
    bbox: '-4.131,50.439,-3.713,50.695',
    area: 'great-britain',
    defaultZoom: 14,
    approxSizeMb: 62,
  ),
  RegionPreset(
    id: 'exmoor',
    name: 'Exmoor',
    region: 'Devon/Somerset · National Park',
    bbox: '-3.978,51.071,-3.250,51.288',
    area: 'great-britain',
    defaultZoom: 14,
    approxSizeMb: 62,
  ),
  RegionPreset(
    id: 'brecon-beacons',
    name: 'Brecon Beacons (Bannau Brycheiniog)',
    region: 'Wales · National Park',
    bbox: '-4.026,51.776,-2.890,52.093',
    area: 'great-britain',
    defaultZoom: 14,
    approxSizeMb: 112,
  ),
  RegionPreset(
    id: 'pembrokeshire-coast',
    name: 'Pembrokeshire Coast',
    region: 'Wales · National Park',
    bbox: '-5.354,51.561,-4.554,52.115',
    area: 'great-britain',
    defaultZoom: 14,
    approxSizeMb: 88,
  ),
  RegionPreset(
    id: 'northumberland',
    name: 'Northumberland',
    region: 'North-east · National Park',
    bbox: '-2.557,54.998,-1.985,55.443',
    area: 'great-britain',
    defaultZoom: 14,
    approxSizeMb: 62,
  ),
  RegionPreset(
    id: 'south-downs',
    name: 'South Downs',
    region: 'Sussex/Hampshire · National Park',
    bbox: '-1.346,50.715,0.290,51.121',
    area: 'great-britain',
    defaultZoom: 14,
    approxSizeMb: 150,
  ),
  RegionPreset(
    id: 'new-forest',
    name: 'New Forest',
    region: 'Hampshire · National Park',
    bbox: '-1.821,50.741,-1.379,51.012',
    area: 'great-britain',
    defaultZoom: 14,
    approxSizeMb: 62,
  ),
  RegionPreset(
    id: 'cairngorms',
    name: 'Cairngorms',
    region: 'Scotland · National Park (largest in UK)',
    bbox: '-4.502,56.794,-2.962,57.310',
    area: 'great-britain',
    defaultZoom: 14,
    approxSizeMb: 200,
  ),
  RegionPreset(
    id: 'loch-lomond-trossachs',
    name: 'Loch Lomond & The Trossachs',
    region: 'Scotland · National Park',
    bbox: '-5.013,55.998,-4.149,56.519',
    area: 'great-britain',
    defaultZoom: 14,
    approxSizeMb: 125,
  ),
  RegionPreset(
    id: 'cotswolds',
    name: 'Cotswolds',
    region: 'England · AONB (largest in UK)',
    bbox: '-2.396,51.550,-1.530,52.246',
    area: 'great-britain',
    defaultZoom: 14,
    approxSizeMb: 175,
  ),
];
