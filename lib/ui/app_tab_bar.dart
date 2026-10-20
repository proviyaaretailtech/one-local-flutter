import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

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

/// The one bottom bar every screen uses: same height, radius, margins, icon and label sizes everywhere. The current
/// tab ([active]) is a filled lime tile. All bars share one hero tag, so on a page change the bar stays where it is
/// while the page above it moves. [keyPrefix] keeps each caller's tab keys (for example 'tab-', 'inv-tab-').
class AppTabBar extends StatelessWidget {
  const AppTabBar({super.key, required this.tabs, required this.onTap, this.active, this.keyPrefix = 'tab-'});
  final List<AppTab> tabs;
  final String? active;
  final ValueChanged<String> onTap;
  final String keyPrefix;

  static const height = 72.0;
  static const _bar = Color(0xFF111827);
  static const _lime = Color(0xFFA1FE2F);
  // Frosted glass: the dark bar at 86% with a blur behind it and a faint light edge (founder, 20 Oct 2026).
  static const _glass = Color(0xDB111827);

  @override
  Widget build(BuildContext context) => TabShellScope.inside(context)
      ? const SizedBox.shrink()
      : SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          child: Hero(
            tag: 'app-tab-bar',
            // A pill: fully round ends, circular buttons inside.
            child: ClipRRect(
              borderRadius: BorderRadius.circular(height / 2),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Material(
                  color: _glass,
                  shape: const StadiumBorder(side: BorderSide(color: Color(0x2EFFFFFF))),
                  child: SizedBox(
                    height: height,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(children: [
                        for (final t in tabs)
                          Expanded(child: _Tab(tab: t, current: t.id == active, onTap: () => onTap(t.id), tabKey: ValueKey('$keyPrefix${t.id}'))),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
}

class _Tab extends StatelessWidget {
  const _Tab({required this.tab, required this.current, required this.onTap, required this.tabKey});
  final AppTab tab;
  final bool current;
  final VoidCallback onTap;
  final Key tabKey;
  @override
  Widget build(BuildContext context) {
    final outlined = tab.primary && !current;
    return Semantics(
      button: true,
      selected: current,
      label: tab.label,
      child: InkWell(
        key: tabKey,
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          // Circular buttons: filled lime for the current tab, a lime ring for the centre action.
          Container(
            width: 38,
            height: 38,
            decoration: current
                ? const BoxDecoration(color: AppTabBar._lime, shape: BoxShape.circle)
                : outlined
                    ? BoxDecoration(border: Border.all(color: AppTabBar._lime, width: 1.5), shape: BoxShape.circle)
                    : null,
            child: Icon(tab.icon, size: 20, color: current ? AppTabBar._bar : outlined ? AppTabBar._lime : Colors.white),
          ),
          const SizedBox(height: 4),
          ExcludeSemantics(
            child: Text(tab.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, current ? 700 : 500, color: Colors.white)),
          ),
        ]),
      ),
    );
  }
}
