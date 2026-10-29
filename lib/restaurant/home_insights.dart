import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_nav.dart';
import '../home/home_widgets.dart';
import '../orders/channel_orders.dart' show ChannelLogo, ChannelLook;
import '../orders/orders_board_screen.dart' show OrdersBoardScreen;
import '../service/service_widgets.dart' show svcRupees;
import '../ui/theme.dart';
import 'restaurant_api.dart';

/// More on the restaurant Home's My Feed (founder, 27 Oct 2026), from data the app already keeps:
///   * Delivery today - OneLocal, Swiggy, Zomato and on-call orders with their logos (`rst_channel_orders`)
///   * How orders were served - dine in, takeaway, delivery, and the average bill
///   * Payments today - cash, card, UPI
///   * Top dishes today
///   * Menu health - food cost, dishes over 45%, few left to make, missing recipe / photo / description
/// (`rst_home_insights`). It loads on its own; when the server cannot answer, the cards are left out and the rest of Home stands.
class RestaurantInsights extends StatefulWidget {
  const RestaurantInsights({super.key, required this.api, this.locationId});
  final RestaurantApi api;
  final String? locationId;
  @override
  State<RestaurantInsights> createState() => _RestaurantInsightsState();
}

class _RestaurantInsightsState extends State<RestaurantInsights> {
  Map<String, dynamic>? _i, _ch;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final i = await widget.api.insights(locationId: widget.locationId);
      if (mounted) setState(() => _i = i);
    } catch (_) {/* extra cards: without them Home still shows everything else */}
    try {
      final c = await widget.api.deliveryChannels(locationId: widget.locationId);
      if (mounted) setState(() => _ch = c);
    } catch (_) {}
  }

  static Map<String, dynamic> _m(Object? v) => v is Map ? v.cast<String, dynamic>() : const {};
  static List<Map<String, dynamic>> _l(Object? v) => [for (final e in (v as List?) ?? const []) _m(e)];
  static num _n(Object? v) => v is num ? v : num.tryParse('$v') ?? 0;

  Widget _title(String t, {String? sub, String? link, VoidCallback? onLink, Key? linkKey}) => Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t, style: inter(13, 700)),
            if (sub != null) Text(sub, style: inter(10.5, 400, color: kMuted)),
          ]),
        ),
        if (link != null)
          InkWell(key: linkKey, onTap: onLink, child: Padding(padding: const EdgeInsets.all(4), child: Text('$link ›', style: inter(11.5, 600, color: kLink)))),
      ]);

  @override
  Widget build(BuildContext context) {
    final i = _i, ch = _ch;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (ch != null && _l(ch['channels']).isNotEmpty) ...[const SizedBox(height: 10), _delivery(ch)],
      if (i != null) ...[
        const SizedBox(height: 10),
        _served(_m(i['mix'])),
        if (_l(i['payments']).isNotEmpty) ...[const SizedBox(height: 10), _payments(_l(i['payments']))],
        if (_l(i['top']).isNotEmpty) ...[const SizedBox(height: 10), _top(_l(i['top']))],
        const SizedBox(height: 10),
        _menu(_m(i['menu']), _n(i['ready']).toInt()),
      ],
    ]);
  }

  // ---- Delivery today: one tile per source, with its logo
  Widget _delivery(Map<String, dynamic> ch) {
    final cs = _l(ch['channels']);
    return HomeCard(
      key: const ValueKey('rst-delivery'),
      onTap: () => HomeNav.go(context, HomeNav.orders, 'Orders'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _title('Delivery today', sub: 'OneLocal, Swiggy, Zomato and phone orders', link: 'Orders', onLink: () => HomeNav.go(context, HomeNav.orders, 'Orders')),
        const SizedBox(height: 10),
        Row(children: [
          for (final (n, c) in cs.indexed) ...[
            if (n > 0) const SizedBox(width: 8),
            Expanded(
              // a source's tile opens its delivery list in Orders
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  OrdersBoardScreen.requestedDelivery.value = (source: '${c['key']}', orderId: null);
                  HomeNav.go(context, HomeNav.orders, 'Orders');
                },
                child: Container(
                key: ValueKey('rst-delivery-${c['key']}'),
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
                decoration: BoxDecoration(
                  color: ChannelLook.of('${c['key']}').from.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: ChannelLook.of('${c['key']}').from.withValues(alpha: 0.25)),
                ),
                child: Column(children: [
                  ChannelLogo('${c['key']}', width: 44, height: 32, radius: 8),
                  const SizedBox(height: 6),
                  Text('${_n(c['count']).toInt()}', style: inter(18, 800, height: 1)),
                  Text(svcRupees(_n(c['total'])), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(10.5, 600, color: kMuted)),
                  if (_n(c['new']) > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('${_n(c['new']).toInt()} new', style: inter(10, 700, color: ChannelLook.of('${c['key']}').ink)),
                    ),
                ]),
              ),
              ),
            ),
          ],
        ]),
      ]),
    );
  }

  // ---- How orders were served: a split bar and the three ways, with the average bill
  Widget _served(Map<String, dynamic> mix) {
    final by = _l(mix['by']);
    final total = _n(mix['orders']);
    const colors = {'dine_in': Color(0xFF2563EB), 'takeaway': Color(0xFFEA580C), 'delivery': Color(0xFF7C3AED)};
    return HomeCard(
      key: const ValueKey('rst-served'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _title('How orders were served', sub: '${total.toInt()} orders today · average bill ${svcRupees(_n(mix['avg_bill']))}'),
        const SizedBox(height: 10),
        if (total > 0)
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 10,
              child: Row(children: [
                for (final b in by)
                  if (_n(b['orders']) > 0) Expanded(flex: _n(b['orders']).toInt(), child: ColoredBox(color: colors['${b['key']}'] ?? kMuted)),
              ]),
            ),
          ),
        const SizedBox(height: 10),
        for (final b in by)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: colors['${b['key']}'] ?? kMuted, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(child: Text('${b['label']}', style: inter(12.5, 600))),
              Text('${_n(b['orders']).toInt()} · ', key: ValueKey('rst-served-${b['key']}'), style: inter(12.5, 500, color: kMuted)),
              Text(svcRupees(_n(b['sales'])), style: inter(12.5, 700)),
            ]),
          ),
      ]),
    );
  }

  // ---- Payments today
  Widget _payments(List<Map<String, dynamic>> pays) {
    final sum = pays.fold<num>(0, (a, p) => a + _n(p['amount']));
    String name(String m) => switch (m) { 'cash' => 'Cash', 'card' => 'Card', 'upi' => 'UPI', 'wallet' => 'Wallet', _ => m.isEmpty ? 'Other' : m[0].toUpperCase() + m.substring(1) };
    IconData icon(String m) => switch (m) { 'cash' => LucideIcons.banknote, 'card' => LucideIcons.creditCard, 'upi' => LucideIcons.smartphone, _ => LucideIcons.wallet };
    return HomeCard(
      key: const ValueKey('rst-payments'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _title('Payments today', sub: '${svcRupees(sum)} collected'),
        const SizedBox(height: 10),
        for (final p in pays)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              Icon(icon('${p['method']}'), size: 18, color: kInk),
              const SizedBox(width: 8),
              SizedBox(width: 54, child: Text(name('${p['method']}'), style: inter(12.5, 600))),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: sum <= 0 ? 0 : (_n(p['amount']) / sum).toDouble(),
                    minHeight: 8,
                    backgroundColor: const Color(0xFFF1F2EE),
                    color: const Color(0xFF3DB800),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(svcRupees(_n(p['amount'])), key: ValueKey('rst-pay-${p['method']}'), style: inter(12.5, 700)),
            ]),
          ),
      ]),
    );
  }

  // ---- Top dishes today
  Widget _top(List<Map<String, dynamic>> top) => HomeCard(
        key: const ValueKey('rst-top'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title('Top dishes today', sub: 'By quantity sold'),
          const SizedBox(height: 8),
          for (final (n, d) in top.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: n == 0 ? const Color(0xFFFEF3C7) : const Color(0xFFF1F2EE), shape: BoxShape.circle),
                  child: Text('${n + 1}', style: inter(11, 800, color: n == 0 ? const Color(0xFFB45309) : kInk)),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text('${d['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13, 600))),
                Text('${_n(d['qty']).toInt()} sold · ', style: inter(12, 500, color: kMuted)),
                Text(svcRupees(_n(d['sales'])), style: inter(12.5, 700)),
              ]),
            ),
        ]),
      );

  // ---- Menu health: food cost, dishes to fix, and what is low
  Widget _menu(Map<String, dynamic> m, int ready) {
    final avg = m['food_cost_avg'] as num?;
    final high = _l(m['high_cost']), low = _l(m['low']);
    final (bg, ink) = avg == null
        ? (const Color(0xFFF1F2EE), kMuted)
        : avg <= 35
            ? (const Color(0xFFDCFCE7), const Color(0xFF15803D))
            : avg <= 45
                ? (const Color(0xFFFEF3C7), const Color(0xFFB45309))
                : (const Color(0xFFFEE2E2), const Color(0xFFB91C1C));
    Widget chip(String t, Color b, Color i, {Key? key}) => Container(
          key: key,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: b, borderRadius: BorderRadius.circular(8)),
          child: Text(t, style: inter(11, 600, color: i)),
        );
    final missing = [
      if (_n(m['no_recipe']) > 0) '${_n(m['no_recipe']).toInt()} without a recipe',
      if (_n(m['no_photo']) > 0) '${_n(m['no_photo']).toInt()} without a photo',
      if (_n(m['no_description']) > 0) '${_n(m['no_description']).toInt()} without a description',
    ];
    return HomeCard(
      key: const ValueKey('rst-menu-health'),
      onTap: () => HomeNav.go(context, HomeNav.menu, 'The menu'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _title('Menu health', sub: '${_n(m['dishes']).toInt()} dishes', link: 'Menu', onLink: () => HomeNav.go(context, HomeNav.menu, 'The menu')),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          chip(avg == null ? 'Food cost not set' : 'Food cost ${avg.toStringAsFixed(1)}%', bg, ink, key: const ValueKey('rst-food-cost')),
          if (_n(m['out']) > 0) chip('${_n(m['out']).toInt()} out of stock', const Color(0xFFFEE2E2), const Color(0xFFB91C1C)),
          if (ready > 0) chip('$ready ready to serve', const Color(0xFFDBEAFE), const Color(0xFF1D4ED8), key: const ValueKey('rst-ready')),
          if (missing.isEmpty) chip('Every dish has a recipe, photo and description', const Color(0xFFDCFCE7), const Color(0xFF15803D)),
        ]),
        if (high.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('Food cost too high (over 45%)', style: inter(11.5, 700, color: const Color(0xFFB91C1C))),
          const SizedBox(height: 4),
          for (final h in high)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(children: [
                Expanded(child: Text('${h['name']}', style: inter(12.5, 500))),
                Text('${_n(h['pct']).toStringAsFixed(1)}%', style: inter(12.5, 700, color: const Color(0xFFB91C1C))),
              ]),
            ),
          Padding(padding: const EdgeInsets.only(top: 4), child: Text('Raise the price or use less of the costly ingredient in Menu → Recipe.', style: inter(10.5, 400, color: kMuted))),
        ],
        if (low.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('Running low · can be made', style: inter(11.5, 700, color: const Color(0xFFB45309))),
          const SizedBox(height: 4),
          for (final l in low)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(children: [
                Expanded(child: Text('${l['name']}', style: inter(12.5, 500))),
                Text('${_n(l['can_make']).toInt()} left', style: inter(12.5, 700, color: const Color(0xFFB45309))),
              ]),
            ),
        ],
        if (missing.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(missing.join(' · '), key: const ValueKey('rst-menu-missing'), style: inter(11.5, 500, color: kMuted)),
        ],
      ]),
    );
  }
}
