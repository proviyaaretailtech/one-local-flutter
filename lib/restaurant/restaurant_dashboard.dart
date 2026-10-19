import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_nav.dart';
import '../home/home_widgets.dart';
import '../outlets/outlet_header.dart';
import '../outlets/outlet_scope.dart';
import '../service/service_widgets.dart' show svcRupees;
import '../ui/theme.dart';
import 'restaurant_api.dart';

const _notReported = 'Not reported';

/// The home screen of a restaurant, laid out as the founder's Figma frame "restraunt dasboard" (FINAL PARTNER APP, section D, node 1:12410):
/// the outlet header, the My Feed / Sales / Funnel / Service Quality tabs, then the cards of My Feed. Every figure comes from
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
  int _tab = 0; // My Feed, Sales, Funnel, Service Quality
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
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
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
        for (final (i, t) in const ['My Feed', 'Sales', 'Funnel', 'Service Quality'].indexed)
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: switch (_tab) {
            0 => _feed(d),
            1 => _salesTab(d),
            2 => [_comingSoon('Funnel', 'How many guests saw the menu, ordered and paid is not recorded yet.')],
            _ => [_comingSoon('Service Quality', 'Complaints, reviews and ratings are not recorded yet, so there is nothing to show.')],
          },
        ),
      ),
    ],
  );

  Widget _comingSoon(String title, String why) => HomeCard(
    key: ValueKey('rst-soon-$title'),
    padding: const EdgeInsets.all(20),
    child: Column(
      children: [
        const Icon(LucideIcons.hourglass, size: 26, color: kMuted),
        const SizedBox(height: 10),
        Text('Coming soon', style: inter(15, 700)),
        const SizedBox(height: 6),
        Text(why, textAlign: TextAlign.center, style: inter(11.5, 400, color: kMuted, height: 1.4)),
      ],
    ),
  );

  List<Widget> _salesTab(RestaurantDashboardData d) => [
    _salesToday(d),
    const SizedBox(height: 10),
    _todaySoFar(d),
    const SizedBox(height: 10),
    _analytics(d),
  ];

  List<Widget> _feed(RestaurantDashboardData d) {
    final kot = d.kot, tb = d.tables, ol = d.onelocal, low = d.ingredientsLow, rows = d.ingredientRows;
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
                Text('${d.dateLabel} · Restaurant operations', style: inter(11, 400, color: kMuted)),
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
                        Text('${d.orders.i('live')}', style: inter(24, 800, height: 1)),
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
                        Text(pending == null ? '—' : '$pending', style: inter(24, 800, height: 1)),
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
      HomeCard(
        key: const ValueKey('rst-kitchen'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Kitchen status', style: inter(13, 700)),
            const SizedBox(height: 8),
            Row(
              children: [
                kot == null
                    ? _chip(_notReported, kAmberBg, kAmberInk)
                    : _chip('${kot.i('delayed')} delayed', kRedBg, kRedInk),
                const SizedBox(width: 8),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _arrowLink('Open kitchen display', () => HomeNav.go(context, HomeNav.kitchen, 'The kitchen display')),
                  ),
                ),
              ],
            ),
            if (kot == null) const EmptyNote('Not reported: your role cannot see the kitchen display.'),
          ],
        ),
      ),
      const SizedBox(height: 10),
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
      const SizedBox(height: 10),
      HomeCard(
        key: const ValueKey('rst-onelocal'),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('OneLocal orders', style: inter(13, 700)),
                  const SizedBox(height: 2),
                  Text('Manage orders received through OneLocal.', style: inter(10.5, 400, color: kMuted)),
                  const SizedBox(height: 4),
                  Text(
                    ol == null ? _notReported : '${ol.i('open')} open · ${ol.i('today')} today · ${svcRupees(ol.n('sales_today'))}',
                    style: inter(11, 600, color: ol == null ? kAmberInk : kInk),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Material(
              color: kNavy,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                key: const ValueKey('rst-view-orders'),
                borderRadius: BorderRadius.circular(10),
                onTap: () => HomeNav.go(context, HomeNav.orders, 'Online orders'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  child: Text('View orders ›', style: inter(11.5, 600, color: Colors.white)),
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      Row(
        children: [
          Container(
            key: const ValueKey('rst-period'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: kLine)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Last 7 days', style: inter(11.5, 600)),
                const SizedBox(width: 4),
                const Icon(LucideIcons.chevronDown, size: 14, color: kInk),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              key: const ValueKey('rst-compare-label'),
              onTap: () => setState(() => _compare = !_compare),
              child: Text('Compare: Prev period', textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 500, color: kMuted)),
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 46,
            height: 28,
            child: FittedBox(
              child: Switch(
                key: const ValueKey('rst-compare'),
                value: _compare,
                activeTrackColor: kGreenDot,
                onChanged: (v) => setState(() => _compare = v),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      _todaySoFar(d),
      const SizedBox(height: 18),
      Text('Quick Links', style: inter(16, 800)),
      Text('Manage daily operations', style: inter(11, 400, color: kMuted)),
      const SizedBox(height: 10),
      GridView.count(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.0,
        children: [
          _link(LucideIcons.history, 'Order history', () => HomeNav.go(context, HomeNav.orderHistory, 'Order history')),
          _link(LucideIcons.triangleAlert, 'Complaints', () => HomeNav.go(context, HomeNav.complaints, 'Complaints'),
              note: d.notReported.contains('complaints') ? _notReported : null),
          _link(LucideIcons.star, 'Reviews', () => HomeNav.go(context, HomeNav.reviews, 'Reviews'),
              note: d.notReported.contains('reviews') ? _notReported : null),
          _link(LucideIcons.settings, 'Settings', () => HomeNav.go(context, HomeNav.setup, 'Settings')),
          _link(LucideIcons.store, 'Outlet info', () => HomeNav.go(context, HomeNav.setup, 'Outlet info')),
          // Show all = the restaurant More page (Figma 45:7539), the same page as ☰
          _link(LucideIcons.layoutGrid, 'Show all', widget.onMenu),
        ],
      ),
      const SizedBox(height: 18),
      _analytics(d),
      const SizedBox(height: 16),
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
    final reorder = r['reorder_level'] is num ? 'reorder at ${q(r['reorder_level'])}' : 'no reorder level set';
    final critical = r['level'] == 'critical';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${r['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 600)),
                Text('${q(r['available'])} · $reorder', style: inter(10, 400, color: kMuted)),
              ],
            ),
          ),
          _chip(critical ? 'CRITICAL' : 'LOW', kRedBg, kRedInk),
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

  Widget _todaySoFar(RestaurantDashboardData d) {
    final ch = d.channel;
    final open = ch?.i('open_outlets') ?? 0, outlets = ch?.i('outlets') ?? 0;
    final status = ch == null
        ? _notReported
        : outlets > 1
        ? '$open of $outlets open'
        : open > 0
        ? 'Open'
        : 'Paused';
    return HomeCard(
      key: const ValueKey('rst-today-so-far'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _label('Today so far')),
              Dot(ch == null ? kMuted : open > 0 ? kGreenDot : kAmber, size: 10),
              const SizedBox(width: 6),
              Text(status, key: const ValueKey('rst-open'), style: inter(11.5, 600)),
            ],
          ),
          const SizedBox(height: 4),
          Text(svcRupees(d.sales.n('today')), style: inter(26, 800)),
          Text('${d.orders.i('today')} orders received', style: inter(10.5, 400, color: kMuted)),
        ],
      ),
    );
  }

  /// % change against the previous 7 days; null when there is nothing to compare with.
  String? _change(num now, num? before) {
    if (before == null || before == 0) return null;
    return '${((now - before) / before * 100).abs().toStringAsFixed(1)}%';
  }

  Widget _metric(String label, String value, num now, num? before, {required Key key}) {
    final pct = _compare ? _change(now, before) : null;
    final up = before != null && now >= before;
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 10),
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
                      Icon(up ? LucideIcons.trendingUp : LucideIcons.trendingDown, size: 14, color: up ? kUp : kRed),
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
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Sales Analytics', style: inter(14, 800)),
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

  Widget _link(IconData icon, String label, VoidCallback? onTap, {String? note}) => InkWell(
    borderRadius: BorderRadius.circular(12),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: kNavy),
          const SizedBox(height: 6),
          Text(label, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(11, 600)),
          if (note != null) Text(note, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(9, 500, color: kMuted)),
        ],
      ),
    ),
  );

  /// The 7-day bars: today in lime, the tallest earlier day dark, the rest grey (as the frame).
  Widget _chart(List<Map<String, dynamic>> days) {
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
                    Text('${e['label']}', style: inter(9, 500, color: kMuted)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
