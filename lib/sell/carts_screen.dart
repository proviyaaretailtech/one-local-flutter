import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart';
import '../ui/mobile_input.dart';
import '../ui/theme.dart';
import 'pay_screen.dart';
import 'search_screen.dart';
import 'sell_api.dart';
import 'sell_carts.dart';
import 'sell_env.dart';
import 'sell_widgets.dart';
import '../ui/i18n.dart';

/// Carts as a wallet (founder, 27 Oct 2026, after Google Wallet): two kinds of card only. The green card is the one active cart; every
/// other cart is on hold, in warm colours: carts parked on this till and bills held on the server. Tapping the green card shows the active
/// cart with its items; tapping the on-hold pile fans the held cards out, and tapping one opens it. Every card's customer name and mobile
/// can be changed from the card.
class CartsScreen extends StatefulWidget {
  const CartsScreen({super.key, required this.env});
  final SellEnv env;
  @override
  State<CartsScreen> createState() => _CartsScreenState();
}

/// One on-hold card: a cart parked on this till ([cart]) or a bill held on the server ([bill]).
class _Held {
  _Held.cart(SellCart this.cart) : bill = null;
  _Held.bill(Receipt this.bill) : cart = null;
  final SellCart? cart;
  final Receipt? bill;
  String get key => cart?.id ?? bill!.id;
  String get label => cart != null ? 'Cart ${cart!.label}' : bill!.displayNo;
  String get customer => cart != null ? (cart!.customerName.isEmpty ? 'Guest' : cart!.customerName) : bill!.customer;
  String get phone => (cart != null ? cart!.customerPhone : bill!.customerPhone) ?? '';
}

// the active card is green; held cards are warm colours, one after another
const _green = [Color(0xFF14532D), Color(0xFF2F8F4E)];
const _warm = [
  [Color(0xFFC2410C), Color(0xFFF97316)],
  [Color(0xFFB91C1C), Color(0xFFEF4444)],
  [Color(0xFFA16207), Color(0xFFEAB308)],
  [Color(0xFFBE185D), Color(0xFFF472B6)],
];

class _CartsScreenState extends State<CartsScreen> {
  SellEnv get env => widget.env;
  SellCart get cart => env.carts.active;
  Quote? _quote;
  List<Receipt>? _heldBills;
  String? _heldError;
  bool _showItems = true, _busy = false;
  String _view = 'active'; // active | hold
  String? _openKey; // the held card that is open
  final _billItems = <String>{}; // held cards showing their items (bills and parked carts)
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    env.carts.addListener(_changed);
    _requote();
    _loadHeld();
  }

  @override
  void dispose() {
    env.carts.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  List<_Held> get _held => [
        for (final c in env.carts.carts.where((c) => c != cart)) _Held.cart(c),
        for (final b in _heldBills ?? const <Receipt>[]) _Held.bill(b),
      ];

  Future<void> _requote() async {
    if (cart.isEmpty) {
      setState(() => _quote = null);
      return;
    }
    final mine = ++_seq;
    try {
      final q = await env.orders.quote(cart.lines, coupon: cart.couponCode);
      if (mounted && mine == _seq) setState(() => _quote = q);
    } catch (_) {
      if (mounted && mine == _seq) setState(() => _quote = null);
    }
  }

  Future<void> _loadHeld() async {
    try {
      final r = await env.sell.receipts(status: 'unpaid');
      if (!mounted) return;
      setState(() {
        _heldBills = r;
        _heldError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _heldError = sellErrorText(e));
    }
  }

  void _qty(CartLine l, int qty) {
    cart.setQty(l, qty);
    env.carts.changed();
    _quote = null;
    _requote();
  }

  Future<void> _hold() async {
    if (cart.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await env.orders.hold(lines: cart.lines, key: OrdersApi.newKey(), customerName: cart.customerName, customerPhone: cart.customerPhone, couponCode: cart.couponCode);
      env.carts.finish(cart);
      _quote = null;
      await _loadHeld();
      if (mounted) showToast(context, 'Bill held.');
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Name and mobile, for any card. Answers the trimmed name and the digits of the mobile, or null when closed.
  Future<(String, String)?> _askCustomer(String name, String phone) async {
    final n = TextEditingController(text: name == 'Guest' ? '' : name), p = TextEditingController(text: phone);
    final ok = await showOrderSheet<bool>(
      context,
      title: tr('Customer'),
      body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(key: const ValueKey('cart-customer-name'), controller: n, textCapitalization: TextCapitalization.words, decoration: InputDecoration(hintText: tr('Name'))),
        const SizedBox(height: 10),
        TextField(key: const ValueKey('cart-customer-phone'), controller: p, keyboardType: TextInputType.phone, inputFormatters: mobileFormatters, decoration: InputDecoration(hintText: tr('Mobile number'), prefixText: kMobilePrefix)),
        const SizedBox(height: 16),
        DarkCta(key: const ValueKey('cart-customer-save'), label: tr('Save'), onPressed: () => Navigator.pop(ctx, true)),
      ]),
    );
    if (ok != true) return null;
    return (n.text.trim(), p.text.replaceAll(RegExp(r'\D'), ''));
  }

  Future<void> _editCart(SellCart c) async {
    final r = await _askCustomer(c.customerName, c.customerPhone);
    if (r == null || !mounted) return;
    c.customerName = r.$1;
    c.customerPhone = r.$2;
    env.carts.changed();
  }

  /// A held bill's customer is changed on the server, on the same bill.
  Future<void> _editBill(Receipt b) async {
    final r = await _askCustomer(b.customer, b.customerPhone ?? '');
    if (r == null || !mounted) return;
    try {
      final order = await env.orders.get(b.id);
      await env.orders.updateHold(b.id, customerName: r.$1, customerPhone: r.$2, version: order.version, key: OrdersApi.newKey());
      await _loadHeld();
      if (mounted) showToast(context, '${b.displayNo} updated.');
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e));
    }
  }

  Future<void> _addItems() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SearchScreen(env: env, onAdd: (i) {
      cart.add(i);
      env.carts.changed();
    })));
    if (mounted) _requote();
  }

  /// More items on a cart parked on this till: they go straight into that cart.
  Future<void> _addToParked(SellCart c) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SearchScreen(env: env, onAdd: (i) {
      c.add(i);
      env.carts.changed();
    })));
    if (mounted) setState(() => _billItems.add(c.id));
  }

  /// More items on a held bill (founder, 27 Oct 2026): picked like any cart, then the bill is re-priced on the server with its old and new
  /// lines together. It stays the same bill, still held and unpaid.
  Future<void> _addToBill(Receipt b) async {
    final extra = SellCart(id: 'add-${b.id}', number: 0);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SearchScreen(env: env, onAdd: extra.add)));
    if (!mounted || extra.isEmpty) return;
    try {
      final order = await env.orders.get(b.id);
      final lines = <String, CartLine>{
        for (final i in order.items)
          if (i['menu_item_id'] != null) '${i['menu_item_id']}': CartLine(menuItemId: '${i['menu_item_id']}', name: '${i['name']}', qty: (i['qty'] as num).toInt()),
      };
      for (final l in extra.lines) {
        final had = lines[l.menuItemId];
        if (had != null) {
          had.qty += l.qty;
        } else {
          lines[l.menuItemId] = CartLine(menuItemId: l.menuItemId, name: l.name, qty: l.qty);
        }
      }
      await env.orders.updateHold(b.id, lines: lines.values.toList(), version: order.version, key: OrdersApi.newKey());
      await _loadHeld();
      if (!mounted) return;
      setState(() => _billItems.add(b.id));
      showToast(context, '${extra.units} ${extra.units == 1 ? 'item' : 'items'} added to ${b.displayNo}.');
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e));
    }
  }

  void _makeActive(SellCart c) {
    env.carts.select(c);
    _quote = null;
    _requote();
    setState(() {
      _view = 'active';
      _openKey = null;
    });
  }

  void _discard(SellCart c) {
    env.carts.finish(c);
    setState(() => _openKey = null);
    showToast(context, 'Cart ${c.label} removed.');
  }

  Future<void> _payHeld(Receipt r) async {
    try {
      final order = await env.orders.get(r.id);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PayScreen(env: env, held: order)));
      if (mounted) _loadHeld();
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e));
    }
  }

  Future<void> _cancelHeld(Receipt r) async {
    try {
      final order = await env.orders.get(r.id);
      await env.orders.cancel(r.id, reason: 'Held bill cancelled', version: order.version);
      if (mounted) showToast(context, '${r.displayNo} cancelled.');
      await _loadHeld();
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e));
    }
  }

  // ---------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    final held = _held;
    final total = _quote?.total;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        SellTopBar(title: 'OneLocal POS', onBack: () => Navigator.maybePop(context), initials: env.initials),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(12, 14, 12, 16), children: [
            Row(children: [
              Expanded(child: SellTitle('Cart', sub: '1 ${tr('active')} · ${held.length} ${tr('on hold')}')),
              Material(
                color: kDark,
                shape: const StadiumBorder(),
                child: InkWell(
                  key: const ValueKey('cart-new'),
                  customBorder: const StadiumBorder(),
                  onTap: () {
                    env.carts.newCart();
                    _quote = null;
                    setState(() => _view = 'active');
                  },
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12), child: Text(tr('+ New cart'), style: inter(15, 700, color: kLime))),
                ),
              ),
            ]),
            const SizedBox(height: 14),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              switchInCurve: Curves.easeOut,
              child: _view == 'active' ? _activeView(held) : _holdView(held),
            ),
            if (_heldError != null) ...[const SizedBox(height: 10), Text(_heldError!, style: inter(13, 400, color: kBadText))],
          ]),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Text('Cart ${cart.label}', style: inter(15, 600)),
              const SizedBox(width: 8),
              const TagChip('Unpaid', bg: Color(0xFFF3F4F1), fg: kMuted),
              const Spacer(),
              Text(total == null ? '' : 'Total ${rupees(total)}', style: inter(20, 800, color: kGreenText)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(flex: 3, child: DarkCta(label: 'PAY', labelStart: true, amount: total == null ? null : rupees(total), onPressed: cart.isEmpty ? null : () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PayScreen(env: env, cart: cart)));
                if (mounted) {
                  _requote();
                  _loadHeld();
                }
              })),
              const SizedBox(width: 10),
              Expanded(flex: 2, child: LightCta(label: tr('+ Items'), onPressed: _addItems)),
            ]),
          ]),
        ),
        PosBottomNav(active: 'bill', onTap: (id) => env.tab(context, id)),
      ]),
    );
  }

  // ---------------------------------------------------------------- the active view: the green card on top, the held pile under it
  Widget _activeView(List<_Held> held) => Column(key: const ValueKey('wallet-active'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _activeCard(),
        if (_showItems) _itemsPanel(),
        const SizedBox(height: 14),
        _holdPile(held),
      ]);

  /// A wallet card: a gradient with white type.
  Widget _walletCard({required Key key, required List<Color> colors, required Widget child, VoidCallback? onTap, double radius = 22}) => Material(
        key: key,
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
            boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 10, offset: Offset(0, 4))],
          ),
          child: InkWell(borderRadius: BorderRadius.circular(radius), onTap: onTap, child: Padding(padding: const EdgeInsets.all(16), child: child)),
        ),
      );

  Widget _onCard(String text, {double size = 13, int weight = 500, double alpha = 0.85}) =>
      Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(size, weight, color: Colors.white.withValues(alpha: alpha)));

  Widget _chip(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(99)),
        child: Text(label, style: inter(12, 700, color: Colors.white)),
      );

  Widget _editButton(Key key, VoidCallback onTap) => IconButton(
        key: key,
        tooltip: tr('Edit customer'),
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.2)),
        onPressed: onTap,
        icon: const Icon(LucideIcons.pencil, size: 16, color: Colors.white),
      );

  Widget _cardButton(String label, VoidCallback? onTap, {Key? key, bool solid = false}) => Material(
        key: key,
        color: solid ? Colors.white : Colors.white.withValues(alpha: 0.18),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Text(tr(label), textAlign: TextAlign.center, style: inter(13.5, 800, color: solid ? kInk : Colors.white.withValues(alpha: onTap == null ? 0.5 : 1))),
          ),
        ),
      );

  Widget _activeCard() {
    final q = _quote;
    return _walletCard(
      key: const ValueKey('wallet-card-active'),
      colors: _green,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Cart ${cart.label}', style: inter(20, 800, color: Colors.white)),
          const SizedBox(width: 10),
          _chip(tr('Active')),
          const Spacer(),
          const Icon(LucideIcons.shoppingCart, size: 22, color: Colors.white70),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _onCard(cart.customerName.isEmpty ? 'Guest' : cart.customerName, size: 17, weight: 700, alpha: 1),
              _onCard(cart.customerPhone.isEmpty ? tr('Add a mobile number') : cart.customerPhone),
            ]),
          ),
          _editButton(const ValueKey('cart-edit-active'), () => _editCart(cart)),
        ]),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(child: _onCard('${cart.lines.length} ${cart.lines.length == 1 ? 'item' : 'items'} · ${cart.units} ${cart.units == 1 ? 'unit' : 'units'}')),
          Text(rupees(q?.total ?? cart.estimate), style: inter(22, 800, color: Colors.white)),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _cardButton('Hold', cart.isEmpty || _busy ? null : _hold, key: const ValueKey('cart-hold'))),
          const SizedBox(width: 8),
          Expanded(child: _cardButton('Slip', cart.isEmpty ? null : () {
            Clipboard.setData(ClipboardData(text: [for (final l in cart.lines) '${l.qty} x ${l.name}'].join('\n')));
            showToast(context, 'Slip copied. Printers connect in a later release.');
          })),
          const SizedBox(width: 8),
          Expanded(child: _cardButton(_showItems ? 'Hide items' : 'Show items', () => setState(() => _showItems = !_showItems), solid: true)),
        ]),
      ]),
    );
  }

  /// The active cart's lines, editable, tucked under the green card.
  Widget _itemsPanel() {
    final priced = {for (final l in _quote?.lines ?? const <Map<String, dynamic>>[]) l['menu_item_id']: l};
    final q = _quote;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(bottom: Radius.circular(18))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (cart.isEmpty) Padding(padding: const EdgeInsets.all(6), child: Text(tr('No items yet. Add items to start the bill.'), style: inter(13, 400, color: kMuted))),
        for (final l in cart.lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.name, style: inter(15, 700)),
                Text('${rupees(cart.unitPrice[l.menuItemId] ?? 0)} each', style: inter(12.5, 400, color: kMuted)),
              ])),
              _step(LucideIcons.minus, 'One less ${l.name}', () => _qty(l, l.qty - 1)),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('${l.qty}', style: inter(16, 700))),
              _step(LucideIcons.plus, 'One more ${l.name}', () => _qty(l, l.qty + 1)),
              SizedBox(width: 68, child: Text(rupees(num.tryParse('${priced[l.menuItemId]?['amount'] ?? ''}') ?? (cart.unitPrice[l.menuItemId] ?? 0) * l.qty), textAlign: TextAlign.right, style: inter(15, 800))),
            ]),
          ),
        if (q != null)
          Text('Subtotal ${rupees(q.subtotal)} · Tax (${q.gstPct == q.gstPct.roundToDouble() ? q.gstPct.toInt() : q.gstPct}%) ${rupees(q.gst)}', style: inter(12.5, 400, color: kMuted)),
      ]),
    );
  }

  Widget _step(IconData icon, String label, VoidCallback onTap) => Semantics(
        button: true,
        label: label,
        child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: Container(width: 32, height: 32, decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: const Color(0xFFDADCD5))), child: Icon(icon, size: 15))),
      );

  /// The held cards as a pile: up to three edges peeking out, the top one says how many and their worth. One tap fans them out.
  Widget _holdPile(List<_Held> held) {
    if (held.isEmpty) {
      return Container(
        key: const ValueKey('wallet-pile-empty'),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(22), border: Border.all(color: kLine, width: 1.5)),
        child: Row(children: [
          const Icon(LucideIcons.pause, size: 18, color: kMuted),
          const SizedBox(width: 8),
          Expanded(child: Text(tr('No carts on hold. Hold a cart to serve the next customer.'), style: inter(13, 500, color: kMuted))),
        ]),
      );
    }
    final worth = held.fold<num>(0, (n, h) => n + (h.bill?.total ?? h.cart!.estimate));
    final peeks = held.length.clamp(1, 3);
    return GestureDetector(
      key: const ValueKey('wallet-pile'),
      onTap: () => setState(() => _view = 'hold'),
      child: SizedBox(
        height: 96 + (peeks - 1) * 12,
        child: Stack(children: [
          // the edges of the cards behind, then the front card
          for (var i = peeks - 1; i >= 1; i--)
            Positioned(
              left: 12.0 * i,
              right: 12.0 * i,
              top: 0,
              child: Transform.translate(
                offset: Offset(0, (peeks - 1 - i) * 12.0),
                child: Container(height: 40, decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), gradient: LinearGradient(colors: _warm[i % _warm.length]))),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            top: (peeks - 1) * 12.0,
            child: _walletCard(
              key: const ValueKey('wallet-card-hold'),
              colors: _warm[0],
              onTap: () => setState(() => _view = 'hold'),
              child: Row(children: [
                const Icon(LucideIcons.pause, size: 20, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${tr('On hold')} · ${held.length}', style: inter(17, 800, color: Colors.white)),
                    _onCard(held.take(3).map((h) => h.customer).join(', ')),
                  ]),
                ),
                Text(rupees(worth), style: inter(18, 800, color: Colors.white)),
                const SizedBox(width: 4),
                const Icon(LucideIcons.chevronRight, size: 18, color: Colors.white),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  // ---------------------------------------------------------------- the on-hold view: the green card shrinks, the held cards fan out
  Widget _holdView(List<_Held> held) => Column(key: const ValueKey('wallet-hold'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _walletCard(
          key: const ValueKey('wallet-card-active'),
          colors: _green,
          onTap: () => setState(() => _view = 'active'),
          child: Row(children: [
            Text('Cart ${cart.label}', style: inter(16, 800, color: Colors.white)),
            const SizedBox(width: 8),
            _chip(tr('Active')),
            const SizedBox(width: 8),
            Expanded(child: _onCard(cart.customerName.isEmpty ? 'Guest' : cart.customerName)),
            Text(rupees(_quote?.total ?? cart.estimate), style: inter(16, 800, color: Colors.white)),
          ]),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: Text('${tr('On hold')} · ${held.length}', style: inter(15, 800))),
          TextButton(onPressed: () => setState(() => _view = 'active'), child: Text(tr('Back to active'), style: inter(13, 700, color: kLink))),
        ]),
        const SizedBox(height: 4),
        if (held.isEmpty) Text(tr('No carts on hold.'), style: inter(13, 500, color: kMuted)),
        // a wallet: each closed card tucks under the next one; the open card shows in full
        for (final (i, h) in held.indexed)
          // one after another, none covering the next
          Padding(padding: EdgeInsets.only(bottom: i == held.length - 1 ? 0 : 10), child: _heldCard(h, _warm[i % _warm.length])),
      ]);

  /// A button on a held card, in the card's colour: filled for the main step, outlined for the others.
  Widget _accentButton(String label, VoidCallback onTap, Color accent, {Key? key, bool solid = false}) => Material(
        key: key,
        color: solid ? accent : Colors.white,
        shape: StadiumBorder(side: BorderSide(color: accent.withValues(alpha: solid ? 1 : 0.5))),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Text(tr(label), textAlign: TextAlign.center, style: inter(13.5, 800, color: solid ? Colors.white : accent)),
          ),
        ),
      );

  /// A held cart or bill (founder, 27 Oct 2026, like the online orders): a white card with its colour as the border and accent; the
  /// customer leads, big and in that colour; the number is small. Tap to open its items and actions.
  Widget _heldCard(_Held h, List<Color> colors) {
    final open = h.key == _openKey;
    final accent = colors.first;
    final c = h.cart, b = h.bill;
    final amount = b?.total ?? c!.estimate;
    final counts = b?.counts ?? '${c!.lines.length} ${c.lines.length == 1 ? 'line' : 'lines'} · ${c.units} ${c.units == 1 ? 'unit' : 'units'}';
    Widget line(String name, num money) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13.5, 600))),
            Text(rupees(money), style: inter(13.5, 700)),
          ]),
        );
    return Container(
      key: ValueKey('wallet-held-${h.key}'),
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
          onTap: () => setState(() => _openKey = open ? null : h.key),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(h.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(17, 800, color: accent)),
                      const SizedBox(height: 1),
                      Text([h.label, if (h.phone.isNotEmpty) h.phone else tr('Add a mobile number')].join(' · '),
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 500, color: kMuted)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Text(rupees(amount), style: inter(17, 800)),
                  const SizedBox(width: 2),
                  IconButton(
                    key: ValueKey('cart-edit-${h.key}'),
                    tooltip: tr('Edit customer'),
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(backgroundColor: accent.withValues(alpha: 0.10)),
                    onPressed: () => c != null ? _editCart(c) : _editBill(b!),
                    icon: Icon(LucideIcons.pencil, size: 15, color: accent),
                  ),
                ]),
                const SizedBox(height: 6),
                Row(children: [
                  Container(width: 7, height: 7, decoration: BoxDecoration(color: accent, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text([tr('On hold'), counts, if (b != null) b.when else tr('On this till')].join(' · '),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12.5, 600)),
                  ),
                  Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 16, color: kMuted),
                  const SizedBox(width: 4),
                ]),
                if (open) ...[
                  const Divider(height: 20, color: kLine),
                  if (b != null && _billItems.contains(b.id)) ...[
                    for (final i in b.items) line('${i['qty']}× ${i['name']}', (i['amount'] as num?) ?? 0),
                    const SizedBox(height: 6),
                  ],
                  if (c != null) ...[
                    if (_billItems.contains(c.id)) ...[
                      if (c.isEmpty) Text(tr('No items yet.'), style: inter(13, 400, color: kMuted)),
                      for (final l in c.lines) line('${l.qty}× ${l.name}', (c.unitPrice[l.menuItemId] ?? 0) * l.qty),
                      const SizedBox(height: 6),
                    ],
                    Row(children: [
                      Expanded(child: _accentButton(_billItems.contains(c.id) ? 'Hide items' : 'Show items', () => setState(() => _billItems.contains(c.id) ? _billItems.remove(c.id) : _billItems.add(c.id)), accent)),
                      const SizedBox(width: 8),
                      Expanded(child: _accentButton('+ Add items', () => _addToParked(c), accent, key: ValueKey('cart-add-${h.key}'))),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: _accentButton('Make active', () => _makeActive(c), accent, key: ValueKey('cart-activate-${h.key}'), solid: true)),
                      const SizedBox(width: 8),
                      Expanded(child: _accentButton('Remove', () => _discard(c), accent, key: ValueKey('cart-remove-${h.key}'))),
                    ]),
                  ] else ...[
                    Row(children: [
                      Expanded(child: _accentButton(_billItems.contains(b!.id) ? 'Hide items' : 'Show items', () => setState(() => _billItems.contains(b.id) ? _billItems.remove(b.id) : _billItems.add(b.id)), accent)),
                      const SizedBox(width: 8),
                      Expanded(child: _accentButton('+ Add items', () => _addToBill(b), accent, key: ValueKey('cart-add-${h.key}'))),
                    ]),
                    const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: _accentButton('Pay', () => _payHeld(b), accent, key: ValueKey('cart-pay-${h.key}'), solid: true)),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(onPressed: () => _cancelHeld(b), child: Text(tr('Cancel this held bill'), style: inter(13, 700, color: kBadText))),
                    ),
                  ],
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
