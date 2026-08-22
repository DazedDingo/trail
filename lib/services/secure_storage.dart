import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The one `FlutterSecureStorage` handle for the UI isolate.
///
/// Every Keystore-backed value in the app — the onboarding flag, the
/// panic-mode prefs, the GitHub PAT, and (once `lib/db/keystore_key.dart`
/// adopts it) the SQLCipher key — reads and writes through this single
/// instance, so the `AndroidOptions` live in exactly one place and no
/// call site can drift to a differently-configured store (a mismatch
/// in `encryptedSharedPreferences` would silently read a *different*
/// preferences file and report every key as missing).
///
/// Honest note on cost: with `flutter_secure_storage` 9.2.4 the native
/// side re-runs its EncryptedSharedPreferences setup on every call
/// (`ensureInitialized()`'s early-return is commented out upstream), so
/// sharing the Dart instance does not by itself skip a Keystore unwrap.
/// The startup win in 0.14.1 comes from running the two router-gating
/// reads concurrently and deferring everything else past the first
/// frame (see `main.dart`).
const FlutterSecureStorage secureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);
