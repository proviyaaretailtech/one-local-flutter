import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../ui/theme.dart';
import 'document_picker.dart';

/// The PAN card's shape (85.6 × 54 mm).
const kCardAspect = 85.6 / 54;

/// The frame on the camera view, as a share of the view's width.
const _frameWidth = 0.86;

/// The camera with a PAN-card frame, for phones and browsers without the built-in document scanner (founder, 27 Oct 2026). The
/// photo is cropped to the frame, so only the card is uploaded.
class PanCameraScreen extends StatefulWidget {
  const PanCameraScreen({super.key});
  @override
  State<PanCameraScreen> createState() => _PanCameraScreenState();
}

class _PanCameraScreenState extends State<PanCameraScreen> {
  CameraController? _camera;
  String? _problem;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _camera?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw StateError('no camera');
      final back = cams.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      final c = CameraController(cams[back >= 0 ? back : 0], ResolutionPreset.veryHigh, enableAudio: false);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _camera = c);
    } catch (_) {
      if (mounted) setState(() => _problem = 'The camera could not open. Allow camera access in your browser or phone settings, or upload a file instead.');
    }
  }

  Future<void> _shoot() async {
    final c = _camera;
    if (c == null || !c.value.isInitialized || _busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await (await c.takePicture()).readAsBytes();
      final cropped = cropToCard(bytes);
      if (mounted) Navigator.of(context).pop(PickedDocument(name: 'pan_card_photo.jpg', bytes: cropped, contentType: 'image/jpeg'));
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The photo could not be taken. Try again.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _camera;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
            child: Row(children: [
              IconButton(key: const ValueKey('pan-camera-close'), onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close, color: Colors.white)),
              const SizedBox(width: 4),
              Text('Scan your PAN card', style: inter(17, 600, color: Colors.white)),
            ]),
          ),
          Expanded(
            child: Center(
              child: _problem != null
                  ? Padding(padding: const EdgeInsets.all(32), child: Text(_problem!, textAlign: TextAlign.center, style: inter(15, 400, color: Colors.white70, height: 1.5)))
                  : c == null || !c.value.isInitialized
                      ? const CircularProgressIndicator(color: Colors.white)
                      : AspectRatio(
                          aspectRatio: _previewAspect(c),
                          child: Stack(fit: StackFit.expand, children: [
                            CameraPreview(c),
                            const CustomPaint(painter: _CardFrame()),
                          ]),
                        ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
            child: Text('Fit the front of the card inside the frame, in good light, with no glare.', textAlign: TextAlign.center, style: inter(14, 400, color: Colors.white70, height: 1.4)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: GestureDetector(
              key: const ValueKey('pan-camera-shoot'),
              onTap: c == null || _busy ? null : _shoot,
              child: Container(
                width: 74,
                height: 74,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
                padding: const EdgeInsets.all(5),
                child: Container(
                  decoration: BoxDecoration(shape: BoxShape.circle, color: _busy ? Colors.white38 : Colors.white),
                  child: _busy ? const Padding(padding: EdgeInsets.all(18), child: CircularProgressIndicator(strokeWidth: 3, color: Colors.black)) : null,
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// The preview's shape on screen: a phone app shows its camera upright (taller than wide); a browser shows the stream as it comes.
double _previewAspect(CameraController c) {
  final a = c.value.aspectRatio;
  return kIsWeb || a < 1 ? a : 1 / a;
}

/// Crops a photo to the card frame (the same share of the picture as the frame is of the view), with a little room around it.
Uint8List cropToCard(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  final photo = img.bakeOrientation(decoded);
  final r = cardRect(photo.width.toDouble(), photo.height.toDouble(), margin: 0.04);
  final cropped = img.copyCrop(photo, x: r.left.round(), y: r.top.round(), width: r.width.round(), height: r.height.round());
  final out = cropped.width > 1600 ? img.copyResize(cropped, width: 1600) : cropped;
  return Uint8List.fromList(img.encodeJpg(out, quality: 88));
}

/// Where the card frame sits in a view of [w] × [h]: centred, [_frameWidth] of the width, the card's shape.
Rect cardRect(double w, double h, {double margin = 0}) {
  var fw = w * _frameWidth;
  var fh = fw / kCardAspect;
  if (fh > h * 0.9) {
    fh = h * 0.9;
    fw = fh * kCardAspect;
  }
  final r = Rect.fromCenter(center: Offset(w / 2, h / 2), width: fw, height: fh);
  final grown = r.inflate(w * margin);
  return Rect.fromLTRB(grown.left.clamp(0, w), grown.top.clamp(0, h), grown.right.clamp(0, w), grown.bottom.clamp(0, h));
}

/// Darkens around the card and draws its corners.
class _CardFrame extends CustomPainter {
  const _CardFrame();
  @override
  void paint(Canvas canvas, Size size) {
    final r = cardRect(size.width, size.height);
    final card = RRect.fromRectAndRadius(r, const Radius.circular(14));
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRRect(card)),
      Paint()..color = Colors.black54,
    );
    final line = Paint()
      ..color = const Color(0xFFA1FE2F)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const l = 28.0;
    for (final (x, y, dx, dy) in [(r.left, r.top, 1, 1), (r.right, r.top, -1, 1), (r.left, r.bottom, 1, -1), (r.right, r.bottom, -1, -1)]) {
      canvas.drawLine(Offset(x, y + dy * l), Offset(x, y), line);
      canvas.drawLine(Offset(x, y), Offset(x + dx * l, y), line);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
