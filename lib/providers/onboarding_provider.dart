import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/secure_storage.dart';

/// Whether the user has completed the first-run onboarding flow.
///
/// Stored in secure storage so it survives app upgrades but not reinstall.
/// A `ValueNotifier` wrapped via `StateProvider` so the router can
/// synchronously read it inside `redirect` without async plumbing.
final onboardingCompleteProvider = StateProvider<bool>((ref) => false);

class OnboardingGate {
  static const _key = 'trail_onboarded_v1';

  /// Whether onboarding has been completed on this install.
  ///
  /// A missing key (`null`) is a genuine "no" — that is a first run. A
  /// *thrown* read is not: it means secure storage could not be reached
  /// at all, and reporting that as "not onboarded" would walk a user
  /// with years of history back through the first-run flow. Storage
  /// exceptions therefore propagate, and `runStartupGates` turns them
  /// into `/startup-failed`.
  static Future<bool> isComplete() async {
    final v = await secureStorage.read(key: _key);
    return v == '1';
  }

  static Future<void> markComplete() async {
    try {
      await secureStorage.write(key: _key, value: '1');
    } catch (e) {
      debugPrint('[OnboardingGate] persist failed: $e');
    }
  }
}
