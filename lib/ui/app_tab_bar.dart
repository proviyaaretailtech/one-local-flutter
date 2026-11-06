import 'package:flutter/material.dart';

import 'i18n.dart';
import 'ol_mascot.dart';
import 'theme.dart';

/// One tab of the app's bottom bar. [primary] is the centre action (Bill / POS): a lime outline when it is not the
/// current tab, so it stands out without looking selected.
class AppTab {
  const AppTab(this.id, this.label, this.icon, {this.primary = false});
  final String id, label;
  final IconData icon;
  final bool primary;
}

/// Marks the pages inside the app shell: there the shell draws the one bar, so a page's own [AppTabBar] draws nothing.
class TabShellScope extends InheritedWidget {
  const TabShellScope({super.key, required super.child});
  static bool inside(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TabShellScope>() != null;
  @override
  bool updateShouldNotify(TabShellScope old) => false;
}

/// The one bottom bar every screen uses, for every kind of business (founder's Pinterest reference, 4 Nov 2026, first on the Service POS; on
/// the store and restaurant too, 6 Nov 2026): the picked tab's icon lifts out of the bar into a lime bubble, and a smooth dip in the bar's top
/// edge slides under it to the next tab with a small overshoot. Tabs shrink a little while pressed. All bars share one hero tag, so on a page
/// change the bar stays where it is while the page above it moves. [keyPrefix] keeps each caller's tab keys (for example 'tab-', 'inv-tab-').
class AppTabBar extends StatelessWidget {
  const AppTabBar({super.key, required this.tabs, required this.onTap, this.active, this.keyPrefix = 'tab-', this.trailing});
  final List<AppTab> tabs;

  /// One more slot after the tabs, as wide as a tab (Ol, the helper or guide, goes here).
  final Widget? trailing;
  final String? active;
  final ValueChanged<String> onTap;
  final String keyPrefix;

  static const height = 72.0;
  static const _lift = 10.0; // how far the bubble peeks above the bar (founder, 4 Nov 2026: lower, closer to its name)
  static const _bubble = 46.0;
  static const _inset = 18.0; // tabs sit this far in, so the dip never reaches the round ends
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
    final index = tabs.indexWhere((t) => t.id == active);
    final slots = tabs.length + (trailing == null ? 0 : 1);
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Hero(
        tag: 'app-tab-bar',
        child: Material(
          type: MaterialType.transparency,
          child: SizedBox(
            height: height + _lift,
            child: LayoutBuilder(builder: (context, box) {
              final slot = (box.maxWidth - 2 * _inset) / slots;
              double centre(double i) => _inset + slot * i + slot / 2;
              // the tabs are built once; only the bar's shape and the bubble move, each frame (a moving blur made the glide stutter)
              final row = Padding(
                padding: const EdgeInsets.symmetric(horizontal: _inset),
                child: Row(children: [
                  for (final (i, t) in tabs.indexed) Expanded(child: _Tab(tab: t, current: i == index, onTap: () => onTap(t.id), tabKey: ValueKey('$keyPrefix${t.id}'))),
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
                            key: ValueKey('${keyPrefix}bubble'),
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
                              child: Icon(tabs[index].icon, key: ValueKey(tabs[index].id), size: 20, color: _bar),
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
      ),
    );
  }
}

/// The pill with a smooth dip in its top edge at [cx].
Path _barPath(Size size, double cx, double depth) {
  final pill = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(30)));
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
    canvas.drawPath(path, Paint()..color = AppTabBar._glass);
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
  const _Tab({required this.tab, required this.current, required this.onTap, required this.tabKey});
  final AppTab tab;
  final bool current;
  final VoidCallback onTap;
  final Key tabKey;
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
    // The kept slot (a tab with no label) is Ol's place (founder, 27 Oct 2026): OneLocal's helper, who opens what the vendor asks for.
    // as tall as a tab's button and name together, so it sits level with the other icons (founder, 28 Oct 2026)
    if (t.label.isEmpty) return Center(child: OlMascot(key: widget.tabKey, size: 58));
    final outlined = t.primary && !current;
    return Semantics(
      button: true,
      selected: current,
      label: tr(t.label),
      child: GestureDetector(
        key: widget.tabKey,
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
                  decoration: outlined ? BoxDecoration(border: Border.all(color: AppTabBar._lime, width: 1.5), shape: BoxShape.circle) : null,
                  child: Icon(t.icon, size: 20, color: outlined ? AppTabBar._lime : Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 4),
            // a long name ("Online order", or its Hindi) shrinks a little to fit its fifth of the bar instead of being cut with "…"
            ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 280),
                    style: inter(11, current ? 700 : 500, color: current ? AppTabBar._lime : Colors.white),
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
