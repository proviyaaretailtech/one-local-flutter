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
