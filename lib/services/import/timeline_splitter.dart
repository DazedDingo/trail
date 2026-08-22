/// Byte-level splitter for Google Maps Timeline exports.
///
/// `jsonDecode` on a 200 MB `Timeline.json` builds a ~500 MB object tree
/// and gets LMK-killed on mid-range phones (docs/TIMELINE_IMPORT.md
/// "Parsing"), so the import reads the file as bytes and hands the
/// consumer one *element* at a time — a single `semanticSegments[i]` /
/// `rawSignals[i]` object, or the whole `userLocationProfile` — which is
/// small enough to `jsonDecode` on its own.
///
/// The scanner never decodes text: it tracks strings, escapes and
/// container depth over raw bytes, so it is immune to invalid UTF-8
/// inside strings (real exports contain some), to CRLF and to
/// pretty-printing, and it is chunk-boundary agnostic — feeding it
/// one byte at a time yields byte-identical elements.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Section name used for every element of the iOS bare-array dialect.
const String kTimelineRootSection = 'root';

/// One JSON element lifted out of a Timeline export.
class TimelineElement {
  const TimelineElement({
    required this.section,
    required this.bytes,
    required this.endOffset,
  });

  /// The depth-1 key the element came from (`semanticSegments`,
  /// `rawSignals`, `userLocationProfile`, …), or [kTimelineRootSection]
  /// when the document's root is an array. Consumers filter on this.
  final String section;

  /// The element's raw JSON bytes — feed to [decodeElement].
  final Uint8List bytes;

  /// Absolute offset of the first byte *after* this element in the
  /// stream. Monotonically increasing; drives the progress bar.
  final int endOffset;

  @override
  String toString() =>
      'TimelineElement($section, ${bytes.length}B, @$endOffset)';
}

/// Decodes one [TimelineElement]. Invalid UTF-8 becomes U+FFFD rather
/// than throwing; malformed *JSON* still throws [FormatException], so
/// callers wrap this per element and count failures.
dynamic decodeElement(TimelineElement element) =>
    jsonDecode(utf8.decode(element.bytes, allowMalformed: true));

/// Splits a Timeline export into elements.
///
/// Root object: every depth-1 key whose value is an array yields one
/// element per array entry (section = the key); a depth-1 key whose
/// value is an object yields that object as a single element; depth-1
/// scalars are ignored. Root array (iOS): every entry is yielded with
/// section [kTimelineRootSection].
///
/// Memory is bounded by one input chunk plus the current element; a
/// truncated final element is dropped rather than emitted half-parsed.
Stream<TimelineElement> splitTimelineJson(Stream<List<int>> bytes) async* {
  final splitter = _Splitter();
  await for (final chunk in bytes) {
    splitter.beginChunk(chunk);
    for (var e = splitter.next(); e != null; e = splitter.next()) {
      yield e;
    }
  }
}

/// [splitTimelineJson] over a file on disk.
Stream<TimelineElement> splitTimelineFile(String path) =>
    splitTimelineJson(File(path).openRead());

const int _kTab = 0x09;
const int _kLf = 0x0A;
const int _kCr = 0x0D;
const int _kSpace = 0x20;
const int _kQuote = 0x22;
const int _kComma = 0x2C;
const int _kColon = 0x3A;
const int _kBackslash = 0x5C;
const int _kOpenBracket = 0x5B;
const int _kCloseBracket = 0x5D;
const int _kOpenBrace = 0x7B;
const int _kCloseBrace = 0x7D;

/// Far beyond any real key; only there so a pathological depth-1 string
/// value cannot grow the key buffer without bound.
const int _kMaxKeyBytes = 4096;

bool _isWs(int b) => b == _kSpace || b == _kLf || b == _kCr || b == _kTab;

/// Resumable state machine. [next] runs until it can return an element
/// or the current chunk is exhausted, so the caller can yield each
/// element immediately instead of buffering a chunk's worth.
class _Splitter {
  Uint8List _c = Uint8List(0);
  int _i = 0;
  int _consumedBefore = 0;

  int _depth = 0;
  bool _inString = false;
  bool _escape = false;

  bool _rootSeen = false;
  bool _rootIsObject = false;

  // Key capture: the last string completed at depth 1 becomes the
  // section name when a ':' follows it at depth 1.
  bool _keyCapture = false;
  final BytesBuilder _keyBuf = BytesBuilder();
  String? _lastString;
  String? _pendingKey;

  String? _section;
  int _elementLevel = -1; // depth at which elements sit; -1 = none
  bool _multi = false; // container holds many elements (an array)

  bool _capturing = false;
  bool _captureContainer = false;
  int _captureLevel = 0;
  int _sliceStart = 0;
  final BytesBuilder _elemBuf = BytesBuilder();

  void beginChunk(List<int> chunk) {
    _consumedBefore += _c.length;
    _c = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    _i = 0;
    _sliceStart = 0;
  }

  TimelineElement? next() {
    final c = _c;
    while (_i < c.length) {
      final b = c[_i];

      if (_inString) {
        if (_escape) {
          _escape = false;
        } else if (b == _kBackslash) {
          _escape = true;
        } else if (b == _kQuote) {
          _inString = false;
          if (_keyCapture) {
            _keyCapture = false;
            _lastString =
                utf8.decode(_keyBuf.takeBytes(), allowMalformed: true);
          }
        } else if (_keyCapture && _keyBuf.length < _kMaxKeyBytes) {
          _keyBuf.addByte(b);
        }
        _i++;
        continue;
      }

      if (_isWs(b)) {
        _i++;
        continue;
      }

      if (!_rootSeen) {
        if (b == _kOpenBrace) {
          _rootSeen = true;
          _rootIsObject = true;
          _depth = 1;
        } else if (b == _kOpenBracket) {
          _rootSeen = true;
          _rootIsObject = false;
          _depth = 1;
          _elementLevel = 1;
          _multi = true;
          _section = kTimelineRootSection;
        }
        _i++;
        continue;
      }

      // A scalar element ends at the next delimiter at its own level.
      if (_capturing &&
          !_captureContainer &&
          _depth == _captureLevel &&
          (b == _kComma || b == _kCloseBracket || b == _kCloseBrace)) {
        return _emit();
      }

      // First byte of a depth-1 value in a root object decides what the
      // key's section is worth: array -> stream its entries, object ->
      // yield it whole, scalar -> ignore.
      if (!_capturing && _pendingKey != null) {
        final key = _pendingKey!;
        _pendingKey = null;
        if (b == _kOpenBracket) {
          _section = key;
          _multi = true;
          _depth++;
          _elementLevel = _depth;
          _i++;
          continue;
        }
        if (b == _kOpenBrace) {
          _section = key;
          _multi = false;
          _elementLevel = _depth;
          _startCapture(container: true);
          _depth++;
          _i++;
          continue;
        }
        // Scalar: fall through to the generic handling below.
      }

      if (!_capturing && _elementLevel >= 0 && _depth == _elementLevel) {
        if (b == _kComma) {
          _i++;
          continue;
        }
        if (b == _kCloseBracket || b == _kCloseBrace) {
          if (_depth > 0) _depth--;
          _elementLevel = -1;
          _section = null;
          _multi = false;
          _i++;
          continue;
        }
        _startCapture(container: b == _kOpenBrace || b == _kOpenBracket);
        // Falls through so the byte still moves the depth / string state.
      }

      if (b == _kOpenBrace || b == _kOpenBracket) {
        _depth++;
      } else if (b == _kCloseBrace || b == _kCloseBracket) {
        if (_depth > 0) _depth--;
        if (_capturing && _captureContainer && _depth == _captureLevel) {
          _i++;
          return _emit();
        }
      } else if (b == _kQuote) {
        _inString = true;
        if (!_capturing && _rootIsObject && _depth == 1) {
          _keyCapture = true;
          _keyBuf.clear();
        }
      } else if (b == _kColon) {
        if (!_capturing && _rootIsObject && _depth == 1) {
          _pendingKey = _lastString;
          _lastString = null;
        }
      }
      _i++;
    }

    if (_capturing && _sliceStart < c.length) {
      _elemBuf.add(Uint8List.sublistView(c, _sliceStart, c.length));
      _sliceStart = c.length;
    }
    return null;
  }

  void _startCapture({required bool container}) {
    _capturing = true;
    _captureContainer = container;
    _captureLevel = _depth;
    _sliceStart = _i;
    _elemBuf.clear();
  }

  TimelineElement _emit() {
    if (_sliceStart < _i) {
      _elemBuf.add(Uint8List.sublistView(_c, _sliceStart, _i));
    }
    var bytes = _elemBuf.takeBytes();
    var end = _consumedBefore + _i;
    if (!_captureContainer) {
      var n = bytes.length;
      while (n > 0 && _isWs(bytes[n - 1])) {
        n--;
      }
      if (n != bytes.length) {
        end -= bytes.length - n;
        bytes = Uint8List.sublistView(bytes, 0, n);
      }
    }
    final section = _section ?? kTimelineRootSection;
    _capturing = false;
    _captureContainer = false;
    _sliceStart = _i;
    if (!_multi) {
      _elementLevel = -1;
      _section = null;
    }
    return TimelineElement(section: section, bytes: bytes, endOffset: end);
  }
}
