import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';
import 'control_centre_screen.dart' show initials;
import 'home_nav.dart';
import 'home_widgets.dart';

/// One row of the side nav. [open] is null when the screen is not built yet: the row is then
/// greyed with a "Soon" tag instead of looking live and answering with a toast (control rule).
class SideNavEntry {
  const SideNavEntry(this.icon, this.label, this.open, {this.children = const []});
  final IconData icon;
  final String label;
  final VoidCallback? open;

  /// Sub-pages shown right under this row in the menu itself (Stock management's three sections).
  final List<SideNavEntry> children;
}

/// Figma section D "side Nav bar" (39:7416), store: profile, module list, Manage account, Sign out.
/// Slides in from the left over a dimmed screen; tapping outside closes it.
Future<void> showStoreSideNav(
  BuildContext context, {
  required String name,
  String? email,
  required VoidCallback onReports,
  required VoidCallback onSignOut,
}) {
  // Each entry opens through its HomeNav hook; an unplugged hook makes the row "Soon".
  VoidCallback? hook(HomeRoute? r) => r == null ? null : () => r(context);
  // Ordered by how often a shop needs them, daily tools first and the set-up-once pages last. Dashboard, Store POS and
  // Catalogue are not here: they are the bottom bar's Home, Bill and Item (founder, 20 Oct 2026). Stock and Purchase are not
  // either: they are parts of Item now (founder, 25 Oct 2026).
  final entries = [
    SideNavEntry(LucideIcons.qrCode, 'All Orders', hook(HomeNav.orderHistory ?? HomeNav.orders)),
    SideNavEntry(LucideIcons.indianRupee, 'Money', hook(HomeNav.money)),
    SideNavEntry(LucideIcons.circleUser, 'Customer', hook(HomeNav.customers)),
    SideNavEntry(LucideIcons.fileText, 'Reports', onReports),
    SideNavEntry(LucideIcons.users, 'Team', hook(HomeNav.team)),
    SideNavEntry(LucideIcons.settings, 'Settings', hook(HomeNav.settings ?? HomeNav.setup)),
    SideNavEntry(LucideIcons.globe, 'OneLocal page', hook(HomeNav.storefront)),
    SideNavEntry(LucideIcons.wallet, 'One Local Wallet', hook(HomeNav.wallet)),
    SideNavEntry(LucideIcons.circleQuestionMark, 'Help & support', hook(HomeNav.support)),
  ];
  return showSideNav(context, name: name, email: email, entries: entries, onSignOut: onSignOut);
}

/// The side nav with any list of rows: the store's (above) and the restaurant's (founder, 29 Oct 2026: the restaurant side bar looks like
/// the store's, with the restaurant's own links). Profile (Manage account), Search the app, the rows, Sign out.
Future<void> showSideNav(
  BuildContext context, {
  required String name,
  String? email,
  String? line,
  required List<SideNavEntry> entries,
  required VoidCallback onSignOut,
  Set<String> openGroups = const {},
}) {
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
        line: line,
        entries: entries,
        openGroups: openGroups,
        onAccount: HomeNav.account == null ? null : () => HomeNav.account!(context),
        onSignOut: onSignOut,
      ),
    ),
    transitionBuilder: (ctx, anim, _, child) => SlideTransition(
      position: Tween(begin: const Offset(-1, 0), end: Offset.zero).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

class _StoreSideNav extends StatefulWidget {
  const _StoreSideNav({required this.name, required this.email, required this.entries, required this.onSignOut, this.onAccount, this.line, this.openGroups = const {}});

  /// The folding rows open from the start (back from an Inventory page: Inventory).
  final Set<String> openGroups;
  final String name;
  final String? email;

  /// A line under the email (the restaurant's outlet).
  final String? line;
  final List<SideNavEntry> entries;
  final VoidCallback onSignOut;
  final VoidCallback? onAccount;

  @override
  State<_StoreSideNav> createState() => _StoreSideNavState();
}

class _StoreSideNavState extends State<_StoreSideNav> {
  final _q = TextEditingController();
  late final _openGroups = <String>{...widget.openGroups}; // the folding rows now open

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  // Close the panel first, then open the screen from the page underneath.
  void _go(BuildContext context, VoidCallback open) {
    Navigator.of(context).pop();
    open();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.name, email = widget.email, onAccount = widget.onAccount, onSignOut = widget.onSignOut;
    // "Search the app": the rows whose name (or a sub-row's) has the words typed
    final q = _q.text.trim().toLowerCase();
    // rows whose name starts with the words first ("settings" → Settings, then Delivery settings)
    final entries = q.isEmpty
        ? widget.entries
        : ([for (final e in widget.entries) if (e.label.toLowerCase().contains(q) || e.children.any((c) => c.label.toLowerCase().contains(q))) e]
          ..sort((a, b) => (a.label.toLowerCase().startsWith(q) ? 0 : 1).compareTo(b.label.toLowerCase().startsWith(q) ? 0 : 1)));
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
              // Profile: initials stand in for the photo the Figma frame shows. It is also the way to Manage account
              // (founder, 20 Oct 2026: one place for the account, not a separate row at the foot).
              Semantics(
                button: onAccount != null,
                label: 'Manage account',
                excludeSemantics: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: onAccount == null ? null : () => _go(context, onAccount),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Row(children: [
                      Container(
                        width: 52,
                        height: 52,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(color: kLime, shape: BoxShape.circle),
                        child: Text(_mark(name, email), style: inter(16, 700, color: kNavy)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          name.trim().isEmpty
                              ? Text('Add your name', style: inter(15, 700, color: kLink))   // no name on the account yet: Manage account sets it
                              : Text(name, style: inter(15, 700), maxLines: 1, overflow: TextOverflow.ellipsis),
                          if (email != null && email.isNotEmpty) Text(email, style: inter(12, 400, color: kMuted), maxLines: 1, overflow: TextOverflow.ellipsis),
                          if ((widget.line ?? '').isNotEmpty) Text(widget.line!, key: const ValueKey('side-nav-line'), style: inter(12, 600, color: kLink), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              // Search the app: narrows the rows below as you type
              TextField(
                key: const ValueKey('side-nav-search'),
                controller: _q,
                onChanged: (_) => setState(() {}),
                style: inter(14, 500),
                decoration: InputDecoration(
                  hintText: 'Search the app',
                  hintStyle: inter(14, 400, color: kMuted),
                  prefixIcon: const Icon(LucideIcons.search, size: 18, color: kMuted),
                  filled: true,
                  fillColor: const Color(0xFFF3F4EE),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFDDE0D6))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFDDE0D6))),
                ),
              ),
              const SizedBox(height: 12),
              if (entries.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text('Nothing called "${_q.text.trim()}".', style: inter(13, 500, color: kMuted))),
              Expanded(
                child: ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    // a row with sub-rows and no page of its own folds open and shut (Inventory, founder 29 Oct 2026); a search for a
                    // sub-row opens its group
                    final group = e.children.isNotEmpty && e.open == null;
                    final open = group && (_openGroups.contains(e.label) || (q.isNotEmpty && e.children.any((c) => c.label.toLowerCase().contains(q))));
                    final row = _NavRow(
                      key: group ? ValueKey('side-nav-group-${e.label}') : null,
                      icon: e.icon,
                      label: e.label,
                      soon: e.open == null && !group,
                      expanded: group ? open : null,
                      onTap: group
                          ? () => setState(() => _openGroups.contains(e.label) ? _openGroups.remove(e.label) : _openGroups.add(e.label))
                          : e.open == null
                              ? null
                              : () => _go(context, e.open!),
                    );
                    if (e.children.isEmpty || (group && !open)) return row;
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      row,
                      for (final c in e.children)
                        Padding(
                          padding: const EdgeInsets.only(left: 22, top: 6),
                          child: _NavRow(icon: c.icon, label: c.label, sub: true, soon: c.open == null, onTap: c.open == null ? null : () => _go(context, c.open!)),
                        ),
                    ]);
                  },
                ),
              ),
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
  const _NavRow({super.key, required this.icon, required this.label, required this.onTap, this.soon = false, this.danger = false, this.sub = false, this.expanded});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool soon, danger;

  /// A folding row: open (chevron up) or shut (chevron down); null for a plain row.
  final bool? expanded;

  /// A section under a row (Stock management's three): lighter and a little smaller, with a lime edge.
  final bool sub;

  @override
  Widget build(BuildContext context) {
    final fg = danger ? kRed : soon ? kMuted : kInk;
    final bg = danger ? const Color(0xFFFEF2F2) : sub ? const Color(0xFFF8F9F4) : const Color(0xFFF3F4EE);
    if (sub) {
      return Semantics(
        button: true,
        enabled: onTap != null,
        label: soon ? '$label, coming soon' : label,
        child: Material(
          color: bg,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10)), side: BorderSide(color: Color(0xFFE4E7DC))),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Container(
              decoration: const BoxDecoration(border: Border(left: BorderSide(color: kLime, width: 3))),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(children: [
                Icon(icon, size: 17, color: fg),
                const SizedBox(width: 12),
                Expanded(child: Text(label, style: inter(12.5, 600, color: fg))),
                Icon(LucideIcons.chevronRight, size: 15, color: kMuted),
              ]),
            ),
          ),
        ),
      );
    }
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
              if (expanded != null) Icon(expanded! ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 18, color: kMuted),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The profile circle: the name's initials, else the email's first letter (an account without a name), else "?".
String _mark(String name, String? email) {
  if (name.trim().isNotEmpty && initials(name) != '?') return initials(name);
  final e = (email ?? '').trim();
  return e.isEmpty ? '?' : e[0].toUpperCase();
}
