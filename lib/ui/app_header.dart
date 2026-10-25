import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_nav.dart';
import 'theme.dart';

const _tintLeft = Color(0xFFE9F2E5);
const _tintRight = Color(0xFFF6F9F4);
const _ring = Color(0xFFE1E8DD);

/// The one top banner every screen uses (founder, 22 Oct 2026): a soft green card with the side menu ☰ in the left corner (a back
/// arrow instead on a page that can go back), a small caps line over a bold name, then the bell and the profile icon on the right.
/// Main screens pass [kicker] "OneLocal Partner" and the store's name as [title], with the outlet and its status as [subtitle]; inner
/// pages leave [kicker] to default to the store's name ([HomeNav.storeName]) over the page's own title.
/// ☰ opens the side menu ([HomeNav.openMenu]) unless the screen passes its own [onMenu]; the profile icon opens Manage account.
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
    this.profile = true,
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

  /// The profile icon (the person's initials) on the right; it opens Manage account when that screen is plugged in.
  final bool profile;
  final Widget? trailing;

  /// Adds the status-bar inset (for screens without a SafeArea above the header).
  final bool safeTop;

  @override
  Widget build(BuildContext context) {
    final showBack = back ?? (onBack != null || (ModalRoute.of(context)?.canPop ?? false));
    final menu = onMenu ?? (HomeNav.openMenu == null ? null : () => HomeNav.openMenu!(context));
    final top = Text((kicker ?? HomeNav.storeName ?? 'OneLocal Partner').toUpperCase(),
        maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(10, 700, color: kMuted).copyWith(letterSpacing: 0.8));
    final name = Row(children: [
      // a long store name wraps onto a second line rather than being cut off
      Flexible(child: Text(title, key: titleKey, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(17, 800, height: 1.15))),
      if (onTitle != null) ...[const SizedBox(width: 2), const Icon(LucideIcons.chevronDown, size: 16, color: kInk)],
    ]);
    final account = profile ? HomeNav.account : null;
    return Container(
      color: kBg,
      padding: EdgeInsets.fromLTRB(10, (safeTop ? MediaQuery.paddingOf(context).top : 0) + 6, 10, 4),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _ring),
          gradient: const LinearGradient(colors: [_tintLeft, _tintRight], begin: Alignment.centerLeft, end: Alignment.centerRight),
        ),
        child: Stack(children: [
          // the lighter sweep on the right of the card
          Positioned(right: -70, top: -60, bottom: -60, width: 260, child: DecoratedBox(decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.55), shape: BoxShape.circle))),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 7, 8, 7), // compact (founder, 22 Oct 2026)
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              if (showBack)
                _Round(icon: LucideIcons.arrowLeft, label: 'Back', onTap: onBack ?? () => Navigator.of(context).maybePop())
              else if (menu != null)
                _Round(key: menuKey, icon: LucideIcons.menu, label: 'Menu', onTap: menu)
              else
                const SizedBox(width: 4),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  top,
                  const SizedBox(height: 1),
                  if (onTitle == null) name else InkWell(onTap: onTitle, child: name),
                  if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 3), child: subtitle),
                ]),
              ),
              if (trailing != null) ...[const SizedBox(width: 6), trailing!],
              if (bell) ...[
                const SizedBox(width: 6),
                _Round(key: bellKey, icon: LucideIcons.bell, label: 'Notifications', onTap: onBell ?? () => HomeNav.go(context, HomeNav.notifications, 'Notifications')),
              ],
              if (account != null) ...[
                const SizedBox(width: 8),
                _Profile(onTap: () => account(context)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

/// A round white button on the banner (☰, back, bell).
class _Round extends StatelessWidget {
  const _Round({super.key, required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: Material(
          color: Colors.white,
          shape: const CircleBorder(side: BorderSide(color: _ring)),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: 36, height: 36, child: Icon(icon, size: 18, color: kInk)),
          ),
        ),
      );
}

/// The person's initials in a green circle; opens Manage account.
class _Profile extends StatelessWidget {
  const _Profile({required this.onTap});
  final VoidCallback onTap;

  static String _initials(String? name) {
    final parts = (name ?? '').trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty && RegExp(r'[A-Za-z]').hasMatch(p[0])).toList();
    if (parts.isEmpty) return '';
    return (parts.length == 1 ? parts.first[0] : parts.first[0] + parts.last[0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final text = _initials(HomeNav.personName);
    return Semantics(
      button: true,
      label: 'Your profile',
      excludeSemantics: true,
      child: Material(
        color: const Color(0xFF1B5E3A),
        shape: const CircleBorder(),
        child: InkWell(
          key: const ValueKey('app-header-profile'),
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Center(child: text.isEmpty ? const Icon(LucideIcons.user, size: 18, color: Colors.white) : Text(text, style: inter(13, 800, color: Colors.white))),
          ),
        ),
      ),
    );
  }
}
