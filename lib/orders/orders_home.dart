import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';
import 'cart_screen.dart';
import 'order_screen.dart';
import 'order_widgets.dart';
import 'orders_api.dart';

/// Section E entry (Figma "Orders History"): every order of this business, newest first, with search and
/// All / Completed / Pending / Cancelled. The control centre (section D) links here.
/// [onNavigate] receives the bottom-bar tabs this section does not own ('money', 'item', 'online', 'stock'); 'bill' opens a new cart.
class OrdersHome extends StatefulWidget {
  const OrdersHome({super.key, this.api, this.onNavigate, this.onMenu});
  final OrdersApi? api;
  final ValueChanged<String>? onNavigate;
  final VoidCallback? onMenu;
  @override
  State<OrdersHome> createState() => _OrdersHomeState();
}

class _OrdersHomeState extends State<OrdersHome> {
  late final OrdersApi _api = widget.api ?? OrdersApi();
  final _search = TextEditingController();
  Timer? _debounce;
  String _filter = 'all';
  List<OrderCard>? _orders;
  String? _error;
  int _seq = 0;

  static const _filters = [('all', 'All'), ('completed', 'Completed'), ('pending', 'Pending'), ('cancelled', 'Cancelled')];

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
        _error = null;
      });
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() => _error = e.toString());
    }
  }

  void _open(String id) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(api: _api, orderId: id, onNavigate: widget.onNavigate)));
    if (mounted) _load();
  }

  void _tab(String id) async {
    if (id == 'bill') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CartScreen(api: _api, onNavigate: widget.onNavigate)));
      if (mounted) _load();
      return;
    }
    if (widget.onNavigate != null) {
      widget.onNavigate!(id);
    } else {
      showToast(context, 'That part of the app is not built yet.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        OrdersTopBar(title: 'Orders History', onMenu: widget.onMenu),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
              children: [
                _searchField(),
                const SizedBox(height: 12),
                _filterRow(),
                const SizedBox(height: 14),
                Row(children: [
                  const Expanded(child: Kick('Recent orders')),
                  if (_orders != null) Text('${_orders!.length} ${_orders!.length == 1 ? 'order' : 'orders'}', style: inter(11.5, 400, color: kKicker)),
                ]),
                const SizedBox(height: 10),
                ..._body(),
              ],
            ),
          ),
        ),
        PosBottomNav(active: 'bill', onTap: _tab),
      ]),
    );
  }

  Widget _searchField() => Container(
        height: 42,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: const Color(0xFFDADCD5))),
        child: Row(children: [
          const SizedBox(width: 14),
          const Icon(LucideIcons.search, size: 18, color: kMuted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _search,
              style: inter(14, 400),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(border: InputBorder.none, isCollapsed: true, hintText: 'Search by order ID or customer', hintStyle: inter(14, 400, color: kMuted)),
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 350), _load);
              },
              onSubmitted: (_) => _load(),
            ),
          ),
        ]),
      );

  Widget _filterRow() => Row(children: [
        for (final (id, label) in _filters) ...[
          if (id != 'all') const SizedBox(width: 8),
          Expanded(
            child: Material(
              color: _filter == id ? kDark : Colors.white,
              shape: StadiumBorder(side: BorderSide(color: _filter == id ? kDark : const Color(0xFFDADCD5))),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () {
                  setState(() => _filter = id);
                  _load();
                },
                child: SizedBox(
                  height: 34,
                  child: Center(child: Text(label, style: inter(12.5, 600, color: _filter == id ? kLime : kInk))),
                ),
              ),
            ),
          ),
        ],
      ]);

  List<Widget> _body() {
    if (_error != null && _orders == null) {
      return [
        const SizedBox(height: 40),
        Text(_error!, textAlign: TextAlign.center, style: inter(14, 400, color: kMuted)),
        const SizedBox(height: 12),
        Center(child: SmallPill('Try again', onTap: _load)),
      ];
    }
    if (_orders == null) return const [SizedBox(height: 60), Center(child: CircularProgressIndicator(color: kGreenText))];
    if (_orders!.isEmpty) {
      return [
        const SizedBox(height: 40),
        Text(_search.text.isEmpty && _filter == 'all' ? 'No orders yet. Bills you make appear here.' : 'No orders match.', textAlign: TextAlign.center, style: inter(14, 400, color: kMuted)),
      ];
    }
    return [for (final o in _orders!) Padding(padding: const EdgeInsets.only(bottom: 12), child: _OrderHistoryCard(order: o, onOpen: () => _open(o.id)))];
  }
}

class _OrderHistoryCard extends StatelessWidget {
  const _OrderHistoryCard({required this.order, required this.onOpen});
  final OrderCard order;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final o = order;
    return OrderCardBox(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Order #${o.displayNo}', style: inter(16, 800))),
          TagChip(o.channelLabel),
        ]),
        const SizedBox(height: 3),
        Text('Customer: ${o.customer}', style: inter(12.5, 400, color: kMuted)),
        const SizedBox(height: 8),
        Text(o.placedAt, style: inter(12.5, 400, color: kMuted)),
        const SizedBox(height: 10),
        Row(children: [
          DotChip.status(o.status, o.statusLabel),
          const Spacer(),
          Text(rupees(o.total), style: inter(22, 800, color: kGreenText)),
        ]),
        const SizedBox(height: 8),
        KeyValue('Items', o.items),
        KeyValue('Payment status', o.paymentStatus),
        KeyValue('Payment mode', o.paymentMode),
        KeyValue('Delivery status', o.deliveryStatus),
        KeyValue('Delivery time', o.deliveryTime),
        KeyValue('Refund / Damages', o.refundDamages),
        const Divider(height: 18, color: kLine),
        InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Expanded(child: Text('View details', style: inter(14, 600, color: kGreenText))),
              const Icon(LucideIcons.chevronRight, size: 18, color: kGreenText),
            ]),
          ),
        ),
      ]),
    );
  }
}
