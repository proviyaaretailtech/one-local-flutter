import 'package:flutter/material.dart';

import 'i18n.dart';
import 'theme.dart';

/// The three purchase steps (founder, 26 Oct 2026; simplified 29 Oct 2026): 1 place the order, 2 mark what was received, 3 the supplier's bill. Shown on top
/// of each step's screen so the person always sees where the purchase is; [current] is 1, 2 or 3.
class PurchaseSteps extends StatelessWidget {
  const PurchaseSteps(this.current, {super.key});
  final int current;

  static const _steps = ['Order', 'Received', 'Bill'];

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(key: ValueKey('purchase-steps-$current'), children: [
          for (var i = 0; i < _steps.length; i++) ...[
            if (i > 0) Expanded(child: Container(height: 2, margin: const EdgeInsets.symmetric(horizontal: 6), color: i < current ? const Color(0xFF22A355) : kLine)),
            _step(i + 1, _steps[i]),
          ],
        ]),
      );

  Widget _step(int n, String label) {
    final done = n < current, now = n == current;
    final fill = done ? const Color(0xFF22A355) : (now ? kInk : Colors.white);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(shape: BoxShape.circle, color: fill, border: Border.all(color: done || now ? fill : kLine, width: 1.5)),
        child: done ? const Icon(Icons.check, size: 13, color: Colors.white) : Text('$n', style: inter(11.5, 800, color: now ? Colors.white : kMuted)),
      ),
      const SizedBox(width: 5),
      Text(tr(label), style: inter(12.5, now ? 800 : 600, color: now ? kInk : kMuted)),
    ]);
  }
}
