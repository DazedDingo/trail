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

  static Future<bool> isComplete() async {
    try {
      final v = await secureStorage.read(key: _key);
      return v == '1';
    } catch (_) {
      return false;
    }
  }

  static Future<void> markComplete() async {
    try {
      await secureStorage.write(key: _key, value: '1');
    } catch (e) {
      debugPrint('[OnboardingGate] persist failed: $e');
    }
  }
}
