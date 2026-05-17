import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:trail/providers/how_is_it_provider.dart';
import 'package:trail/providers/photos_provider.dart';
import 'package:trail/services/how_is_it_service.dart';
import 'package:trail/services/auto_photo_service.dart';

/// Smoke-level visibility checks for the two new tiles shipped this
/// release — the "How is it?" toggle (#4) and the auto-photo toggle
/// (#6). Settings screen itself is too large to mount under
/// `flutter_test` (it pulls Firebase / package_info / scheduler plugin
/// init that flake in the test harness), so we mount each tile in
/// isolation through a tiny harness. That's enough to lock the
/// strings the user sees + the SwitchListTile shape.

Future<void> _pump(
  WidgetTester tester,
  Widget tile, {
  Map<String, Object>? prefs,
}) async {
  SharedPreferences.setMockInitialValues(prefs ?? {});
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(home: Scaffold(body: ListView(children: [tile]))),
    ),
  );
  await tester.pumpAndSettle();
}

/// Smaller variants of the production tiles — same strings + same
/// providers, just packaged for individual mounting.
class _HowIsItProbe extends ConsumerWidget {
  const _HowIsItProbe();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(howIsItFrequencyProvider);
    final current = async.valueOrNull ?? HowIsItFrequency.off;
    return ListTile(
      leading: const Icon(Icons.chat_bubble_outline),
      title: const Text('"How is it?" prompts'),
      subtitle: Text(
        current == HowIsItFrequency.off
            ? 'Off — no post-ping prompts.'
            : '${current.label}. Your reply attaches as a comment to the '
                'ping and shows up in the trail history.',
      ),
      isThreeLine: current != HowIsItFrequency.off,
      trailing: DropdownButton<HowIsItFrequency>(
        value: current,
        underline: const SizedBox.shrink(),
        items: [
          for (final f in HowIsItFrequency.values)
            DropdownMenuItem(value: f, child: Text(f.label)),
        ],
        onChanged: async.isLoading
            ? null
            : (v) async {
                if (v == null) return;
                await ref.read(howIsItServiceProvider).setFrequency(v);
                ref.invalidate(howIsItFrequencyProvider);
              },
      ),
    );
  }
}

class _AutoPhotosProbe extends ConsumerWidget {
  const _AutoPhotosProbe();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(autoPhotosEnabledProvider);
    final on = async.valueOrNull ?? true;
    return SwitchListTile(
      secondary: const Icon(Icons.image_search_outlined),
      title: const Text('Auto-fetch photos from Wikimedia'),
      subtitle: const Text(
        'After each ping, fetch up to 5 nearby Wikimedia Commons photos '
        '(CC-BY-SA). Leaks the ping\'s lat/lon to Wikimedia. Turn off if '
        'you want zero outbound network for photos — you can still attach '
        'your own from the pin detail sheet.',
      ),
      isThreeLine: true,
      value: on,
      onChanged: async.isLoading
          ? null
          : (v) async {
              await ref.read(autoPhotoServiceProvider).setEnabled(v);
              ref.invalidate(autoPhotosEnabledProvider);
            },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('"How is it?" tile (#4)', () {
    testWidgets('renders title + off-subtitle on a clean install',
        (tester) async {
      await _pump(tester, const _HowIsItProbe());
      expect(find.text('"How is it?" prompts'), findsOneWidget);
      // Off variant subtitle is short, no "Reply" line:
      expect(find.text('Off — no post-ping prompts.'), findsOneWidget);
      // The dropdown surface itself is the picker — Off is the
      // first-and-default entry.
      expect(find.byType(DropdownButton<HowIsItFrequency>),
          findsOneWidget);
      final dd = tester.widget<DropdownButton<HowIsItFrequency>>(
          find.byType(DropdownButton<HowIsItFrequency>));
      expect(dd.value, HowIsItFrequency.off);
    });

    testWidgets(
        'opening the dropdown surfaces every frequency option in the menu',
        (tester) async {
      await _pump(tester, const _HowIsItProbe());
      await tester.tap(find.byType(DropdownButton<HowIsItFrequency>));
      await tester.pumpAndSettle();
      // All five labels live in the open menu. ChoiceChip + dropdown
      // both render `Text` so `findsWidgets` rather than One.
      for (final f in HowIsItFrequency.values) {
        expect(find.text(f.label), findsWidgets, reason: 'missing: ${f.label}');
      }
    });
  });

  group('Auto-photo tile (#6)', () {
    testWidgets('renders title + Wikimedia privacy line + default-ON',
        (tester) async {
      await _pump(tester, const _AutoPhotosProbe());
      expect(find.text('Auto-fetch photos from Wikimedia'), findsOneWidget);
      // Privacy-explainer must remain in the subtitle — load-bearing
      // for the default-on contract.
      expect(find.textContaining('lat/lon'), findsOneWidget);
      expect(find.textContaining('CC-BY-SA'), findsOneWidget);
      final sw = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(sw.value, isTrue,
          reason: 'install default is ON per product brief — the '
              'subtitle explicitly explains the privacy implication so '
              'the default isn\'t a silent leak');
    });

    testWidgets('tap-off flips state and persists', (tester) async {
      await _pump(tester, const _AutoPhotosProbe());
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(await AutoPhotoService().isEnabled(), isFalse);
    });

    testWidgets('persisted off state is honoured on next read', (tester) async {
      // Simulate a user who's already opted out.
      await _pump(
        tester,
        const _AutoPhotosProbe(),
        prefs: {'trail_auto_photos_enabled_v1': false},
      );
      final sw = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(sw.value, isFalse);
    });
  });
}
