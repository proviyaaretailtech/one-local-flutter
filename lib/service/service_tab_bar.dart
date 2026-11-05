import 'package:flutter/material.dart';

import '../home/home_widgets.dart' show BarTab;
import '../ui/app_tab_bar.dart' show AppTabBar, TabShellScope;
import '../ui/i18n.dart';
import '../ui/theme.dart';

// The Service POS bottom bar, made interactive (founder's Pinterest reference, 4 Nov 2026): the picked tab's icon lifts out of the bar
// into a lime bubble, and a smooth dip in the bar's top edge slides under it to the next tab with a small overshoot. Tabs shrink a little
// while pressed. Same frosted navy pill, size and keys ('tab-Home' ...) as the shared bar; the store and restaurant bars are untouched.

class ServiceTabBar extends StatelessWidget {
  const ServiceTabBar({super.key, required this.tabs, required this.onTap, this.current, this.trailing});
  final List<BarTab> tabs;
  final ValueChanged<String> onTap;
  final String? current;

  /// After the tabs: Ol, the guide.
  final Widget? trailing;

  static const _lift = 10.0; // how far the bubble peeks above the bar (founder, 4 Nov 2026: lower, closer to its name)
  static const _bubble = 46.0;
  static const _inset = 18.0; // tabs sit this far in, so the dip never reaches the round ends
  static const _radius = 30.0;
  // a calm glide with a soft settle, not a snap (founder, 4 Nov 2026: slower, but not slow)
  static const _glide = Duration(milliseconds: 800);
  static const _sink = Duration(milliseconds: 450);
  static const _ease = Cubic(0.34, 1.28, 0.64, 1);
  static const _bar = Color(0xFF111827);
  static const _glass = Color(0xF2111827); // nearly solid: no blur behind it
  static const _lime = Color(0xFFA1FE2F);

  @override
  Widget build(BuildContext context) {
    if (TabShellScope.inside(context)) return const SizedBox.shrink();
    final index = tabs.indexWhere((t) => t.label == current);
    final slots = tabs.length + (trailing == null ? 0 : 1);
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Hero(
        tag: 'app-tab-bar',
        child: SizedBox(
          height: AppTabBar.height + _lift,
          child: LayoutBuilder(builder: (context, box) {
            final slot = (box.maxWidth - 2 * _inset) / slots;
            double centre(double i) => _inset + slot * i + slot / 2;
            // the tabs are built once; only the bar's shape and the bubble move, each frame (a moving blur made the glide stutter)
            final row = Padding(
              padding: const EdgeInsets.symmetric(horizontal: _inset),
              child: Row(children: [
                for (final (i, t) in tabs.indexed) Expanded(child: _Tab(tab: t, current: i == index, onTap: () => onTap(t.label))),
                if (trailing != null) Expanded(child: trailing!),
              ]),
            );
            // the dip and the bubble glide to the picked tab together; with no tab picked (a page Ol opened) they sink away
            return Stack(clipBehavior: Clip.none, children: [
              Positioned.fill(
                top: _lift,
                child: RepaintBoundary(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: index < 0 ? 0 : index.toDouble()),
                    duration: _glide,
                    curve: _ease,
                    builder: (context, at, _) => TweenAnimationBuilder<double>(
                      tween: Tween(end: index < 0 ? 0 : 1),
                      duration: _sink,
                      curve: Curves.easeOutCubic,
                      builder: (context, shown, _) => CustomPaint(painter: _BarPainter(cx: centre(at), depth: 17 * shown), size: Size.infinite),
                    ),
                  ),
                ),
              ),
              Positioned.fill(top: _lift, child: row),
              if (index >= 0)
                Positioned.fill(
                  child: IgnorePointer(
                    child: RepaintBoundary(
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(end: index.toDouble()),
                        duration: _glide,
                        curve: _ease,
                        builder: (context, at, bubble) => TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: 1),
                          duration: _sink,
                          curve: Curves.easeOutCubic,
                          builder: (context, shown, _) => Stack(clipBehavior: Clip.none, children: [
                            Positioned(
                              left: centre(at) - _bubble / 2,
                              top: (_lift - 2) * (1 - shown),
                              child: Opacity(opacity: shown.clamp(0, 1), child: bubble),
                            ),
                          ]),
                        ),
                        child: Container(
                          key: const ValueKey('tab-bubble'),
                          width: _bubble,
                          height: _bubble,
                          decoration: BoxDecoration(
                            color: _lime,
                            shape: BoxShape.circle,
                            border: Border.all(color: _bar, width: 4),
                            boxShadow: const [BoxShadow(color: Color(0x55A1FE2F), blurRadius: 14, offset: Offset(0, 4))],
                          ),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 380),
                            transitionBuilder: (child, a) => ScaleTransition(
                              scale: Tween(begin: 0.4, end: 1.0).animate(CurvedAnimation(parent: a, curve: _ease)),
                              child: RotationTransition(turns: Tween(begin: -0.12, end: 0.0).animate(a), child: child),
                            ),
                            child: Icon(tabs[index].icon, key: ValueKey(tabs[index].label), size: 20, color: _bar),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ]);
          }),
        ),
      ),
    );
  }
}

/// The pill with a smooth dip in its top edge at [cx].
Path _barPath(Size size, double cx, double depth) {
  final pill = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(ServiceTabBar._radius)));
  if (depth <= 0.5) return pill;
  const half = 34.0;
  final dip = Path()
    ..moveTo(cx - half, -1)
    ..cubicTo(cx - half * 0.55, -1, cx - half * 0.62, depth, cx, depth)
    ..cubicTo(cx + half * 0.62, depth, cx + half * 0.55, -1, cx + half, -1)
    ..close();
  return Path.combine(PathOperation.difference, pill, dip);
}

/// The navy fill and its faint light edge, following the dip.
class _BarPainter extends CustomPainter {
  const _BarPainter({required this.cx, required this.depth});
  final double cx, depth;
  @override
  void paint(Canvas canvas, Size size) {
    final path = _barPath(size, cx, depth);
    canvas.drawPath(path, Paint()..color = ServiceTabBar._glass);
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0x2EFFFFFF));
  }

  @override
  bool shouldRepaint(_BarPainter old) => old.cx != cx || old.depth != depth;
}

class _Tab extends StatefulWidget {
  const _Tab({required this.tab, required this.current, required this.onTap});
  final BarTab tab;
  final bool current;
  final VoidCallback onTap;
  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  bool _down = false;

  void _press(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tab;
    final current = widget.current;
    final outlined = t.hero && !current;
    return Semantics(
      button: true,
      selected: current,
      label: tr(t.label),
      child: GestureDetector(
        key: ValueKey('tab-${t.label}'),
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _press(true),
        onTapCancel: () => _press(false),
        onTapUp: (_) => _press(false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? 0.86 : 1,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            // the picked tab's icon has lifted into the bubble above; its place stays so the names line up
            AnimatedOpacity(
              duration: const Duration(milliseconds: 260),
              opacity: current ? 0 : 1,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 380),
                curve: Curves.easeOutBack,
                offset: current ? const Offset(0, -0.6) : Offset.zero,
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: outlined ? BoxDecoration(border: Border.all(color: ServiceTabBar._lime, width: 1.5), shape: BoxShape.circle) : null,
                  child: Icon(t.icon, size: 20, color: outlined ? ServiceTabBar._lime : Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 4),
            ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 280),
                    style: inter(11, current ? 700 : 500, color: current ? ServiceTabBar._lime : Colors.white),
                    child: Text(tr(t.label), maxLines: 1, softWrap: false),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
