import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart';
import '../ui/theme.dart';
import 'pay_screen.dart';
import 'search_screen.dart';
import 'sell_api.dart';
import 'sell_carts.dart';
import 'sell_env.dart';
import 'sell_widgets.dart';

/// Figma "442 multiple Cart": every cart open on this till. The active cart is expanded (customer, items, quantities, the server's total);
/// the others wait beside it, and bills that were held are listed with a way to pay or cancel them. Packing and pick-up progress belong to
/// section E's order screens, not to a cart that is not paid yet.
class CartsScreen extends StatefulWidget {
  const CartsScreen({super.key, required this.env});
  final SellEnv env;
  @override
  State<CartsScreen> createState() => _CartsScreenState();
}

class _CartsScreenState extends State<CartsScreen> {
  SellEnv get env => widget.env;
  SellCart get cart => env.carts.active;
  Quote? _quote;
  List<Receipt>? _held;
  String? _heldError;
  bool _showItems = true, _busy = false;
  final _open = <String>{};
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
        _held = r;
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

  Future<void> _customer() async {
    final name = TextEditingController(text: cart.customerName), phone = TextEditingController(text: cart.customerPhone);
    final ok = await showOrderSheet<bool>(
      context,
      title: 'Customer',
      body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: name, decoration: const InputDecoration(hintText: 'Name')),
        const SizedBox(height: 10),
        TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(hintText: 'Mobile number')),
        const SizedBox(height: 16),
        DarkCta(label: 'Save', onPressed: () => Navigator.pop(ctx, true)),
      ]),
    );
    if (ok == true && mounted) {
      cart.customerName = name.text.trim();
      cart.customerPhone = phone.text.replaceAll(RegExp(r'\D'), '');
      env.carts.changed();
    }
  }

  Future<void> _addItems() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SearchScreen(env: env, onAdd: (i) {
      cart.add(i);
      env.carts.changed();
    })));
    if (mounted) _requote();
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

  @override
  Widget build(BuildContext context) {
    final carts = env.carts.carts;
    final held = _held ?? const <Receipt>[];
    final total = _quote?.total;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        SellTopBar(title: 'OneLocal POS', onBack: () => Navigator.maybePop(context), initials: env.initials),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(12, 14, 12, 16), children: [
            Row(children: [
              Expanded(child: SellTitle('Cart', sub: '${carts.length} open · ${held.length} on hold')),
              Material(
                color: kDark,
                shape: const StadiumBorder(),
                child: InkWell(customBorder: const StadiumBorder(), onTap: () {
                  env.carts.newCart();
                  _quote = null;
                }, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12), child: Text('+ New cart', style: inter(15, 700, color: kLime)))),
              ),
            ]),
            const SizedBox(height: 14),
            _activeCard(),
            for (final c in carts.where((c) => c != cart)) ...[
              const SizedBox(height: 10),
              InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: () {
                  env.carts.select(c);
                  _quote = null;
                  _requote();
                },
                child: OrderCardBox(radius: 22, child: Row(children: [
                  Text('Cart ${c.label}', style: inter(17, 700)),
                  const SizedBox(width: 8),
                  TagChip(c.isEmpty ? 'Empty' : 'Waiting', bg: kWarnBg, fg: kWarnText),
                  const Spacer(),
                  Text(c.isEmpty ? '' : '${c.units} ${c.units == 1 ? 'unit' : 'units'}', style: inter(13, 500, color: kMuted)),
                ])),
              ),
            ],
            if (_heldError != null) ...[const SizedBox(height: 10), Text(_heldError!, style: inter(13, 400, color: kBadText))],
            if (held.isNotEmpty) ...[
              const SizedBox(height: 14),
              for (final r in held) ...[_heldCard(r), const SizedBox(height: 10)],
            ],
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
              Expanded(flex: 3, child: DarkCta(label: total == null ? 'PAY' : 'PAY ${rupees(total)}', onPressed: cart.isEmpty ? null : () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PayScreen(env: env, cart: cart)));
                if (mounted) {
                  _requote();
                  _loadHeld();
                }
              })),
              const SizedBox(width: 10),
              Expanded(flex: 2, child: LightCta(label: '+ Items', onPressed: _addItems)),
            ]),
          ]),
        ),
        PosBottomNav(active: 'bill', onTap: (id) => env.tab(context, id)),
      ]),
    );
  }

  Widget _activeCard() {
    final priced = {for (final l in _quote?.lines ?? const <Map<String, dynamic>>[]) l['menu_item_id']: l};
    final q = _quote;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFF8BE800))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Text('Cart ${cart.label}', style: inter(22, 800)), const SizedBox(width: 10), const TagChip('Active')]),
        const SizedBox(height: 10),
        InkWell(
          onTap: _customer,
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(cart.customerName.isEmpty ? 'Guest' : cart.customerName, style: inter(18, 700)),
              Text(cart.customerPhone.isEmpty ? 'Add a mobile number' : cart.customerPhone, style: inter(14, 400, color: kMuted)),
            ])),
            const Icon(LucideIcons.pencil, size: 16, color: kMuted),
          ]),
        ),
        const SizedBox(height: 6),
        Text('${cart.lines.length} ${cart.lines.length == 1 ? 'item' : 'items'} / ${cart.units} ${cart.units == 1 ? 'unit' : 'units'}', style: inter(14, 400, color: kMuted)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: LightCta(label: 'Hold', onPressed: cart.isEmpty || _busy ? null : _hold)),
          const SizedBox(width: 8),
          Expanded(child: LightCta(label: 'Slip', onPressed: cart.isEmpty ? null : () {
            Clipboard.setData(ClipboardData(text: [for (final l in cart.lines) '${l.qty} x ${l.name}'].join('\n')));
            showToast(context, 'Slip copied. Printers connect in a later release.');
          })),
          const SizedBox(width: 8),
          Expanded(flex: 2, child: LightCta(label: _showItems ? 'Hide items' : 'Show items', icon: _showItems ? LucideIcons.chevronUp : LucideIcons.chevronDown, bg: kChipGreen, fg: kGreenText, onPressed: () => setState(() => _showItems = !_showItems))),
        ]),
        if (_showItems) ...[
          const SizedBox(height: 10),
          if (cart.isEmpty) Padding(padding: const EdgeInsets.all(8), child: Text('No items yet. Add items to start the bill.', style: inter(13, 400, color: kMuted))),
          for (final l in cart.lines)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: kSoftField, borderRadius: BorderRadius.circular(16)),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.name, style: inter(16, 700)),
                  Text('${rupees(cart.unitPrice[l.menuItemId] ?? 0)} each', style: inter(13, 400, color: kMuted)),
                ])),
                _step(LucideIcons.minus, 'One less ${l.name}', () => _qty(l, l.qty - 1)),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text('${l.qty}', style: inter(17, 700))),
                _step(LucideIcons.plus, 'One more ${l.name}', () => _qty(l, l.qty + 1)),
                SizedBox(width: 72, child: Text(rupees(num.tryParse('${priced[l.menuItemId]?['amount'] ?? ''}') ?? (cart.unitPrice[l.menuItemId] ?? 0) * l.qty), textAlign: TextAlign.right, style: inter(16, 800))),
              ]),
            ),
        ],
        if (q != null) ...[
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: Text('Subtotal ${rupees(q.subtotal)} · Tax (${q.gstPct == q.gstPct.roundToDouble() ? q.gstPct.toInt() : q.gstPct}%) ${rupees(q.gst)}', style: inter(13, 400, color: kMuted))),
            Text(rupees(q.total), style: inter(20, 800, color: kGreenText)),
          ]),
        ],
      ]),
    );
  }

  Widget _step(IconData icon, String label, VoidCallback onTap) => Semantics(
        button: true,
        label: label,
        child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: Container(width: 34, height: 34, decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: const Color(0xFFDADCD5))), child: Icon(icon, size: 16))),
      );

  Widget _heldCard(Receipt r) => OrderCardBox(
        radius: 22,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Text(r.displayNo, style: inter(17, 800)), const Spacer(), const TagChip('On hold', bg: kWarnBg, fg: kWarnText)]),
          const SizedBox(height: 4),
          Row(children: [Expanded(child: Text(r.customer, style: inter(15, 500, color: kMuted))), Text(rupees(r.total), style: inter(18, 800))]),
          Text('${r.counts} · Unpaid', style: inter(13, 400, color: kMuted)),
          if (_open.contains(r.id)) ...[
            const Divider(height: 18, color: kLine),
            for (final i in r.items) ItemLine(name: '${i['name']}', sub: '', amount: (i['amount'] as num?) ?? 0, qtyBadge: '${i['qty']}×'),
          ],
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: LightCta(label: _open.contains(r.id) ? 'Hide items' : 'Show items', onPressed: () => setState(() => _open.contains(r.id) ? _open.remove(r.id) : _open.add(r.id)))),
            const SizedBox(width: 8),
            Expanded(child: DarkCta(label: 'Pay', onPressed: () => _payHeld(r))),
          ]),
          UnderLink('Cancel this held bill', onTap: () => _cancelHeld(r)),
        ]),
      );
}
