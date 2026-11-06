import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../catalogue/item_photo.dart';
import '../orders/order_widgets.dart' show kLime;
import '../ui/theme.dart';

/// Crop, rotate and flip a photo before it is used (founder, 6 Nov 2026). Works on the phone or in the browser, nothing leaves the device.
/// Returns the adjusted photo, or null when closed without using it.
class ImageAdjustScreen extends StatefulWidget {
  const ImageAdjustScreen({super.key, required this.photo});
  final ItemPhoto photo;

  static Future<ItemPhoto?> open(BuildContext context, ItemPhoto photo) =>
      Navigator.of(context).push<ItemPhoto>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => ImageAdjustScreen(photo: photo)));

  @override
  State<ImageAdjustScreen> createState() => _ImageAdjustScreenState();
}

const _maxSide = 2400; // keeps the photo under the 5 MB limit and quick to work on
const _maxBytes = 5 * 1024 * 1024;
const _minCrop = 0.08;
const _ratios = <(String, double?)>[('Free', null), ('Square', 1), ('4:5', 4 / 5), ('16:9', 16 / 9)];

enum _Drag { move, topLeft, topRight, bottomLeft, bottomRight }

class _ImageAdjustScreenState extends State<ImageAdjustScreen> {
  img.Image? _image;
  Uint8List? _preview;
  Rect _crop = const Rect.fromLTWH(0, 0, 1, 1); // as parts of the picture, 0 to 1
  double? _ratio;
  _Drag? _drag;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    final decoded = img.decodeImage(widget.photo.bytes);
    if (decoded == null) return;
    final upright = img.bakeOrientation(decoded);
    final long = math.max(upright.width, upright.height);
    _image = long > _maxSide ? img.copyResize(upright, width: upright.width * _maxSide ~/ long, height: upright.height * _maxSide ~/ long) : upright;
    _redraw();
  }

  /// A lighter copy to draw on screen while working; the full picture is only cut at the end.
  void _redraw() {
    final i = _image!;
    final long = math.max(i.width, i.height);
    final small = long > 1000 ? img.copyResize(i, width: i.width * 1000 ~/ long, height: i.height * 1000 ~/ long) : i;
    _preview = img.encodeJpg(small.hasAlpha ? (img.Image(width: small.width, height: small.height)..clear(img.ColorRgb8(255, 255, 255))..let((bg) => img.compositeImage(bg, small))) : small, quality: 85);
    _crop = _cropFor(_ratio);
  }

  /// The largest box of [ratio] (width / height, null: everything), in the middle of the picture.
  Rect _cropFor(double? ratio) {
    if (ratio == null) return const Rect.fromLTWH(0, 0, 1, 1);
    final i = _image!;
    final k = ratio * i.height / i.width; // the box's width / height, in parts of the picture
    final w = k >= 1 ? 1.0 : k;
    final h = k >= 1 ? 1 / k : 1.0;
    return Rect.fromLTWH((1 - w) / 2, (1 - h) / 2, w, h);
  }

  void _turn(num angle) => setState(() {
        _image = img.copyRotate(_image!, angle: angle);
        _changed = true;
        _redraw();
      });

  void _flip() => setState(() {
        _image = img.copyFlip(_image!, direction: img.FlipDirection.horizontal);
        _changed = true;
        _redraw();
      });

  void _use() {
    final i = _image!;
    final x = (_crop.left * i.width).round().clamp(0, i.width - 1);
    final y = (_crop.top * i.height).round().clamp(0, i.height - 1);
    final w = (_crop.width * i.width).round().clamp(1, i.width - x);
    final h = (_crop.height * i.height).round().clamp(1, i.height - y);
    final whole = x == 0 && y == 0 && w == i.width && h == i.height;
    if (whole && !_changed) return Navigator.of(context).pop(widget.photo); // nothing was done: the photo stays exactly as it was
    final cut = whole ? i : img.copyCrop(i, x: x, y: y, width: w, height: h);
    // a PNG stays a PNG (it may be see-through), unless that makes it too big to upload
    if (widget.photo.contentType == 'image/png') {
      final png = img.encodePng(cut);
      if (png.length <= _maxBytes) return Navigator.of(context).pop(ItemPhoto(bytes: png, contentType: 'image/png'));
    }
    Navigator.of(context).pop(ItemPhoto(bytes: img.encodeJpg(cut, quality: 88), contentType: 'image/jpeg'));
  }

  void _dragStart(Offset at, Size box) {
    final c = Rect.fromLTRB(_crop.left * box.width, _crop.top * box.height, _crop.right * box.width, _crop.bottom * box.height);
    const reach = 30.0;
    final corners = {_Drag.topLeft: c.topLeft, _Drag.topRight: c.topRight, _Drag.bottomLeft: c.bottomLeft, _Drag.bottomRight: c.bottomRight};
    _Drag? near;
    var best = reach;
    corners.forEach((k, p) {
      final d = (p - at).distance;
      if (d <= best) {
        best = d;
        near = k;
      }
    });
    _drag = near ?? (c.contains(at) ? _Drag.move : null);
  }

  void _dragBy(Offset at, Offset delta, Size box) {
    final drag = _drag;
    if (drag == null) return;
    setState(() {
      if (drag == _Drag.move) {
        final dx = (delta.dx / box.width).clamp(-_crop.left, 1 - _crop.right);
        final dy = (delta.dy / box.height).clamp(-_crop.top, 1 - _crop.bottom);
        _crop = _crop.shift(Offset(dx, dy));
        return;
      }
      // the corner opposite stays where it is
      final left = drag == _Drag.topLeft || drag == _Drag.bottomLeft;
      final top = drag == _Drag.topLeft || drag == _Drag.topRight;
      final ax = left ? _crop.right : _crop.left;
      final ay = top ? _crop.bottom : _crop.top;
      final px = (at.dx / box.width).clamp(0.0, 1.0), py = (at.dy / box.height).clamp(0.0, 1.0);
      final roomX = left ? ax : 1 - ax, roomY = top ? ay : 1 - ay;
      var w = math.min(math.max((px - ax).abs(), _minCrop), roomX);
      var h = math.min(math.max((py - ay).abs(), _minCrop), roomY);
      final ratio = _ratio;
      if (ratio != null) {
        final k = ratio * _image!.height / _image!.width;
        h = w / k;
        if (h > roomY) {
          h = roomY;
          w = h * k;
        }
      }
      _crop = Rect.fromLTRB(left ? ax - w : ax, top ? ay - h : ay, left ? ax : ax + w, top ? ay : ay + h);
    });
  }

  Widget _tool(String key, IconData icon, String label, VoidCallback onTap) => Expanded(
        child: InkWell(
          key: ValueKey(key),
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 22, color: Colors.white),
              const SizedBox(height: 4),
              Text(label, style: inter(12, 600, color: Colors.white)),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final i = _image;
    return Scaffold(
      backgroundColor: const Color(0xFF111827),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111827),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text('Adjust photo', style: inter(16, 700, color: Colors.white)),
        leading: IconButton(key: const ValueKey('adjust-close'), tooltip: 'Close', icon: const Icon(LucideIcons.x), onPressed: () => Navigator.of(context).pop()),
      ),
      body: SafeArea(
        child: i == null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('This photo cannot be adjusted here. Try a JPG or PNG.', key: const ValueKey('adjust-unreadable'), textAlign: TextAlign.center, style: inter(14, 500, color: Colors.white))))
            : Column(children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: LayoutBuilder(builder: (context, box) {
                      final scale = math.min(box.maxWidth / i.width, box.maxHeight / i.height);
                      final size = Size(i.width * scale, i.height * scale);
                      return Center(
                        child: SizedBox.fromSize(
                          size: size,
                          child: GestureDetector(
                            key: const ValueKey('adjust-crop'),
                            onPanStart: (d) => _dragStart(d.localPosition, size),
                            onPanUpdate: (d) => _dragBy(d.localPosition, d.delta, size),
                            onPanEnd: (_) => _drag = null,
                            child: Stack(fit: StackFit.expand, children: [
                              Image.memory(_preview!, fit: BoxFit.fill, gaplessPlayback: true),
                              CustomPaint(painter: _CropPainter(_crop)),
                            ]),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(children: [
                    for (final (name, ratio) in _ratios)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          key: ValueKey('adjust-ratio-$name'),
                          label: Text(name, style: inter(13, 600, color: _ratio == ratio ? kInk : Colors.white)),
                          selected: _ratio == ratio,
                          showCheckmark: false,
                          selectedColor: kLime,
                          backgroundColor: const Color(0xFF1F2937),
                          side: BorderSide.none,
                          onSelected: (_) => setState(() {
                            _ratio = ratio;
                            _crop = _cropFor(ratio);
                          }),
                        ),
                      ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Row(children: [
                    _tool('adjust-left', LucideIcons.rotateCcw, 'Rotate left', () => _turn(-90)),
                    _tool('adjust-right', LucideIcons.rotateCw, 'Rotate right', () => _turn(90)),
                    _tool('adjust-flip', LucideIcons.flipVertical2, 'Flip', _flip),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      key: const ValueKey('adjust-use'),
                      style: FilledButton.styleFrom(backgroundColor: kLime, foregroundColor: kInk, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                      onPressed: _use,
                      child: Text('Use photo', style: inter(15, 700, color: kInk)),
                    ),
                  ),
                ),
              ]),
      ),
    );
  }
}

extension _Let<T> on T {
  T let(void Function(T) f) {
    f(this);
    return this;
  }
}

/// Dims what will be cut off; a box with thirds and corner handles shows what stays.
class _CropPainter extends CustomPainter {
  const _CropPainter(this.crop);
  final Rect crop;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Rect.fromLTRB(crop.left * size.width, crop.top * size.height, crop.right * size.width, crop.bottom * size.height);
    canvas.drawPath(Path()..fillType = PathFillType.evenOdd..addRect(Offset.zero & size)..addRect(c), Paint()..color = const Color(0x99000000));
    final line = Paint()
      ..color = const Color(0x66FFFFFF)
      ..strokeWidth = 1;
    for (var n = 1; n < 3; n++) {
      canvas.drawLine(Offset(c.left + c.width * n / 3, c.top), Offset(c.left + c.width * n / 3, c.bottom), line);
      canvas.drawLine(Offset(c.left, c.top + c.height * n / 3), Offset(c.right, c.top + c.height * n / 3), line);
    }
    canvas.drawRect(c, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5..color = Colors.white);
    final handle = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.square
      ..color = kLime;
    final arm = math.min(18.0, math.min(c.width, c.height) / 2);
    for (final (p, dx, dy) in [(c.topLeft, 1.0, 1.0), (c.topRight, -1.0, 1.0), (c.bottomLeft, 1.0, -1.0), (c.bottomRight, -1.0, -1.0)]) {
      canvas.drawLine(p, p + Offset(dx * arm, 0), handle);
      canvas.drawLine(p, p + Offset(0, dy * arm), handle);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.crop != crop;
}
