import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/net_guard.dart';
import '../devices/printer_router.dart' show channelName;
import '../orders/order_screen.dart';
import '../orders/order_widgets.dart';
import '../orders/orders_api.dart';
import '../tables/bill_api.dart' show money;
import '../ui/i18n.dart';
import '../ui/theme.dart';

/// All Orders in a restaurant's side menu (founder, 6 Nov 2026): every order, newest first: dine-in, takeaway, delivery and online, open,
/// paid or cancelled. It opened the store's online-order piles, which left out every dine-in bill. Search by bill number or customer; a
/// filter for open, paid or cancelled; 50 at a time from `pos_order_history`, then Show more. A tap opens the order.
class RstAllOrdersScreen extends StatefulWidget {
  const RstAllOrdersScreen({super.key, this.api, this.onNavigate});
  final OrdersApi? api;
  final ValueChanged<String>? onNavigate;
  @override
  State<RstAllOrdersScreen> createState() => _RstAllOrdersScreenState();
}

class _RstAllOrdersScreenState extends State<RstAllOrdersScreen> {
  static const _page = 50;
  static const _filters = [('all', 'All'), ('pending', 'Open'), ('completed', 'Paid'), ('cancelled', 'Cancelled')];

  late final OrdersApi _api = widget.api ?? OrdersApi();
  final _search = TextEditingController();
  Timer? _debounce;
  String _filter = 'all';
  List<OrderCard>? _orders;
  String? _error;
  bool _more = false, _loadingMore = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final mine = ++_seq;
    try {
      final rows = await _api.history(filter: _filter, q: _search.text);
      if (!mounted || mine != _seq) return;
      setState(() {
        _orders = rows;
        _more = rows.length >= _page && rows.last.createdAt.isNotEmpty;
        _error = null;
      });
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() => _error = errorSentence(e));
    }
  }

  Future<void> _loadMore() async {
    final have = _orders;
    if (have == null || have.isEmpty || _loadingMore) return;
    final mine = _seq;
    setState(() => _loadingMore = true);
    try {
      final rows = await _api.history(filter: _filter, q: _search.text, before: have.last.createdAt);
      if (!mounted || mine != _seq) return;
      setState(() {
        _orders = [...have, ...rows];
        _more = rows.length >= _page && rows.last.createdAt.isNotEmpty;
      });
    } catch (e) {
      if (mounted) showToast(context, errorSentence(e));
    }
    if (mounted) setState(() => _loadingMore = false);
  }

  void _pick(String filter) {
    if (filter == _filter) return;
    setState(() {
      _filter = filter;
      _orders = null;
      _error = null;
    });
    _load();
  }

  Future<void> _open(OrderCard o) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(api: _api, orderId: o.id, onNavigate: widget.onNavigate)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final orders = _orders;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        OrdersTopBar(title: tr('All Orders'), onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 110), // the floating bottom bar sits over the end of the list
              children: [
                _searchField(),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [for (final (id, label) in _filters) _chip(id, label)]),
                ),
                const SizedBox(height: 12),
                if (_error != null && orders == null) ...[
                  const SizedBox(height: 30),
                  Text(_error!, key: const ValueKey('all-orders-error'), textAlign: TextAlign.center, style: inter(14, 400, color: kMuted)),
                  const SizedBox(height: 12),
                  Center(child: SmallPill('Try again', onTap: _load)),
                ] else if (orders == null) ...[
                  const SizedBox(height: 60),
                  const Center(child: CircularProgressIndicator(color: kGreenText)),
                ] else if (orders.isEmpty) ...[
                  const SizedBox(height: 40),
                  Text(_search.text.trim().isEmpty && _filter == 'all' ? tr('No orders yet.') : tr('No orders match.'),
                      key: const ValueKey('all-orders-empty'), textAlign: TextAlign.center, style: inter(14, 400, color: kMuted)),
                ] else ...[
                  for (final o in orders) _card(o),
                  if (_more)
                    Center(
                      child: _loadingMore
                          ? const Padding(padding: EdgeInsets.all(10), child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: kInk)))
                          : SmallPill('Show more', key: const ValueKey('all-orders-more'), onTap: _loadMore),
                    ),
                ],
              ],
            ),
          ),
        ),
      ]),
    );
  }

  Widget _searchField() => Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: const Color(0xFFDADCD5))),
        child: Row(children: [
          const Icon(LucideIcons.search, size: 18, color: kMuted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              key: const ValueKey('all-orders-search'),
              controller: _search,
              style: inter(14, 400),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(border: InputBorder.none, isCollapsed: true, hintText: tr('Search by bill number or customer'), hintStyle: inter(14, 400, color: kHint)),
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 350), _load);
              },
              onSubmitted: (_) => _load(),
            ),
          ),
        ]),
      );

  Widget _chip(String id, String label) {
    final on = id == _filter;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        key: ValueKey('all-orders-filter-$id'),
        borderRadius: BorderRadius.circular(999),
        onTap: () => _pick(id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(color: on ? kInk : Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: on ? kInk : kLine)),
          child: Text(tr(label), style: inter(13, 700, color: on ? Colors.white : kInk)),
        ),
      ),
    );
  }

  Widget _card(OrderCard o) {
    final kind = o.channel.isEmpty ? o.channelLabel : channelName(o.channel);
    final cancelled = o.status == 'cancelled';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: ValueKey('all-order-${o.id}'),
          borderRadius: BorderRadius.circular(14),
          onTap: () => _open(o),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('#${o.displayNo}', style: inter(15, 800))),
                Text(money(o.total), style: inter(15, 800, color: cancelled ? kMuted : kInk)),
              ]),
              const SizedBox(height: 4),
              Text('$kind · ${o.customer}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13, 500, color: kMuted)),
              Text(o.placedAt, style: inter(12.5, 400, color: kMuted)),
              const SizedBox(height: 6),
              Text(cancelled ? tr('Cancelled') : o.paymentStatus, style: inter(12.5, 700, color: cancelled ? kError : (o.status == 'completed' ? kGreenText : const Color(0xFFB45309)))),
            ]),
          ),
        ),
      ),
    );
  }
}
