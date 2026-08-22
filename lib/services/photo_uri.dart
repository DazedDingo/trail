/// URI-scheme helpers for `PingPhoto.uri` / `thumbUri` values.
///
/// A photo row carries one of three shapes:
///   - `https://…` — Wikimedia, rendered through `CachedNetworkImage`.
///   - `file://<absolute path>` — the user's own camera / gallery photo.
///     Written verbatim by `PingPhotosGallery._attachAt` as
///     `'file://$path'` (no percent-encoding), so the path is recovered
///     by stripping the prefix — **not** via `Uri.parse`, which would
///     mangle a literal `%` and is pointless for a string we built
///     ourselves.
///   - anything else (`content://`, …) — not something we can decode
///     locally; callers fall through to a placeholder.
///
/// Pure Dart, no Flutter import, so both widgets and the denylist can
/// share one definition of "is this a local file".
const String _fileScheme = 'file://';

/// True for `file://…` URIs (user photos).
bool isLocalFileUri(String? uri) =>
    uri != null && uri.startsWith(_fileScheme);

/// Absolute filesystem path for a `file://` URI, or `null` when [uri] is
/// not a local-file URI (http(s), `content://`, a bare scheme, empty,
/// null).
String? localPathForUri(String? uri) {
  if (!isLocalFileUri(uri)) return null;
  final path = uri!.substring(_fileScheme.length);
  return path.isEmpty ? null : path;
}
