# gps-pinger

Personal-safety + curious-data-gathering Android app. Pings GPS every 6 hours, logs locally to an encrypted SQLite DB, renders offline map of history, supports on-demand panic ping. Fully offline — no internet dependency at runtime.

Status: **design phase, not yet implemented**.

See [`docs/PLAN.md`](docs/PLAN.md) for the full implementation plan, phased milestones, architectural risks, and open questions.

## Stack (planned)

- Flutter (Dart ^3.11), Android-only
- Riverpod + go_router (matches other apps in this ecosystem)
- SQLite + SQLCipher (Keystore-derived key) for encrypted local storage
- `flutter_map` + MBTiles for offline raster map tiles
- WorkManager + AlarmManager dual-path scheduling for 6h cadence reliability

## Initial region coverage

UK only at launch. Additional regions installable via the in-app regions screen — ship tiles to phone manually, no runtime download.
