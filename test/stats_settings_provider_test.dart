import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail/providers/stats_settings_provider.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('statsIncludeImportsProvider', () {
    test('default is false on a fresh install', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final value = await container.read(statsIncludeImportsProvider.future);
      expect(value, isFalse);
    });

    test('reads a persisted true value back on build', () async {
      SharedPreferences.setMockInitialValues({
        'trail_stats_include_imports_v1': true,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final value = await container.read(statsIncludeImportsProvider.future);
      expect(value, isTrue);
    });

    test('set() updates state and persists for the next build', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Wait for the initial build before mutating.
      await container.read(statsIncludeImportsProvider.future);

      await container.read(statsIncludeImportsProvider.notifier).set(true);
      expect(
        container.read(statsIncludeImportsProvider).asData?.value,
        isTrue,
      );

      // Verify the write hit shared-prefs by rebuilding in a fresh
      // container against the same in-memory store.
      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      final reloaded = await fresh.read(statsIncludeImportsProvider.future);
      expect(reloaded, isTrue);
    });

    test('set(false) round-trips back to off', () async {
      SharedPreferences.setMockInitialValues({
        'trail_stats_include_imports_v1': true,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(statsIncludeImportsProvider.future);

      await container.read(statsIncludeImportsProvider.notifier).set(false);

      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      expect(await fresh.read(statsIncludeImportsProvider.future), isFalse);
    });
  });
}
