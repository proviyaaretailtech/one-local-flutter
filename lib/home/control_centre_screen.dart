import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/auth_repository.dart';
import '../auth/partner_api.dart';
import '../ui/theme.dart';
import 'home_api.dart';
import 'home_nav.dart';
import 'home_widgets.dart';
import '../outlets/outlet_header.dart';
import 'hub_screen.dart';
import 'side_nav.dart';
import '../service/history_screen.dart';
import '../service/service_api.dart';
import '../service/service_dashboard.dart';
import '../restaurant/restaurant_api.dart';
import '../restaurant/restaurant_dashboard.dart';
import '../restaurant/restaurant_more_screen.dart';

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
  late Future<HomeSummary> _summary = _api.summary();
  String? _location;
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
            Text('Show data for', style: inter(15, 600)),
            const SizedBox(height: 8),
            _OutletOption(label: 'All my outlets', selected: _location == null, onTap: () => Navigator.pop(ctx, '')),
            for (final o in s.outlets)
              _OutletOption(label: (o['name'] ?? '') as String, selected: _location == o['id'], onTap: () => Navigator.pop(ctx, o['id'] as String)),
          ]),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    _location = picked.isEmpty ? null : picked;
    _reload();
  }

  void _signOut() {
    (widget.auth ?? AuthRepository()).signOut();
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  void _openMenu() {
    // A store gets the Figma side nav (section D 39:7416); restaurant and service keep the short sheet for now.
    if (_kind != 'restaurant' && _kind != 'service') {
      showStoreSideNav(
        context,
        name: _personName ?? 'Partner',
        email: (widget.auth ?? AuthRepository()).currentEmail,
        onDashboard: () {},
        onReports: _openHub,
        onSignOut: _signOut,
      );
      return;
    }
    // A restaurant gets the Figma More page (section D 45:7539).
    if (_kind == 'restaurant') {
      Navigator.of(context).push(RestaurantMoreScreen.route(outletName: _outletName ?? 'My outlet', outletLine: 'Restaurant', onLogout: _signOut));
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(kPadX, 16, kPadX, 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _MenuRow(icon: LucideIcons.chartColumn, label: 'Sales feed', onTap: () {
              Navigator.pop(ctx);
              _openHub();
            }),
            _MenuRow(icon: LucideIcons.settings, label: 'Settings', onTap: () {
              Navigator.pop(ctx);
              HomeNav.go(context, HomeNav.setup, 'Settings');
            }),
            _MenuRow(icon: LucideIcons.logOut, label: 'Sign out', onTap: () {
              Navigator.pop(ctx);
              _signOut();
            }),
          ]),
        ),
      ),
    );
  }

  void _openHub() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => HubScreen(api: _api, location: _location)));

  void _tab(String label) {
    switch (label) {
      case 'Online order':
      case 'Orders':
        HomeNav.go(context, HomeNav.orders, 'Online orders');
      case 'Bill':
      case 'POS':
        final service = HomeNav.partnerType == 'service' || _kind == 'service';
        HomeNav.go(context, service ? HomeNav.service : HomeNav.bill, service ? 'Appointments' : 'Billing');
      case 'Item':
      case 'Menu':
        HomeNav.go(context, HomeNav.items, label == 'Menu' ? 'The menu' : 'Items');
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
        }
        final loading = snap.connectionState != ConnectionState.done;
        final tabs = s?.outletKind == 'restaurant' ? kHubTabs : kStoreTabs;
        return Scaffold(
          backgroundColor: kBg,
          extendBody: true,
          bottomNavigationBar: SafeArea(top: false, child: FloatingTabBar(tabs: tabs, onTap: _tab)),
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
    final syncLine = '${s.outletName} · ${syncedAt == null ? 'Updated ${ago(s.asOf, now)}' : 'Synced ${ago(syncedAt, now)}'}';
    final gaps = <(String, int)>[
      if ((s.missingDescriptions ?? 0) > 0) ('Missing descriptions', s.missingDescriptions!),
      if ((s.missingPhotos ?? 0) > 0) ('Missing photos', s.missingPhotos!),
      if (restaurant && (s.missingRecipes ?? 0) > 0) ('Missing recipes', s.missingRecipes!),
    ];
    return ListView(
      padding: const EdgeInsets.only(bottom: 132),
      children: [
        // Top bar: the outlet header (outlet name, live status, all-outlets chip, initials) — specs/outlets-multi.
        OutletHeader(title: s.outletName, onMenu: onMenu, safeTop: false, menuKey: const ValueKey('home-menu'), initials: initials(s.personName)),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 16, 0),
          child: Text('OneLocal', style: inter(24, 800, height: 1.1)),
        ),
        // Navy header band.
        Container(
          color: kNavy,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Dot(s.isOpen == true ? kLime : s.isOpen == false ? kRed : kMuted),
              const SizedBox(width: 8),
              Text(
                s.isOpen == true ? 'Store Open' : s.isOpen == false ? 'Store Closed' : 'Status not set',
                style: inter(12, 700, color: s.isOpen == true ? kLime : Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: InkWell(
                  onTap: onOutlet,
                  child: Text(syncLine, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(10, 400, color: const Color(0xFFD1D5DB))),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: _StatTile(
                  label: 'SALES · $day',
                  value: s.salesTotal == null ? '—' : rupees(s.salesTotal!.round()),
                  chip: '${dayLabel(s.day, caps: false)} report',
                  good: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatTile(
                  label: 'ORDERS · $day',
                  value: s.ordersCount == null ? '—' : count(s.ordersCount!),
                  chip: '${s.activeCount ?? 0} active now',
                  good: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: (s.ordersCount ?? 0) == 0 || s.unitsSold == null
                    ? _StatTile(label: 'ITEMS · $day', value: '—', chip: 'Not reported', good: false)
                    : _StatTile(label: 'ITEMS · $day', value: count(s.unitsSold!), chip: 'units sold', good: true),
              ),
            ]),
            const SizedBox(height: 10),
            Material(
              color: const Color(0xFF0E1F12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: Color(0xFF2F4F1F))),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => HomeNav.go(context, HomeNav.orders, 'Orders'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('OPERATIONS · $day', style: inter(10, 700, color: kLime)),
                        const SizedBox(height: 2),
                        Text(
                          '${s.settledCount ?? 0} bills settled · ${s.pax ?? 0} pax · ${s.activeCount ?? 0} open',
                          style: inter(10.5, 400, color: const Color(0xFFD1D5DB)),
                        ),
                      ]),
                    ),
                    Text('View', style: inter(10, 500, color: kMuted)),
                  ]),
                ),
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (gaps.isNotEmpty) ...[
              _AttentionCard(day: dayLabel(s.day, caps: false), total: s.itemsTotal ?? 0, gaps: gaps, restaurant: restaurant),
              const SizedBox(height: 20),
            ],
            SectionHeader(
              'Active orders',
              badge: GreyTag('${s.activeCount ?? 0} active', dot: (s.activeCount ?? 0) > 0 ? kRed : kMuted),
              action: 'View all',
              onAction: () => HomeNav.go(context, HomeNav.orders, 'Orders'),
            ),
            const SizedBox(height: 12),
            if (s.activeOrders.isEmpty)
              const HomeCard(child: EmptyNote('No open orders right now.'))
            else
              for (final o in s.activeOrders) ...[_OrderCard(o), const SizedBox(height: 8)],
            const SizedBox(height: 12),
            SectionHeader('Stock health', action: 'Full report', onAction: () => HomeNav.go(context, HomeNav.stock, 'Stock')),
            const SizedBox(height: 12),
            _StockCard(s),
            if (s.stock.isNotEmpty) ...[
              const SizedBox(height: 8),
              LimeOnDarkButton(label: 'Restock critical items', onPressed: () => HomeNav.go(context, HomeNav.lowStock, 'Restocking')),
            ],
            const SizedBox(height: 20),
            SectionHeader('Business insights', badge: GreyTag(day), action: 'See all', onAction: onInsights),
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
                child: Padding(padding: const EdgeInsets.all(4), child: Text('Need help? Contact support', style: inter(11, 600))),
              ),
            ),
          ]),
        ),
      ],
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

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value, required this.chip, required this.good});
  final String label, value, chip;
  final bool good;
  @override
  Widget build(BuildContext context) => Container(
        height: 82,
        padding: const EdgeInsets.fromLTRB(10, 10, 6, 8),
        decoration: BoxDecoration(color: kNavyTile, borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(8, 500, color: const Color(0xFF9CA3AF))),
          const SizedBox(height: 2),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: inter(18, 700, color: Colors.white))),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: good ? const Color(0xFF173D12) : const Color(0xFF2D1F08), borderRadius: BorderRadius.circular(12)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Dot(good ? kLime : kAmber, size: 6),
              const SizedBox(width: 5),
              Flexible(child: Text(chip, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(10.5, 500, color: good ? kLime : kAmber))),
            ]),
          ),
        ]),
      );
}

class _AttentionCard extends StatelessWidget {
  const _AttentionCard({required this.day, required this.total, required this.gaps, required this.restaurant});
  final String day;
  final int total;
  final List<(String, int)> gaps;
  final bool restaurant;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: kAmberBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: kAmber)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 20,
              height: 20,
              margin: const EdgeInsets.only(top: 2),
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: kAmber, shape: BoxShape.circle),
              child: Text('!', style: inter(10, 800, color: Colors.white)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Item data needs attention', style: inter(12, 700)),
                const SizedBox(height: 2),
                Text('$day · $total ${restaurant ? 'menu' : 'catalogue'} items', style: inter(10, 400, color: kAmberInk)),
              ]),
            ),
          ]),
          const SizedBox(height: 10),
          for (final (label, n) in gaps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Expanded(child: Text(label, style: inter(10.5, 400, color: kMuted))),
                Text('$n ${n == 1 ? 'item' : 'items'}', style: inter(10.5, 700, color: kAmberInk)),
              ]),
            ),
          const SizedBox(height: 10),
          LimeOnDarkButton(label: 'Review item data', height: 34, onPressed: () => HomeNav.go(context, HomeNav.items, 'Item editing')),
        ]),
      );
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
      return const HomeCard(child: EmptyNote('Stock is not tracked for this outlet yet. Once stock items have reorder levels, the ones running low show here.'));
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
          Expanded(child: _SoftTile(label: 'Revenue', value: s.salesTotal == null ? '—' : rupees(s.salesTotal!.round()), foot: '${s.ordersCount ?? 0} orders')),
          const SizedBox(width: 8),
          Expanded(
            child: s.expenses == null
                ? const _SoftTile(label: 'Expenses', value: '—', foot: 'Not tracked yet')
                : _SoftTile(label: 'Expenses', value: rupees(s.expenses!.round()), foot: dayLabel(s.day, caps: false)),
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
          label: 'GRN received',
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
          SizedBox(width: 200, child: PrimaryAction(label: 'Try again', onPressed: onRetry)),
        ]),
      ),
    );
  }
}
