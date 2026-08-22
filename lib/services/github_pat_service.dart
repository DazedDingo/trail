import 'secure_storage.dart';

/// Stores the GitHub Personal Access Token used to fire
/// `workflow_dispatch` against `DazedDingo/trail`'s
/// `build-region.yml`. Token sits in the same Keystore-backed secure
/// storage as the SQLCipher key, so an APK uninstall wipes it. Scope
/// `public_repo` is enough — the workflow lives in a public repo.
class GithubPatService {
  static const _key = 'trail_github_pat_v1';

  static Future<String?> read() => secureStorage.read(key: _key);

  static Future<void> write(String pat) =>
      secureStorage.write(key: _key, value: pat.trim());

  static Future<void> clear() => secureStorage.delete(key: _key);

  /// Returns "ghp_…last4" so the settings tile can show the user that
  /// a token is configured without revealing its value.
  static String mask(String pat) {
    if (pat.length < 8) return '****';
    return '${pat.substring(0, 4)}…${pat.substring(pat.length - 4)}';
  }
}
