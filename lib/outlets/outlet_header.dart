import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';
import '../home/home_nav.dart';
import 'outlet_scope.dart';
import 'outlet_status_screen.dart';
import 'outlets_api.dart';

const kOutletOnline = Color(0xFF16A34A);
const kOutletPaused = Color(0xFFD97706);
const kOutletChipBg = Color(0xFFE9F9DC);
const kOutletChipText = Color(0xFF14532D);
const kOutletSquare = Color(0xFFF3F4F6);

/// Colour of an outlet status word (D7 in specs/outlets-multi/spec.md).
Color outletStatusColor(String status) => switch (status) {
      'online' => kOutletOnline,
      'paused' || 'pending' => kOutletPaused,
      'rejected' => kError,
      _ => kMuted,
    };

String outletInitials(String name) {
  final parts = name.trim().split(RegExp(r'[\s@._]+')).where((p) => p.isNotEmpty && RegExp(r'[A-Za-z]').hasMatch(p[0])).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

/// The one top header of every main screen once a partner is onboarded. Two looks, one widget:
/// * single outlet (Figma `screen-pos-orders`; Orders, Bill, Item, Stock…): ☰, the outlet's name ▾, its live status from the server
///   (Online / Offline / Paused), the "All online ›" chip that sums up every outlet, and the person's initials.
/// * [dashboard] (Home; founder screenshot 20 Oct): "SHOWING DATA FOR" over "All outlets (N) ▾" or the chosen outlet, the outlets' status
///   line, a bell and ☰ on the right.
/// The name opens the outlet switcher ([OutletScope.selected], one choice for the whole app); the chip and "Manage outlets" open
/// Restaurant status. While the server has not answered (or cannot be reached) it shows [title], so the screen is never blank.
class OutletHeader extends StatefulWidget {
  const OutletHeader({
    super.key,
    required this.title,
    this.onMenu,
    this.locationId,
    this.safeTop = true,
    this.rounded = false,
    this.menuKey = const ValueKey('outlet-header-menu'),
    this.initials,
    this.dashboard = false,
    this.allowAll = true,
    this.onBell,
  });

  /// Shown until the outlet is known.
  final String title;
  final VoidCallback? onMenu;

  /// The outlet the screen works in when it decides itself; otherwise the app's selection ([OutletScope]), else the default outlet.
  final String? locationId;

  /// Adds the status-bar inset (for screens without a SafeArea above the header).
  final bool safeTop;

  /// Rounded bottom corners, for the section top bars that had them.
  final bool rounded;

  /// The person's initials the screen already knows, shown until the server names the person.
  final String? initials;

  /// Key of the ☰ button (screens keep the key their tests already use).
  final Key menuKey;

  /// The Home look: "SHOWING DATA FOR / All outlets (N) ▾", bell and ☰ on the right.
  final bool dashboard;

  /// Whether this screen can sum its data over all outlets ("All outlets (N)" in the switcher).
  final bool allowAll;

  final VoidCallback? onBell;

  /// Where the header reads from. Tests replace it.
  static OutletsApi Function() api = OutletsApi.new;

  /// One read shared by every header on screen; [refresh] drops it after a change (a toggle, a new outlet).
  static final Map<String, Future<OutletOverview>> _cache = {};
  static final ValueNotifier<int> changes = ValueNotifier(0);
  static void refresh() {
    _cache.clear();
    changes.value++;
  }

  static Future<OutletOverview> load([String? locationId]) =>
      _cache.putIfAbsent(locationId ?? '', () => api().list(locationId: locationId)..catchError((Object _) {
            _cache.remove(locationId ?? '');
            return const OutletOverview({});
          }));

  /// Opens Restaurant status; every header reloads when it closes.
  static Future<void> openStatus(BuildContext context) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OutletStatusScreen(api: api())));
    refresh();
  }

  @override
  State<OutletHeader> createState() => _OutletHeaderState();
}

class _OutletHeaderState extends State<OutletHeader> {
  late Future<OutletOverview> _f;

  String? get _want => widget.locationId ?? OutletScope.selected.value;

  @override
  void initState() {
    super.initState();
    _f = OutletHeader.load(_want);
    OutletHeader.changes.addListener(_reload);
    OutletScope.selected.addListener(_reload);
  }

  @override
  void didUpdateWidget(OutletHeader old) {
    super.didUpdateWidget(old);
    if (old.locationId != widget.locationId) _f = OutletHeader.load(_want);
  }

  @override
  void dispose() {
    OutletHeader.changes.removeListener(_reload);
    OutletScope.selected.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      _f = OutletHeader.load(_want);
    });
  }

  /// The switcher: "All outlets (N)" (where the screen can sum), every verified outlet, and "Manage outlets".
  Future<void> _pick(OutletOverview o) async {
    final all = widget.dashboard && widget.allowAll;
    final sel = OutletScope.selected.value;
    final cur = o.current?.id;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 20, 20, 12), children: [
            Text('Show data for', style: inter(15, 700)),
            const SizedBox(height: 6),
            if (all)
              _PickRow(key: const ValueKey('outlet-pick-all'), title: 'All outlets (${o.verified.length})', subtitle: o.chip, selected: sel == null, onTap: () => Navigator.pop(ctx, '')),
            for (final x in o.verified)
              _PickRow(
                key: ValueKey('outlet-pick-${x.id}'),
                title: x.name,
                subtitle: [x.code, if (x.locality.isNotEmpty) x.locality, x.statusLabel].join(' · '),
                dot: outletStatusColor(x.status),
                selected: all ? sel == x.id : (sel ?? cur) == x.id,
                onTap: () => Navigator.pop(ctx, x.id),
              ),
            const Divider(height: 20, color: kLine),
            _PickRow(key: const ValueKey('outlet-pick-manage'), title: 'Manage outlets', subtitle: 'Status, rush mode, add a restaurant/store', onTap: () => Navigator.pop(ctx, '#manage')),
          ]),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked == '#manage') {
      await OutletHeader.openStatus(context);
      return;
    }
    OutletScope.selected.value = picked.isEmpty ? null : picked;
  }

  Widget _menuButton(BuildContext context) => Semantics(
        button: true,
        label: 'Menu',
        child: InkWell(
          key: widget.menuKey,
          borderRadius: BorderRadius.circular(12),
          onTap: widget.onMenu ?? () => HomeNav.go(context, HomeNav.home, 'Menu'),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: kOutletSquare, borderRadius: BorderRadius.circular(12)),
            child: const Icon(LucideIcons.menu, size: 20, color: kInk),
          ),
        ),
      );

  BoxDecoration get _box => BoxDecoration(
        color: Colors.white,
        borderRadius: widget.rounded ? const BorderRadius.vertical(bottom: Radius.circular(28)) : null,
        border: widget.rounded ? null : const Border(bottom: BorderSide(color: kLine)),
      );

  EdgeInsets _pad(BuildContext context) => EdgeInsets.fromLTRB(16, (widget.safeTop ? MediaQuery.paddingOf(context).top : 0) + 10, 16, 10);

  Widget _dashboard(BuildContext context, OutletOverview? o) {
    final all = widget.allowAll && OutletScope.selected.value == null && widget.locationId == null;
    final cur = o?.current;
    final label = o == null || cur == null ? widget.title : all ? 'All outlets (${o.verified.length})' : cur.name;
    return Container(
      padding: _pad(context),
      decoration: _box,
      child: Row(children: [
        Expanded(
          child: Semantics(
            button: o != null,
            label: o == null ? null : 'Showing data for $label. Change outlet',
            excludeSemantics: o != null,
            child: InkWell(
              key: const ValueKey('outlet-header-name'),
              onTap: o == null || cur == null ? null : () => _pick(o),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('SHOWING DATA FOR', style: inter(10.5, 700, color: kMuted).copyWith(letterSpacing: 0.8)),
                const SizedBox(height: 2),
                Row(children: [
                  Flexible(child: Text(label, key: const ValueKey('outlet-header-label'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(18, 700))),
                  if (o != null && cur != null) const Icon(LucideIcons.chevronDown, size: 18, color: kInk),
                ]),
                if (o != null && cur != null)
                  InkWell(
                    key: const ValueKey('outlet-header-chip'),
                    onTap: () => OutletHeader.openStatus(context),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Container(width: 8, height: 8, decoration: BoxDecoration(color: outletStatusColor(all ? (o.chip == 'All online' ? 'online' : 'paused') : cur.status), shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Text(all ? o.chip : cur.statusLabel, key: const ValueKey('outlet-header-status'), style: inter(12.5, 600, color: kMuted)),
                        const Icon(LucideIcons.chevronRight, size: 12, color: kMuted),
                      ]),
                    ),
                  ),
              ]),
            ),
          ),
        ),
        Semantics(
          button: true,
          label: 'Notifications',
          excludeSemantics: true,
          child: IconButton(
            key: const ValueKey('outlet-header-bell'),
            onPressed: widget.onBell ?? () => HomeNav.go(context, HomeNav.notifications, 'Notifications'),
            icon: const Icon(LucideIcons.bell, size: 22, color: kInk),
          ),
        ),
        const SizedBox(width: 4),
        _menuButton(context),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<OutletOverview>(
      future: _f,
      builder: (context, snap) {
        final o = snap.hasError ? null : snap.data;
        if (widget.dashboard) return _dashboard(context, o);
        final cur = o?.current;
        final name = cur?.name.isNotEmpty == true ? cur!.name : widget.title;
        return Container(
          padding: _pad(context),
          decoration: _box,
          child: Row(children: [
            _menuButton(context),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                button: cur != null,
                label: cur == null ? null : 'Outlet ${cur.name}, ${cur.statusLabel}. Change outlet',
                excludeSemantics: cur != null,
                child: InkWell(
                  key: const ValueKey('outlet-header-name'),
                  onTap: cur == null ? null : () => _pick(o!),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(17, 700))),
                      if (cur != null && (o?.verified.length ?? 0) > 1) const Icon(LucideIcons.chevronDown, size: 16, color: kInk),
                    ]),
                    if (cur != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(children: [
                          Container(width: 8, height: 8, decoration: BoxDecoration(color: outletStatusColor(cur.status), shape: BoxShape.circle)),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(cur.statusLabel,
                                key: const ValueKey('outlet-header-status'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: inter(13, 600, color: outletStatusColor(cur.status))),
                          ),
                        ]),
                      ),
                  ]),
                ),
              ),
            ),
            if (o != null && o.chip.isNotEmpty) ...[
              const SizedBox(width: 8),
              Semantics(
                button: true,
                label: '${o.chip}. Open restaurant status',
                excludeSemantics: true,
                child: InkWell(
                  key: const ValueKey('outlet-header-chip'),
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => OutletHeader.openStatus(context),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
                    decoration: BoxDecoration(color: kOutletChipBg, borderRadius: BorderRadius.circular(999)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(o.chip, style: inter(11, 600, color: kOutletChipText)),
                      const Icon(LucideIcons.chevronRight, size: 12, color: kOutletChipText),
                    ]),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 10),
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: kOutletSquare, shape: BoxShape.circle),
              child: Text(o == null || o.personName.isEmpty ? (widget.initials ?? '') : outletInitials(o.personName), style: inter(13, 700)),
            ),
          ]),
        );
      },
    );
  }
}

class _PickRow extends StatelessWidget {
  const _PickRow({super.key, required this.title, required this.subtitle, required this.onTap, this.selected = false, this.dot});
  final String title, subtitle;
  final VoidCallback onTap;
  final bool selected;
  final Color? dot;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(children: [
            if (dot != null) ...[Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)), const SizedBox(width: 10)],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: inter(15, 600)),
                if (subtitle.isNotEmpty) Text(subtitle, style: inter(12.5, 400, color: kMuted)),
              ]),
            ),
            if (selected) const Icon(LucideIcons.check, size: 18, color: kOutletOnline),
          ]),
        ),
      );
}
