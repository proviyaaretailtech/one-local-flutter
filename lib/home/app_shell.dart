import 'package:flutter/material.dart';

import '../ui/app_tab_bar.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'home_nav.dart';
import 'home_widgets.dart';

/// Builds a tab's first screen for a business kind ('store', 'restaurant', 'service'); null when the tab has no screen
/// yet (the bar then says it opens in a later release).
typedef ShellRoot = Widget? Function(String kind, String label);

/// The app shell: one bottom bar that never moves, and a back stack per tab under it. A tab's stack is built the first
/// time it is opened and kept, so switching tabs returns to where you were; tapping the current tab goes back to its
/// first screen. Pages inside draw no bar of their own ([TabShellScope]). Back pops inside the tab, then goes Home,
/// then leaves the shell.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.rootFor, this.initialKind});
  final ShellRoot rootFor;
  final String? initialKind;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with SingleTickerProviderStateMixin implements TabShell {
  /// Switching tabs (founder's reference video, 29 Oct 2026): the tab you open fades in and rises, like a page arriving.
  late final AnimationController _swap = AnimationController(vsync: this, duration: const Duration(milliseconds: 380), value: 1);
  late final Animation<double> _swapT = CurvedAnimation(parent: _swap, curve: Curves.easeOutCubic);

  void _playSwap() {
    if (!reduceMotion(context)) _swap.forward(from: 0);
  }

  late String _kind = _known(widget.initialKind ?? HomeNav.partnerType);
  String _current = 'Home';
  final _navigators = <String, GlobalKey<NavigatorState>>{};
  final _opened = <String>{'Home'};
  // Sheets and dialogs open inside a tab, under the bar; while one is up in the current tab the bar steps aside so the
  // sheet reaches the bottom of the screen and the dialog's dimming covers everything.
  final _popups = <String, int>{};
  final _observers = <String, _PopupWatch>{};

  _PopupWatch _watch(String label) => _observers.putIfAbsent(
        label,
        () => _PopupWatch((delta) {
          _popups[label] = ((_popups[label] ?? 0) + delta).clamp(0, 99);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }),
      );

  static String _known(String? k) => k == 'restaurant' || k == 'service' ? k! : 'store';
  List<BarTab> get _tabs => _kind == 'restaurant' ? kHubTabs : kStoreTabs;

  @override
  void initState() {
    super.initState();
    HomeNav.shell = this;
    // the store's language (Settings → Me & app): every screen shows in it from the start
    HomeNav.loadLanguage?.call();
  }

  @override
  void dispose() {
    _swap.dispose();
    if (HomeNav.shell == this) HomeNav.shell = null;
    super.dispose();
  }

  @override
  String get kind => _kind;

  /// The Home screen learns the business kind when its summary loads; the bar then shows that kind's tabs.
  @override
  void setKind(String kind) {
    final k = _known(kind);
    if (k == _kind || !mounted) return;
    setState(() {
      _kind = k;
      _current = 'Home';
      _opened.removeWhere((l) => l != 'Home');
      _navigators.removeWhere((l, _) => l != 'Home');
    });
  }

  @override
  bool show(String label) {
    if (!mounted || !_tabs.any((t) => t.label == label) || widget.rootFor(_kind, label) == null) return false;
    // Anything opened over the shell (setup, a full-screen page) closes first.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) Navigator.of(context).popUntil((r) => r == route);
    if (label == _current) {
      _navigators[label]?.currentState?.popUntil((r) => r.isFirst);
    } else {
      setState(() {
        _current = label;
        _opened.add(label);
      });
      _playSwap();
    }
    return true;
  }

  void _tap(String label) {
    if (!show(label)) HomeNav.go(context, null, label);
  }

  void _back() {
    final nav = _navigators[_current]?.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
    } else if (_current != 'Home') {
      setState(() => _current = 'Home');
      _playSwap();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    final index = tabs.indexWhere((t) => t.label == _current);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: kBg,
        body: TabShellScope(
          child: AnimatedBuilder(
            animation: _swapT,
            builder: (_, child) => Opacity(
              opacity: 0.15 + 0.85 * _swapT.value,
              child: Transform.translate(offset: Offset(0, 28 * (1 - _swapT.value)), child: child),
            ),
            child: IndexedStack(
            index: index < 0 ? 0 : index,
            children: [
              for (final t in tabs)
                _opened.contains(t.label)
                    ? Navigator(
                        key: _navigators.putIfAbsent(t.label, GlobalKey<NavigatorState>.new),
                        observers: [_watch(t.label)],
                        onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => widget.rootFor(_kind, t.label) ?? const SizedBox.shrink()),
                      )
                    : const SizedBox.shrink(),
            ],
          ),
          ),
        ),
        bottomNavigationBar: (_popups[_current] ?? 0) > 0 ? null : FloatingTabBar(tabs: tabs, onTap: _tap, current: _current),
      ),
    );
  }
}

/// Counts the sheets and dialogs (popup routes) open in one tab.
class _PopupWatch extends NavigatorObserver {
  _PopupWatch(this.changed);
  final void Function(int delta) changed;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) changed(1);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) changed(-1);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) changed(-1);
  }
}
