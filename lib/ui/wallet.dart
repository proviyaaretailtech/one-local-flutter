import 'package:flutter/material.dart';

import 'theme.dart';

/// The wallet look (founder, 27 Oct 2026, after Google Wallet): cards in a colour gradient with white type, stacked in piles.
class WalletColors {
  static const green = [Color(0xFF14532D), Color(0xFF2F8F4E)];
  static const orange = [Color(0xFFC2410C), Color(0xFFF97316)];
  static const red = [Color(0xFFB91C1C), Color(0xFFEF4444)];
  static const slate = [Color(0xFF475569), Color(0xFF94A3B8)];
}

/// One wallet card: a gradient, rounded, with a soft shadow; [onTap] makes the whole card a button.
class WalletCard extends StatelessWidget {
  const WalletCard({super.key, required this.colors, required this.child, this.onTap, this.radius = 22, this.padding = const EdgeInsets.all(16)});
  final List<Color> colors;
  final Widget child;
  final VoidCallback? onTap;
  final double radius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
            boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 10, offset: Offset(0, 4))],
          ),
          child: InkWell(borderRadius: BorderRadius.circular(radius), onTap: onTap, child: Padding(padding: padding, child: child)),
        ),
      );
}

/// A pile: the edges of up to [behind] cards peek above the front card.
class WalletPile extends StatelessWidget {
  const WalletPile({super.key, required this.colors, required this.behind, required this.child, this.onTap});
  final List<Color> colors;
  final int behind;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final n = behind.clamp(0, 2);
    return Padding(
      padding: EdgeInsets.only(top: n * 8.0),
      child: Stack(clipBehavior: Clip.none, children: [
        for (var i = n; i >= 1; i--)
          Positioned(
            top: -8.0 * i,
            left: 14.0 * i,
            right: 14.0 * i,
            height: 36,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: LinearGradient(colors: [Color.lerp(colors[0], Colors.white, 0.18 * i)!, Color.lerp(colors[1], Colors.white, 0.18 * i)!]),
              ),
            ),
          ),
        WalletCard(colors: colors, onTap: onTap, child: child),
      ]),
    );
  }
}

/// White text on a wallet card.
Widget onWallet(String text, {double size = 13, int weight = 500, double alpha = 0.85, int maxLines = 1}) =>
    Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: inter(size, weight, color: Colors.white.withValues(alpha: alpha)));
