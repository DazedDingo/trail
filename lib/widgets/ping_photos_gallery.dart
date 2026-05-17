import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../db/database.dart';
import '../db/ping_photo_dao.dart';
import '../models/ping_photo.dart';
import '../providers/photos_provider.dart';

/// Horizontal photo carousel for a single ping (schema v2). Renders:
///   - online auto-fetched photos (CC-BY-SA Wikimedia) with attribution
///   - user-supplied photos (camera or gallery) attached via the
///     "Add your photo" trailing tile
///
/// Empty state when no photos: just an "Add your photo" prompt. The
/// online auto-fetch may still be in flight on a fresh ping; the
/// gallery picks up the new rows on the next pingPhotosProvider
/// invalidate.
class PingPhotosGallery extends ConsumerStatefulWidget {
  final int pingId;
  const PingPhotosGallery({super.key, required this.pingId});

  @override
  ConsumerState<PingPhotosGallery> createState() => _PingPhotosGalleryState();
}

class _PingPhotosGalleryState extends ConsumerState<PingPhotosGallery> {
  final _picker = ImagePicker();
  bool _adding = false;

  Future<void> _attachFromCamera() async {
    setState(() => _adding = true);
    try {
      final picked = await _picker.pickImage(source: ImageSource.camera);
      if (picked != null) {
        await _attachAt(picked.path, PingPhotoSource.userCamera);
      }
    } catch (_) {
      // Permission denied / camera unavailable — silent. The Settings
      // toggle gives the user a path to revisit; an error toast at the
      // tap site would just confuse "I cancelled" vs "it failed".
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _attachFromGallery() async {
    setState(() => _adding = true);
    try {
      final picked = await _picker.pickImage(source: ImageSource.gallery);
      if (picked != null) {
        await _attachAt(picked.path, PingPhotoSource.userGallery);
      }
    } catch (_) {
      // Same rationale as camera path.
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _attachAt(String filePath, PingPhotoSource source) async {
    final db = await TrailDatabase.shared();
    final dao = PingPhotoDao(db);
    final existing = await dao.byPingId(widget.pingId);
    await dao.insert(PingPhoto(
      pingId: widget.pingId,
      uri: 'file://$filePath',
      source: source,
      fetchedAt: DateTime.now().toUtc(),
      ordinal: existing.length,
    ));
    ref.invalidate(pingPhotosProvider(widget.pingId));
  }

  void _showSourceSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(ctx);
                _attachFromCamera();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Pick from gallery'),
              onTap: () {
                Navigator.pop(ctx);
                _attachFromGallery();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _removePhoto(int photoId) async {
    final db = await TrailDatabase.shared();
    await PingPhotoDao(db).deleteById(photoId);
    ref.invalidate(pingPhotosProvider(widget.pingId));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(pingPhotosProvider(widget.pingId));
    final photos = async.valueOrNull ?? const <PingPhoto>[];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        height: 132,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final photo in photos)
              _PhotoTile(
                photo: photo,
                onLongPress: () => _confirmRemove(context, photo),
              ),
            _AddPhotoTile(
              onTap: _adding ? null : _showSourceSheet,
              busy: _adding,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    PingPhoto photo,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this photo?'),
        content: Text(
          photo.source.isUserSupplied
              ? 'This removes your attached photo from this pin.'
              : 'This hides the Wikimedia photo from this pin. '
                  'The next auto-refresh will not re-add a hidden photo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true && photo.id != null) {
      await _removePhoto(photo.id!);
    }
  }
}

class _PhotoTile extends StatelessWidget {
  final PingPhoto photo;
  final VoidCallback onLongPress;
  const _PhotoTile({required this.photo, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = photo.source.isUserSupplied;
    final imageUri = photo.thumbUri ?? photo.uri;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onLongPress: onLongPress,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            children: [
              SizedBox(
                width: 132,
                height: 132,
                child: _buildImage(context, imageUri, scheme),
              ),
              if (!isUser && photo.attribution.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.55),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    child: Text(
                      photo.attribution,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              if (isUser)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.85),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      photo.source == PingPhotoSource.userCamera
                          ? Icons.photo_camera
                          : Icons.photo_library,
                      color: scheme.onPrimary,
                      size: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImage(BuildContext context, String uri, ColorScheme scheme) {
    if (uri.startsWith('file://')) {
      final path = uri.replaceFirst('file://', '');
      return Image.asset(path,
          fit: BoxFit.cover, errorBuilder: (_, __, ___) {
        return _placeholder(scheme);
      });
    }
    if (uri.startsWith('http')) {
      return CachedNetworkImage(
        imageUrl: uri,
        fit: BoxFit.cover,
        placeholder: (_, __) => _placeholder(scheme),
        errorWidget: (_, __, ___) => _placeholder(scheme),
      );
    }
    return _placeholder(scheme);
  }

  Widget _placeholder(ColorScheme scheme) => Container(
        color: scheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(Icons.image_outlined, color: scheme.onSurfaceVariant),
      );
}

class _AddPhotoTile extends StatelessWidget {
  final VoidCallback? onTap;
  final bool busy;
  const _AddPhotoTile({required this.onTap, required this.busy});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 132,
        height: 132,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.6),
            style: BorderStyle.solid,
          ),
        ),
        alignment: Alignment.center,
        child: busy
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_a_photo_outlined,
                      color: scheme.onSurfaceVariant),
                  const SizedBox(height: 6),
                  Text(
                    'Add your photo',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
