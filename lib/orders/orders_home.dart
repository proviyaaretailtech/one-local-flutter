import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/net_guard.dart';
import '../sell/history_screen.dart';
import '../sell/sell_env.dart';
import '../ui/theme.dart';
import 'cart_screen.dart';
import 'order_screen.dart';
import 'order_widgets.dart';
import 'orders_api.dart';
import '../ui/i18n.dart';
import '../ui/wallet.dart';

/// The Online order tab as a wallet (founder, 27 Oct 2026): online orders sit in piles by where they are, in the order they need the
/// shop: New orders (accept them), In progress (being packed or on the way), Packed · waiting for rider, Return requested, Delivered.
/// Cancelled ones are a small link under the piles. Counter bills are not online orders, so they are not here (they live in Carts).
/// Tapping a pile fans its orders out; tapping a card opens its details. Search narrows every pile.
/// [onNavigate] receives the bottom-bar tabs this section does not own ('home', 'item', 'online', 'stock'); 'bill' opens a new cart.
/// Past orders (31 Oct 2026) lists the online orders of a day, a week, a month or a chosen month.
class OrdersHome extends StatefulWidget {
  const OrdersHome({super.key, this.api, this.onNavigate, this.onMenu, this.sellEnv});
  final OrdersApi? api;

  /// What Past orders reads the orders with (tests pass a fake).
  final SellEnv? sellEnv;
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

  // (state, name, what it means, icon), in the order the shop needs them
  static const _piles = [
    ('new', 'New orders', 'Waiting for you to accept', LucideIcons.bellRing),
    ('ongoing', 'In progress', 'Being packed or on the way', LucideIcons.packageOpen),
    ('ready', 'Packed · waiting for rider', 'Ready to hand over', LucideIcons.bike),
    ('return', 'Return requested', 'Delivered, the customer wants to return', LucideIcons.undo2),
    ('delivered', 'Delivered', 'Done', LucideIcons.circleCheck),
  ];

  /// The short names on the tabs, so none is cut.
  static String _short(String pile) => switch (pile) {
    'new' => 'New',
    'ongoing' => 'In progress',
    'ready' => 'Packed',
    'return' => 'Returns',
    'delivered' => 'Delivered',
    _ => 'Cancelled',
  };

  static List<Color> _colors(String pile) => switch (pile) {
    'new' => WalletColors.orange,
    'ongoing' => WalletColors.blue,
    'ready' => WalletColors.purple,
    'return' => WalletColors.rose,
    'delivered' => WalletColors.green,
    _ => WalletColors.slate,
  };

  /// Online orders only: a counter bill is not one.
  List<OrderCard> get _online => (_orders ?? const <OrderCard>[]).where((o) => o.state != 'counter').toList();

  List<OrderCard> _in(String pile) => _online.where((o) => o.state == pile).toList();

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
      setState(() => _error = errorSentence(e));
    }
  }

  void _open(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OrderScreen(api: _api, orderId: id, onNavigate: widget.onNavigate),
      ),
    );
    if (mounted) _load();
  }

  /// Past orders: the online orders by date; one opens its own page.
  Future<void> _past() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => HistoryScreen(
        env: widget.sellEnv ?? SellEnv(),
        source: 'online',
        onOpen: _open,
        bottomNav: PosBottomNav(active: 'online', onTap: _tab),
      ),
    ));
    if (mounted) _load();
  }

  void _tab(String id) async {
    if (id == 'bill') {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CartScreen(api: _api, onNavigate: widget.onNavigate),
        ),
      );
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
    return PopScope(
      canPop: _pile == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _pile = null);
      },
      child: Scaffold(
        backgroundColor: kBg,
        body: Column(
          children: [
            OrdersTopBar(title: tr('Orders History'), onMenu: widget.onMenu),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
                  children: [
                    _searchField(),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        const Expanded(child: Kick('Online orders')),
                        if (_orders != null) Text('${_online.length} ${_online.length == 1 ? 'order' : 'orders'}', style: inter(11.5, 400, color: kKicker)),
                        const SizedBox(width: 10),
                        SmallPill('Past orders', key: const ValueKey('orders-past'), onTap: _past),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ..._body(),
                  ],
                ),
              ),
            ),
            PosBottomNav(active: 'online', onTap: _tab), // Orders History is the store's Online order tab
          ],
        ),
      ),
    );
  }

  Widget _searchField() => Container(
    height: 42,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: const Color(0xFFDADCD5)),
    ),
    child: Row(
      children: [
        const SizedBox(width: 14),
        const Icon(LucideIcons.search, size: 18, color: kMuted),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            controller: _search,
            style: inter(14, 400),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              border: InputBorder.none,
              isCollapsed: true,
              hintText: tr('Search by order ID or customer'),
              hintStyle: inter(14, 400, color: kMuted),
            ),
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 350), _load);
            },
            onSubmitted: (_) => _load(),
          ),
        ),
      ],
    ),
  );

  List<Widget> _body() {
    if (_error != null && _orders == null) {
      return [
        const SizedBox(height: 40),
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: inter(14, 400, color: kMuted),
        ),
        const SizedBox(height: 12),
        Center(child: SmallPill('Try again', onTap: _load)),
      ];
    }
    if (_orders == null) return const [SizedBox(height: 60), Center(child: CircularProgressIndicator(color: kGreenText))];
    if (_online.isEmpty) {
      return [
        const SizedBox(height: 40),
        Text(
          _search.text.isEmpty ? 'No online orders yet. Orders customers place appear here.' : 'No orders match.',
          textAlign: TextAlign.center,
          style: inter(14, 400, color: kMuted),
        ),
      ];
    }
    return [AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: _pile == null ? _overview() : _fanned(_pile!))];
  }

  /// The three piles, one under another.
  Widget _overview() {
    final cancelled = _in('cancelled');
    return Column(
      key: const ValueKey('orders-piles'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (id, label, line, icon) in _piles) ...[_pileCard(id, label, line, icon), const SizedBox(height: 14)],
        if (cancelled.isNotEmpty)
          Center(
            child: TextButton.icon(
              key: const ValueKey('orders-cancelled'),
              onPressed: () => setState(() {
                _pile = 'cancelled';
                _openId = null;
              }),
              icon: const Icon(LucideIcons.circleX, size: 15, color: kMuted),
              label: Text('${tr('Cancelled')} · ${cancelled.length}', style: inter(13, 600, color: kMuted)),
            ),
          ),
      ],
    );
  }

  Widget _pileCard(String id, String label, String line, IconData icon) {
    final list = _in(id);
    final worth = list.fold<num>(0, (n, o) => n + o.total);
    return WalletPile(
      key: ValueKey('orders-pile-$id'),
      colors: _colors(id),
      behind: list.length - 1,
      onTap: list.isEmpty
          ? null
          : () => setState(() {
              _pile = id;
              _openId = null;
            }),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
            child: Icon(icon, size: 20, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${tr(label)} · ${list.length}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: inter(17, 800, color: Colors.white),
                ),
                onWallet(list.isEmpty ? tr(line) : '${tr(line)} · ${list.take(2).map((o) => o.customer).join(', ')}'),
              ],
            ),
          ),
          Text(rupees(worth), style: inter(18, 800, color: Colors.white)),
          if (list.isNotEmpty) ...[const SizedBox(width: 4), const Icon(LucideIcons.chevronRight, size: 18, color: Colors.white)],
        ],
      ),
    );
  }

  /// One pile fanned out: the other piles as small tabs on top, then its orders as cards tucked under each other.
  Widget _fanned(String pile) {
    final list = _in(pile);
    return Column(
      key: ValueKey('orders-fanned-$pile'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // back to the piles, and which pile this is
        Row(
          children: [
            IconButton(
              key: const ValueKey('orders-all-piles'),
              tooltip: tr('Back'),
              style: IconButton.styleFrom(
                backgroundColor: Colors.white,
                side: const BorderSide(color: Color(0xFFDADCD5)),
              ),
              onPressed: () => setState(() => _pile = null),
              icon: const Icon(LucideIcons.arrowLeft, size: 20, color: kInk),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${tr(pile == 'cancelled' ? 'Cancelled' : _piles.firstWhere((p) => p.$1 == pile).$2)} · ${list.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: inter(17, 800),
                  ),
                  if (pile != 'cancelled')
                    Text(
                      tr(_piles.firstWhere((p) => p.$1 == pile).$3),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: inter(12.5, 400, color: kMuted),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final (i, (id, _, _, _)) in _piles.indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                SizedBox(
                  width: 112,
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
                      child: Text(
                        '${tr(_short(id))} ${_in(id).length}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: inter(12.5, id == pile ? 800 : 600, color: Colors.white.withValues(alpha: id == pile ? 1 : 0.8)),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              tr('No orders here.'),
              textAlign: TextAlign.center,
              style: inter(14, 400, color: kMuted),
            ),
          ),
        for (final (i, o) in list.indexed)
          Padding(
            padding: EdgeInsets.only(bottom: i == list.length - 1 ? 0 : 10),
            child: _orderCard(o, pile),
          ),
      ],
    );
  }

  /// One order in an opened pile (founder, 27 Oct 2026): a white card with the pile's colour as its border and accent; the customer
  /// leads, big and in that colour, the order number is small. Tap to open the details.
  Widget _orderCard(OrderCard o, String pile) {
    final open = o.id == _openId;
    final accent = _colors(pile).first;
    return Container(
      key: ValueKey('order-card-${o.id}'),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: open ? 1 : 0.55), width: open ? 2 : 1.5),
        boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.10), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => setState(() => _openId = open ? null : o.id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(o.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(17, 800, color: accent)),
                      const SizedBox(height: 1),
                      Text('#${o.displayNo} · ${o.placedAt}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 500, color: kMuted)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Text(rupees(o.total), style: inter(17, 800)),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  // exactly where it is ("Picking · 2 of 5 units", "Ready · not handed over")
                  Container(width: 7, height: 7, decoration: BoxDecoration(color: accent, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      o.state == 'return' ? '${tr('Return requested')} · ${o.deliveryStatus}' : o.deliveryStatus,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: inter(12.5, 600, color: kInk),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: accent.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(99)),
                    child: Text(o.channelLabel, style: inter(10.5, 700, color: accent)),
                  ),
                  const SizedBox(width: 4),
                  Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 16, color: kMuted),
                ]),
                if (open) ...[
                  const Divider(height: 20, color: kLine),
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
                        Expanded(child: Text(tr(k), style: inter(12.5, 400, color: kMuted))),
                        const SizedBox(width: 10),
                        Flexible(child: Text(v, textAlign: TextAlign.right, style: inter(12.5, 700))),
                      ]),
                    ),
                  const SizedBox(height: 10),
                  Material(
                    color: accent,
                    shape: const StadiumBorder(),
                    child: InkWell(
                      customBorder: const StadiumBorder(),
                      onTap: () => _open(o.id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Text(tr('View details'), style: inter(14, 800, color: Colors.white)),
                          const SizedBox(width: 4),
                          const Icon(LucideIcons.chevronRight, size: 16, color: Colors.white),
                        ]),
                      ),
                    ),
                  ),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
