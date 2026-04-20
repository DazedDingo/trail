# Trail — GPS Logger Codebase Guide

**Trail** is a personal-safety + data-gathering Android app. Pings GPS every 4 hours, logs to encrypted SQLite, renders offline map history, supports on-demand panic pings. Fully offline, no internet dependency.

## Tech Stack

- **Flutter:** Dart ^3.5.0
- **State management:** Riverpod (FutureProvider, StateProvider, ConsumerWidget)
- **Routing:** GoRouter with redirect rule (onboarding gate, lock screen)
- **Storage:** SQLite + SQLCipher (encrypted, Keystore-derived key)
- **Location:** geolocator + LocationAccuracy.high (battery-conscious)
- **Background scheduling:** WorkManager (4h periodic cadence)
- **Biometric lock:** local_auth (fingerprint/face fallback to PIN)
- **Native permissions:** permission_handler (staged: fine → background location)
- **Battery/network telemetry:** battery_plus, connectivity_plus
- **Export:** GPX + CSV exporters (share_plus)
- **Android-only** (no iOS variant planned)

## Directory Map: `lib/`

```
lib/
├── main.dart                    # Entry point: WorkManager init, onboarding gate
├── app.dart                     # Router (GoRouter), root ConsumerWidget
├── models/                      # Data classes (Ping, EmergencyContact)
├── db/                          # Database layer
│   ├── database.dart           # TrailDatabase (SQLCipher wrapper, schema v1)
│   ├── ping_dao.dart           # CRUD for pings table
│   ├── contact_dao.dart        # CRUD for emergency_contacts
│   └── keystore_key.dart       # Keystore-backed passphrase
├── providers/                   # Riverpod state
│   ├── pings_provider.dart     # recentPingsProvider, lastSuccessfulPingProvider, heartbeatHealthyProvider, approxLocationProvider
│   ├── onboarding_provider.dart # onboardingCompleteProvider, OnboardingGate (secure storage)
│   └── backup_provider.dart     # backupEnabledProvider, needsUnlockProvider, computeNeedsUnlock()
├── services/                    # Business logic
│   ├── location_service.dart    # Wraps geolocator, enforces 2min timeout, passive cell/Wi-Fi reads
│   ├── permissions_service.dart # Staged permission requests (fine → background location)
│   ├── biometric_service.dart   # BiometricService (local_auth, PIN fallback)
│   ├── battery_network_service.dart # Battery % + network state snapshots
│   ├── cell_wifi_service.dart   # Passive cell tower ID + Wi-Fi SSID capture
│   ├── geo_client.dart          # Geolocator wrapper (testable)
│   ├── geocoding_service.dart   # Reverse geocode wrapper (offline-tolerant)
│   ├── passphrase_service.dart  # PBKDF2 + salt file for the backup-passphrase mode
│   ├── scheduler/
│   │   ├── workmanager_scheduler.dart # WorkManager init, periodic/retry/boot task enqueue
│   │   └── scheduler_policy.dart      # Cadence constants, battery/network constraints
│   └── export/
│       ├── gpx_exporter.dart    # GPX serialization
│       └── csv_exporter.dart    # CSV serialization
├── screens/                     # Screens (all ConsumerWidget)
│   ├── home_screen.dart         # Last ping + heartbeat + trail viz + export + recent history
│   ├── history_screen.dart      # Paginated full history, optional map view (Phase 2)
│   ├── settings_screen.dart     # Diagnostics, permissions, cloud-backup setup, app version
│   ├── lock_screen.dart         # Biometric/PIN unlock gate (pre-home)
│   ├── passphrase_entry_screen.dart # Post-restore backup-passphrase unlock gate
│   └── onboarding/              # First-run flow (permissions, emergency contacts)
│       └── onboarding_flow.dart
├── widgets/
│   └── trail_map.dart           # CustomPaint scatter of recent fixes (tile-free, offline)
├── theme/
│   └── app_theme.dart           # Dark theme only (ThemeMode.dark explicit)
```

## Key Conventions

### State Management (Riverpod)
- **FutureProvider** for async data (ping queries, location fix, exports).
- **StateProvider** for simple flags (onboarding-complete, settings overrides).
- UI-isolate providers share a single DB handle via `TrailDatabase.shared()` — never `close()` it. Four concurrent `open()` calls on the home screen raced SQLCipher key derivation + first-install `onCreate` in 0.1.3 and surfaced as a generic "database exception" (fixed in 0.1.4).
- Invalidation via `ref.invalidate(providerName)` after writes (manual ping, export).

### Screens & Widgets
- All screens extend **ConsumerWidget** for direct `ref.watch()` of providers.
- Navigation via **GoRouter** — no named routes in `go_router.dart`, only path-based.
- Router's `redirect` rule gates onboarding (hard block) + lock screen (UI gate).

### Permissions (Android 11+ aware)
- **Staged request order** (critical — must request fine *before* background):
  1. Fine location (ACCESS_FINE_LOCATION)
  2. Background location (ACCESS_BACKGROUND_LOCATION)
  3. Notifications (POST_NOTIFICATIONS, Phase 2)
  4. Ignore battery optimizations (REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
- Manifest declares all permissions upfront; some granted automatically on < API 33.
- See `PermissionsService.requestFineLocation()` → `requestBackgroundLocation()`.

### GPS Acquisition (Battery-Critical)
- **LocationAccuracy.high** for scheduled pings (never `.best`).
- **2-minute timeout** hardcoded in `LocationService.getScheduledPing()`.
- **No streaming** — `getCurrentPosition()` acquires once, releases GPS client on completion.
- Passive cell/Wi-Fi reads (no active scans) via `CellWifiService`.

### Background Scheduling
- **WorkManager** (Dart + native integration) handles periodic + one-off tasks.
- **Cadence:** 4h periodic ping; 5min retry after no-fix; boot marker on reboot.
- **Callback dispatcher** (`_callbackDispatcher` in `workmanager_scheduler.dart`) runs in isolated Dart VM — no access to UI providers.
- **Isolate model:** background callback opens fresh DB handle, cannot share UI isolate's handle.
- **Constraints:** no battery required, no charging required, device may be idle (no `requiresDeviceIdle: true`).
- See `SchedulerPolicy` for cadence + constraint constants (unit-tested, testable without native plugin).

### Biometric Lock
- **BiometricService** uses `local_auth` with `biometricOnly: false` → falls back to device PIN if no fingerprint/face enrolled.
- Lock screen is **not** a hard gate; users can swipe past (Phase 2 hardens this with panic-mode gating).

### Database Schema (Phase 1, v1)
- **pings table:** timestamp_utc (primary key for queries), lat/lon/accuracy/altitude/heading/speed, battery_pct, network_state, cell_id, wifi_ssid, source (enum: scheduled|panic|boot|no_fix), note.
- **emergency_contacts table:** name, phone_e164 (Phase 2 panic-share).
- **Index:** `idx_pings_ts_utc DESC` for fast recent queries.
- **Encryption:** SQLCipher with a 32-byte key persisted in Keystore-backed secure storage. Two key-source modes:
  - **Keystore mode (default):** 32 bytes of `Random.secure()` entropy generated on first launch, base64url-encoded. Zero user interaction.
  - **Passphrase mode (opt-in via Settings → Enable cloud backup):** key is PBKDF2-SHA256(user passphrase, salt, 210k). Salt is a 16-byte random blob in `trail_salt_v1.bin` alongside the DB; both files are `include`'d in Android's `backup_rules.xml` so Google Drive auto-backup preserves them across uninstall. The derived key is cached in secure storage the same way the random key is, so the background WorkManager isolate never sees the passphrase itself. Setup rekeys the DB in place via `PRAGMA rekey`. Post-restore detection: salt file present + secure storage empty → route to `/unlock`; `KeystoreKey.getOrCreate()` returns `null` rather than silently overwriting.

## Build, Test, Run

### Run (development)
```bash
flutter pub get
flutter run
```

### Test
```bash
flutter test
```
Tests live in `test/`; use `sqflite_common_ffi` for in-memory SQLite DAO tests (no SQLCipher at test time).

### Build APK (release)
```bash
flutter build apk --release
```
GitHub Actions workflow (`.github/workflows/release.yml`) pushes APK to GitHub Releases on push-to-main.

### Signing (pinned debug keystore)

Both local and CI builds sign with the committed `android/app/debug.keystore`
(password `android`, alias `androiddebugkey`, SHA-1 pinned to `EXPECTED_SHA1`
in the release workflow). Do NOT delete the keystore or regenerate it —
every release must share the same cert or users hit
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`. The `.gitignore` wildcard
`*.keystore` is explicitly overridden with `!android/app/debug.keystore`
so the pin survives commits; if that negation ever drops, CI restores
would revert to random-keystore-per-build (the v0.1.5 fix was exactly
that).

### Key Android manifest entries
- **Boot receiver:** enqueues WorkManager task + logs `boot` row on reboot.
- **Permissions declared:** fine/coarse/background location, boot completed, exact alarms, notifications, ignore battery optimizations, nearby Wi-Fi, read phone state, foreground service (Phase 2 only).
- **No backup:** `android:allowBackup="false"` (encrypted DB not intended to sync across devices).

## Commit Conventions

Commits follow conventional pattern:
- **`feat(phase-1):`** new feature
- **`fix(scheduler):`** bug fix with component prefix
- **`test:`** test coverage additions
- **`docs:`** design decisions, PLAN updates
- **`ci:`** GitHub Actions, build config

Example: `feat(scheduler): extract SchedulerPolicy for testable cadence logic`

See `git log --oneline -20` for recent pattern.

## Known Constraints & Gotchas

1. **WorkManager isolate isolation:** background callback runs in separate Dart VM; cannot share DB handles or plugin state with UI isolate. Always open fresh handle in callback.
2. **Permission staging order (Android 11+):** requesting background-location before fine-location silently collapses to denied. Always request fine first.
3. **SQLCipher + tests:** sqflite_sqlcipher does not work in unit test context (platform channel unavailable). Use sqflite_common_ffi for test database. Production uses sqflite_sqlcipher.
4. **Dark mode only:** no light theme variant. All Color tokens assume `ThemeMode.dark` explicitly.
5. **Phase 1 scope:** no map rendering, no panic-share, no notifications, no exact alarms. These land in Phases 2–5. Manifest declares them upfront so manifest validation passes early.
6. **`PassphraseNeededException`:** `TrailDatabase.open()` throws this in passphrase-mode-post-restore installs. The UI startup gate (`computeNeedsUnlock` → `needsUnlockProvider`) detects this at `main()` and routes to `/unlock`. Background workers catch and skip silently — they can't write a marker row when the DB is the thing they can't open. Don't handle this exception ad-hoc in new providers; catch at the screen boundary (or rely on the router gate).
7. **Don't disable `allowBackup` or remove `backup_rules.xml`.** Passphrase-mode users rely on auto-backup for uninstall survivability. If you ever add a new on-disk file that must NOT be backed up, add an `<exclude>` to `backup_rules.xml` + `data_extraction_rules.xml`.

## Related Docs

- **`docs/PLAN.md`:** full design, battery budget, phase breakdown, open questions, confirmed decisions (19 total).
- **`README.md`:** project summary, planned stack.
