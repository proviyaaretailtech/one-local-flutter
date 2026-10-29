import 'package:flutter/material.dart';

import 'theme.dart';

/// The wallet look (founder, 27 Oct 2026, after Google Wallet): cards in a colour gradient with white type, stacked in piles.
class WalletColors {
  // three stops each, a deep start through a bright middle to a light, warmer end (founder, 28 Oct 2026: "more gradient, prettier")
  static const green = [Color(0xFF0B7A45), Color(0xFF1DB66A), Color(0xFF4CC985)];
  static const orange = [Color(0xFFE8441C), Color(0xFFFF7A2F), Color(0xFFFFA24C)];
  static const red = [Color(0xFFB4162A), Color(0xFFEF4444), Color(0xFFFF7A6E)];
  static const slate = [Color(0xFF3F4C63), Color(0xFF6B7A93), Color(0xFF8C9AB3)];
  static const blue = [Color(0xFF2B3FD6), Color(0xFF3D8BFF), Color(0xFF52B6FF)];
  static const purple = [Color(0xFF5B13C9), Color(0xFF9B3DF2), Color(0xFFC65CFF)];
  static const rose = [Color(0xFFD1124F), Color(0xFFFF4F7B), Color(0xFFFF7E86)];
}

/// One wallet card: a three-colour gradient with a glossy sheen, soft light bubbles in the corner and a glow of its own colour under it;
/// [onTap] makes the whole card a button.
class WalletCard extends StatelessWidget {
  const WalletCard({super.key, required this.colors, required this.child, this.onTap, this.radius = 22, this.padding = const EdgeInsets.all(16)});
  final List<Color> colors;
  final Widget child;
  final VoidCallback? onTap;
  final double radius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    Widget bubble(double size, double alpha) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [Colors.white.withValues(alpha: alpha), Colors.white.withValues(alpha: 0)])),
        );
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [BoxShadow(color: colors.first.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 8))],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors)),
          child: InkWell(
            onTap: onTap,
            child: Stack(children: [
              // light bubbles in the right corner
              Positioned(right: -36, top: -46, child: IgnorePointer(child: bubble(150, 0.30))),
              Positioned(right: 54, bottom: -40, child: IgnorePointer(child: bubble(90, 0.18))),
              // a ring, like light on glass
              Positioned(
                right: -18,
                bottom: -30,
                child: IgnorePointer(
                  child: Container(width: 110, height: 110, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white.withValues(alpha: 0.16), width: 1.5))),
                ),
              ),
              // the glossy top half
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.center,
                        colors: [Colors.white.withValues(alpha: 0.18), Colors.white.withValues(alpha: 0)],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(padding: padding, child: child),
            ]),
          ),
        ),
      ),
    );
  }
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
