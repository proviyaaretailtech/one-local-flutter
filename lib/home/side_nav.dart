import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';
import 'control_centre_screen.dart' show initials;
import 'app_actions.dart';
import 'home_nav.dart';
import 'home_widgets.dart';
import '../ui/i18n.dart';

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
    // how the shop looks to customers (founder, 27 Oct 2026): next to the customers it is for
    SideNavEntry(LucideIcons.store, 'Business profile', hook(HomeNav.businessProfile ?? HomeNav.storefront)),
    SideNavEntry(LucideIcons.fileText, 'Reports', onReports),
    SideNavEntry(LucideIcons.users, 'Team', hook(HomeNav.team)),
    SideNavEntry(LucideIcons.settings, 'Settings', hook(HomeNav.settings ?? HomeNav.setup)),
    SideNavEntry(LucideIcons.wallet, 'One Local Wallet', hook(HomeNav.wallet)),
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
        actions: appActions(context, onReports: onReports),
        onAccount: hook(HomeNav.account),
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
  const _StoreSideNav({required this.name, required this.email, required this.entries, required this.onSignOut, this.onAccount, this.actions = const []});
  final String name;
  final String? email;
  final List<SideNavEntry> entries;
  final VoidCallback onSignOut;
  final VoidCallback? onAccount;

  /// Everything the search finds ([appActions]).
  final List<AppAction> actions;

  @override
  State<_StoreSideNav> createState() => _StoreSideNavState();
}

class _StoreSideNavState extends State<_StoreSideNav> {
  final _search = TextEditingController();

  String get name => widget.name;
  String? get email => widget.email;
  List<SideNavEntry> get entries => widget.entries;
  VoidCallback? get onAccount => widget.onAccount;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // Close the panel first, then open the screen from the page underneath.
  void _go(BuildContext context, VoidCallback open) {
    Navigator.of(context).pop();
    open();
  }

  /// "Search the app" (founder, 26 Oct 2026): any place or action, by its name or the words people use for it.
  Widget _searchField() => Container(
        height: 44,
        decoration: BoxDecoration(color: const Color(0xFFF4F5F1), borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
        child: Row(children: [
          const SizedBox(width: 12),
          const Icon(LucideIcons.search, size: 18, color: kMuted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: const ValueKey('side-nav-search'),
              controller: _search,
              textInputAction: TextInputAction.search,
              style: inter(14, 400),
              decoration: InputDecoration.collapsed(hintText: tr('Search the app'), hintStyle: inter(14, 400, color: kMuted)),
              onChanged: (_) => setState(() {}),
              onSubmitted: (q) {
                final hits = searchActions(widget.actions, q);
                if (hits.isNotEmpty) _go(context, hits.first.open);
              },
            ),
          ),
          if (_search.text.isNotEmpty)
            IconButton(
              tooltip: tr('Clear'),
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(_search.clear),
              icon: const Icon(LucideIcons.x, size: 16, color: kMuted),
            ),
        ]),
      );

  Widget _results() {
    final hits = searchActions(widget.actions, _search.text);
    if (hits.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Nothing matches "${_search.text.trim()}". Try another word, like stock, bill or supplier.', style: inter(13.5, 400, color: kMuted, height: 1.4)),
      );
    }
    return ListView.separated(
      key: const ValueKey('side-nav-results'),
      padding: EdgeInsets.zero,
      itemCount: hits.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, i) {
        final a = hits[i];
        return Material(
          color: const Color(0xFFF4F5F1),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            key: ValueKey('side-nav-result-${a.title}'),
            borderRadius: BorderRadius.circular(14),
            onTap: () => _go(context, a.open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(children: [
                Icon(a.icon, size: 19, color: kInk),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr(a.title), style: inter(14.5, 600)),
                    Text(tr(a.where), style: inter(11.5, 400, color: kMuted)),
                  ]),
                ),
                const Icon(LucideIcons.chevronRight, size: 16, color: kMuted),
              ]),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final searching = _search.text.trim().isNotEmpty;
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
                label: tr('Manage account'),
                excludeSemantics: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: onAccount == null ? null : () => _go(context, onAccount!),
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
                              ? Text(tr('Add your name'), style: inter(15, 700, color: kLink))   // no name on the account yet: Manage account sets it
                              : Text(name, style: inter(15, 700), maxLines: 1, overflow: TextOverflow.ellipsis),
                          if (email != null && email!.isNotEmpty) Text(email!, style: inter(12, 400, color: kMuted), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _searchField(),
              const SizedBox(height: 12),
              Expanded(
                child: searching ? _results() : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    final row = _NavRow(
                      icon: e.icon,
                      label: e.label,
                      soon: e.open == null,
                      onTap: e.open == null ? null : () => _go(context, e.open!),
                    );
                    if (e.children.isEmpty) return row;
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
              _NavRow(icon: LucideIcons.logOut, label: tr('Sign out'), danger: true, onTap: () => _go(context, widget.onSignOut)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({required this.icon, required this.label, required this.onTap, this.soon = false, this.danger = false, this.sub = false});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool soon, danger;

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
                Expanded(child: Text(tr(label), style: inter(12.5, 600, color: fg))),
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
              Expanded(child: Text(tr(label), style: inter(13, 600, color: fg))),
              if (soon)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: const Color(0xFFFEF0C7), borderRadius: BorderRadius.circular(10)),
                  child: Text(tr('Soon'), style: inter(10, 700, color: const Color(0xFFB54708))),
                ),
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
