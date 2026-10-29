import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/auth_repository.dart';
import '../auth/partner_api.dart';
import '../ui/theme.dart';
import 'home_api.dart';
import 'home_nav.dart';
import 'home_widgets.dart';
import '../outlets/outlet_header.dart';
import '../outlets/outlet_scope.dart';
import 'hub_screen.dart';
import 'side_nav.dart';
import '../service/history_screen.dart';
import '../service/service_api.dart';
import '../service/service_dashboard.dart';
import '../restaurant/restaurant_api.dart';
import '../restaurant/restaurant_dashboard.dart';
import '../restaurant/restaurant_more_screen.dart';
import '../ui/i18n.dart';
import '../ui/motion.dart';

/// Figma section D "Seller Admin Dashboard / POS control center". Every figure comes from
/// `GET /api/partner/home`; a tile without a data source says so instead of showing a number.
/// A restaurant gets its own dashboard ([RestaurantHomeBody], from `rst_dashboard`) with the restaurant tab set.
/// A service business gets its own dashboard ([ServiceHomeBody], from `svc_dashboard`) inside the same shell.
class ControlCentreScreen extends StatefulWidget {
  const ControlCentreScreen({super.key, this.api, this.auth, this.now, this.serviceApi, this.restaurantApi});
  final RestaurantApi? restaurantApi;
  final HomeApi? api;
  final ServiceApi? serviceApi;
  final AuthRepository? auth;

  /// Clock for "Synced … ago" (tests).
  final DateTime Function()? now;

  @override
  State<ControlCentreScreen> createState() => _ControlCentreScreenState();
}

class _ControlCentreScreenState extends State<ControlCentreScreen> {
  late final HomeApi _api = widget.api ?? HomeApi();
  // the outlet chosen in the header's switcher (null = all outlets, summed by the server)
  String? _location = OutletScope.selected.value;
  late Future<HomeSummary> _summary = _api.summary(location: _location);

  // Every screen's ☰ opens this dashboard's side menu, over that screen.
  late final HomeRoute _menuHook = (c) => _openMenu(c);

  @override
  void initState() {
    super.initState();
    OutletScope.selected.addListener(_followScope);
    HomeNav.openMenu = _menuHook;
  }

  @override
  void dispose() {
    OutletScope.selected.removeListener(_followScope);
    if (HomeNav.openMenu == _menuHook) HomeNav.openMenu = null;
    super.dispose();
  }

  void _followScope() {
    if (!mounted || OutletScope.selected.value == _location) return;
    _location = OutletScope.selected.value;
    _reload();
  }
  String? _personName;
  String? _outletName;
  String? _kind; // the kind of business the summary reported (decides what the centre tab opens)

  Future<void> _reload() async {
    final next = _api.summary(location: _location);
    setState(() {
      _summary = next;
    });
    try {
      await next;
    } catch (_) {
      // The error is drawn by the builder.
    }
  }

  void _pickOutlet(HomeSummary s) async {
    if (s.outlets.length < 2 && _location == null) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(kPadX, 24, kPadX, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Show data for'), style: inter(15, 600)),
            const SizedBox(height: 8),
            _OutletOption(label: tr('All my outlets'), selected: _location == null, onTap: () => Navigator.pop(ctx, '')),
            for (final o in s.outlets)
              _OutletOption(label: (o['name'] ?? '') as String, selected: _location == o['id'], onTap: () => Navigator.pop(ctx, o['id'] as String)),
          ]),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    OutletScope.selected.value = picked.isEmpty ? null : picked;   // every header and outlet-aware screen follows
  }

  void _signOut() {
    (widget.auth ?? AuthRepository()).signOut();
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  /// Opens the side menu over [from] (any screen's ☰, through [HomeNav.openMenu]), or over the dashboard.
  void _openMenu([BuildContext? from]) {
    final c = from ?? context;
    // A store gets the Figma side nav (section D 39:7416); restaurant and service keep the short sheet for now.
    if (_kind != 'restaurant' && _kind != 'service') {
      showStoreSideNav(
        c,
        name: _personName ?? 'Partner',
        email: (widget.auth ?? AuthRepository()).currentEmail,
        onReports: () => _openHub(c),
        onSignOut: _signOut,
      );
      return;
    }
    // A restaurant gets the Figma More page (section D 45:7539).
    if (_kind == 'restaurant') {
      Navigator.of(c).push(RestaurantMoreScreen.route(outletName: _outletName ?? 'My outlet', outletLine: 'Restaurant', onLogout: _signOut));
      return;
    }
    showModalBottomSheet<void>(
      context: c,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(kPadX, 16, kPadX, 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _MenuRow(icon: LucideIcons.chartColumn, label: tr('Sales feed'), onTap: () {
              Navigator.pop(ctx);
              _openHub(c);
            }),
            _MenuRow(icon: LucideIcons.settings, label: tr('Settings'), onTap: () {
              Navigator.pop(ctx);
              HomeNav.go(c, HomeNav.settings ?? HomeNav.setup, 'Settings');
            }),
            _MenuRow(icon: LucideIcons.logOut, label: tr('Sign out'), onTap: () {
              Navigator.pop(ctx);
              _signOut();
            }),
          ]),
        ),
      ),
    );
  }

  void _openHub([BuildContext? from]) => Navigator.of(from ?? context).push(MaterialPageRoute(builder: (_) => HubScreen(api: _api, location: _location)));

  void _tab(String label) {
    switch (label) {
      case 'Online order':
      case 'Orders':
        HomeNav.go(context, HomeNav.orders, 'Online orders');
      case 'Bill':
      case 'POS':
        final service = HomeNav.partnerType == 'service' || _kind == 'service';
        // A restaurant bills from a table: Bill opens the floor (founder, 2026-10-20). Store bills from the cart.
        final restaurant = _kind == 'restaurant';
        HomeNav.go(
          context,
          service ? HomeNav.service : restaurant ? (HomeNav.tables ?? HomeNav.bill) : HomeNav.bill,
          service ? 'Appointments' : restaurant ? 'Tables' : 'Billing',
        );
      case 'Item':
        HomeNav.go(context, HomeNav.items, 'Items');
      case 'Menu':
        HomeNav.go(context, HomeNav.menu ?? HomeNav.items, 'The menu'); // restaurant: menu and dish detail
      case 'Stock':
        HomeNav.go(context, HomeNav.stock, 'Stock');
      case 'Home':
        break; // already on the dashboard
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<HomeSummary>(
      future: _summary,
      builder: (context, snap) {
        final s = snap.data;
        if (s != null) {
          _kind = s.outletKind;
          _personName = s.personName;
          _outletName = s.outletName;
          HomeNav.storeName = s.outletName;   // the store's name on every screen's header
          HomeNav.personName = s.personName; // the profile icon's initials
          // Inside the app shell: its bar shows this kind's tabs (store / restaurant / service).
          final shell = HomeNav.shell;
          if (shell != null && shell.kind != s.outletKind) WidgetsBinding.instance.addPostFrameCallback((_) => shell.setKind(s.outletKind));
        }
        final loading = snap.connectionState != ConnectionState.done;
        final tabs = s?.outletKind == 'restaurant' ? kHubTabs : kStoreTabs;
        return Scaffold(
          backgroundColor: kBg,
          extendBody: true,
          bottomNavigationBar: SafeArea(top: false, child: FloatingTabBar(tabs: tabs, onTap: _tab, current: 'Home')),
          body: SafeArea(
            bottom: false,
            child: loading && s == null
                ? const Center(child: CircularProgressIndicator(color: kLink))
                : snap.hasError
                    ? _ErrorState(error: snap.error!, onRetry: _reload)
                    : s!.outletKind == 'service'
                        ? ServiceHomeBody(
                            api: widget.serviceApi ?? ServiceApi(),
                            personName: s.personName,
                            onMenu: _openMenu,
                            onInsights: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServiceHistoryScreen(api: widget.serviceApi ?? ServiceApi()))),
                          )
                        : s.outletKind == 'restaurant'
                        ? RestaurantHomeBody(
                            api: widget.restaurantApi ?? RestaurantApi(),
                            personName: s.personName,
                            onMenu: _openMenu,
                            onInsights: _openHub,
                          )
                        : RefreshIndicator(
                        color: kLink,
                        onRefresh: _reload,
                        child: _Body(
                          s: s,
                          now: (widget.now ?? DateTime.now)(),
                          onMenu: _openMenu,
                          onOutlet: () => _pickOutlet(s),
                          onInsights: _openHub,
                        ),
                      ),
          ),
        );
      },
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.s, required this.now, required this.onMenu, required this.onOutlet, required this.onInsights});
  final HomeSummary s;
  final DateTime now;
  final VoidCallback onMenu, onOutlet, onInsights;

  @override
  Widget build(BuildContext context) {
    final day = dayLabel(s.day);
    final restaurant = s.outletKind == 'restaurant';
    final syncedAt = s.lastSync;
    final synced = syncedAt == null ? 'Updated ${ago(s.asOf, now)}' : 'Synced ${ago(syncedAt, now)}';
    final syncLine = '${s.outletName} · $synced';
    final gaps = <(String, int)>[
      if ((s.missingDescriptions ?? 0) > 0) ('description', s.missingDescriptions!),
      if ((s.missingPhotos ?? 0) > 0) ('photo', s.missingPhotos!),
      if (restaurant && (s.missingRecipes ?? 0) > 0) ('recipe', s.missingRecipes!),
    ];
    final open = s.isOpen;
    return ListView(
      padding: const EdgeInsets.only(bottom: 132),
      children: staggered([ // the dashboard builds in, section by section (lib/ui/motion.dart)
        // Top bar: the outlet header (outlet name, live status, all-outlets chip, initials) — specs/outlets-multi.
        OutletHeader(title: s.outletName, onMenu: onMenu, safeTop: false, menuKey: const ValueKey('home-menu'), dashboard: true),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // One light status card: open or closed, the day once, three plain numbers, today's operations.
            HomeCard(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Dot(open == true ? kLink : open == false ? kRed : kMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(open == true ? 'Store open' : open == false ? 'Store closed' : 'Status not set', style: inter(14, 700)),
                      Text('Today · ${dayLabel(s.day, caps: false)}', style: inter(11, 400, color: kMuted)),
                    ]),
                  ),
                  // The outlet's sync time; tapping it switches outlet (as the old header line did).
                  InkWell(
                    onTap: onOutlet,
                    child: Padding(padding: const EdgeInsets.all(4), child: Text(synced, style: inter(11, 400, color: kMuted))),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _StatTile(label: tr('Sales'), value: s.salesTotal == null ? '—' : rupees(s.salesTotal!.round()))),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _StatTile(label: tr('Orders'), value: s.ordersCount == null ? '—' : count(s.ordersCount!), note: '${s.activeCount ?? 0} active now'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: (s.ordersCount ?? 0) == 0 || s.unitsSold == null
                        ? _StatTile(label: tr('Items sold'), value: '—', note: tr('Not reported'))
                        : _StatTile(label: tr('Items sold'), value: count(s.unitsSold!)),
                  ),
                ]),
                const SizedBox(height: 10),
                // Today's figures open today's report (the insights feed: today so far, daily takings), not the
                // orders board: in a store that board read as kitchen orders (founder, 20 Oct 2026).
                InkWell(
                  onTap: onInsights,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Expanded(
                        child: Text(
                          '${s.settledCount ?? 0} bills settled · ${s.pax ?? 0} pax · ${s.activeCount ?? 0} open',
                          style: inter(11.5, 400, color: kMuted),
                        ),
                      ),
                      Text(tr('Today’s report'), style: inter(11.5, 600, color: kLink)),
                      const Icon(LucideIcons.chevronRight, size: 14, color: kLink),
                    ]),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 20),
            if (gaps.isNotEmpty) ...[
              _AttentionCard(total: s.itemsTotal ?? 0, gaps: gaps, restaurant: restaurant),
              const SizedBox(height: 20),
            ],
            SectionHeader(
              'Active orders',
              badge: GreyTag('${s.activeCount ?? 0} active', dot: (s.activeCount ?? 0) > 0 ? kRed : kMuted),
              action: tr('View all'),
              onAction: () => HomeNav.go(context, HomeNav.orders, 'Orders'),
            ),
            const SizedBox(height: 12),
            if (s.activeOrders.isEmpty)
              const HomeCard(child: EmptyNote('No open orders right now.'))
            else
              for (final o in s.activeOrders) ...[_OrderCard(o), const SizedBox(height: 8)],
            const SizedBox(height: 12),
            // "Full report" is the stock alerts (low stock, expiry, not selling, mismatch) (founder, 25 Oct 2026)
            SectionHeader('Stock health', action: tr('Full report'), onAction: () => HomeNav.go(context, HomeNav.stockPage == null ? null : (c) => HomeNav.stockPage!(c, 'alerts'), 'Stock alerts')),
            const SizedBox(height: 12),
            _StockCard(s),
            if (s.stock.isNotEmpty) ...[
              const SizedBox(height: 8),
              LimeOnDarkButton(label: tr('Restock critical items'), onPressed: () => HomeNav.go(context, HomeNav.lowStock, 'Restocking')),
            ],
            const SizedBox(height: 20),
            SectionHeader('Business insights', badge: GreyTag(day), action: tr('See all'), onAction: onInsights),
            const SizedBox(height: 12),
            _RevenueCard(s),
            const SizedBox(height: 8),
            _TopItemsCard(s, day: day),
            const SizedBox(height: 8),
            HomeCard(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('PURCHASE PRICE TREND', style: inter(10, 700, color: kMuted)),
                const SizedBox(height: 6),
                const EmptyNote('Purchase prices are not recorded bill by bill yet, so there is no trend to show.'),
              ]),
            ),
            const SizedBox(height: 20),
            Text(syncLine, textAlign: TextAlign.center, style: inter(10, 400, color: const Color(0xFF9CA3AF))),
            const SizedBox(height: 4),
            Center(
              child: InkWell(
                onTap: () => HomeNav.go(context, HomeNav.support, 'Support'),
                child: Padding(padding: const EdgeInsets.all(4), child: Text(tr('Need help? Contact support'), style: inter(11, 600))),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// "RS" from "Riya Sharma"; "?" when no name is on file.
String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty && RegExp(r'[A-Za-z]').hasMatch(p[0])).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

/// A plain number on the status card: small label, the value, and an optional muted note (no badges).
class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value, this.note});
  final String label, value;
  final String? note;
  @override
  Widget build(BuildContext context) => Container(
        height: 82,
        padding: const EdgeInsets.fromLTRB(10, 9, 6, 8),
        decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 500, color: kMuted)),
          const SizedBox(height: 2),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: inter(20, 700))),
          const Spacer(),
          if (note != null) Text(note!, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(10.5, 500, color: kMuted)),
        ]),
      );
}

/// "Needs attention": one line per gap in the item data, each with a Fix link to item editing.
class _AttentionCard extends StatelessWidget {
  const _AttentionCard({required this.total, required this.gaps, required this.restaurant});
  final int total;
  final List<(String, int)> gaps;
  final bool restaurant;
  static const _icons = {'description': LucideIcons.fileText, 'photo': LucideIcons.image, 'recipe': LucideIcons.chefHat};
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionHeader('Needs attention', badge: GreyTag('$total ${restaurant ? 'menu' : 'catalogue'} items')),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: kAmber)),
          child: Column(children: [
            for (var i = 0; i < gaps.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: kLine),
              InkWell(
                onTap: () => HomeNav.go(context, HomeNav.items, 'Item editing'),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  child: Row(children: [
                    Icon(_icons[gaps[i].$1] ?? LucideIcons.circleAlert, size: 16, color: kAmberInk),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('${gaps[i].$2} ${gaps[i].$2 == 1 ? 'item' : 'items'} missing ${gaps[i].$2 == 1 ? 'a ${gaps[i].$1}' : '${gaps[i].$1}s'}',
                          style: inter(12.5, 500)),
                    ),
                    Text(tr('Fix'), style: inter(12.5, 700, color: kLink)),
                  ]),
                ),
              ),
            ],
          ]),
        ),
      ]);
}

class _OrderCard extends StatelessWidget {
  const _OrderCard(this.o);
  final ActiveOrder o;

  static String statusLabel(String s) => switch (s) {
        'new' => 'New',
        'preparing' => 'Preparing',
        'ready' => 'Ready',
        'out_for_delivery' => 'Out for delivery',
        'awaiting_payment' => 'Awaiting payment',
        'in_billing' => 'In billing',
        _ => s.isEmpty ? 'Open' : '${s[0].toUpperCase()}${s.substring(1).replaceAll('_', ' ')}',
      };

  static String fulfilmentLabel(String f) => switch (f) {
        'delivery' => 'Delivery',
        'pickup' => 'Pickup',
        'dine_in' => 'Dine-in',
        _ => 'Other',
      };

  @override
  Widget build(BuildContext context) {
    final (bg, dot, fg) = switch (o.status) {
      'out_for_delivery' || 'ready' => (const Color(0xFFEBFAE0), kGreenDot, const Color(0xFF1E6B00)),
      'preparing' || 'awaiting_payment' || 'in_billing' => (const Color(0xFFFFF7E0), kAmber, kAmberInk),
      _ => (const Color(0xFFF1F2F4), kMuted, const Color(0xFF4B5563)),
    };
    final parts = [
      if (o.items != null) '${o.items} ${o.items == 1 ? 'item' : 'items'}',
      if (o.total != null) rupees(o.total!),
      fulfilmentLabel(o.fulfilment),
      if (o.etaMinutes != null) 'ETA ${o.etaMinutes} min',
    ];
    return HomeCard(
      onTap: () => HomeNav.go(context, HomeNav.orders, 'Orders'),
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: kNote, borderRadius: BorderRadius.circular(10)),
          child: Icon(o.isDelivery ? LucideIcons.truck : LucideIcons.shoppingBag, size: 18, color: kNavy),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text('Order #${o.number}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 700))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Dot(dot, size: 6),
                  const SizedBox(width: 6),
                  Text(statusLabel(o.status), style: inter(9, 600, color: fg)),
                ]),
              ),
            ]),
            const SizedBox(height: 4),
            Text(parts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(10, 400, color: kMuted)),
          ]),
        ),
      ]),
    );
  }
}

class _StockCard extends StatelessWidget {
  const _StockCard(this.s);
  final HomeSummary s;
  @override
  Widget build(BuildContext context) {
    if (!s.stockTracked) {
      return const HomeCard(child: EmptyNote('Set reorder levels on stock items to see what’s running low.'));
    }
    if (s.stock.isEmpty) return const HomeCard(child: EmptyNote('Everything is above its reorder level.'));
    return HomeCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(children: [
        for (var i = 0; i < s.stock.length; i++) ...[
          if (i > 0) const Divider(height: 1, color: kLine),
          _StockLine(s.stock[i]),
        ],
        if (s.stockLowCount > s.stock.length)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 6),
            child: Text('+${s.stockLowCount - s.stock.length} more running low', style: inter(10, 500, color: kMuted)),
          ),
      ]),
    );
  }
}

class _StockLine extends StatelessWidget {
  const _StockLine(this.r);
  final StockRow r;
  @override
  Widget build(BuildContext context) {
    final out = r.level == 'out';
    final q = r.quantity;
    final left = q == null ? 'Low' : '${q % 1 == 0 ? q.toInt() : q} ${r.unit ?? ''}'.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Dot(out ? kRed : kAmber),
        const SizedBox(width: 12),
        Expanded(child: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 400))),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: out ? kRedBg : const Color(0xFFFFF7E0), borderRadius: BorderRadius.circular(6)),
          child: Text(out ? 'Out' : '$left left', style: inter(10, 700, color: out ? kRedInk : kAmberInk)),
        ),
      ]),
    );
  }
}

class _RevenueCard extends StatelessWidget {
  const _RevenueCard(this.s);
  final HomeSummary s;
  @override
  Widget build(BuildContext context) {
    final kot = s.kotNotBilled;
    final grnBills = s.grnBills;
    return HomeCard(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('REVENUE & OPERATIONS', style: inter(10, 700, color: kMuted)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _SoftTile(label: tr('Revenue'), value: s.salesTotal == null ? '—' : rupees(s.salesTotal!.round()), foot: '${s.ordersCount ?? 0} orders')),
          const SizedBox(width: 8),
          Expanded(
            child: s.expenses == null
                ? _SoftTile(label: tr('Expenses'), value: '—', foot: 'Not tracked yet')
                : _SoftTile(label: tr('Expenses'), value: rupees(s.expenses!.round()), foot: dayLabel(s.day, caps: false)),
          ),
        ]),
        const SizedBox(height: 10),
        const Divider(height: 1, color: kLine),
        const SizedBox(height: 8),
        _InsightRow(
          dot: (kot ?? 0) > 0 ? kRed : kGreenDot,
          label: 'Revenue leakage',
          value: kot == null ? 'Not reported' : kot == 0 ? 'None' : '$kot KOT${kot == 1 ? '' : 's'} not billed',
          valueColor: (kot ?? 0) > 0 ? kRedInk : kInk,
        ),
        const SizedBox(height: 4),
        _InsightRow(
          dot: kGreenDot,
          label: tr('Purchase received'),
          value: grnBills == null ? 'Not reported' : grnBills == 0 ? 'None today' : '$grnBills bill${grnBills == 1 ? '' : 's'} · ${s.grnAmount == null ? 'cost not entered' : rupees(s.grnAmount!)}',
          valueColor: kInk,
        ),
      ]),
    );
  }
}

class _SoftTile extends StatelessWidget {
  const _SoftTile({required this.label, required this.value, required this.foot});
  final String label, value, foot;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: kSoftTile, borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: inter(10, 400, color: kMuted)),
          const SizedBox(height: 2),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: inter(15, 700))),
          const SizedBox(height: 2),
          Text(foot, style: inter(9, 400, color: const Color(0xFF9CA3AF))),
        ]),
      );
}

class _InsightRow extends StatelessWidget {
  const _InsightRow({required this.dot, required this.label, required this.value, required this.valueColor});
  final Color dot, valueColor;
  final String label, value;
  @override
  Widget build(BuildContext context) => Row(children: [
        Dot(dot),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: inter(10.5, 400))),
        Text(value, style: inter(10.5, 700, color: valueColor)),
      ]);
}

class _TopItemsCard extends StatelessWidget {
  const _TopItemsCard(this.s, {required this.day});
  final HomeSummary s;
  final String day;
  @override
  Widget build(BuildContext context) => HomeCard(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('TOP PERFORMING ITEMS · $day', style: inter(10, 700, color: kMuted)),
          const SizedBox(height: 6),
          if (s.topItems.isEmpty)
            const EmptyNote('Nothing sold yet today.')
          else
            for (final t in s.topItems)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(child: Text('${t.name} · ${count(t.qty)} sold', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 400))),
                  Text(rupees(t.revenue.round()), style: inter(11, 700)),
                ]),
              ),
        ]),
      );
}

class _OutletOption extends StatelessWidget {
  const _OutletOption({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(children: [
            Expanded(child: Text(label, style: inter(11, selected ? 600 : 400))),
            if (selected) const Icon(LucideIcons.circleCheck, size: 18, color: kLink),
          ]),
        ),
      );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(children: [Icon(icon, size: 20, color: kInk), const SizedBox(width: 14), Text(label, style: inter(12, 500))]),
        ),
      );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final offline = error is! PartnerApiException;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(kPadX),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(offline ? 'We could not reach OneLocal.' : 'Your dashboard did not load.', textAlign: TextAlign.center, style: inter(15, 700)),
          const SizedBox(height: 8),
          Text(offline ? 'Check your internet connection and try again.' : error.toString(), textAlign: TextAlign.center, style: inter(10.5, 400, color: kMuted, height: 1.5)),
          const SizedBox(height: 20),
          SizedBox(width: 200, child: PrimaryAction(label: tr('Try again'), onPressed: onRetry)),
        ]),
      ),
    );
  }
}
