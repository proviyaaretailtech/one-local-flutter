import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../ui/app_header.dart';
import '../ui/theme.dart';
import 'home_api.dart';
import 'home_nav.dart';
import 'home_widgets.dart';
import '../ui/i18n.dart';

/// Figma section D "split-nav-hub": the owner's feed across their outlets. Figures from
/// `GET /api/partner/home/feed`. Funnel and Service Quality have no data source yet and say so.
class HubScreen extends StatefulWidget {
  const HubScreen({super.key, this.api, this.location});
  final HomeApi? api;

  /// The outlet the control centre was showing, or null for all of the person's outlets.
  final String? location;

  @override
  State<HubScreen> createState() => _HubScreenState();
}

const _ranges = [(1, 'Today'), (7, 'Last 7 days'), (30, 'Last 30 days')];
const _pills = ['My Feed', 'Sales']; // Funnel and Service Quality removed (founder, 28 Oct 2026)

class _HubScreenState extends State<HubScreen> {
  late final HomeApi _api = widget.api ?? HomeApi();
  late String? _location = widget.location;
  int _days = 7;
  bool _compare = true;
  String _pill = _pills.first;
  late Future<HubFeed> _feed = _load();

  Future<HubFeed> _load() => _api.feed(days: _days, compare: _compare, location: _location);

  void _reload() {
    final next = _load();
    setState(() {
      _feed = next;
    });
  }

  Future<void> _pickRange() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(kPadX, 24, kPadX, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Period'), style: inter(15, 600)),
            for (final (d, label) in _ranges)
              _SheetOption(label: label, selected: d == _days, onTap: () => Navigator.pop(ctx, d)),
          ]),
        ),
      ),
    );
    if (picked == null || picked == _days) return;
    _days = picked;
    _reload();
  }

  Future<void> _pickOutlet(HubFeed f) async {
    if (f.outlets.length < 2 && _location == null) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(kPadX, 24, kPadX, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Show data for'), style: inter(15, 600)),
            _SheetOption(label: tr('All my outlets'), selected: _location == null, onTap: () => Navigator.pop(ctx, '')),
            for (final o in f.outlets)
              _SheetOption(label: (o['name'] ?? '') as String, selected: _location == o['id'], onTap: () => Navigator.pop(ctx, o['id'] as String)),
          ]),
        ),
      ),
    );
    if (picked == null) return;
    _location = picked.isEmpty ? null : picked;
    _reload();
  }

  void _tab(String label) {
    switch (label) {
      case 'Orders':
        HomeNav.go(context, HomeNav.orders, 'Orders');
      case 'Bill':
      case 'POS':
        // The hub carries the restaurant bar: Bill opens the floor first (founder, 2026-10-20).
        HomeNav.go(context, HomeNav.tables ?? HomeNav.bill, 'Tables');
      case 'Menu':
        HomeNav.go(context, HomeNav.menu ?? HomeNav.items, 'The menu');
      case 'Stock':
        HomeNav.go(context, HomeNav.stock, 'Stock');
      case 'Home':
        HomeNav.go(context, HomeNav.home, 'Home');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kHubBg,
      extendBody: true,
      bottomNavigationBar: SafeArea(top: false, child: FloatingTabBar(tabs: kHubTabs, onTap: _tab, current: 'Home')),
      body: SafeArea(
        bottom: false,
        child: FutureBuilder<HubFeed>(
          future: _feed,
          builder: (context, snap) {
            final loaded = snap.data;
            // the shared banner (founder, 22 Oct 2026); the scope ("All outlets (5) ▾", the switcher) is the line under "Reports"
            final header = AppHeader(
              title: tr('Reports'),
              safeTop: false,
              subtitle: loaded == null
                  ? null
                  : InkWell(
                      key: const ValueKey('hub-outlet'),
                      onTap: () => _pickOutlet(loaded),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Flexible(child: Text(loaded.scopeLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13.5, 500, color: kMuted))),
                        if (loaded.outlets.length > 1 || _location != null) ...[const SizedBox(width: 2), const Icon(LucideIcons.chevronDown, size: 14, color: kMuted)],
                      ]),
                    ),
            );
            Widget body() {
              if (snap.connectionState != ConnectionState.done && loaded == null) return const Center(child: CircularProgressIndicator(color: kLink));
              if (snap.hasError) return _HubError(error: snap.error!, onRetry: _reload);
              return _feedList(context, loaded!);
            }

            return Column(children: [header, Expanded(child: body())]);
          },
        ),
      ),
    );
  }

  Widget _feedList(BuildContext context, HubFeed f) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 132),
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final p in _pills) ...[
                      _Pill(label: p, selected: p == _pill, onTap: () => setState(() => _pill = p)),
                      const SizedBox(width: 8),
                    ],
                  ]),
                ),
                const SizedBox(height: 18),
                ...[
                  Row(children: [
                    InkWell(
                      key: const ValueKey('hub-range'),
                      onTap: _pickRange,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: kLine)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(_ranges.firstWhere((r) => r.$1 == _days).$2, style: inter(11, 600)),
                          const SizedBox(width: 8),
                          const Icon(LucideIcons.chevronDown, size: 16, color: kInk),
                        ]),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text('Compare: Prev period', textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(10.5, 400, color: kMuted))),
                    const SizedBox(width: 8),
                    Switch(
                      key: const ValueKey('hub-compare'),
                      value: _compare,
                      activeThumbColor: Colors.white,
                      activeTrackColor: kCheck,
                      onChanged: (v) {
                        _compare = v;
                        _reload();
                      },
                    ),
                  ]),
                  const SizedBox(height: 16),
                  if (_pill == 'My Feed') ...[
                    _TodayCard(f),
                    const SizedBox(height: 24),
                    Text(tr('Quick Links'), style: inter(16.5, 700)),
                    Text(tr('Manage daily operations'), style: inter(11, 400, color: kMuted)),
                    const SizedBox(height: 16),
                    const _QuickLinks(),
                    const SizedBox(height: 20),
                  ],
                  _AnalyticsCard(f, compare: _compare),
                ],
              ],
            );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: selected ? kNavy : Colors.white,
        shape: StadiumBorder(side: BorderSide(color: selected ? kNavy : kLine)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(label, style: inter(11, selected ? 600 : 500, color: selected ? Colors.white : const Color(0xFF4B5563))),
          ),
        ),
      );
}

class _TodayCard extends StatelessWidget {
  const _TodayCard(this.f);
  final HubFeed f;
  @override
  Widget build(BuildContext context) => HomeCard(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
        radius: 20,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(tr('Today so far'), style: inter(11, 500, color: kMuted)),
            const Spacer(),
            Dot(f.isOpen == true ? kUp : f.isOpen == false ? kRed : kMuted, size: 14),
            const SizedBox(width: 6),
            Text(f.isOpen == true ? 'Open' : f.isOpen == false ? 'Closed' : 'Status not set', style: inter(10.5, 500)),
          ]),
          const SizedBox(height: 12),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(rupees(f.todaySales.round()), style: inter(27, 800))),
          const SizedBox(height: 6),
          Text('${count(f.todayOrders)} ${f.todayOrders == 1 ? 'order' : 'orders'} received', style: inter(11, 400, color: kMuted)),
        ]),
      );
}

class _QuickLinks extends StatelessWidget {
  const _QuickLinks();
  @override
  Widget build(BuildContext context) {
    final links = <(IconData, String, VoidCallback)>[
      (LucideIcons.history, 'Order history', () => HomeNav.go(context, HomeNav.orderHistory, 'Order history')),
      (LucideIcons.triangleAlert, 'Complaints', () => HomeNav.go(context, HomeNav.complaints, 'Complaints')),
      (LucideIcons.star, 'Reviews', () => HomeNav.go(context, HomeNav.reviews, 'Reviews')),
      (LucideIcons.users, 'Team', () => HomeNav.go(context, HomeNav.team, 'Team')),
      (LucideIcons.settings, 'Settings', () => HomeNav.go(context, HomeNav.setup, 'Settings')),
      (LucideIcons.store, 'Storefront', () => HomeNav.go(context, HomeNav.storefront, 'Storefront')),
      (LucideIcons.layoutGrid, 'Show all', () => HomeNav.go(context, null, 'The full list')),
    ];
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      padding: EdgeInsets.zero, // not the bottom bar's inset, which the list already leaves room for
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.5,
      children: [
        for (final (icon, label, onTap) in links)
          HomeCard(
            onTap: onTap,
            padding: const EdgeInsets.all(8),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 20, color: kInk),
              const SizedBox(height: 8),
              Text(label, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(10.5, 600)),
            ]),
          ),
      ],
    );
  }
}

class _AnalyticsCard extends StatelessWidget {
  const _AnalyticsCard(this.f, {required this.compare});
  final HubFeed f;
  final bool compare;
  @override
  Widget build(BuildContext context) {
    return HomeCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      radius: 20,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(tr('Sales Analytics'), style: inter(15, 700)),
          const Spacer(),
          const Icon(LucideIcons.ellipsis, size: 20, color: kMuted),
        ]),
        const SizedBox(height: 10),
        _Metric(label: tr('Net sales'), value: rupees(f.netSales.round()), change: compare ? percentChange(f.netSales, f.prevNetSales) : null),
        const Divider(height: 20, color: kLine),
        _Metric(label: tr('Orders completed'), value: count(f.delivered), change: compare ? percentChange(f.delivered, f.prevDelivered) : null),
        const Divider(height: 20, color: kLine),
        _Metric(label: tr('Average order value'), value: f.aov == null ? '—' : rupees(f.aov!.round()), change: compare ? percentChange(f.aov, f.prevAov) : null),
        const SizedBox(height: 16),
        if (f.daily.length > 1) SalesBars(days: f.daily) else const SizedBox.shrink(),
        const SizedBox(height: 16),
        Material(
          color: kLimeCta,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => HomeNav.go(context, HomeNav.money, 'Detailed reports'),
            child: SizedBox(
              height: 40,
              child: Center(child: Text('Get deeper insights →', style: inter(12, 700, color: kPrimary))),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.change});
  final String label, value;
  final double? change;
  @override
  Widget build(BuildContext context) {
    final c = change;
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: inter(11, 400, color: kMuted)),
          const SizedBox(height: 2),
          Text(value, style: inter(19.5, 800)),
        ]),
      ),
      if (c != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            Icon(c >= 0 ? LucideIcons.arrowUpRight : LucideIcons.arrowDownRight, size: 16, color: c >= 0 ? kUp : kRed),
            const SizedBox(width: 4),
            Text('${c.abs().toStringAsFixed(c.abs() >= 10 ? 0 : 1)}%', style: inter(11, 600, color: c >= 0 ? kUp : kRed)),
          ]),
        ),
    ]);
  }
}

/// Daily takings as bars: today lime, the best day navy, the rest grey (Figma hub chart).
class SalesBars extends StatelessWidget {
  const SalesBars({super.key, required this.days});
  final List<DayTotal> days;

  static const _week = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  /// Axis top: the peak rounded up to a "nice" step (₹60k for a ₹54k peak).
  static num axisTop(num peak) {
    if (peak <= 0) return 0;
    final mag = math.pow(10, (math.log(peak) / math.ln10).floor());
    for (final step in [1, 2, 3, 5, 6, 10]) {
      if (step * mag >= peak) return step * mag;
    }
    return 10 * mag;
  }

  static String short(num v) {
    if (v >= 100000) return '₹${(v / 100000).toStringAsFixed(v % 100000 == 0 ? 0 : 1)}L';
    if (v >= 1000) return '₹${(v / 1000).toStringAsFixed(v % 1000 == 0 ? 0 : 1)}k';
    return '₹${v.round()}';
  }

  @override
  Widget build(BuildContext context) {
    final peak = days.map((d) => d.sales).fold<num>(0, math.max);
    final top = axisTop(peak);
    final best = peak > 0 ? days.lastIndexWhere((d) => d.sales == peak) : -1;
    final labelEvery = days.length > 10 ? 5 : 1;
    return SizedBox(
      height: 150,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 36,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 22),
            child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(short(top), style: inter(7.5, 400, color: const Color(0xFF9CA3AF))),
              Text(short(top / 2), style: inter(7.5, 400, color: const Color(0xFF9CA3AF))),
              Text('₹0', style: inter(7.5, 400, color: const Color(0xFF9CA3AF))),
            ]),
          ),
        ),
        const SizedBox(width: 6),
        for (var i = 0; i < days.length; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: days.length > 10 ? 1 : 3),
              child: Column(children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      heightFactor: top == 0 ? 0.02 : math.max(0.02, days[i].sales / top),
                      child: Container(
                        decoration: BoxDecoration(
                          color: i == days.length - 1 ? kLimeCta : i == best ? kNavy : kLine,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 22,
                  child: Center(
                    child: (days.length - 1 - i) % labelEvery == 0
                        ? Text(
                            days.length > 7 ? '${days[i].day.day}' : _week[days[i].day.weekday - 1],
                            maxLines: 1,
                            style: inter(8, i == days.length - 1 ? 700 : 400, color: i == days.length - 1 ? kInk : const Color(0xFF9CA3AF)),
                          )
                        : null,
                  ),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}

class _SheetOption extends StatelessWidget {
  const _SheetOption({required this.label, required this.selected, required this.onTap});
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

class _HubError extends StatelessWidget {
  const _HubError({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(kPadX),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(error is PartnerApiException ? 'Your sales feed did not load.' : 'We could not reach OneLocal.', textAlign: TextAlign.center, style: inter(15, 700)),
            const SizedBox(height: 8),
            Text(error is PartnerApiException ? error.toString() : 'Check your internet connection and try again.', textAlign: TextAlign.center, style: inter(10.5, 400, color: kMuted, height: 1.5)),
            const SizedBox(height: 20),
            SizedBox(width: 200, child: PrimaryAction(label: tr('Try again'), onPressed: onRetry)),
            const SizedBox(height: 8),
            TextButton(onPressed: () => Navigator.maybePop(context), child: Text(tr('Back'), style: inter(11, 600, color: kLink))),
          ]),
        ),
      );
}
