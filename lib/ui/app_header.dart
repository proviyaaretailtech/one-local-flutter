import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_nav.dart';
import 'theme.dart';

const _square = Color(0xFFF3F4F6);

/// The one top banner every screen uses, in the dashboard's layout (founder, 20 Oct 2026): a back arrow when there is a
/// page to go back to, a small grey line over the page's name in bold, then the bell and ☰ on the right.
/// [kicker] defaults to the store's name ([HomeNav.storeName]); [subtitle] sits under the title (the outlet's status).
/// ☰ opens the side menu from any screen ([HomeNav.openMenu]) unless the screen passes its own [onMenu].
class AppHeader extends StatelessWidget {
  const AppHeader({
    super.key,
    required this.title,
    this.kicker,
    this.subtitle,
    this.onTitle,
    this.titleKey,
    this.onBack,
    this.back,
    this.onMenu,
    this.menuKey = const ValueKey('app-header-menu'),
    this.onBell,
    this.bellKey = const ValueKey('app-header-bell'),
    this.bell = true,
    this.trailing,
    this.safeTop = true,
  });

  final String title;
  final String? kicker;
  final Widget? subtitle;

  /// Tapping the title (for example, the outlet switcher); a ▾ shows next to it.
  final VoidCallback? onTitle;
  final Key? titleKey;

  /// What back does; by default the page closes. [back] forces the arrow on or off (default: shown when a page is open below).
  final VoidCallback? onBack;
  final bool? back;
  final VoidCallback? onMenu;
  final Key menuKey;
  final VoidCallback? onBell;
  final Key bellKey;
  final bool bell;
  final Widget? trailing;

  /// Adds the status-bar inset (for screens without a SafeArea above the header).
  final bool safeTop;

  @override
  Widget build(BuildContext context) {
    final showBack = back ?? (onBack != null || (ModalRoute.of(context)?.canPop ?? false));
    final menu = onMenu ?? (HomeNav.openMenu == null ? null : () => HomeNav.openMenu!(context));
    final top = Text((kicker ?? HomeNav.storeName ?? 'OneLocal').toUpperCase(),
        maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 700, color: kMuted).copyWith(letterSpacing: 0.8));
    final name = Row(children: [
      Flexible(child: Text(title, key: titleKey, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(18, 700))),
      if (onTitle != null) const Icon(LucideIcons.chevronDown, size: 18, color: kInk),
    ]);
    return Container(
      padding: EdgeInsets.fromLTRB(12, (safeTop ? MediaQuery.paddingOf(context).top : 0) + 10, 12, 10),
      decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: kLine))),
      child: Row(children: [
        if (showBack) ...[
          _Square(
            icon: LucideIcons.arrowLeft,
            label: 'Back',
            circle: true,
            onTap: onBack ?? () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 10),
        ] else
          const SizedBox(width: 4),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            top,
            const SizedBox(height: 2),
            if (onTitle == null) name else InkWell(onTap: onTitle, child: name),
            if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 2), child: subtitle),
          ]),
        ),
        if (trailing != null) ...[const SizedBox(width: 6), trailing!],
        if (bell)
          Semantics(
            button: true,
            label: 'Notifications',
            excludeSemantics: true,
            child: IconButton(
              key: bellKey,
              onPressed: onBell ?? () => HomeNav.go(context, HomeNav.notifications, 'Notifications'),
              icon: const Icon(LucideIcons.bell, size: 22, color: kInk),
            ),
          ),
        if (menu != null) ...[const SizedBox(width: 2), _Square(key: menuKey, icon: LucideIcons.menu, label: 'Menu', onTap: menu)],
      ]),
    );
  }
}

class _Square extends StatelessWidget {
  const _Square({super.key, required this.icon, required this.label, required this.onTap, this.circle = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool circle;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          customBorder: circle ? const CircleBorder() : RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          onTap: onTap,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: _square, shape: circle ? BoxShape.circle : BoxShape.rectangle, borderRadius: circle ? null : BorderRadius.circular(12)),
            child: Icon(icon, size: 20, color: kInk),
          ),
        ),
      );
}
