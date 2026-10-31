import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trail/providers/photos_provider.dart';

/// Riverpod 3 filters provider updates through `==`: a rebuild that
/// produces a value equal to the previous one notifies nobody. That makes
/// [photoLibraryRevisionProvider] load-bearing in a way it was not under
/// Riverpod 2, because its entire job is to notify.
///
/// It is the app's ONLY `ref.listen` target (`slideshow_view.dart:223`,
/// which re-reads `SlideshowView._photoCache` — the one photo read that
/// is not itself a provider). It survives the new filtering only because
/// it yields a fresh `Object()` per build, and `Object` has identity
/// equality. "Simplifying" it to an `int`, a `bool`, a counter reset to
/// the same number, or anything with value equality would silently stop
/// the slideshow refreshing after a photo backfill — with no test failing
/// and no error, which is exactly how the original "pictures don't
/// display on pins anymore" report happened.
void main() {
  group('photoLibraryRevisionProvider is a notification token', () {
    test('invalidation yields a value that is NOT == the previous one', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final before = container.read(photoLibraryRevisionProvider);
      container.invalidate(photoLibraryRevisionProvider);
      final after = container.read(photoLibraryRevisionProvider);

      expect(
        after == before,
        isFalse,
        reason: 'Riverpod 3 drops updates where new == old, so a revision '
            'token whose value can repeat would stop notifying listeners',
      );
    });

    test('a listener actually fires on invalidation', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      var fired = 0;
      container.listen(
        photoLibraryRevisionProvider,
        (_, __) => fired++,
        fireImmediately: false,
      );

      container.invalidate(photoLibraryRevisionProvider);
      await container.pump();
      expect(fired, 1);

      container.invalidate(photoLibraryRevisionProvider);
      await container.pump();
      expect(fired, 2, reason: 'every invalidation must reach the listener');
    });
  });
}
