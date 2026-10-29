import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart';
import '../ui/mobile_input.dart';
import '../ui/theme.dart';
import '../ui/whatsapp.dart';
import '../shift/shift_screens.dart';
import 'payment_pending_screen.dart';
import 'razorpay_screen.dart';
import 'result_screens.dart';
import 'sell_carts.dart';
import 'sell_env.dart';
import 'sell_widgets.dart';
import '../ui/i18n.dart';

/// Figma "446 Payment": the bill, how it is paid (Cash, Card, UPI / QR, Split Pay), the totals the server worked out, a coupon, the cash
/// received and the change. Pays a new [cart] through section E's checkout, or a held bill ([held]) through its pay; a split pays one
/// held bill with several tenders in one database transaction. Money rules (amount due, change, over-payment, coupon) are the database's.
class PayScreen extends StatefulWidget {
  const PayScreen({super.key, required this.env, this.cart, this.held, this.method = 'cash'}) : assert(cart != null || held != null);
  final SellEnv env;
  final SellCart? cart;
  final OrderView? held;
  final String method;
  @override
  State<PayScreen> createState() => _PayScreenState();
}

class _SplitPart {
  _SplitPart(this.method);
  String method;
  final amount = TextEditingController();
  final tendered = TextEditingController();
}

class _PayScreenState extends State<PayScreen> {
  SellEnv get env => widget.env;
  late String _method = widget.method;
  Quote? _quote;
  String? _quoteError;
  OrderView? _placed; // the bill once it is saved on the server (held)
  final _tender = TextEditingController();
  final _parts = [_SplitPart('cash'), _SplitPart('upi')];
  String? _holdKey, _payKey;
  bool _busy = false;
  int _seq = 0;

  static const _methods = [('cash', 'Cash'), ('card', 'Card'), ('upi', 'UPI / QR'), ('split', 'Split Pay')];

  OrderView? get _order => _placed ?? widget.held;
  num get _total => _order != null ? (num.tryParse('${_order!.payment['due']}') ?? _order!.bill['total'] as num? ?? 0) : (_quote?.total ?? 0);
  num? get _tendered => num.tryParse(_tender.text.replaceAll(',', '').trim());

  @override
  void initState() {
    super.initState();
    _requote();
  }

  @override
  void dispose() {
    _tender.dispose();
    for (final p in _parts) {
      p.amount.dispose();
      p.tendered.dispose();
    }
    super.dispose();
  }

  void _intentChanged() {
    _payKey = null;
    setState(() {});
  }

  Future<void> _requote() async {
    final cart = widget.cart;
    if (cart == null || _order != null) return;
    final mine = ++_seq;
    try {
      final q = await env.orders.quote(cart.lines, coupon: cart.couponCode);
      if (!mounted || mine != _seq) return;
      setState(() {
        _quote = q;
        _quoteError = null;
      });
    } on OrdersApiException catch (e) {
      if (!mounted || mine != _seq) return;
      if (cart.couponCode != null && (e.code == 'coupon_unknown' || e.code == 'coupon_minimum')) {
        cart.couponCode = null;
        showToast(context, e.message);
        return _requote();
      }
      setState(() => _quoteError = e.message);
    } catch (e) {
      if (mounted && mine == _seq) setState(() => _quoteError = sellErrorText(e));
    }
  }

  Future<void> _coupon() async {
    final cart = widget.cart;
    if (cart == null || _order != null) {
      showToast(context, 'A held bill keeps the discount it was saved with.');
      return;
    }
    final c = TextEditingController(text: cart.couponCode ?? '');
    final code = await showOrderSheet<String>(
      context,
      title: tr('Apply coupon'),
      body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: c, autofocus: true, textCapitalization: TextCapitalization.characters, decoration: InputDecoration(hintText: tr('Coupon code'))),
        const SizedBox(height: 16),
        DarkCta(label: tr('Apply'), onPressed: () => Navigator.pop(ctx, c.text.trim())),
      ]),
    );
    if (code == null || !mounted) return;
    final previous = cart.couponCode;
    cart.couponCode = code.isEmpty ? null : code.toUpperCase();
    try {
      final q = await env.orders.quote(cart.lines, coupon: cart.couponCode);
      if (mounted) setState(() => _quote = q);
    } catch (e) {
      cart.couponCode = previous; // the server said no: keep what worked
      if (mounted) showToast(context, sellErrorText(e));
    }
  }

  Future<void> _customer() async {
    final cart = widget.cart;
    if (cart == null) return;
    final name = TextEditingController(text: cart.customerName), phone = TextEditingController(text: cart.customerPhone);
    final ok = await showOrderSheet<bool>(
      context,
      title: tr('Customer'),
      body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: name, decoration: InputDecoration(hintText: tr('Name'))),
        const SizedBox(height: 10),
        TextField(controller: phone, keyboardType: TextInputType.phone, inputFormatters: mobileFormatters, decoration: InputDecoration(hintText: tr('Mobile number'), prefixText: kMobilePrefix)),
        const SizedBox(height: 16),
        DarkCta(label: tr('Save'), onPressed: () => Navigator.pop(ctx, true)),
      ]),
    );
    if (ok == true && mounted) {
      cart.customerName = name.text.trim();
      cart.customerPhone = phone.text.replaceAll(RegExp(r'\D'), '');
      env.carts.changed();
      setState(() {});
    }
  }

  /// Saves the cart on the server as an unpaid held bill (once; the key makes a retry safe).
  Future<OrderView> _ensurePlaced() async {
    if (_order != null) return _order!;
    final cart = widget.cart!;
    _holdKey ??= OrdersApi.newKey();
    final v = await env.orders.hold(lines: cart.lines, key: _holdKey!, customerName: cart.customerName, customerPhone: cart.customerPhone, couponCode: cart.couponCode);
    env.carts.finish(cart);
    _placed = v;
    return v;
  }

  Future<void> _guard(Future<void> Function() job) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await job();
    } on OrdersApiException catch (e) {
      if (mounted) showToast(context, e.message);
      if (mounted && e.code == 'no_shift') {
        // the store takes no payment without an open cash shift (S5.1): open it, then the person presses Pay again
        await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => OpenShiftScreen(api: env.shift, storeLine: env.storeLine, initials: env.initials, required: true)));
      }
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _done(OrderView v) {
    final cart = widget.cart;
    if (cart != null) env.carts.finish(cart);
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => SuccessScreen(env: env, view: v)));
  }

  Future<void> _pay() => _guard(() async {
        if (_method == 'split') return _paySplit();
        if (_method == 'card' || _method == 'upi') return _collect();
        if (_method == 'cash' && (_tendered == null || _tendered! < _total)) {
          showToast(context, _tendered == null ? 'Enter the cash received.' : 'The cash received is less than ${rupees(_total)}.');
          return;
        }
        _payKey ??= OrdersApi.newKey();
        final held = _order;
        final tender = _method == 'cash' ? _tendered : null;
        final v = held != null
            ? await env.orders.pay(held.id, method: _method, tendered: tender, version: held.version, key: _payKey!)
            : await env.orders.checkout(
                lines: widget.cart!.lines, method: _method, tendered: tender, key: _payKey!,
                customerName: widget.cart!.customerName, customerPhone: widget.cart!.customerPhone, couponCode: widget.cart!.couponCode);
        if (mounted) _done(v);
      });

  /// UPI and card wait for confirmation (S5.14): the bill is saved unpaid and the pending screen confirms or fails the payment.
  Future<void> _collect() async {
    final order = await _ensurePlaced();
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => PaymentPendingScreen(env: env, order: order, method: _method)));
  }

  num get _splitSum => _parts.fold<num>(0, (n, p) => n + (num.tryParse(p.amount.text.trim()) ?? 0));

  Future<void> _paySplit() async {
    if ((_splitSum - _total).abs() > 0.004) {
      showToast(context, 'The parts add up to ${rupees(_splitSum)} but ${rupees(_total)} is due.');
      return;
    }
    final order = await _ensurePlaced();
    _payKey ??= OrdersApi.newKey();
    final parts = [
      for (final p in _parts)
        {'method': p.method, 'amount': num.parse(p.amount.text.trim()), if (p.method == 'cash' && num.tryParse(p.tendered.text.trim()) != null) 'tendered': num.parse(p.tendered.text.trim())},
    ];
    final v = await env.sell.splitPay(order.id, parts, version: order.version, key: _payKey!);
    if (mounted) _done(v);
  }

  Future<void> _hold() => _guard(() async {
        final v = await _ensurePlaced();
        if (!mounted) return;
        showToast(context, '${v.displayNo} held. Find it under Open carts.');
        Navigator.of(context).maybePop();
      });

  /// The card machine or UPI app said no: save the bill, log the attempt (nothing is charged) and show the failure screen.
  Future<void> _failed(String method, {String code = 'declined', String message = 'Declined at the terminal'}) => _guard(() async {
        final order = await _ensurePlaced();
        final f = await env.sell.recordAttempt(order.id, method: method, code: code, message: message);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => FailedScreen(env: env, failure: f)));
      });

  Future<void> _online() => _guard(() async {
        final order = await _ensurePlaced();
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => RazorpayScreen(env: env, order: order)));
      });

  Future<void> _whatsapp() async {
    final phone = widget.cart?.customerPhone ?? '';
    if (phone.length < 10) {
      showToast(context, 'Ask for a mobile number before sharing.');
      return;
    }
    final q = _quote;
    final text = q == null ? 'Your bill' : 'Your bill: ${rupees(q.total)} (subtotal ${rupees(q.subtotal)}, GST ${rupees(q.gst)}${q.discount > 0 ? ', discount -${rupees(q.discount)}' : ''}).';
    await env.openUrl(whatsAppLink(phone, text));
  }

  @override
  Widget build(BuildContext context) {
    final cart = widget.cart;
    final q = _quote;
    final order = _order;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        SellTopBar(onBack: () => Navigator.maybePop(context), initials: env.initials),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 16), children: [
            _itemsCard(cart, order),
            const SizedBox(height: 14),
            _methodCard(),
            const SizedBox(height: 14),
            if (_method == 'split') _splitCard() else _summaryCard(q, order),
            const SizedBox(height: 18),
            DarkCta(label: 'Pay ${rupees(_total)}', busy: _busy, onPressed: (order == null && q == null && _method != 'split') ? null : _pay),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: LightCta(label: tr('Send by WhatsApp'), onPressed: _whatsapp)),
              const SizedBox(width: 10),
              Expanded(child: LightCta(label: tr('Save & Hold'), onPressed: _busy ? null : _hold)),
            ]),
            if (_method == 'card' || _method == 'upi') ...[
              const SizedBox(height: 4),
              UnderLink('Payment did not go through', onTap: _busy ? null : () => _failed(_method)),
              UnderLink('Collect online instead (Razorpay checkout)', onTap: _busy ? null : _online),
            ],
            const SizedBox(height: 8),
            Text(((cart?.customerPhone ?? order?.raw['customer_phone'] ?? '') as String).length >= 10 ? 'Customer · ${cart?.customerName ?? ''}' : 'Guest sale · Ask for a mobile number before sharing.', style: inter(13, 400, color: kMuted)),
          ]),
        ),
      ]),
    );
  }

  Widget _itemsCard(SellCart? cart, OrderView? order) {
    final priced = {for (final l in _quote?.lines ?? const <Map<String, dynamic>>[]) l['menu_item_id']: l};
    final rows = order != null
        ? [for (final i in order.items) (i['name'].toString(), (i['qty'] as num).toInt(), (i['amount'] as num))]
        : [for (final l in cart!.lines) (l.name, l.qty, num.tryParse('${priced[l.menuItemId]?['amount'] ?? 0}') ?? 0)];
    final who = order != null ? order.customer : (cart!.customerName.isEmpty ? 'Guest' : cart.customerName);
    return OrderCardBox(
      radius: 22,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(env.storeLine, style: inter(18, 700)),
        const SizedBox(height: 4),
        Text('${order?.displayNo ?? 'New bill'} · ${_methods.firstWhere((m) => m.$1 == _method).$2} selected · $who', style: inter(13, 400, color: kMuted)),
        Text(order == null ? 'Payment not completed' : 'Payment not completed · ${order.paymentChip}', style: inter(13, 400, color: kMuted)),
        const Divider(height: 20, color: kLine),
        for (final (name, qty, amount) in rows)
          ItemLine(name: name, sub: '', amount: amount, qtyBadge: '$qty×'),
        if (cart != null && order == null) ...[
          const Divider(height: 18, color: kLine),
          Wrap(spacing: 8, children: [
            SmallPill('Customer', onTap: _customer),
            SmallPill(cart.couponCode == null ? 'Apply coupon' : 'Coupon ${cart.couponCode}', bg: kChipGreen, fg: kGreenText, border: kChipGreen, onTap: _coupon),
          ]),
        ],
      ]),
    );
  }

  Widget _methodCard() => OrderCardBox(
        radius: 22,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Kick('Select payment method'),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 4.4,
            children: [
              for (final (id, label) in _methods)
                Semantics(
                  button: true,
                  selected: _method == id,
                  label: label,
                  child: Material(
                    color: _method == id ? const Color(0xFF7BEE00) : kSoftField,
                    shape: StadiumBorder(side: BorderSide(color: _method == id ? const Color(0xFF7BEE00) : const Color(0xFFDDDFD8))),
                    child: InkWell(
                      customBorder: const StadiumBorder(),
                      onTap: () {
                        _method = id;
                        _intentChanged();
                      },
                      child: Center(child: ExcludeSemantics(child: Text(label, style: inter(14, _method == id ? 800 : 500, color: _method == id ? kInk : kMuted)))),
                    ),
                  ),
                ),
            ],
          ),
        ]),
      );

  Widget _summaryCard(Quote? q, OrderView? order) {
    final b = order?.bill;
    final subtotal = q?.subtotal ?? (b?['subtotal'] as num?) ?? 0;
    final gstPct = q?.gstPct ?? (b?['gst_pct'] as num?) ?? 0;
    final gst = q?.gst ?? (b?['gst'] as num?) ?? 0;
    final sc = q?.serviceCharge ?? (b?['service_charge'] as num?) ?? 0;
    final disc = q?.discount ?? (b?['discount'] as num?) ?? 0;
    final code = widget.cart?.couponCode;
    final total = _total;
    final t = _tendered;
    final change = t == null ? 0 : t - total;
    final r100 = (total / 100).ceil() * 100, r500 = (total / 500).ceil() * 500;
    final options = <num>{total, if (r100 > total) r100, if (r500 > r100) r500}.toList();
    if (q == null && order == null) {
      return OrderCardBox(radius: 22, child: Text(_quoteError ?? 'Pricing…', style: inter(13, 400, color: kMuted)));
    }
    return OrderCardBox(
      radius: 22,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Kick('Bill summary'),
        const SizedBox(height: 8),
        KeyValue('Subtotal', rupees(subtotal), size: 15, bold: true),
        if (gst > 0 || gstPct > 0) KeyValue('GST (${gstPct == gstPct.roundToDouble() ? gstPct.toInt() : gstPct}%)', rupees(gst), size: 15),
        if (sc > 0) KeyValue('Service Charge', rupees(sc), size: 15),
        if (disc > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2.5),
            child: Row(children: [
              Text(tr('Discount'), style: inter(15, 500, color: kGreenText)),
              if (code != null) ...[const SizedBox(width: 8), TagChip(code)],
              const Spacer(),
              Text('−${rupees(disc)}', style: inter(15, 700, color: kGreenText)),
            ]),
          ),
        const Divider(height: 22, color: kLine),
        Row(children: [Text(tr('Total Amount'), style: inter(17, 800)), const Spacer(), Text(rupees(total), style: inter(26, 800, color: kGreenText))]),
        if (_method == 'cash') ...[
          const SizedBox(height: 12),
          Text(tr('Amount Received'), style: inter(13, 600, color: kMuted)),
          const SizedBox(height: 6),
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(color: kSoftField, borderRadius: BorderRadius.circular(999), border: Border.all(color: const Color(0xFFD9DBD3))),
            child: Row(children: [
              Text('₹', style: inter(22, 800)),
              Expanded(
                child: TextField(
                  key: const ValueKey('tender-field'),
                  controller: _tender,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  style: inter(22, 800),
                  decoration: InputDecoration(border: InputBorder.none, isCollapsed: true, hintText: '0', hintStyle: inter(22, 800, color: kKicker)),
                  onChanged: (_) => _intentChanged(),
                ),
              ),
              const Icon(LucideIcons.pencil, size: 16, color: kWarnText),
            ]),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final v in options)
              Material(
                color: t == v ? const Color(0xFF7BEE00) : kSoftField,
                shape: StadiumBorder(side: BorderSide(color: t == v ? const Color(0xFF7BEE00) : const Color(0xFFDDDFD8))),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () {
                    _tender.text = v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
                    _intentChanged();
                  },
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Text(v == total ? '${rupees(v)} (Exact)' : rupees(v), style: inter(13, t == v ? 700 : 500, color: t == v ? kInk : kMuted))),
                ),
              ),
          ]),
          const Divider(height: 22, color: kLine),
          Row(children: [
            Text(tr('Change Due'), style: inter(15, 500, color: kMuted)),
            const Spacer(),
            if (change > 0) ...[TagChip('+${rupees(change)}'), const SizedBox(width: 8)],
            Text(rupees(change > 0 ? change : 0), style: inter(24, 800, color: kGreenText)),
          ]),
        ] else ...[
          const SizedBox(height: 10),
          Text(_method == 'card' ? 'Press Pay, take the card on the machine, then confirm with the approval code.' : 'Press Pay, show the UPI QR, then confirm with the UPI reference once the customer has paid.', style: inter(13, 400, color: kMuted)),
        ],
      ]),
    );
  }

  Widget _splitCard() {
    final left = _total - _splitSum;
    return OrderCardBox(
      radius: 22,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Kick('Split payment'),
        const SizedBox(height: 4),
        Text('Total due ${rupees(_total)}. Add 2 to 4 parts; they must add up to the total.', style: inter(13, 400, color: kMuted)),
        const SizedBox(height: 10),
        for (var i = 0; i < _parts.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              DropdownButton<String>(
                value: _parts[i].method,
                underline: SizedBox.shrink(),
                items: [DropdownMenuItem(value: 'cash', child: Text(tr('Cash'))), DropdownMenuItem(value: 'card', child: Text(tr('Card'))), DropdownMenuItem(value: 'upi', child: Text('UPI'))],
                onChanged: (v) {
                  _parts[i].method = v!;
                  _intentChanged();
                },
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  key: ValueKey('split-amount-$i'),
                  controller: _parts[i].amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  decoration: InputDecoration(prefixText: '₹ ', hintText: tr('Amount'), suffixIcon: _parts.length > 2 ? IconButton(icon: const Icon(LucideIcons.x, size: 16), tooltip: 'Remove part', onPressed: () {
                    _parts.removeAt(i);
                    _intentChanged();
                  }) : null),
                  onChanged: (_) => _intentChanged(),
                ),
              ),
            ]),
          ),
        Row(children: [
          if (_parts.length < 4) TextButton.icon(onPressed: () {
            _parts.add(_SplitPart('upi'));
            _intentChanged();
          }, icon: const Icon(LucideIcons.plus, size: 16), label: const Text('Add part')),
          const Spacer(),
          Text(left.abs() < 0.005 ? 'Adds up' : (left > 0 ? '${rupees(left)} still to allocate' : '${rupees(-left)} too much'), style: inter(13, 700, color: left.abs() < 0.005 ? kGreenText : kWarnText)),
        ]),
      ]),
    );
  }
}
