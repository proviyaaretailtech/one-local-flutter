import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:photo_manager/photo_manager.dart';

import '../orders/order_widgets.dart' show kDark, kLime;
import '../ui/theme.dart';
import 'item_photo.dart';
import '../ui/i18n.dart';

/// Opens the camera-first product photo flow: the camera, then the clean-up step (remove the background, compare, use). Null when
/// closed without a photo.
Future<ItemPhoto?> showPhotoCapture(BuildContext context, ItemPhotoService photos) =>
    Navigator.of(context).push<ItemPhoto>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => PhotoCaptureScreen(photos: photos)));

/// The device's cameras (tests replace it: there is no camera there).
Future<List<CameraDescription>> Function() findCameras = availableCameras;

/// The phone's latest gallery photo as a small thumbnail, or null (no permission, no photos, the browser). Tests replace it.
Future<Uint8List?> Function() latestGalleryThumb = () async {
  if (kIsWeb) return null;
  try {
    final p = await PhotoManager.requestPermissionExtend();
    if (!p.hasAccess) return null;
    final albums = await PhotoManager.getAssetPathList(type: RequestType.image, onlyAll: true);
    if (albums.isEmpty) return null;
    final latest = await albums.first.getAssetListPaged(page: 0, size: 1);
    if (latest.isEmpty) return null;
    return await latest.first.thumbnailDataWithSize(const ThumbnailSize(160, 160));
  } catch (_) {
    return null;
  }
};

/// Camera first (founder, 26 Oct 2026): the camera opens straight away with a big shutter, the latest gallery photo in the corner
/// (tap it to choose any photo instead) and a switch for the front camera. After the shot comes the clean-up step: remove the
/// background (on the phone), compare it with the original, then use it or take it again. [initial] starts on the clean-up step.
class PhotoCaptureScreen extends StatefulWidget {
  const PhotoCaptureScreen({super.key, required this.photos, this.initial});
  final ItemPhotoService photos;
  final ItemPhoto? initial;
  @override
  State<PhotoCaptureScreen> createState() => _PhotoCaptureScreenState();
}

class _PhotoCaptureScreenState extends State<PhotoCaptureScreen> {
  CameraController? _camera;
  List<CameraDescription> _cameras = const [];
  int _which = 0;
  String? _cameraProblem;
  Uint8List? _thumb;
  bool _busy = false;

  // the clean-up step
  late ItemPhoto? _original = widget.initial;
  ItemPhoto? _cutOut;
  bool _showCutOut = true;

  @override
  void initState() {
    super.initState();
    if (_original == null) _startCamera();
    latestGalleryThumb().then((t) {
      if (mounted) setState(() => _thumb = t);
    });
  }

  @override
  void dispose() {
    _camera?.dispose();
    super.dispose();
  }

  Future<void> _startCamera() async {
    try {
      if (_cameras.isEmpty) _cameras = await findCameras();
      if (_cameras.isEmpty) throw StateError('no camera');
      final back = _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      if (_camera == null && back >= 0) _which = back;
      final c = CameraController(_cameras[_which], ResolutionPreset.high, enableAudio: false);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      final old = _camera;
      setState(() {
        _camera = c;
        _cameraProblem = null;
      });
      await old?.dispose();
    } catch (_) {
      if (mounted) setState(() => _cameraProblem = 'The camera could not open. Allow camera access, or choose a photo from the gallery.');
    }
  }

  Future<void> _flip() async {
    if (_cameras.length < 2) return;
    _which = (_which + 1) % _cameras.length;
    await _startCamera();
  }

  Future<void> _shoot() async {
    final c = _camera;
    if (c == null || !c.value.isInitialized || _busy) return;
    setState(() => _busy = true);
    try {
      final shot = await c.takePicture();
      final bytes = await shot.readAsBytes();
      if (bytes.length > DeviceItemPhotos.maxBytes) throw const ItemPhotoUnavailable('That photo is over 5 MB. Try again.');
      _review(ItemPhoto(bytes: bytes, contentType: 'image/jpeg'));
    } catch (e) {
      if (mounted) showToast(context, e is ItemPhotoUnavailable ? e.message : 'The photo could not be taken. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _gallery() async {
    try {
      final p = await widget.photos.pick();
      if (p != null && mounted) _review(p);
    } catch (e) {
      if (mounted) showToast(context, e is ItemPhotoUnavailable ? e.message : 'That photo could not be opened.');
    }
  }

  void _review(ItemPhoto p) {
    _camera?.pausePreview().catchError((_) {});
    setState(() {
      _original = p;
      _cutOut = null;
      _showCutOut = true;
    });
  }

  void _retake() {
    setState(() {
      _original = null;
      _cutOut = null;
    });
    if (_camera == null) {
      _startCamera();
    } else {
      _camera!.resumePreview().catchError((_) {});
    }
  }

  Future<void> _removeBackground() async {
    final p = _original;
    if (p == null) return;
    setState(() => _busy = true);
    try {
      final clean = await widget.photos.removeBackground(p);
      if (mounted) {
        setState(() {
          _cutOut = clean;
          _showCutOut = true;
        });
      }
    } catch (e) {
      if (mounted) showToast(context, e is ItemPhotoUnavailable ? e.message : 'The background could not be removed.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(child: _original == null ? _cameraView() : _cleanUp()),
      );

  // ---------------------------------------------------------------- 1. camera
  Widget _cameraView() {
    final c = _camera;
    return Column(children: [
      _topBar('Product photo', onClose: () => Navigator.of(context).pop()),
      Expanded(
        child: c != null && c.value.isInitialized
            ? Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: AspectRatio(aspectRatio: 1 / c.value.aspectRatio, child: CameraPreview(c)),
                ),
              )
            : Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: _cameraProblem == null
                      ? const CircularProgressIndicator(color: Colors.white)
                      : Text(_cameraProblem!, key: const ValueKey('camera-problem'), textAlign: TextAlign.center, style: inter(15, 500, color: Colors.white70, height: 1.4)),
                ),
              ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(28, 14, 28, 22),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          // the latest gallery photo, like the phone's own camera; tap to choose any photo
          InkWell(
            key: const ValueKey('camera-gallery'),
            borderRadius: BorderRadius.circular(14),
            onTap: _busy ? null : _gallery,
            child: Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white70, width: 1.5)),
              clipBehavior: Clip.antiAlias,
              child: _thumb == null ? const Icon(LucideIcons.images, color: Colors.white, size: 24) : Image.memory(_thumb!, fit: BoxFit.cover, gaplessPlayback: true),
            ),
          ),
          // the shutter
          GestureDetector(
            key: const ValueKey('camera-shutter'),
            onTap: _shoot,
            child: Container(
              width: 76,
              height: 76,
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
              child: Container(decoration: BoxDecoration(shape: BoxShape.circle, color: _busy ? Colors.white54 : Colors.white)),
            ),
          ),
          IconButton(
            key: const ValueKey('camera-flip'),
            tooltip: tr('Switch camera'),
            onPressed: _cameras.length < 2 || _busy ? null : _flip,
            iconSize: 28,
            icon: Icon(LucideIcons.switchCamera, color: _cameras.length < 2 ? Colors.white24 : Colors.white),
          ),
        ]),
      ),
    ]);
  }

  // ---------------------------------------------------------------- 2. clean-up
  Widget _cleanUp() {
    final shown = _cutOut != null && _showCutOut ? _cutOut! : _original!;
    return Column(children: [
      _topBar(_cutOut == null ? 'Clean up the photo' : 'Background removed', onClose: _retake, closeIcon: LucideIcons.arrowLeft, closeLabel: 'Retake'),
      if (_cutOut != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SegmentedButton<bool>(
            key: ValueKey('photo-compare'),
            segments: [ButtonSegment(value: false, label: Text(tr('Original'))), ButtonSegment(value: true, label: Text(tr('Cut-out')))],
            selected: {_showCutOut},
            onSelectionChanged: (s) => setState(() => _showCutOut = s.first),
            style: SegmentedButton.styleFrom(backgroundColor: Colors.white12, foregroundColor: Colors.white, selectedBackgroundColor: kLime, selectedForegroundColor: kDark),
          ),
        ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Container(
            // a cut-out is shown on white, as it will look in the catalogue
            decoration: BoxDecoration(color: shown.backgroundRemoved ? Colors.white : Colors.black, borderRadius: BorderRadius.circular(18)),
            clipBehavior: Clip.antiAlias,
            child: Stack(fit: StackFit.expand, children: [
              Image.memory(shown.bytes, key: ValueKey('photo-${shown.backgroundRemoved ? 'cutout' : 'original'}'), fit: BoxFit.contain, gaplessPlayback: true),
              if (_busy)
                Container(
                  color: Colors.black45,
                  alignment: Alignment.center,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 12),
                    Text(tr('Removing the background…'), style: inter(14, 600, color: Colors.white)),
                  ]),
                ),
            ]),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_cutOut == null)
            FilledButton.icon(
              key: const ValueKey('photo-remove-bg'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), backgroundColor: kLime, foregroundColor: kDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
              onPressed: _busy ? null : _removeBackground,
              icon: const Icon(LucideIcons.sparkles, size: 18),
              label: Text(tr('Remove background'), style: inter(15.5, 800, color: kDark)),
            ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                key: const ValueKey('photo-retake'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50), side: const BorderSide(color: Colors.white54), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                onPressed: _busy ? null : _retake,
                child: Text(tr('Retake'), style: inter(15, 700, color: Colors.white)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: FilledButton(
                key: const ValueKey('photo-use'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50), backgroundColor: Colors.white, foregroundColor: kDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                onPressed: _busy ? null : () => Navigator.of(context).pop(shown),
                child: Text(_cutOut != null && _showCutOut ? 'Use cut-out' : 'Use photo', style: inter(15, 800, color: kDark)),
              ),
            ),
          ]),
        ]),
      ),
    ]);
  }

  Widget _topBar(String title, {required VoidCallback onClose, IconData closeIcon = LucideIcons.x, String closeLabel = 'Close'}) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 16, 10),
        child: Row(children: [
          IconButton(key: const ValueKey('camera-close'), tooltip: closeLabel, onPressed: _busy ? null : onClose, icon: Icon(closeIcon, color: Colors.white)),
          const SizedBox(width: 4),
          Expanded(child: Text(title, style: inter(17, 700, color: Colors.white))),
        ]),
      );
}
