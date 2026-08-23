import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/github_pat_service.dart';
import 'package:trail_secure_store/trail_secure_store.dart';

/// Regression coverage for 0.17.10: the Settings screen's GitHub-PAT
/// tile used to `await GithubPatService.clear()` with no try/catch, so a
/// thrown secure-store write died as an unhandled Future and the tile's
/// subtitle silently kept showing the old (now-cleared-in-the-user's-
/// mind, still-present-on-disk) token. `tryClear` is the pure function
/// the tile now calls instead.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(TrailSecureStore.channel, null);
  });

  test('tryClear returns null on a successful delete', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            TrailSecureStore.channel, (call) async => null);
    expect(await GithubPatService.tryClear(), isNull);
  });

  test('tryClear reports a failure instead of throwing', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(TrailSecureStore.channel, (call) async {
      throw PlatformException(
        code: 'KeyStoreException',
        message: 'UNKNOWN_ERROR (-1000)',
      );
    });
    final error = await GithubPatService.tryClear();
    expect(error, isNotNull);
    expect(error, contains('KeyStoreException'));
  });
}
