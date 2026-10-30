import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_nav.dart';
import 'theme.dart';

const _tintLeft = Color(0xFFE9F2E5);
const _tintRight = Color(0xFFF6F9F4);
const _ring = Color(0xFFE1E8DD);

/// The one top banner every screen uses (founder, 22 Oct 2026): a soft green card with the side menu ☰ in the left corner (always: a
/// page that can go back gets one back arrow just under the banner, 26 Oct 2026), a small caps line over a bold name, then the bell and the profile icon on the right.
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
    this.wallet = true,
    this.profile = true,
    this.trailing,
    this.safeTop = true,
    this.backKey = const ValueKey('app-header-back'),
    this.under,
  });

  /// Key of the back arrow under the banner (screens keep the key their tests already use).
  final Key backKey;

  /// A page's small extras on the back arrow's line (a step count, a status chip, "Start over").
  final Widget? under;

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

  /// The OneLocal wallet button, beside the bell ([HomeNav.wallet]).
  final bool wallet;

  /// The profile icon (the person's initials) on the right; it opens Manage account when that screen is plugged in.
  final bool profile;
  final Widget? trailing;

  /// Adds the status-bar inset (for screens without a SafeArea above the header).
  final bool safeTop;

  @override
  Widget build(BuildContext context) {
    final showBack = back ?? (onBack != null || (ModalRoute.of(context)?.canPop ?? false));
    final menu = onMenu ?? (HomeNav.openMenu == null ? null : () => HomeNav.openMenu!(context));
    final kickerStyle = inter(10, 700, color: kMuted).copyWith(letterSpacing: 0.8);
    final kickerText = (kicker ?? HomeNav.storeName ?? 'OneLocal Partner').toUpperCase();
    // a store name too long for the line becomes its initials (founder, 28 Oct 2026): SHARMA GENERAL STORE - MAIN → SGS - MAIN
    final top = LayoutBuilder(builder: (context, c) {
      final full = TextPainter(text: TextSpan(text: kickerText, style: kickerStyle), maxLines: 1, textDirection: TextDirection.ltr, textScaler: MediaQuery.textScalerOf(context))
        ..layout(maxWidth: double.infinity);
      final text = full.width <= c.maxWidth ? kickerText : shortStoreName(kickerText);
      return Text(text, key: const ValueKey('app-header-kicker'), maxLines: 1, overflow: TextOverflow.ellipsis, style: kickerStyle);
    });
    final titleStyle = inter(17, 800, height: 1.15);
    final isStoreName = HomeNav.storeName != null && title.trim().toLowerCase() == HomeNav.storeName!.trim().toLowerCase();
    final name = Row(children: [
      // the store's name, when it is the title and too long for one line, becomes its initials too; other titles wrap onto a second line
      Flexible(
        child: LayoutBuilder(builder: (context, c) {
          var text = title;
          if (isStoreName) {
            final p = TextPainter(text: TextSpan(text: title, style: titleStyle), maxLines: 1, textDirection: TextDirection.ltr, textScaler: MediaQuery.textScalerOf(context))
              ..layout(maxWidth: double.infinity);
            if (p.width > c.maxWidth) text = shortStoreName(title);
          }
          return Text(text, key: titleKey, maxLines: 2, overflow: TextOverflow.ellipsis, style: titleStyle);
        }),
      ),
      if (onTitle != null) ...[const SizedBox(width: 2), const Icon(LucideIcons.chevronDown, size: 16, color: kInk)],
    ]);
    final account = profile ? HomeNav.account : null;
    return Container(
      color: kBg,
      padding: EdgeInsets.fromLTRB(10, (safeTop ? MediaQuery.paddingOf(context).top : 0) + 6, 10, 4),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        _card(context, menu, top, name, account),
        // the one way back, under the banner (founder, 26 Oct 2026): the banner itself always keeps ☰
        if (showBack || under != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(children: [
              if (showBack)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: IconButton(
                    key: backKey,
                    tooltip: 'Back',
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white,
                      fixedSize: const Size(40, 40),
                      minimumSize: const Size(40, 40),
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFFDADCD5))),
                    ),
                    onPressed: onBack ?? () => Navigator.of(context).maybePop(),
                    icon: const Icon(LucideIcons.arrowLeft, size: 20, color: kInk),
                  ),
                ),
              if (under != null) Expanded(child: under!),
            ]),
          ),
      ]),
    );
  }

  Widget _card(BuildContext context, VoidCallback? menu, Widget top, Widget name, void Function(BuildContext)? account) => Container(
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
              if (menu != null)
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
              // the OneLocal wallet, on every screen's banner (founder, 28 Oct 2026)
              if (wallet && HomeNav.wallet != null) ...[
                const SizedBox(width: 6),
                _Round(key: const ValueKey('app-header-wallet'), icon: LucideIcons.wallet, label: 'OneLocal wallet', onTap: () => HomeNav.wallet!(context)),
              ],
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
      );
}

/// A store's name as initials when it is too long for the banner: "SHARMA GENERAL STORE - MAIN" → "SGS - MAIN". The part after " - " or
/// " · " (the outlet) is kept; small words (and, of, the) and words without a letter are left out.
String shortStoreName(String name) {
  final m = RegExp(r'^(.*?)(\s+[-·–]\s+.*)?$').firstMatch(name.trim());
  final store = (m?.group(1) ?? name).trim(), outlet = m?.group(2) ?? '';
  const small = {'and', 'of', 'the', 'n'}; // "Wholesale and Retail" → WR
  final initials = store
      .split(RegExp(r'\s+'))
      .where((w) => RegExp(r'[A-Za-z]').hasMatch(w) && !small.contains(w.toLowerCase()))
      .map((w) => w[w.indexOf(RegExp(r'[A-Za-z]'))].toUpperCase())
      .join();
  if (initials.length < 2) return name;
  return '$initials$outlet';
}

/// A round white button on the banner (☰, wallet, bell).
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

/// The header's round white button, for a page's own [AppHeader.trailing] (for example the wallet on Page Manager).
class HeaderRound extends _Round {
  const HeaderRound({super.key, required super.icon, required super.label, required super.onTap});
}
