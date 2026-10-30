import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

// The app's motion (founder's reference video, 29 Oct 2026): a page arrives with a soft fade and a short rise, its sections build in
// one after another, toasts are a dark pill that rises from the bottom, and a dialog blurs and dims the page behind it while it
// fades and grows in. Everything is short (under half a second) and is switched off when the phone asks for less motion.

/// The phone's "remove animations" setting.
bool reduceMotion(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

const _ease = Curves.easeOutCubic;

// ---------------------------------------------------------------------------------------------------------------- pages
/// Page change: the new page fades in while rising a little; the page underneath fades back. Used for every route (the theme's
/// pageTransitionsTheme).
class OlPageTransitionsBuilder extends PageTransitionsBuilder {
  const OlPageTransitionsBuilder();
  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    if (reduceMotion(context)) return child;
    final inT = CurvedAnimation(parent: animation, curve: _ease, reverseCurve: Curves.easeInCubic);
    final outT = CurvedAnimation(parent: secondaryAnimation, curve: _ease);
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.6).animate(outT),
      child: FadeTransition(
        opacity: inT,
        child: SlideTransition(position: Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero).animate(inT), child: child),
      ),
    );
  }
}

/// The theme's page transitions, the same on every platform.
const olPageTransitions = PageTransitionsTheme(builders: {
  TargetPlatform.android: OlPageTransitionsBuilder(),
  TargetPlatform.iOS: OlPageTransitionsBuilder(),
  TargetPlatform.macOS: OlPageTransitionsBuilder(),
  TargetPlatform.windows: OlPageTransitionsBuilder(),
  TargetPlatform.linux: OlPageTransitionsBuilder(),
  TargetPlatform.fuchsia: OlPageTransitionsBuilder(),
});

// ---------------------------------------------------------------------------------------------------------------- sections
/// One section building in: it fades in and rises 24 px, [index] steps after the page's first section (60 ms a step, at most 8
/// steps, so a long list never waits). It plays once, when the section first appears; rebuilding does not replay it.
class Entrance extends StatefulWidget {
  const Entrance({super.key, required this.index, required this.child});
  final int index;
  final Widget child;
  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance> with SingleTickerProviderStateMixin {
  static const _step = 60, _run = 420;
  late final int _delay = math.min(widget.index, 8) * _step;
  late final AnimationController _c = AnimationController(vsync: this, duration: Duration(milliseconds: _delay + _run));
  // the delay is the start of the same animation (no timers), so nothing is left running when the page closes
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: Interval(_delay / (_delay + _run), 1, curve: _ease));
  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.isAnimating || _c.isCompleted || _still) return;
    if (reduceMotion(context)) {
      _still = true;
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _t,
        child: widget.child,
        builder: (_, child) => Opacity(
          opacity: _t.value,
          child: Transform.translate(offset: Offset(0, 24 * (1 - _t.value)), child: child),
        ),
      );
}

/// [children] building in one after another (see [Entrance]).
List<Widget> staggered(List<Widget> children) => [for (final (i, c) in children.indexed) Entrance(index: i, child: c)];

// ---------------------------------------------------------------------------------------------------------------- dialogs
/// A dialog that blurs and dims the page behind it and fades and grows in. Takes what [showDialog] takes here.
Future<T?> showOlDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
  String? barrierLabel,
  RouteSettings? routeSettings,
}) {
  final calm = reduceMotion(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierLabel ?? MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent, // the blur layer below dims instead
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    transitionDuration: Duration(milliseconds: calm ? 0 : 260),
    pageBuilder: (ctx, _, _) => SafeArea(child: Builder(builder: builder)),
    transitionBuilder: (ctx, a, _, child) {
      final t = CurvedAnimation(parent: a, curve: _ease, reverseCurve: Curves.easeInCubic);
      return Stack(children: [
        // taps go through to the barrier underneath, which closes the dialog
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: t,
              builder: (_, _) => BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 6 * t.value, sigmaY: 6 * t.value),
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.28 * t.value)),
              ),
            ),
          ),
        ),
        FadeTransition(
          opacity: t,
          child: ScaleTransition(scale: Tween<double>(begin: 0.94, end: 1).animate(t), child: child),
        ),
      ]);
    },
  );
}

// ---------------------------------------------------------------------------------------------------------------- numbers
/// A number that counts up to [value] when it first shows, and glides to a new value when it changes (the reference video's stat
/// tiles). [format] writes it (whole numbers by default); [textKey] goes on the Text, so a test finds the final value after settling.
class CountUp extends StatelessWidget {
  const CountUp(this.value, {super.key, required this.style, this.format, this.textKey, this.duration = const Duration(milliseconds: 700)});
  final num value;
  final TextStyle style;
  final String Function(num v)? format;
  final Key? textKey;
  final Duration duration;
  @override
  Widget build(BuildContext context) {
    String write(num v) => format == null ? '${v.round()}' : format!(v);
    if (reduceMotion(context)) return Text(write(value), key: textKey, style: style);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value.toDouble()),
      duration: duration,
      curve: _ease,
      // the last frame writes the exact value (no rounding drift for money)
      builder: (_, v, _) => Text(v == value.toDouble() ? write(value) : write(v), key: textKey, style: style),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------- bars
/// A bar that fills to [fraction] (0 to 1) when it first shows and glides when it changes.
class FillBar extends StatelessWidget {
  const FillBar({super.key, required this.fraction, required this.color, required this.track, this.height = 7, this.radius = 8});
  final double fraction;
  final Color color, track;
  final double height, radius;
  @override
  Widget build(BuildContext context) {
    final to = fraction.isNaN ? 0.0 : fraction.clamp(0.0, 1.0);
    Widget bar(double f) => ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: SizedBox(
            height: height,
            child: Stack(fit: StackFit.expand, children: [
              ColoredBox(color: track),
              FractionallySizedBox(alignment: Alignment.centerLeft, widthFactor: f, child: ColoredBox(color: color)),
            ]),
          ),
        );
    if (reduceMotion(context)) return bar(to);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: to),
      duration: const Duration(milliseconds: 650),
      curve: _ease,
      builder: (_, f, _) => bar(f),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------- swaps
/// One part of the page swapped for another (a tab's content, the picked row's details): the old fades out while the new fades in
/// and rises a little. Give [child] a key that changes with what it shows.
class SwapFade extends StatelessWidget {
  const SwapFade({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if (reduceMotion(context)) return child;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: _ease,
      switchOutCurve: Curves.easeInCubic,
      // the new part on top, both from the top edge, so a shorter part does not jump
      layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(position: Tween<Offset>(begin: const Offset(0, 0.02), end: Offset.zero).animate(a), child: child),
      ),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------- tabs
/// Tabs of equal width whose highlight slides to the picked one (the reference video's side rail and segmented switches).
/// [builder] draws tab i's label (selected or not); [highlight] is the moving pill.
class SlidingTabs extends StatelessWidget {
  const SlidingTabs({super.key, required this.count, required this.selected, required this.onSelect, required this.builder, required this.highlight,
      this.height = 40, this.keyOf});
  final int count, selected;
  final ValueChanged<int> onSelect;
  final Widget Function(BuildContext context, int i, bool selected) builder;
  final Widget highlight;
  final double height;
  /// Each tab's key (tests and Semantics find a tab by it).
  final Key Function(int i)? keyOf;
  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth / count;
          return Stack(children: [
            AnimatedPositioned(
              duration: reduceMotion(context) ? Duration.zero : const Duration(milliseconds: 300),
              curve: _ease,
              left: w * selected,
              top: 0,
              bottom: 0,
              width: w,
              child: highlight,
            ),
            Row(children: [
              for (var i = 0; i < count; i++)
                Expanded(
                  child: InkWell(
                    key: keyOf?.call(i),
                    borderRadius: BorderRadius.circular(height / 2),
                    onTap: () => onSelect(i),
                    child: Center(child: builder(context, i, i == selected)),
                  ),
                ),
            ]),
          ]);
        }),
      );
}
