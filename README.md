<p align="center">
  <img src="android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" width="128" alt="Trail app icon"/>
</p>

# Trail

Personal-safety + curious-data-gathering Android app. Pings GPS at a user-selectable cadence (30 min / 1 h / 2 h / 4 h, default 4 h), logs to an encrypted SQLite DB, renders an offline vector-tile map of every fix, supports on-demand panic ping with SMS hand-off, and exports GPX / CSV (optionally as a passphrase-protected AES-256 zip). Fully offline — no internet dependency at runtime.

[![Latest release](https://img.shields.io/github/v/release/DazedDingo/trail?label=latest&color=4DB6AC)](https://github.com/DazedDingo/trail/releases/latest)
[![Platform](https://img.shields.io/badge/platform-Android-3DDC84?logo=android&logoColor=white)](#install)
[![Built with Flutter](https://img.shields.io/badge/Flutter-3.5+-02569B?logo=flutter&logoColor=white)](https://flutter.dev)

## Install

Head to the [**latest release**](https://github.com/DazedDingo/trail/releases/latest), grab the `.apk` for your phone — `…-arm64-v8a.apk` for any phone from the last ~8 years, `…-armeabi-v7a.apk` for old 32-bit devices, `…-x86_64.apk` only for emulators (since 0.15.0 releases are per-ABI and R8-shrunk, roughly a third the size of the old single file) — and open it on Android. First-time install? You may need to allow your browser to install apps from unknown sources. Upgrades install over the top — your encrypted log, panic contacts, and home location all survive.

See [`CHANGELOG.md`](CHANGELOG.md) for what's new in each build, or any release page for plain-English bullets.

## Features

- **Encrypted GPS log** — SQLCipher database with a Keystore-derived key; optional passphrase mode survives uninstall via Android backup.
- **Configurable cadence + motion-aware skipping** — pick 30 min / 1 h / 2 h / 4 h; opt-in motion-aware mode skips GPS warm-up when the last two fixes are within 50 m of each other.
- **Offline vector-tile map** — Protomaps basemap archives (`pmtiles extract` of the daily planet) layered as one active region + any number of coverage packs + a world overview, all served by an in-app loopback server that overzooms the nearest coarser tile where nothing finer is installed; a catalog with the world overview and the UK, on-demand builds, and (with your own extract server) automatic detail packs for new places.
- **Google Maps Timeline import** — stream a `Timeline.json` export into the encrypted log with preview, thinning presets, duplicate skipping and one-tap undo; imported pins are map-only and never hit the network.
- **Hold-to-panic** — 600 ms long-press opens a pre-filled SMS to your emergency contacts (or fires it after a 5-second undo if Auto-send SMS is on); persistent foreground service handles continuous-panic mode.
- **Stats screen** — calendar heatmap, top places, time-of-day chart, automatic trip detection (>10 km from home for ≥6 h).
- **GPX / CSV export** with optional AES-256 encrypted zip wrapper (open with 7-Zip / Archive Utility / `7z`).

## Stack

- Flutter (Dart ^3.5), Android-only
- Riverpod + go_router
- SQLite + SQLCipher (Keystore-derived passphrase) — see `lib/db/keystore_key.dart`
- WorkManager + AlarmManager (dual-path: battery-saver / precise)
- maplibre_gl 0.26 for the vector-tile renderer
- `geolocator` wrapped behind a testable `GeoClient` seam
- `local_auth` biometric gate (PIN fallback)
- `share_plus` + GPX/CSV exporters + zip4j AES-256 encryption (native via MethodChannel)

## Build & run

```bash
flutter pub get
flutter run                    # dev build on connected device
flutter test                   # full unit-test suite
flutter build apk --release    # signed release APK
```

Push to `main` triggers `.github/workflows/release.yml` → APK uploaded to GitHub Releases with auto-generated human-readable notes.

## Repo layout

See [`CLAUDE.md`](CLAUDE.md) for the full directory map and conventions, and [`docs/PLAN.md`](docs/PLAN.md) for the original phase plan.
