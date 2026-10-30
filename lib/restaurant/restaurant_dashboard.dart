import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_nav.dart';
import '../home/home_widgets.dart';
import '../outlets/outlet_header.dart';
import '../outlets/outlet_scope.dart';
import '../service/service_widgets.dart' show svcRupees;
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'home_insights.dart';
import 'restaurant_api.dart';

const _notReported = 'Not reported';

/// The home screen of a restaurant, laid out as the founder's Figma frame "restraunt dasboard" (FINAL PARTNER APP, section D, node 1:12410):
/// the outlet header, the My Feed / Sales tabs, then the cards of My Feed. Every figure comes from
/// `rst_dashboard_scope` (0491, 0524, 0570). A figure the database cannot supply is drawn as "Not reported", never as zero; a tab with no
/// source yet says "Coming soon".
class RestaurantHomeBody extends StatefulWidget {
  const RestaurantHomeBody({
    super.key,
    required this.api,
    required this.personName,
    required this.onMenu,
    this.onInsights,
  });
  final RestaurantApi api;
  final String personName;
  final VoidCallback onMenu;
  final VoidCallback? onInsights;
  @override
  State<RestaurantHomeBody> createState() => _RestaurantHomeBodyState();
}

class _RestaurantHomeBodyState extends State<RestaurantHomeBody> {
  // the outlet chosen in the header's switcher; null = all outlets (summed by rst_dashboard_scope)
  String? _location = OutletScope.selected.value;
  late Future<RestaurantDashboardData> _f = widget.api.dashboard(locationId: _location);
  int _tab = 0; // My Feed, Sales
  int _refreshes = 0; // a pull to refresh reloads the extra Home cards too
  bool _compare = true; // "Compare: Prev period"

  @override
  void initState() {
    super.initState();
    OutletScope.selected.addListener(_followScope);
  }

  @override
  void dispose() {
    OutletScope.selected.removeListener(_followScope);
    super.dispose();
  }

  void _followScope() {
    if (!mounted || OutletScope.selected.value == _location) return;
    _location = OutletScope.selected.value;
    _reload();
  }

  Future<void> _reload() async {
    final next = widget.api.dashboard(locationId: _location);
    setState(() {
      _f = next;
      _refreshes++;
    });
    try {
      await next;
    } catch (_) {
      // drawn by the builder
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<RestaurantDashboardData>(
    future: _f,
    builder: (context, snap) {
      if (snap.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator(color: kLink));
      }
      if (snap.hasError) {
        final msg = snap.error is RestaurantApiException
            ? (snap.error as RestaurantApiException).message
            : 'Could not load the dashboard. Check the connection and try again.';
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(msg, textAlign: TextAlign.center, style: inter(14, 500)),
                const SizedBox(height: 12),
                LimeOnDarkButton(label: 'Try again', onPressed: _reload),
              ],
            ),
          ),
        );
      }
      return RefreshIndicator(
        color: kLink,
        onRefresh: _reload,
        child: _content(snap.data!),
      );
    },
  );

  // ---- small pieces of the frame ----

  static const _blueBg = Color(0xFFDBEAFE), _blueInk = Color(0xFF1D4ED8);
  static const _greenBg = Color(0xFFDCFCE7), _greenInk = Color(0xFF15803D);

  Widget _chip(String label, Color bg, Color ink, {Key? key}) => Container(
    key: key,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
    child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(10, 600, color: ink)),
  );

  Widget _arrowLink(String label, VoidCallback? onTap) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text('$label ›', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 600)),
    ),
  );

  Widget _label(String t) => Text(t, style: inter(11, 500, color: kMuted));

  Widget _tabs() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      children: [
        for (final (i, t) in const ['My Feed', 'Sales'].indexed) // Funnel and Service Quality removed (founder, 28 Oct 2026)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              key: ValueKey('rst-tab-$t'),
              borderRadius: BorderRadius.circular(20),
              onTap: () => setState(() => _tab = i),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: _tab == i ? kNavy : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _tab == i ? kNavy : kLine),
                ),
                child: Text(t, style: inter(12, 600, color: _tab == i ? Colors.white : kInk)),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _content(RestaurantDashboardData d) => ListView(
    padding: const EdgeInsets.only(bottom: 132),
    children: [
      // the outlet header (specs/outlets-multi): "SHOWING DATA FOR / All outlets (N) ▾", bell, ☰; its switcher drives OutletScope
      OutletHeader(title: d.locationName, onMenu: widget.onMenu, safeTop: false, menuKey: const ValueKey('home-menu'), dashboard: true),
      const SizedBox(height: 4),
      _tabs(),
      const SizedBox(height: 14),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          key: ValueKey('rst-tab-body-$_tab'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          // the tab's sections build in one after another; switching tabs plays it again (lib/ui/motion.dart)
          children: staggered(switch (_tab) {
            0 => _feed(d),
            _ => _salesTab(d),
          }),
        ),
      ),
    ],
  );

  List<Widget> _salesTab(RestaurantDashboardData d) => [
    _salesToday(d),
    const SizedBox(height: 16),
    Row(
      children: [
        Expanded(child: Text('Last 7 days', key: const ValueKey('rst-period'), style: inter(15, 800))),
        InkWell(
          key: const ValueKey('rst-compare-label'),
          onTap: () => setState(() => _compare = !_compare),
          child: Text('Compare with the 7 days before', style: inter(11, 500, color: kMuted)),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 46,
          height: 28,
          child: FittedBox(
            child: Switch(key: const ValueKey('rst-compare'), value: _compare, activeTrackColor: kGreenDot, onChanged: (v) => setState(() => _compare = v)),
          ),
        ),
      ],
    ),
    const SizedBox(height: 8),
    _analytics(d),
  ];

  List<Widget> _feed(RestaurantDashboardData d) {
    final kot = d.kot, tb = d.tables, low = d.ingredientsLow, rows = d.ingredientRows;
    final split = d.orders.raw.containsKey('new');
    final pending = kot == null ? null : kot.i('new') + kot.i('in_progress');
    return [
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Restaurant Dashboard', style: inter(18, 800)),
                const SizedBox(height: 2),
                Text('Today · Restaurant operations', style: inter(11, 400, color: kMuted)),
              ],
            ),
          ),
          _chip('LIVE', _greenBg, _greenInk, key: const ValueKey('rst-live')),
        ],
      ),
      const SizedBox(height: 12),
      IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: HomeCard(
                key: const ValueKey('rst-orders'),
                onTap: () => HomeNav.go(context, HomeNav.orders, 'Orders'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label('Orders'),
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        CountUp(d.orders.i('live'), style: inter(24, 800, height: 1)),
                        const SizedBox(width: 6),
                        Flexible(child: Text('Live orders', overflow: TextOverflow.ellipsis, style: inter(10.5, 500, color: kMuted))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: split
                          ? [
                              _chip('${d.orders.i('new')} new', _blueBg, _blueInk),
                              _chip('${d.orders.i('in_progress')} in progress', kAmberBg, kAmberInk),
                            ]
                          : [_chip(_notReported, kAmberBg, kAmberInk)],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: HomeCard(
                key: const ValueKey('rst-kots'),
                onTap: () => HomeNav.go(context, HomeNav.kitchen, 'The kitchen display'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label('KOTs'),
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        pending == null ? Text('—', style: inter(24, 800, height: 1)) : CountUp(pending, style: inter(24, 800, height: 1)),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(pending == null ? _notReported : 'Pending', overflow: TextOverflow.ellipsis, style: inter(10.5, 500, color: kMuted)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (kot != null)
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _chip('${kot.i('critical')} critical', kRedBg, kRedInk),
                          Text('Kitchen queue', style: inter(10, 500, color: kMuted)),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      // no Kitchen status card (founder, 28 Oct 2026): the kitchen is in Orders → KDS view
      HomeCard(
        key: const ValueKey('rst-tables'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Tables', style: inter(13, 700))),
                _arrowLink('View tables', () => HomeNav.go(context, HomeNav.tables, 'Tables')),
                const SizedBox(width: 10),
                Text(tb == null ? _notReported : '${tb.i('all')} total', style: inter(11, 500, color: kMuted)),
              ],
            ),
            const SizedBox(height: 8),
            if (tb == null)
              const EmptyNote('Not reported: your role cannot see the floor.')
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _chip('${tb.i('available')} Available', _greenBg, _greenInk),
                  _chip('${tb.i('occupied')} Occupied', _blueBg, _blueInk),
                  _chip('${tb.i('reserved')} Reserved', kAmberBg, kAmberInk),
                  _chip('${tb.i('cleaning')} Cleaning', const Color(0xFFF1F2F4), const Color(0xFF4B5563)),
                ],
              ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      _salesToday(d),
      // more from the day's data (0607, 0608): delivery by source, how orders were served, payments, top dishes, menu health
      RestaurantInsights(key: ValueKey('rst-insights-${_location ?? 'all'}-$_refreshes'), api: widget.api, locationId: _location),
      const SizedBox(height: 10),
      HomeCard(
        key: const ValueKey('rst-ingredients'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('Ingredients', style: inter(13, 700))),
                _arrowLink('View stock', () => HomeNav.go(context, HomeNav.lowStock, 'Restocking')),
                const SizedBox(width: 8),
                low == null
                    ? _chip(_notReported, kAmberBg, kAmberInk)
                    : _chip('${low.i('low') + low.i('critical')} low stock', kRedBg, kRedInk),
              ],
            ),
            if (low != null && rows != null)
              for (final r in rows) _ingredient(r)
            else if (low != null && low.i('low') + low.i('critical') == 0)
              const EmptyNote('Nothing is below its reorder level.'),
          ],
        ),
      ),
      // My Feed is today's operations; sales, the period and analytics live on the Sales tab, and every other page is in the side bar
      // (founder, 29 Oct 2026: no repeated blocks).
      const SizedBox(height: 18),
      Center(
        child: InkWell(
          onTap: () => HomeNav.go(context, HomeNav.support, 'Support'),
          child: Padding(padding: const EdgeInsets.all(4), child: Text('Need help? Contact support', style: inter(11, 600))),
        ),
      ),
    ];
  }

  Widget _ingredient(Map<String, dynamic> r) {
    final unit = '${r['unit'] ?? ''}'.trim();
    String q(Object? v) {
      if (v is! num) return '';
      final s = v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
      return unit.isEmpty ? s : '$s $unit';
    }
    // one quiet line each: a red (out / critical) or amber (low) dot, the name, and what is left
    final critical = r['level'] == 'critical';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: critical ? kRedInk : kAmberInk, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(child: Text('${r['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12.5, 600))),
          Text('${q(r['available'])} left', style: inter(11.5, 600, color: critical ? kRedInk : kAmberInk)),
        ],
      ),
    );
  }

  Widget _salesToday(RestaurantDashboardData d) => HomeCard(
    key: const ValueKey('rst-sales-today'),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label('Sales today'),
              const SizedBox(height: 4),
              Text(svcRupees(d.sales.n('today')), style: inter(22, 800)),
              if (d.sales.n('refunds') > 0)
                Text('${svcRupees(d.sales.n('refunds'))} refunded', style: inter(10, 400, color: kMuted)),
            ],
          ),
        ),
        Text('${d.orders.i('today')} orders received', style: inter(10.5, 500, color: kMuted)),
      ],
    ),
  );

  /// % change against the previous 7 days; null when there is nothing to compare with.
  String? _change(num now, num? before) {
    if (before == null || before == 0) return null;
    return '${((now - before) / before * 100).abs().toStringAsFixed(1)}%';
  }

  Widget _metric(String label, String value, num now, num? before, {required Key key}) {
    final pct = _compare ? _change(now, before) : null;
    final up = before != null && now >= before;
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.only(bottom: 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: kLine))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label(label),
                Text(value, style: inter(18, 800)),
              ],
            ),
          ),
          if (_compare)
            pct == null
                ? Text('No earlier data', style: inter(10, 500, color: kMuted))
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(up ? LucideIcons.arrowUpRight : LucideIcons.arrowDownRight, size: 14, color: up ? kUp : kRed),
                      const SizedBox(width: 4),
                      Text(pct, style: inter(11.5, 700, color: up ? kUp : kRed)),
                    ],
                  ),
        ],
      ),
    );
  }

  Widget _analytics(RestaurantDashboardData d) {
    final sales = d.last7.fold<num>(0, (a, e) => a + (e['sales'] is num ? e['sales'] as num : 0));
    final orders = d.last7.fold<num>(0, (a, e) => a + (e['orders'] is num ? e['orders'] as num : 0));
    final p = d.prev7;
    final aov = orders > 0 ? sales / orders : 0;
    final pAov = p == null || p.n('orders') == 0 ? null : p.n('sales') / p.n('orders');
    return HomeCard(
      key: const ValueKey('rst-analytics'),
      padding: const EdgeInsets.all(18),
      radius: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [Expanded(child: Text('Sales Analytics', style: inter(15, 800))), const Icon(LucideIcons.ellipsis, size: 18, color: kMuted)]),
          Text('Last 7 days${_compare ? ' vs the 7 days before' : ''}', style: inter(10, 400, color: kMuted)),
          const SizedBox(height: 12),
          _metric('Net sales', svcRupees(sales), sales, p?.n('sales'), key: const ValueKey('rst-net-sales')),
          _metric('Orders delivered', '$orders', orders, p?.n('orders'), key: const ValueKey('rst-orders-delivered')),
          _metric('Average order value', orders > 0 ? svcRupees(aov.round()) : '—', aov, pAov, key: const ValueKey('rst-aov')),
          const SizedBox(height: 4),
          d.last7.isEmpty ? const EmptyNote('No sales in the last 7 days.') : _chart(d.last7),
          const SizedBox(height: 12),
          Material(
            color: kLimeCta,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              key: const ValueKey('rst-insights'),
              borderRadius: BorderRadius.circular(12),
              onTap: widget.onInsights,
              child: Container(
                height: 40,
                alignment: Alignment.center,
                child: Text('Get deeper insights →', style: inter(12.5, 700, color: kNavy)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The 7-day bars: today in lime, the tallest earlier day dark, the rest grey (as the frame).
  String _axis(num v) => v >= 1000 ? '₹${(v / 1000).round()}k' : '₹${v.round()}';

  Widget _chart(List<Map<String, dynamic>> days) {
    num top0 = days.fold<num>(0, (m, e) => e['sales'] is num && (e['sales'] as num) > m ? e['sales'] as num : m);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 82,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final f in [1, 0.5, 0]) Text(_axis(top0 * f), style: inter(8, 500, color: kMuted)),
            ],
          ),
        ),
        const SizedBox(width: 4),
        Expanded(child: _bars(days)),
      ],
    );
  }

  Widget _bars(List<Map<String, dynamic>> days) {
    num v(Map<String, dynamic> e) => e['sales'] is num ? e['sales'] as num : 0;
    final top = days.fold<num>(0, (m, e) => v(e) > m ? v(e) : m);
    final earlier = days.take(days.length - 1).fold<num>(0, (m, e) => v(e) > m ? v(e) : m);
    return SizedBox(
      height: 96,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final (i, e) in days.indexed)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      key: ValueKey('bar-${e['date']}'),
                      height: top > 0 ? 4 + 64 * (v(e) / top) : 4,
                      decoration: BoxDecoration(
                        color: i == days.length - 1
                            ? kLimeCta
                            : (v(e) > 0 && v(e) == earlier)
                            ? kNavy
                            : const Color(0xFFE5E7EB),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text('${e['label']}', style: inter(9, i == days.length - 1 ? 700 : 500, color: i == days.length - 1 ? kInk : kMuted)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
