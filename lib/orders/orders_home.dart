import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';
import 'cart_screen.dart';
import 'order_screen.dart';
import 'order_widgets.dart';
import 'orders_api.dart';
import '../ui/i18n.dart';
import '../ui/wallet.dart';

/// Section E entry (Figma "Orders History") as a wallet (founder, 27 Oct 2026): the orders sit in three piles, Pending (orange),
/// Completed (green) and Cancelled (grey). Tapping a pile fans its orders out as cards; tapping a card opens its details. Search
/// narrows every pile. The control centre (section D) links here.
/// [onNavigate] receives the bottom-bar tabs this section does not own ('home', 'item', 'online', 'stock'); 'bill' opens a new cart.
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
  List<OrderCard>? _orders;
  String? _error;
  int _seq = 0;
  String? _pile; // null: the three piles; else the pile that is fanned out
  String? _openId; // the order card that is open

  static const _piles = [('pending', 'Pending', LucideIcons.clock), ('completed', 'Completed', LucideIcons.circleCheck), ('cancelled', 'Cancelled', LucideIcons.circleX)];

  static List<Color> _colors(String pile) => switch (pile) {
        'completed' => WalletColors.green,
        'cancelled' => WalletColors.slate,
        _ => WalletColors.orange,
      };

  static String _pileOf(OrderCard o) => o.status == 'completed' || o.status == 'cancelled' ? o.status : 'pending';

  List<OrderCard> _in(String pile) => (_orders ?? const <OrderCard>[]).where((o) => _pileOf(o) == pile).toList();

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
      final rows = await _api.history(q: _search.text); // every order; the piles sort them
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
        OrdersTopBar(title: tr('Orders History'), onMenu: widget.onMenu),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
              children: [
                _searchField(),
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
        PosBottomNav(active: 'online', onTap: _tab), // Orders History is the store's Online order tab
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
              decoration: InputDecoration(border: InputBorder.none, isCollapsed: true, hintText: tr('Search by order ID or customer'), hintStyle: inter(14, 400, color: kMuted)),
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 350), _load);
              },
              onSubmitted: (_) => _load(),
            ),
          ),
        ]),
      );

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
        Text(_search.text.isEmpty ? 'No orders yet. Bills you make appear here.' : 'No orders match.', textAlign: TextAlign.center, style: inter(14, 400, color: kMuted)),
      ];
    }
    return [
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: _pile == null ? _overview() : _fanned(_pile!),
      ),
    ];
  }

  /// The three piles, one under another.
  Widget _overview() => Column(key: const ValueKey('orders-piles'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (id, label, icon) in _piles) ...[
          _pileCard(id, label, icon),
          const SizedBox(height: 14),
        ],
      ]);

  Widget _pileCard(String id, String label, IconData icon) {
    final list = _in(id);
    final worth = list.fold<num>(0, (n, o) => n + o.total);
    return WalletPile(
      key: ValueKey('orders-pile-$id'),
      colors: _colors(id),
      behind: list.length - 1,
      onTap: list.isEmpty ? null : () => setState(() {
        _pile = id;
        _openId = null;
      }),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
          child: Icon(icon, size: 20, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${tr(label)} · ${list.length}', style: inter(18, 800, color: Colors.white)),
            onWallet(list.isEmpty ? tr('None right now') : list.take(3).map((o) => o.customer).join(', ')),
          ]),
        ),
        Text(rupees(worth), style: inter(18, 800, color: Colors.white)),
        if (list.isNotEmpty) ...[const SizedBox(width: 4), const Icon(LucideIcons.chevronRight, size: 18, color: Colors.white)],
      ]),
    );
  }

  /// One pile fanned out: the other piles as small tabs on top, then its orders as cards tucked under each other.
  Widget _fanned(String pile) {
    final list = _in(pile);
    return Column(key: ValueKey('orders-fanned-$pile'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        for (final (i, (id, label, _)) in _piles.indexed) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: WalletCard(
              key: ValueKey('orders-tab-$id'),
              colors: _colors(id),
              radius: 14,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
              onTap: () => setState(() {
                _pile = id == pile ? null : id;
                _openId = null;
              }),
              child: Center(
                child: Text('${tr(label)} ${_in(id).length}', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: inter(12.5, id == pile ? 800 : 600, color: Colors.white.withValues(alpha: id == pile ? 1 : 0.8))),
              ),
            ),
          ),
        ],
      ]),
      const SizedBox(height: 6),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('orders-all-piles'),
          onPressed: () => setState(() => _pile = null),
          icon: const Icon(LucideIcons.layers, size: 15, color: kLink),
          label: Text(tr('All piles'), style: inter(13, 700, color: kLink)),
        ),
      ),
      if (list.isEmpty) Padding(padding: const EdgeInsets.all(20), child: Text(tr('No orders here.'), textAlign: TextAlign.center, style: inter(14, 400, color: kMuted))),
      for (final (i, o) in list.indexed)
        Align(
          alignment: Alignment.topCenter,
          heightFactor: o.id == _openId || i == list.length - 1 ? 1 : 0.7,
          child: Padding(padding: const EdgeInsets.only(bottom: 10), child: _orderCard(o, pile)),
        ),
    ]);
  }

  Widget _orderCard(OrderCard o, String pile) {
    final open = o.id == _openId;
    return WalletCard(
      key: ValueKey('order-card-${o.id}'),
      colors: _colors(pile),
      onTap: () => setState(() => _openId = open ? null : o.id),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.topCenter,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('Order #${o.displayNo}', style: inter(16, 800, color: Colors.white))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(99)),
              child: Text(o.channelLabel, style: inter(11.5, 700, color: Colors.white)),
            ),
          ]),
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                onWallet(o.customer, size: 15, weight: 700, alpha: 1),
                onWallet(o.placedAt, size: 12.5),
              ]),
            ),
            Text(rupees(o.total), style: inter(20, 800, color: Colors.white)),
          ]),
          if (open) ...[
            const SizedBox(height: 10),
            for (final (k, v) in [
              ('Status', o.statusLabel),
              ('Items', o.items),
              ('Payment status', o.paymentStatus),
              ('Payment mode', o.paymentMode),
              ('Delivery status', o.deliveryStatus),
              ('Delivery time', o.deliveryTime),
              ('Refund / Damages', o.refundDamages),
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: onWallet(tr(k), size: 12.5, alpha: 0.75)),
                  const SizedBox(width: 10),
                  Flexible(child: Text(v, textAlign: TextAlign.right, style: inter(12.5, 700, color: Colors.white))),
                ]),
              ),
            const SizedBox(height: 10),
            Material(
              color: Colors.white,
              shape: const StadiumBorder(),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => _open(o.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(tr('View details'), style: inter(14, 800)),
                    const SizedBox(width: 4),
                    const Icon(LucideIcons.chevronRight, size: 16, color: kInk),
                  ]),
                ),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
