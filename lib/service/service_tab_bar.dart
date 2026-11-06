import 'package:flutter/material.dart';

import '../home/home_widgets.dart' show BarTab;
import '../ui/app_tab_bar.dart' show AppTab, AppTabBar;

/// The Service POS bottom bar: the app's one interactive bar ([AppTabBar]) with the service tabs and Ol the guide.
class ServiceTabBar extends StatelessWidget {
  const ServiceTabBar({super.key, required this.tabs, required this.onTap, this.current, this.trailing});
  final List<BarTab> tabs;
  final ValueChanged<String> onTap;
  final String? current;

  /// After the tabs: Ol, the guide.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => AppTabBar(
        tabs: [for (final t in tabs) AppTab(t.label, t.label, t.icon, primary: t.hero)],
        active: current,
        onTap: onTap,
        trailing: trailing,
      );
}
