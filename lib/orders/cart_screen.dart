import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../customers/customer_picker.dart';
import '../customers/customers_api.dart';
import '../ui/theme.dart';
import 'order_screen.dart';
import 'order_widgets.dart';
import 'orders_api.dart';

/// Figma "Cart" and "Checkout" for a new counter bill. Nothing is placed until Complete Payment (or Save & Hold).
/// Every total on screen is the server's quote; the phone only keeps which items and how many.
class CartScreen extends StatefulWidget {
  const CartScreen({super.key, this.api, this.initialLines = const [], this.onNavigate, this.customersApi});
  final OrdersApi? api;
  final CustomersApi? customersApi; // S5.5: the bill's customer
  final List<CartLine> initialLines;
  final ValueChanged<String>? onNavigate;
  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  late final OrdersApi _api = widget.api ?? OrdersApi();
  late final List<CartLine> _lines = [for (final l in widget.initialLines) CartLine(menuItemId: l.menuItemId, name: l.name, qty: l.qty)];
  final _tender = TextEditingController();
  final _placedAt = TimeOfDay.now();
  Quote? _quote;
  String? _quoteError;
  bool _checkout = false;
  bool _busy = false;
  String _method = 'cash';
  String? _key; // one key per payment intent: kept for a retry, dropped when the cart, method or amount changes
  Timer? _debounce;
  int _seq = 0;
  CustomerChoice? _customer; // S5.5: null = not asked yet (a guest), walk-in, or a customer of the business

  static const _methods = [('cash', 'Cash'), ('card', 'Card'), ('upi', 'UPI / QR'), ('split', 'Split Pay')];

  @override
  void initState() {
    super.initState();
    _requote();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tender.dispose();
    super.dispose();
  }

  void _changed() {
    _key = null;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _requote);
    setState(() {});
  }

  Future<void> _requote() async {
    if (_lines.isEmpty) {
      setState(() {
        _quote = null;
        _quoteError = null;
      });
      return;
    }
    final mine = ++_seq;
    try {
      final q = await _api.quote(_lines);
      if (!mounted || mine != _seq) return;
      setState(() {
        _quote = q;
        _quoteError = null;
      });
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() => _quoteError = e.toString());
    }
  }

  num? get _tendered => num.tryParse(_tender.text.replaceAll(',', '').trim());

  Future<void> _addItems() async {
    final picked = await showOrderSheet<CatalogItem>(context, title: 'Add items', body: (ctx) => _CatalogPicker(api: _api));
    if (picked == null) return;
    final existing = _lines.where((l) => l.menuItemId == picked.id).firstOrNull;
    if (existing != null) {
      if (existing.qty < 99) existing.qty++;
    } else {
      _lines.add(CartLine(menuItemId: picked.id, name: picked.name));
    }
    _changed();
  }

  Future<void> _applyCoupon() async {
    final code = TextEditingController();
    final entered = await showOrderSheet<String>(
      context,
      title: 'Apply coupon',
      body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: code, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(hintText: 'Coupon code')),
        const SizedBox(height: 16),
        DarkCta(label: 'Apply', onPressed: () => Navigator.pop(ctx, code.text.trim())),
      ]),
    );
    if (entered == null || entered.isEmpty || !mounted) return;
    try {
      await _api.quote(_lines, coupon: entered);
      // The server prices coupons; until POS coupons exist it refuses every code, and that refusal is what the person sees.
    } catch (e) {
      if (mounted) showToast(context, e.toString());
    }
  }

  // S5.5 Customer: existing, walk-in or new. Linked to the bill once it is placed (the database records it on the order).
  Future<void> _pickCustomer() async {
    final c = await showCustomerPicker(context, api: widget.customersApi);
    if (c != null && mounted) setState(() => _customer = c);
  }

  Future<void> _linkCustomer(String orderId) async {
    final c = _customer?.customer;
    if (c == null) return;
    try {
      await (widget.customersApi ?? CustomersApi()).attach(orderId, c.id);
    } catch (e) {
      if (mounted) showToast(context, 'Bill saved, but the customer was not linked: $e');
    }
  }

  Future<void> _complete() async {
    final q = _quote;
    if (q == null || _busy) return;
    if (_method == 'cash' && (_tendered == null || _tendered! <= 0)) {
      showToast(context, 'Enter the cash received.');
      return;
    }
    setState(() => _busy = true);
    _key ??= OrdersApi.newKey();
    try {
      final view = await _api.checkout(lines: _lines, method: _method, tendered: _method == 'cash' ? _tendered : null, key: _key!);
      await _linkCustomer(view.id);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => OrderScreen(api: _api, orderId: view.id, initial: view, onNavigate: widget.onNavigate)));
    } catch (e) {
      if (mounted) showToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _hold() async {
    if (_lines.isEmpty || _busy) return;
    setState(() => _busy = true);
    final key = OrdersApi.newKey();
    try {
      final view = await _api.hold(lines: _lines, key: key);
      await _linkCustomer(view.id);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => OrderScreen(api: _api, orderId: view.id, initial: view, onNavigate: widget.onNavigate)));
    } catch (e) {
      if (mounted) showToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _quote;
    final total = q?.total ?? 0;
    final title = _checkout ? 'Checkout' : 'Cart';
    final units = _lines.fold<int>(0, (n, l) => n + l.qty);
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        // Bill is a main tab: the cart shows the outlet header (specs/outlets-multi), checkout keeps the back arrow to the cart
        OrdersTopBar(title: _checkout ? 'Checkout · new bill' : 'Cart · new bill', onBack: _checkout ? () => setState(() => _checkout = false) : null),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(12, 14, 12, 16), children: [
            InkWell(
              key: const ValueKey('cart-customer'),
              borderRadius: BorderRadius.circular(18),
              onTap: _busy ? null : _pickCustomer,
              child: OrderHeaderCard(number: 'New bill', channel: 'Store Checkout', subtitle: 'Customer: ${_customer?.label ?? 'Guest'} · ${_placedAt.format(context)}'),
            ),
            const SizedBox(height: 14),
            StateHeader(
              title: title,
              chip: _checkout ? 'Awaiting payment' : 'Unpaid',
              orderStatus: _checkout ? 'Not placed · payment check' : 'Draft · not placed',
              fulfilment: 'Not started',
            ),
            const SizedBox(height: 10),
            _note(total),
            const SizedBox(height: 12),
            _itemsCard(units),
            const SizedBox(height: 12),
            _methodCard(),
            const SizedBox(height: 12),
            if (q != null)
              BillSummary(
                subtotal: q.subtotal,
                gstPct: q.gstPct,
                gst: q.gst,
                serviceCharge: q.serviceCharge,
                discount: q.discount,
                roundOff: q.roundOff,
                total: q.total,
                footer: _tenderBlock(total),
              )
            else
              OrderCardBox(child: Text(_quoteError ?? (_lines.isEmpty ? 'Add items to see the bill.' : 'Pricing…'), style: inter(13, 400, color: kMuted))),
            const SizedBox(height: 16),
            if (!_checkout) ...[
              DarkCta(label: 'Proceed to Checkout ${rupees(total)}', onPressed: q == null ? null : () => setState(() => _checkout = true)),
              const SizedBox(height: 10),
              LightCta(label: 'Edit cart items', onPressed: _addItems),
            ] else
              DarkCta(label: 'Complete Payment ${rupees(total)}', busy: _busy, onPressed: q == null ? null : _complete),
            const SizedBox(height: 8),
            UnderLink('Save & Hold', onTap: _lines.isEmpty || _busy ? null : _hold),
          ]),
        ),
        PosBottomNav(active: 'bill', onTap: (id) => id == 'bill' ? null : (widget.onNavigate ?? (_) => showToast(context, 'That part of the app is not built yet.'))(id)),
      ]),
    );
  }

  Widget _note(num total) {
    if (!_checkout) return const StateNote(tone: 'info', title: 'Review this individual cart', body: 'Quantities and coupon are editable. No payment has been collected.');
    final t = _tendered;
    if (_method == 'cash' && t != null && t > 0) {
      final change = t - total;
      return StateNote(
        tone: change < 0 ? 'warn' : 'info',
        title: 'Cash tender entered',
        body: change < 0 ? '${rupees(t)} is less than the ${rupees(total)} due.' : 'Confirm ${rupees(t)} received, settle ${rupees(total)} and return ${rupees(change)} change.',
      );
    }
    return StateNote(tone: 'info', title: 'Ready for payment', body: _method == 'cash' ? 'Enter the cash received to work out the change.' : 'Confirm the ${_methods.firstWhere((m) => m.$1 == _method).$2} payment, then complete.');
  }

  Widget _itemsCard(int units) {
    final priced = {for (final l in _quote?.lines ?? const <Map<String, dynamic>>[]) l['menu_item_id']: l};
    return OrderCardBox(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Kick('Order items')),
          Text('${_lines.length} ${_lines.length == 1 ? 'line' : 'lines'} · $units ${units == 1 ? 'unit' : 'units'}', style: inter(11.5, 400, color: kMuted)),
        ]),
        const SizedBox(height: 8),
        if (_lines.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('No items yet.', style: inter(13, 400, color: kMuted))),
        for (final l in _lines)
          ItemLine(
            name: l.name,
            sub: '${l.qty} ${l.qty == 1 ? 'unit' : 'units'} ordered · ${_checkout ? 'ready for checkout' : 'editable'}',
            amount: num.tryParse('${priced[l.menuItemId]?['amount'] ?? 0}') ?? 0,
            qtyBadge: _checkout ? '${l.qty}×' : null,
            stepper: _checkout
                ? null
                : QtyStepper(
                    qty: l.qty,
                    name: l.name,
                    onMinus: () {
                      l.qty <= 1 ? _lines.remove(l) : l.qty--;
                      _changed();
                    },
                    onPlus: () {
                      if (l.qty < 99) l.qty++;
                      _changed();
                    },
                  ),
          ),
        const Divider(height: 18, color: kLine),
        Wrap(spacing: 8, runSpacing: 8, children: [
          SmallPill('Apply Coupon', bg: kChipGreen, fg: kGreenText, border: kChipGreen, onTap: _lines.isEmpty ? null : _applyCoupon),
          SmallPill('Add Tip', onTap: () => showToast(context, 'Tips are not set up for counter bills yet.')),
          SmallPill('Add Items', bg: kLime, border: kLime, onTap: _addItems),
        ]),
      ]),
    );
  }

  Widget _methodCard() => OrderCardBox(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Kick(_checkout ? 'Select payment method' : 'Payment method · not collected'),
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
                Material(
                  color: _method == id ? kLime : kSoftField,
                  shape: StadiumBorder(side: BorderSide(color: _method == id ? kLime : const Color(0xFFDDDFD8))),
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: () {
                      setState(() => _method = id);
                      _key = null;
                    },
                    child: Center(child: Text(label, style: inter(13.5, _method == id ? 700 : 500, color: _method == id ? kInk : kMuted))),
                  ),
                ),
            ],
          ),
        ]),
      );

  Widget _tenderBlock(num total) {
    if (!_checkout) {
      return TenderBlock(
        label: 'Amount Received · not collected',
        amountText: '₹0',
        chips: ['${rupees(total)} due', _methods.firstWhere((m) => m.$1 == _method).$2, 'Draft'],
        selectedChip: 'Draft',
        changeLabel: 'Change Due · none',
        changeChip: 'Unpaid',
        changeValue: '₹0',
      );
    }
    if (_method != 'cash') {
      return TenderBlock(
        label: 'Amount to collect · not yet captured',
        amountText: rupees(total),
        chips: ['${rupees(total)} (Exact)'],
        changeLabel: 'Change Due · none',
        changeChip: 'No change',
        changeValue: '₹0',
      );
    }
    final t = _tendered;
    final round100 = (total / 100).ceil() * 100, round500 = (total / 500).ceil() * 500;
    final options = <num>{total, if (round100 > total) round100, if (round500 > round100) round500}.toList();
    final change = t == null ? 0 : (t - total);
    return TenderBlock(
      label: 'Amount Received · not yet captured',
      amountText: '',
      field: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(color: kSoftField, borderRadius: BorderRadius.circular(999), border: Border.all(color: const Color(0xFFD9DBD3))),
        child: Row(children: [
          Text('₹', style: inter(20, 800)),
          Expanded(
            child: TextField(
              key: const ValueKey('tender-field'),
              controller: _tender,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              style: inter(20, 800),
              decoration: InputDecoration(border: InputBorder.none, isCollapsed: true, hintText: '0', hintStyle: inter(20, 800, color: kKicker)),
              onChanged: (_) => setState(() => _key = null),
            ),
          ),
          const Icon(LucideIcons.pencil, size: 16, color: kWarnText),
        ]),
      ),
      chips: const [],
      changeLabel: 'Change Due',
      changeChip: change > 0 ? '+${rupees(change)}' : (change < 0 ? 'Short' : 'Exact'),
      changeValue: rupees(change > 0 ? change : 0),
    ).withTenderChips(
      options: options,
      exact: total,
      selected: t,
      onPick: (v) {
        _tender.text = v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
        setState(() => _key = null);
      },
    );
  }
}

extension on TenderBlock {
  /// Cash: tappable amount chips (exact / next ₹100 / next ₹500) between the field and the change line.
  Widget withTenderChips({required List<num> options, required num exact, required num? selected, required ValueChanged<num> onPick}) {
    final base = this;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(base.label, style: inter(12.5, 600, color: kMuted)),
      const SizedBox(height: 6),
      base.field!,
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final v in options)
          Material(
            color: selected == v ? kLime : kSoftField,
            shape: StadiumBorder(side: BorderSide(color: selected == v ? kLime : const Color(0xFFDDDFD8))),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => onPick(v),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: Text(v == exact ? '${rupees(v)} (Exact)' : rupees(v), style: inter(11.5, selected == v ? 700 : 500, color: selected == v ? kInk : kMuted)),
              ),
            ),
          ),
      ]),
      const Divider(height: 20, color: kLine),
      Row(children: [
        Expanded(child: Text(base.changeLabel, style: inter(13.5, 400, color: kMuted))),
        TagChip(base.changeChip),
        const SizedBox(width: 6),
        Text(base.changeValue, style: inter(20, 800, color: kGreenText)),
      ]),
    ]);
  }
}

/// Searchable list of this business's sellable items; returns the one tapped.
class _CatalogPicker extends StatefulWidget {
  const _CatalogPicker({required this.api});
  final OrdersApi api;
  @override
  State<_CatalogPicker> createState() => _CatalogPickerState();
}

class _CatalogPickerState extends State<_CatalogPicker> {
  final _q = TextEditingController();
  List<CatalogItem>? _items;
  String? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await widget.api.catalog(q: _q.text);
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          controller: _q,
          decoration: const InputDecoration(hintText: 'Search items', prefixIcon: Icon(LucideIcons.search, size: 18)),
          onChanged: (_) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), _load);
          },
        ),
        const SizedBox(height: 8),
        if (_error != null) Text(_error!, style: inter(13, 400, color: kMuted)),
        if (_items == null && _error == null) const Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(color: kGreenText)),
        if (_items != null && _items!.isEmpty) Padding(padding: const EdgeInsets.all(20), child: Text('No items found.', style: inter(13, 400, color: kMuted))),
        if (_items != null)
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
            child: ListView(shrinkWrap: true, children: [
              for (final i in _items!)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(i.name, style: inter(14, 500)),
                  trailing: Text(rupees(i.price), style: inter(14, 700)),
                  onTap: () => Navigator.pop(context, i),
                ),
            ]),
          ),
      ]);
}
