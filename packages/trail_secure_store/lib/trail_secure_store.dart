/// Trail's own Keystore-backed secret store, plus the DB-key escrow that
/// proved the primitive.
///
/// Both live behind one Android `FlutterPlugin`
/// (`com.dazeddingo.trail_secure_store.TrailSecureStorePlugin`) so
/// `GeneratedPluginRegistrant` installs their channels in every
/// `FlutterEngine` the app creates — the UI one and the WorkManager
/// background one alike.
library;

export 'src/key_escrow.dart' show EscrowResult, EscrowStatus, KeyEscrow;
export 'src/platform_error.dart' show describeStoreError;
export 'src/secure_store.dart' show SecureStoreStatus, TrailSecureStore;
