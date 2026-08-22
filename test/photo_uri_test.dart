import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/photo_uri.dart';
import 'package:trail/widgets/slideshow_view.dart';

void main() {
  group('localPathForUri', () {
    test('file:// URI → absolute filesystem path', () {
      expect(
        localPathForUri('file:///data/user/0/dev.trail/cache/a.jpg'),
        '/data/user/0/dev.trail/cache/a.jpg',
      );
    });

    test('round-trips the exact shape PingPhotosGallery writes', () {
      // `_attachAt` stores `'file://$path'` verbatim — no encoding.
      const path = '/data/user/0/dev.trail/cache/image_picker_7f3.jpg';
      expect(localPathForUri('file://$path'), path);
    });

    test('content:// → null (not decodable locally)', () {
      expect(
        localPathForUri('content://media/external/images/media/42'),
        isNull,
      );
    });

    test('http(s) → null (network path, handled by CachedNetworkImage)',
        () {
      expect(localPathForUri('https://upload.wikimedia.org/x.jpg'), isNull);
      expect(localPathForUri('http://example/x.jpg'), isNull);
    });

    test('bare scheme, empty and null → null', () {
      expect(localPathForUri('file://'), isNull);
      expect(localPathForUri(''), isNull);
      expect(localPathForUri(null), isNull);
    });

    test('does not percent-decode (paths are stored raw)', () {
      expect(localPathForUri('file:///a%20b.jpg'), '/a%20b.jpg');
    });
  });

  group('isLocalFileUri', () {
    test('true only for file://', () {
      expect(isLocalFileUri('file:///a.jpg'), isTrue);
      expect(isLocalFileUri('https://a.jpg'), isFalse);
      expect(isLocalFileUri('content://a'), isFalse);
      expect(isLocalFileUri(''), isFalse);
      expect(isLocalFileUri(null), isFalse);
    });
  });

  group('slideshowDecodeWidth', () {
    test('viewport physical width on a typical phone (411 dp @ 2.625)',
        () {
      expect(slideshowDecodeWidth(411.4, 2.625), 1080);
    });

    test('360 dp @ 2.0 → 720 px', () {
      expect(slideshowDecodeWidth(360, 2.0), 720);
    });

    test('capped at 1080 px on 1440p panels', () {
      expect(slideshowDecodeWidth(480, 3.5), 1080);
    });

    test('never below the 320 px Wikimedia thumb width', () {
      expect(slideshowDecodeWidth(0, 3.0), 320);
      expect(slideshowDecodeWidth(100, 2.0), 320);
    });
  });
}
