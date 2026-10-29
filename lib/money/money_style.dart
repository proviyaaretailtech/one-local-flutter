import 'dart:math';

import 'package:flutter/material.dart';

import '../ui/theme.dart';

// The Money look (founder's inspiration, 28 Oct 2026): a dark balance card with soft rings, lime for the main action, white cards with
// rounded corners, and pill tabs.

const kMoneyDeep = Color(0xFF16181D); // the dark cards
const kMoneyDeepSoft = Color(0xFF2A2E35); // buttons on a dark card
const kMoneyLime = Color(0xFFD2F64B); // the main action, highlights
const kMoneyCardRadius = 26.0;

/// Faint concentric rings in a dark card's corner.
class MoneyRings extends StatelessWidget {
  const MoneyRings({super.key, this.color = Colors.white, this.opacity = 0.07});
  final Color color;
  final double opacity;
  @override
  Widget build(BuildContext context) => IgnorePointer(child: CustomPaint(painter: _RingsPainter(color.withValues(alpha: opacity)), size: Size.infinite));
}

class _RingsPainter extends CustomPainter {
  _RingsPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final c = Offset(size.width * 0.92, size.height * 0.12);
    final r0 = max(size.width, size.height) * 0.12;
    for (var i = 0; i < 6; i++) {
      canvas.drawCircle(c, r0 + i * 18, p);
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.color != color;
}

/// A dark card with rings: the balance cards.
class MoneyDarkCard extends StatelessWidget {
  const MoneyDarkCard({super.key, required this.child, this.padding = const EdgeInsets.fromLTRB(18, 20, 18, 18)});
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(kMoneyCardRadius),
        child: Container(
          color: kMoneyDeep,
          child: Stack(children: [
            const Positioned.fill(child: MoneyRings()),
            Padding(padding: padding, child: child),
          ]),
        ),
      );
}

/// Pill tabs: the selected one dark, the rest plain (like 1D 5D 1W 1M).
class MoneyPills extends StatelessWidget {
  const MoneyPills({super.key, required this.options, required this.selected, required this.onSelect, this.keyPrefix = 'pill'});
  final List<(String, String)> options; // (id, label)
  final String selected;
  final ValueChanged<String> onSelect;
  final String keyPrefix;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final (id, label) in options)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Material(
                color: selected == id ? kMoneyDeep : Colors.white,
                borderRadius: BorderRadius.circular(40),
                child: InkWell(
                  key: ValueKey('$keyPrefix-$id'),
                  borderRadius: BorderRadius.circular(40),
                  onTap: () => onSelect(id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(40), border: Border.all(color: selected == id ? kMoneyDeep : kLine)),
                    child: Text(label, style: inter(13, 700, color: selected == id ? Colors.white : kInk)),
                  ),
                ),
              ),
            ),
        ]),
      );
}

/// A white rounded card.
BoxDecoration moneyCard({Color color = Colors.white}) => BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(22),
      boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 18, offset: Offset(0, 6))],
    );
