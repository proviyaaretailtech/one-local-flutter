import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../orders/order_widgets.dart' show kLime;
import '../ui/motion.dart';
import '../ui/theme.dart';

// A drawn sample map for the Bookings Map view (2 Nov 2026), until the app has a Google Maps key: streets, a river and a park in the
// One Local colours, with one numbered pin per job at a customer's place. The pins rise and pulse gently (still when the phone asks for
// less motion). It is clearly an example: the real map replaces it once the key is added.

class MapPreview extends StatefulWidget {
  const MapPreview({super.key, required this.pins, this.height = 230});

  /// How many jobs to pin (1, 2, 3...); the pins are spread over the drawing in a fixed pattern.
  final int pins;
  final double height;
  @override
  State<MapPreview> createState() => _MapPreviewState();
}

class _MapPreviewState extends State<MapPreview> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotion(context)) {
      _pulse.value = 0.5;
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          height: widget.height,
          child: Stack(children: [
            Positioned.fill(
              child: AnimatedBuilder(animation: _pulse, builder: (_, _) => CustomPaint(painter: _MapPainter(pins: widget.pins, t: _pulse.value))),
            ),
            Positioned(
              left: 12,
              top: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(999)),
                child: Text('Example map', style: inter(12, 700, color: kInk)),
              ),
            ),
          ]),
        ),
      );
}

/// Where pin n sits, as a share of the width and height (a fixed, spread-out pattern).
const _spots = [Offset(0.30, 0.38), Offset(0.66, 0.30), Offset(0.52, 0.64), Offset(0.18, 0.70), Offset(0.82, 0.62), Offset(0.42, 0.20), Offset(0.74, 0.82), Offset(0.10, 0.34)];

class _MapPainter extends CustomPainter {
  _MapPainter({required this.pins, required this.t});
  final int pins;
  final double t; // 0..1, the pulse

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    canvas.drawRect(Offset.zero & s, Paint()..color = const Color(0xFFEFF2EA));

    // blocks
    final block = Paint()..color = const Color(0xFFE2E7DA);
    for (var x = 0.0; x < w; x += 70) {
      for (var y = 0.0; y < h; y += 58) {
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x + 8, y + 8, 54, 42), const Radius.circular(6)), block);
      }
    }
    // a park
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.58, h * 0.44, 92, 50), const Radius.circular(10)), Paint()..color = const Color(0xFFCDEBB4));
    // a river
    final river = Path()
      ..moveTo(-10, h * 0.86)
      ..cubicTo(w * 0.25, h * 0.70, w * 0.45, h * 1.02, w * 0.70, h * 0.84)
      ..cubicTo(w * 0.85, h * 0.74, w * 0.95, h * 0.80, w + 10, h * 0.72);
    canvas.drawPath(river, Paint()
      ..color = const Color(0xFFBFDDF0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16);
    // main roads
    final road = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 9;
    canvas.drawLine(Offset(0, h * 0.5), Offset(w, h * 0.42), road);
    canvas.drawLine(Offset(w * 0.36, 0), Offset(w * 0.46, h), road);
    canvas.drawLine(Offset(w * 0.75, 0), Offset(w * 0.68, h), road..strokeWidth = 7);
    // the route between the jobs, in order
    final n = pins.clamp(0, _spots.length);
    if (n > 1) {
      final route = Path()..moveTo(_spots[0].dx * w, _spots[0].dy * h);
      for (var i = 1; i < n; i++) {
        route.lineTo(_spots[i].dx * w, _spots[i].dy * h);
      }
      canvas.drawPath(route, Paint()
        ..color = kLink.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3);
    }
    // the pins: a pulse ring, then the pin with its number
    for (var i = 0; i < n; i++) {
      final p = Offset(_spots[i].dx * w, _spots[i].dy * h);
      final phase = (t + i * 0.18) % 1;
      canvas.drawCircle(p, 10 + 16 * phase, Paint()..color = kLink.withValues(alpha: 0.30 * (1 - phase)));
      final lift = 3 * math.sin(phase * math.pi);
      final head = p.translate(0, -16 - lift);
      final pin = Path()
        ..moveTo(p.dx, p.dy - lift)
        ..quadraticBezierTo(head.dx - 13, head.dy + 4, head.dx - 11, head.dy - 3)
        ..arcToPoint(Offset(head.dx + 11, head.dy - 3), radius: const Radius.circular(11.5))
        ..quadraticBezierTo(head.dx + 13, head.dy + 4, p.dx, p.dy - lift)
        ..close();
      canvas.drawShadow(pin, Colors.black, 3, false);
      canvas.drawPath(pin, Paint()..color = kPrimary);
      final label = TextPainter(text: TextSpan(text: '${i + 1}', style: inter(11.5, 800, color: kLime)), textDirection: TextDirection.ltr)..layout();
      label.paint(canvas, Offset(head.dx - label.width / 2, head.dy - 3 - label.height / 2));
    }
  }

  @override
  bool shouldRepaint(_MapPainter old) => old.t != t || old.pins != pins;
}
