import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';
import 'control_centre_screen.dart' show initials;
import 'home_nav.dart';
import 'home_widgets.dart';

/// One row of the side nav. [open] is null when the screen is not built yet: the row is then
/// greyed with a "Soon" tag instead of looking live and answering with a toast (control rule).
class SideNavEntry {
  const SideNavEntry(this.icon, this.label, this.open);
  final IconData icon;
  final String label;
  final VoidCallback? open;
}

/// Figma section D "side Nav bar" (39:7416), store: profile, module list, Manage account, Sign out.
/// Slides in from the left over a dimmed screen; tapping outside closes it.
Future<void> showStoreSideNav(
  BuildContext context, {
  required String name,
  String? email,
  required VoidCallback onDashboard,
  required VoidCallback onReports,
  required VoidCallback onSignOut,
}) {
  // Each entry opens through its HomeNav hook; an unplugged hook makes the row "Soon".
  VoidCallback? hook(HomeRoute? r) => r == null ? null : () => r(context);
  final entries = [
    SideNavEntry(LucideIcons.layoutDashboard, 'Dashboard', onDashboard),
    SideNavEntry(LucideIcons.store, 'Store POS', hook(HomeNav.bill)),
    SideNavEntry(LucideIcons.bookOpen, 'Catalogue', hook(HomeNav.items)),
    SideNavEntry(LucideIcons.package, 'GRN', hook(HomeNav.grn)),
    SideNavEntry(LucideIcons.clipboardList, 'Stock management', hook(HomeNav.stock)),
    SideNavEntry(LucideIcons.qrCode, 'All Orders', hook(HomeNav.orderHistory ?? HomeNav.orders)),
    // No wallet or customer screen on this line yet (built in their own sections): they stay "Soon".
    const SideNavEntry(LucideIcons.wallet, 'One Local Wallet', null),
    SideNavEntry(LucideIcons.indianRupee, 'Money', hook(HomeNav.money)),
    const SideNavEntry(LucideIcons.circleUser, 'Customer', null),
    // Founder flow (19 Oct 2026): Team, the OneLocal page, Reports, Settings and Help live in this menu.
    SideNavEntry(LucideIcons.users, 'Team', hook(HomeNav.team)),
    SideNavEntry(LucideIcons.globe, 'OneLocal page', hook(HomeNav.storefront)),
    SideNavEntry(LucideIcons.fileText, 'Reports', onReports),
    SideNavEntry(LucideIcons.settings, 'Settings', hook(HomeNav.settings ?? HomeNav.setup)),
    SideNavEntry(LucideIcons.circleQuestionMark, 'Help & support', hook(HomeNav.support)),
  ];
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close menu',
    barrierColor: const Color(0x66000000),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, _, __) => Align(
      alignment: Alignment.centerLeft,
      child: _StoreSideNav(
        name: name,
        email: email,
        entries: entries,
        onSignOut: onSignOut,
      ),
    ),
    transitionBuilder: (ctx, anim, _, child) => SlideTransition(
      position: Tween(begin: const Offset(-1, 0), end: Offset.zero).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

class _StoreSideNav extends StatelessWidget {
  const _StoreSideNav({required this.name, required this.email, required this.entries, required this.onSignOut});
  final String name;
  final String? email;
  final List<SideNavEntry> entries;
  final VoidCallback onSignOut;

  // Close the panel first, then open the screen from the page underneath.
  void _go(BuildContext context, VoidCallback open) {
    Navigator.of(context).pop();
    open();
  }

  @override
  Widget build(BuildContext context) {
    final width = (MediaQuery.sizeOf(context).width * 0.78).clamp(260.0, 320.0);
    return Material(
      key: const ValueKey('side-nav'),
      color: Colors.white,
      borderRadius: const BorderRadius.horizontal(right: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        height: double.infinity,
        child: SafeArea(
          right: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // Profile: initials stand in for the photo the Figma frame shows.
              Row(children: [
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(color: kLime, shape: BoxShape.circle),
                  child: Text(initials(name), style: inter(16, 700, color: kNavy)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, style: inter(15, 700), maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (email != null && email!.isNotEmpty) Text(email!, style: inter(12, 400, color: kMuted), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ]),
                ),
              ]),
              const SizedBox(height: 14),
              const Divider(height: 1, color: kLine),
              const SizedBox(height: 10),
              Expanded(
                child: ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    return _NavRow(
                      icon: e.icon,
                      label: e.label,
                      soon: e.open == null,
                      onTap: e.open == null ? null : () => _go(context, e.open!),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              const _NavRow(icon: LucideIcons.user, label: 'Manage account', soon: true, onTap: null, light: true),
              const SizedBox(height: 8),
              _NavRow(icon: LucideIcons.logOut, label: 'Sign out', danger: true, onTap: () => _go(context, onSignOut)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({required this.icon, required this.label, required this.onTap, this.soon = false, this.danger = false, this.light = false});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool soon, danger, light;

  @override
  Widget build(BuildContext context) {
    final fg = danger ? kRed : soon ? kMuted : kInk;
    final bg = danger ? const Color(0xFFFEF2F2) : light ? const Color(0xFFF9FAFB) : const Color(0xFFF3F4EE);
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: soon ? '$label, coming soon' : label,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Icon(icon, size: 20, color: fg),
              const SizedBox(width: 14),
              Expanded(child: Text(label, style: inter(13, 600, color: fg))),
              if (soon)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: const Color(0xFFFEF0C7), borderRadius: BorderRadius.circular(10)),
                  child: Text('Soon', style: inter(10, 700, color: const Color(0xFFB54708))),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
