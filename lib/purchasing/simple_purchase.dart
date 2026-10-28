import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../inventory/inventory_api.dart';
import '../inventory/inventory_widgets.dart' hide qty;
import '../inventory/receiving_screen.dart' show newItemForReceiving;
import '../ui/app_header.dart';
import '../ui/barcode_scanner.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'purchasing_api.dart';
import 'purchasing_widgets.dart';

// The purchase flow, simplified (founder, 28 Oct 2026):
//   Generate PO (live at once) → it waits, with a day counter (3 days: needs attention, 7 days: late)
//   → Received: the quantities as they came, any extra item (search, scan or new), the MRP of every line; stock goes up only with the MRP
//   → the purchase bill: invoice, GST, payment, credit note. Past purchases list every delivery by date.

/// Tests replace the camera scanner.
Future<String?> Function(BuildContext context) scanForPurchase = (context) => scanBarcode(context, allowTyping: true);

String _rupees(num v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);
num? _num(String s) => num.tryParse(s.trim().replaceAll(',', ''));

/// How long an order has waited, and how worried to be: under 3 days fine, 3 to 6 needs attention, 7 or more late.
({Color color, Color wash, String word}) waitTone(int days) => days >= 7
    ? (color: const Color(0xFFC62828), wash: const Color(0xFFFDECEC), word: 'Late')
    : days >= 3
        ? (color: const Color(0xFFB45309), wash: const Color(0xFFFFF4E0), word: 'Needs attention')
        : (color: const Color(0xFF15803D), wash: const Color(0xFFE8F7EC), word: 'On time');

/// The day counter on an open order: "Ordered 4 days ago · not received yet", a bar that fills over a week.
class PoWaitBar extends StatelessWidget {
  const PoWaitBar({super.key, required this.days});
  final int days;
  @override
  Widget build(BuildContext context) {
    final t = waitTone(days);
    final when = days == 0 ? tr('Ordered today') : days == 1 ? tr('Ordered yesterday') : '${tr('Ordered')} $days ${tr('days ago')}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('$when · ${tr('not received yet')}', style: inter(12.5, 600, color: kInk))),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: t.wash, borderRadius: BorderRadius.circular(99)),
          child: Text(tr(t.word), style: inter(11.5, 700, color: t.color)),
        ),
      ]),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: LinearProgressIndicator(
          key: const ValueKey('po-wait-bar'),
          value: ((days + 1) / 8).clamp(0.08, 1.0),
          minHeight: 6,
          color: t.color,
          backgroundColor: const Color(0xFFEDEEF1),
        ),
      ),
    ]);
  }
}

/// An open order: supplier, amount, the day counter, and its two outcomes, Received or Cancel.
class OpenOrderCard extends StatelessWidget {
  const OpenOrderCard({super.key, required this.po, required this.onReceived, required this.onCancel, this.onOpen});
  final PurchaseOrder po;
  final VoidCallback onReceived, onCancel;
  final VoidCallback? onOpen;
  @override
  Widget build(BuildContext context) {
    final total = po.totals.no('ordered_total_minor') ?? po.totals.no('estimated_minor');
    final lines = po.lines.length;
    return InvCard(
      key: ValueKey('po-${po.id}'),
      onTap: onOpen,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(po.supplierName, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(15.5, 800, height: 1.25))),
          const SizedBox(width: 10),
          Text(total == null ? '—' : money(total), style: inter(15.5, 800)),
        ]),
        const SizedBox(height: 3),
        Text([po.number, '$lines ${tr(lines == 1 ? 'item' : 'items')}'].join(' · '), style: inter(12, 400, color: kMuted)),
        const SizedBox(height: 10),
        PoWaitBar(days: po.n('days_waiting').toInt()),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              key: ValueKey('po-received-${po.id}'),
              onPressed: onReceived,
              icon: const Icon(LucideIcons.packageCheck, size: 17),
              label: Text(tr('Received'), style: inter(14, 700, color: Colors.white)),
              style: FilledButton.styleFrom(backgroundColor: kPrimary, padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            key: ValueKey('po-cancel-${po.id}'),
            onPressed: onCancel,
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16), side: const BorderSide(color: kCardLine), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: Text(tr('Cancel PO'), style: inter(14, 700, color: const Color(0xFFC62828))),
          ),
        ]),
      ]),
    );
  }
}

/// Cancel an order, after asking. Answers true when it was cancelled.
Future<bool> cancelOrder(BuildContext context, PurchasingApi api, PurchaseOrder po) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('${tr('Cancel')} ${po.number}?', style: inter(18, 700)),
      content: Text(tr('The supplier order is cancelled. Nothing comes into stock.'), style: inter(14, 400, color: kMuted)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Keep'), style: inter(14, 600))),
        TextButton(key: const ValueKey('confirm-cancel-po'), onPressed: () => Navigator.pop(c, true), child: Text(tr('Cancel PO'), style: inter(14, 700, color: const Color(0xFFC62828)))),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  try {
    await api.act(po.id, 'cancel');
    if (context.mounted) showToast(context, '${po.number} ${tr('cancelled')}.');
    return true;
  } catch (e) {
    if (context.mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not cancel. Try again.'));
    return false;
  }
}

/// One line of a delivery: what came, at what MRP and price.
class _Line {
  _Line({required this.itemId, required this.name, this.sku = '', this.ordered, required num qty, num? mrp, num? cost})
      : qty = TextEditingController(text: _rupees(qty)),
        mrp = TextEditingController(text: mrp == null ? '' : _rupees(mrp)),
        cost = TextEditingController(text: cost == null ? '' : _rupees(cost));
  final String itemId, name, sku;
  final num? ordered;
  final TextEditingController qty, mrp, cost;
  bool get extra => ordered == null;
  void dispose() {
    qty.dispose();
    mrp.dispose();
    cost.dispose();
  }
}

/// Received (founder, 28 Oct 2026): the order's items with the quantities that came, editable; an empty line at the end for anything
/// extra (search by name, scan, or a new product); the MRP of every line. Mark received adds the stock and opens the purchase bill.
/// Without [po] it is Add Purchase: goods bought without an order.
class ReceiveGoodsScreen extends StatefulWidget {
  const ReceiveGoodsScreen({super.key, required this.api, this.po, this.openBill});
  final PurchasingApi api;
  final PurchaseOrder? po;

  /// Tests replace what opens after receiving.
  final void Function(BuildContext context, String receiptId)? openBill;
  @override
  State<ReceiveGoodsScreen> createState() => _ReceiveGoodsScreenState();
}

class _ReceiveGoodsScreenState extends State<ReceiveGoodsScreen> {
  late final List<_Line> _lines = [
    for (final l in widget.po?.lines ?? const <Facts>[])
      if (l.s('material_id').isNotEmpty)
        _Line(
          itemId: l.s('material_id'),
          name: l.s('name'),
          sku: l.s('code'),
          ordered: l.n('ordered_qty') - l.n('received_qty') - l.n('rejected_qty'),
          qty: (l.n('ordered_qty') - l.n('received_qty') - l.n('rejected_qty')).clamp(0, double.infinity),
          mrp: l.no('mrp_minor') == null ? null : l.n('mrp_minor') / 100,
          cost: l.no('unit_cost_minor') == null ? null : l.n('unit_cost_minor') / 100,
        ),
  ];
  final _find = TextEditingController();
  final _supplier = TextEditingController();
  final _key = PurchasingApi.newKey();
  List<Facts> _hits = const [];
  bool _busy = false, _searching = false;
  int _seq = 0;

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    _find.dispose();
    _supplier.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    final mine = ++_seq;
    if (q.trim().length < 2) return setState(() => _hits = const []);
    setState(() => _searching = true);
    try {
      final r = await widget.api.findItems(q);
      if (mounted && mine == _seq) setState(() => _hits = r);
    } catch (_) {
      if (mounted && mine == _seq) setState(() => _hits = const []);
    } finally {
      if (mounted && mine == _seq) setState(() => _searching = false);
    }
  }

  void _add(Facts item) {
    setState(() {
      final at = _lines.indexWhere((l) => l.itemId == item.s('id'));
      if (at >= 0) {
        _lines[at].qty.text = _rupees((_num(_lines[at].qty.text) ?? 0) + 1); // the same item again: one more
      } else {
        _lines.add(_Line(
          itemId: item.s('id'),
          name: item.s('name'),
          sku: item.s('sku'),
          qty: 1,
          mrp: item.no('mrp_minor') == null ? null : item.n('mrp_minor') / 100,
          cost: item.no('cost_minor') == null ? null : item.n('cost_minor') / 100,
        ));
      }
      _find.clear();
      _hits = const [];
    });
  }

  Future<void> _scan() async {
    final code = await scanForPurchase(context);
    if (code == null || code.trim().isEmpty || !mounted) return;
    try {
      final r = await widget.api.findItems(code.trim());
      if (!mounted) return;
      if (r.isEmpty) {
        showToast(context, '${tr('No product with code')} ${code.trim()}. ${tr('Add it as a new product.')}');
        _find.text = code.trim();
        return;
      }
      _add(r.first);
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not look that up. Try again.'));
    }
  }

  Future<void> _newProduct() async {
    final item = await newItemForReceiving(context);
    if (item == null || !mounted) return;
    _add(item);
  }

  num get _total => _lines.fold<num>(0, (s, l) => s + (_num(l.qty.text) ?? 0) * (_num(l.cost.text) ?? 0));

  Future<void> _receive() async {
    if (_busy) return;
    if (widget.po == null && _supplier.text.trim().isEmpty) return showToast(context, tr('Enter who the goods came from.'));
    final got = _lines.where((l) => (_num(l.qty.text) ?? 0) > 0).toList();
    if (got.isEmpty) return showToast(context, tr('Enter the quantity that came.'));
    final noMrp = got.where((l) => (_num(l.mrp.text) ?? 0) <= 0).toList();
    if (noMrp.isNotEmpty) {
      setState(() {}); // the lines without MRP turn red
      return showToast(context, '${tr('Add the MRP to add these to stock')}: ${noMrp.map((l) => l.name).join(', ')}');
    }
    setState(() => _busy = true);
    try {
      final r = await widget.api.receivePost(
        poId: widget.po?.id,
        supplierName: widget.po == null ? _supplier.text.trim() : null,
        key: _key,
        lines: [
          for (final l in got)
            {'inventory_item_id': l.itemId, 'qty': _num(l.qty.text), 'mrp': _num(l.mrp.text), 'cost': _num(l.cost.text), 'ordered_qty': l.ordered},
        ],
      );
      if (!mounted) return;
      showToast(context, '${r.s('doc_no')} · ${tr('stock added')}.');
      final open = widget.openBill ?? (c, id) => Navigator.of(c).pushReplacement(MaterialPageRoute(builder: (_) => PurchaseBillScreen(api: widget.api, receiptId: id, justReceived: true)));
      open(context, r.s('document_id'));
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not save. Check your connection and try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(TextEditingController c, String label, {Key? key, bool wrong = false, String? prefix}) => Expanded(
        child: TextField(
          key: key,
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          onChanged: (_) => setState(() {}),
          style: inter(14.5, 600),
          decoration: InputDecoration(
            isDense: true,
            labelText: tr(label),
            prefixText: prefix,
            labelStyle: inter(12.5, 500, color: wrong ? const Color(0xFFC62828) : kMuted),
            filled: true,
            fillColor: wrong ? const Color(0xFFFDECEC) : kBg,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: wrong ? const Color(0xFFC62828) : kCardLine)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: wrong ? const Color(0xFFC62828) : kCardLine)),
          ),
        ),
      );

  Widget _lineCard(int i, _Line l) {
    final q = _num(l.qty.text) ?? 0;
    final noMrp = q > 0 && (_num(l.mrp.text) ?? 0) <= 0;
    return InvCard(
      key: ValueKey('recv-line-$i'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(l.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(14.5, 700))),
          if (l.extra)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFFFFF4E0), borderRadius: BorderRadius.circular(99)),
              child: Text(tr('Not on order'), style: inter(11, 700, color: const Color(0xFFB45309))),
            ),
          IconButton(
            key: ValueKey('recv-remove-$i'),
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _lines.removeAt(i).dispose()),
            icon: const Icon(LucideIcons.x, size: 17, color: kMuted),
          ),
        ]),
        Text([if (l.sku.isNotEmpty) l.sku, if (l.ordered != null) '${tr('Ordered')} ${_rupees(l.ordered!)}'].join(' · '), style: inter(12, 400, color: kMuted)),
        const SizedBox(height: 10),
        Row(children: [
          _field(l.qty, 'Received', key: ValueKey('recv-qty-$i')),
          const SizedBox(width: 8),
          _field(l.mrp, 'MRP', key: ValueKey('recv-mrp-$i'), wrong: noMrp, prefix: '₹ '),
          const SizedBox(width: 8),
          _field(l.cost, 'Price', key: ValueKey('recv-cost-$i'), prefix: '₹ '),
        ]),
        if (noMrp) Padding(padding: const EdgeInsets.only(top: 6), child: Text(tr('Add the MRP to add this to stock.'), style: inter(12, 600, color: const Color(0xFFC62828)))),
        if (l.ordered != null && q < l.ordered! && q >= 0)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text('${_rupees(l.ordered! - q)} ${tr('fewer than ordered')}', style: inter(12, 600, color: const Color(0xFFB45309)))),
      ]),
    );
  }

  /// The empty line at the end: type a name, scan, or make a new product.
  Widget _addLine() => InvCard(
        key: const ValueKey('recv-add-line'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: TextField(
                key: const ValueKey('recv-find'),
                controller: _find,
                onChanged: _search,
                style: inter(14.5, 500),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: tr('Add an item that came: name or code'),
                  prefixIcon: const Icon(LucideIcons.search, size: 18),
                  filled: true,
                  fillColor: kBg,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kCardLine)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kCardLine)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              key: const ValueKey('recv-scan'),
              onPressed: _scan,
              tooltip: tr('Scan a barcode'),
              icon: const Icon(LucideIcons.scanLine, size: 20),
            ),
          ]),
          if (_searching) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator(minHeight: 2)),
          for (final h in _hits)
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: ValueKey('recv-hit-${h.s('id')}'),
                borderRadius: BorderRadius.circular(10),
                onTap: () => _add(h),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(h.s('name'), style: inter(14, 600)),
                        Text([h.s('sku'), if (h.no('mrp_minor') != null) '${tr('MRP')} ${money(h.n('mrp_minor'))}'].where((s) => s.isNotEmpty).join(' · '), style: inter(12, 400, color: kMuted)),
                      ]),
                    ),
                    const Icon(LucideIcons.plus, size: 18, color: kLink),
                  ]),
                ),
              ),
            ),
          if (_find.text.trim().length >= 2 && !_searching)
            TextButton.icon(
              key: const ValueKey('recv-new-product'),
              onPressed: _newProduct,
              icon: const Icon(LucideIcons.plus, size: 16, color: kLink),
              label: Text('${tr('New product')}: "${_find.text.trim()}"', style: inter(13.5, 700, color: kLink)),
            ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final po = widget.po;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(title: tr(po == null ? 'Add purchase' : 'Received'), onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 24), children: [
            if (po != null)
              Text('${po.number} · ${po.supplierName}', style: inter(16, 800))
            else
              TextField(
                key: const ValueKey('recv-supplier'),
                controller: _supplier,
                style: inter(15, 600),
                decoration: InputDecoration(labelText: tr('Supplier'), hintText: tr('Who did the goods come from?'), filled: true, fillColor: Colors.white,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
              ),
            const SizedBox(height: 6),
            Text(tr('Enter what actually came. Stock goes up for every line with an MRP.'), style: inter(13, 400, color: kMuted)),
            const SizedBox(height: 12),
            for (final (i, l) in _lines.indexed) _lineCard(i, l),
            _addLine(),
          ]),
        ),
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: kCardLine))),
            child: Row(children: [
              Expanded(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Total'), style: inter(12, 500, color: kMuted)),
                  Text(money((_total * 100).round()), key: const ValueKey('recv-total'), style: inter(18, 800)),
                ]),
              ),
              FilledButton(
                key: const ValueKey('recv-mark-received'),
                onPressed: _busy ? null : _receive,
                style: FilledButton.styleFrom(backgroundColor: kPrimary, padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 22), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                child: Text(_busy ? '…' : tr('Mark received'), style: inter(15.5, 700, color: Colors.white)),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _BillLine {
  _BillLine(Facts f)
      : itemId = f.s('inventory_item_id'),
        name = TextEditingController(text: f.s('name')),
        qty = TextEditingController(text: _rupees(f.n('qty'))),
        rate = TextEditingController(text: _rupees(f.n('rate_minor') / 100)),
        disc = TextEditingController(text: f.n('discount_pct') == 0 ? '' : _rupees(f.n('discount_pct'))),
        gst = f.n('gst_pct');
  final String itemId;
  final TextEditingController name, qty, rate, disc;
  num gst;
  num get taxable => (_num(qty.text) ?? 0) * (_num(rate.text) ?? 0) * (1 - (_num(disc.text) ?? 0) / 100);
  void dispose() {
    name.dispose();
    qty.dispose();
    rate.dispose();
    disc.dispose();
  }
}

class _CreditLine {
  _CreditLine([Facts? f])
      : name = TextEditingController(text: f?.s('name') ?? ''),
        qty = TextEditingController(text: f?.no('qty') == null ? '' : _rupees(f!.n('qty'))),
        amount = TextEditingController(text: f?.no('amount_minor') == null ? '' : _rupees(f!.n('amount_minor') / 100)),
        reason = f?.so('reason') ?? 'short';
  final TextEditingController name, qty, amount;
  String reason;
  void dispose() {
    name.dispose();
    qty.dispose();
    amount.dispose();
  }
}

const _gstRates = [0, 5, 12, 18, 28];
const _reasons = {'short': 'Short supplied', 'damaged': 'Damaged', 'returned': 'Returned', 'rate_difference': 'Rate difference', 'other': 'Other'};

/// The purchase bill of a received delivery: invoice number and date, supplier GSTIN, every line with rate, discount and GST, the
/// totals, how it was paid, and a credit note for anything short, damaged or returned.
class PurchaseBillScreen extends StatefulWidget {
  const PurchaseBillScreen({super.key, required this.api, required this.receiptId, this.justReceived = false});
  final PurchasingApi api;
  final String receiptId;
  final bool justReceived;
  @override
  State<PurchaseBillScreen> createState() => _PurchaseBillScreenState();
}

class _PurchaseBillScreenState extends State<PurchaseBillScreen> {
  Facts? _receipt;
  String? _error;
  final _supplier = TextEditingController(), _gstin = TextEditingController(), _invoice = TextEditingController(), _paid = TextEditingController(), _note = TextEditingController();
  DateTime? _date;
  String _pay = 'unpaid';
  List<_BillLine> _lines = [];
  List<_CreditLine> _credit = [];
  bool _busy = false, _saved = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_supplier, _gstin, _invoice, _paid, _note]) {
      c.dispose();
    }
    for (final l in _lines) {
      l.dispose();
    }
    for (final l in _credit) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.bill(widget.receiptId);
      if (!mounted) return;
      final rec = r.m('receipt'), bill = r.mo('bill');
      setState(() {
        _receipt = rec;
        _error = null;
        _supplier.text = bill?.s('supplier_name').isNotEmpty == true ? bill!.s('supplier_name') : rec.s('supplier_name');
        _gstin.text = bill?.s('supplier_gstin') ?? '';
        _invoice.text = bill?.s('invoice_no') ?? '';
        _date = DateTime.tryParse(bill?.s('invoice_date') ?? '') ?? DateTime.now();
        _pay = bill?.so('payment_status') ?? 'unpaid';
        _paid.text = (bill?.n('paid_minor') ?? 0) > 0 ? _rupees(bill!.n('paid_minor') / 100) : '';
        _note.text = bill?.s('note') ?? '';
        _saved = bill?.b('saved') ?? false;
        final lines = bill?.l('lines') ?? const <Facts>[];
        _lines = (lines.isNotEmpty ? lines : rec.l('lines').map((l) => Facts({...l.raw, 'rate_minor': 0, 'gst_pct': 0}))).map(_BillLine.new).toList();
        _credit = (bill?.l('credit_lines') ?? const <Facts>[]).map(_CreditLine.new).toList();
      });
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : tr('Could not load the purchase.'));
    }
  }

  num get _taxable => _lines.fold<num>(0, (s, l) => s + l.taxable);
  num get _gstAmt => _lines.fold<num>(0, (s, l) => s + l.taxable * l.gst / 100);
  num get _total => (_taxable + _gstAmt).roundToDouble();
  num get _creditTotal => _credit.fold<num>(0, (s, c) => s + (_num(c.amount.text) ?? 0));

  Future<void> _save() async {
    if (_busy) return;
    if (_invoice.text.trim().isEmpty) return showToast(context, tr('Enter the invoice number.'));
    if (_lines.isEmpty) return showToast(context, tr('The bill needs its lines.'));
    setState(() => _busy = true);
    try {
      final d = _date ?? DateTime.now();
      await widget.api.saveBill({
        'receipt_document_id': widget.receiptId,
        'supplier_name': _supplier.text.trim(),
        'supplier_gstin': _gstin.text.trim().toUpperCase(),
        'invoice_no': _invoice.text.trim(),
        'invoice_date': '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
        'payment_status': _pay,
        'paid': _pay == 'partly_paid' ? _num(_paid.text) : null,
        'note': _note.text.trim(),
        'lines': [
          for (final l in _lines)
            {'inventory_item_id': l.itemId.isEmpty ? null : l.itemId, 'name': l.name.text.trim(), 'qty': _num(l.qty.text) ?? 0, 'rate': _num(l.rate.text) ?? 0, 'discount_pct': _num(l.disc.text) ?? 0, 'gst_pct': l.gst},
        ],
        'credit_lines': [
          for (final c in _credit)
            if ((_num(c.amount.text) ?? 0) > 0) {'name': c.name.text.trim(), 'qty': _num(c.qty.text), 'reason': c.reason, 'amount': _num(c.amount.text)},
        ],
      });
      if (!mounted) return;
      showToast(context, tr('Purchase bill saved.'));
      Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not save. Check your connection and try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  InputDecoration _dec(String label, {String? prefix}) => InputDecoration(
        isDense: true,
        labelText: tr(label),
        prefixText: prefix,
        filled: true,
        fillColor: kBg,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kCardLine)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kCardLine)),
      );

  Widget _num2(TextEditingController c, String label, {String? prefix, Key? key}) => Expanded(
        child: TextField(
          key: key,
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          onChanged: (_) => setState(() {}),
          style: inter(14, 600),
          decoration: _dec(label, prefix: prefix),
        ),
      );

  Widget _section(String title, List<Widget> children, {Widget? trailing}) => InvCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [Expanded(child: Text(tr(title), style: inter(15.5, 800))), ?trailing]),
          const SizedBox(height: 10),
          ...children,
        ]),
      );

  Widget _kv(String k, String v, {bool bold = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(tr(k), style: inter(13.5, bold ? 700 : 500, color: bold ? kInk : kMuted))),
          Text(v, style: inter(bold ? 16 : 13.5, bold ? 800 : 600, color: color ?? kInk)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final rec = _receipt;
    final taxable = _taxable, gst = _gstAmt, total = _total;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(title: tr('Purchase bill'), onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kMuted))))
              : rec == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(key: const ValueKey('purchase-bill'), padding: const EdgeInsets.fromLTRB(14, 14, 14, 24), children: [
                      if (widget.justReceived)
                        Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: kNote, borderRadius: BorderRadius.circular(12)),
                          child: Row(children: [
                            const Icon(Icons.check_circle, color: Color(0xFF15803D)),
                            const SizedBox(width: 8),
                            Expanded(child: Text(tr('Stock added. Now enter the supplier\'s bill, or do it later from Past purchases.'), style: inter(13.5, 500, height: 1.35))),
                          ]),
                        ),
                      Text([rec.s('doc_no'), if (rec.s('po_ref').isNotEmpty) rec.s('po_ref'), if (rec.t('posted_at') != null) dayMonth(rec.t('posted_at')!, year: true)].join(' · '),
                          style: inter(13, 600, color: kMuted)),
                      const SizedBox(height: 10),
                      _section('Invoice', [
                        TextField(key: const ValueKey('bill-supplier'), controller: _supplier, style: inter(14.5, 600), decoration: _dec('Supplier')),
                        const SizedBox(height: 8),
                        Row(children: [
                          Expanded(child: TextField(key: const ValueKey('bill-invoice'), controller: _invoice, style: inter(14.5, 600), decoration: _dec('Invoice number'))),
                          const SizedBox(width: 8),
                          Expanded(
                            child: InkWell(
                              key: const ValueKey('bill-date'),
                              onTap: () async {
                                final d = await showDatePicker(context: context, initialDate: _date ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now());
                                if (d != null) setState(() => _date = d);
                              },
                              child: InputDecorator(decoration: _dec('Invoice date'), child: Text(_date == null ? '—' : dayMonth(_date!, year: true), style: inter(14.5, 600))),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 8),
                        TextField(
                          key: const ValueKey('bill-gstin'),
                          controller: _gstin,
                          textCapitalization: TextCapitalization.characters,
                          maxLength: 15,
                          style: inter(14.5, 600),
                          decoration: _dec('Supplier GSTIN (if any)').copyWith(counterText: ''),
                        ),
                      ]),
                      _section('Items', [
                        for (final (i, l) in _lines.indexed)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              Text(l.name.text, style: inter(14, 700)),
                              const SizedBox(height: 6),
                              Row(children: [
                                _num2(l.qty, 'Qty', key: ValueKey('bill-qty-$i')),
                                const SizedBox(width: 6),
                                _num2(l.rate, 'Rate', prefix: '₹ ', key: ValueKey('bill-rate-$i')),
                              ]),
                              const SizedBox(height: 6),
                              Row(children: [
                                _num2(l.disc, 'Discount %', key: ValueKey('bill-disc-$i')),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: DropdownButtonFormField<num>(
                                    key: ValueKey('bill-gst-$i'),
                                    initialValue: _gstRates.contains(l.gst) ? l.gst : 0,
                                    isDense: true,
                                    isExpanded: true,
                                    decoration: _dec('GST'),
                                    items: [for (final g in _gstRates) DropdownMenuItem(value: g, child: Text('$g%', style: inter(14, 600)))],
                                    onChanged: (v) => setState(() => l.gst = v ?? 0),
                                  ),
                                ),
                              ]),
                              const SizedBox(height: 4),
                              Text('${money((l.taxable * 100).round())} + ${tr('GST')} ${money((l.taxable * l.gst).round())}', style: inter(12, 500, color: kMuted)),
                            ]),
                          ),
                        const Divider(height: 18),
                        _kv('Taxable value', money((taxable * 100).round())),
                        _kv('GST', money((gst * 100).round())),
                        _kv('Round off', money(((total - taxable - gst) * 100).round())),
                        _kv('Invoice total', money((total * 100).round()), bold: true),
                      ]),
                      _section('Payment', [
                        Wrap(spacing: 8, children: [
                          for (final (id, label) in const [('unpaid', 'Unpaid'), ('partly_paid', 'Partly paid'), ('paid', 'Paid')])
                            ChoiceChip(
                              key: ValueKey('bill-pay-$id'),
                              label: Text(tr(label), style: inter(13, 600)),
                              selected: _pay == id,
                              onSelected: (_) => setState(() => _pay = id),
                            ),
                        ]),
                        if (_pay == 'partly_paid') ...[const SizedBox(height: 8), Row(children: [_num2(_paid, 'Amount paid', prefix: '₹ ')])],
                      ]),
                      _section(
                        'Credit note',
                        [
                          if (_credit.isEmpty) Text(tr('Anything short, damaged or returned? Add what the supplier owes back.'), style: inter(13, 400, color: kMuted)),
                          for (final (i, c) in _credit.indexed)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                                Row(children: [
                                  Expanded(flex: 2, child: TextField(key: ValueKey('credit-name-$i'), controller: c.name, style: inter(14, 600), decoration: _dec('Item'))),
                                  const SizedBox(width: 6),
                                  _num2(c.qty, 'Qty'),
                                  IconButton(onPressed: () => setState(() => _credit.removeAt(i).dispose()), icon: const Icon(LucideIcons.x, size: 17, color: kMuted)),
                                ]),
                                const SizedBox(height: 6),
                                Row(children: [
                                  Expanded(
                                    child: DropdownButtonFormField<String>(
                                      initialValue: c.reason,
                                      isDense: true,
                                      isExpanded: true,
                                      decoration: _dec('Why'),
                                      items: [for (final e in _reasons.entries) DropdownMenuItem(value: e.key, child: Text(tr(e.value), style: inter(14, 600)))],
                                      onChanged: (v) => setState(() => c.reason = v ?? 'short'),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  _num2(c.amount, 'Amount', prefix: '₹ ', key: ValueKey('credit-amount-$i')),
                                ]),
                              ]),
                            ),
                          if (_credit.isNotEmpty) _kv('Credit due', money((_creditTotal * 100).round()), bold: true, color: const Color(0xFF15803D)),
                        ],
                        trailing: TextButton.icon(
                          key: const ValueKey('credit-add'),
                          onPressed: () => setState(() => _credit.add(_CreditLine())),
                          icon: const Icon(LucideIcons.plus, size: 15, color: kLink),
                          label: Text(tr('Add'), style: inter(13, 700, color: kLink)),
                        ),
                      ),
                      _section('Note', [TextField(controller: _note, maxLines: 2, style: inter(14, 500), decoration: _dec('Anything else about this bill'))]),
                    ]),
        ),
        if (rec != null)
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: kCardLine))),
              child: Row(children: [
                if (!_saved && widget.justReceived)
                  TextButton(key: const ValueKey('bill-later'), onPressed: () => Navigator.of(context).maybePop(), child: Text(tr('Later'), style: inter(14.5, 700, color: kMuted))),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('bill-save'),
                    onPressed: _busy ? null : _save,
                    style: FilledButton.styleFrom(backgroundColor: kPrimary, padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(_busy ? '…' : '${tr('Save bill')} · ${money((total * 100).round())}', style: inter(15.5, 700, color: Colors.white)),
                    ),
                  ),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// Past purchases: every received delivery, by week, month or any dates; sorted and searched.
class PastPurchasesScreen extends StatefulWidget {
  const PastPurchasesScreen({super.key, required this.api, this.today});
  final PurchasingApi api;

  /// Tests fix "today".
  final DateTime? today;
  @override
  State<PastPurchasesScreen> createState() => _PastPurchasesScreenState();
}

class _PastPurchasesScreenState extends State<PastPurchasesScreen> {
  String _range = 'month';
  DateTimeRange? _custom;
  String _sort = 'newest';
  final _q = TextEditingController();
  List<Facts>? _list;
  String? _error;
  int _seq = 0;

  DateTime get _today {
    final t = widget.today ?? DateTime.now();
    return DateTime(t.year, t.month, t.day);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  (DateTime?, DateTime?) get _dates {
    final t = _today;
    return switch (_range) {
      'week' => (t.subtract(Duration(days: t.weekday - 1)), t), // Monday to today
      'month' => (DateTime(t.year, t.month, 1), t),
      'last_month' => (DateTime(t.year, t.month - 1, 1), DateTime(t.year, t.month, 0)),
      'custom' => (_custom?.start, _custom?.end),
      _ => (null, null),
    };
  }

  static String _iso(DateTime? d) => d == null ? '' : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    final mine = ++_seq;
    final (from, to) = _dates;
    try {
      final r = await widget.api.history(from: from == null ? null : _iso(from), to: to == null ? null : _iso(to), q: _q.text, sort: _sort);
      if (mounted && mine == _seq) {
        setState(() {
          _list = r;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && mine == _seq) setState(() => _error = e is PartnerApiException ? e.message : tr('Could not load past purchases.'));
    }
  }

  Future<void> _setRange(String r) async {
    if (r == 'custom') {
      final picked = await showDateRangePicker(context: context, firstDate: DateTime(2020), lastDate: _today, initialDateRange: _custom);
      if (picked == null || !mounted) return;
      _custom = picked;
    }
    setState(() {
      _range = r;
      _list = null;
    });
    _load();
  }

  static const _payWord = {'unpaid': 'Unpaid', 'partly_paid': 'Partly paid', 'paid': 'Paid'};

  @override
  Widget build(BuildContext context) {
    final list = _list;
    final (from, to) = _dates;
    final total = (list ?? const <Facts>[]).fold<num>(0, (s, p) => s + p.n('total_minor'));
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(title: tr('Past purchases'), onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(key: const ValueKey('past-purchases'), padding: const EdgeInsets.fromLTRB(14, 12, 14, 24), children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: InvChips(
                  items: const [('week', 'This week', null), ('month', 'This month', null), ('last_month', 'Last month', null), ('all', 'All', null), ('custom', 'Pick dates', null)],
                  active: _range,
                  onTap: _setRange,
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('past-search'),
                    controller: _q,
                    onChanged: (_) => _load(),
                    style: inter(14, 500),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: tr('Supplier, invoice or product'),
                      prefixIcon: const Icon(LucideIcons.search, size: 18),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kCardLine)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kCardLine)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  key: const ValueKey('past-sort'),
                  initialValue: _sort,
                  onSelected: (s) {
                    setState(() => _sort = s);
                    _load();
                  },
                  itemBuilder: (_) => [
                    for (final (id, label) in const [('newest', 'Newest first'), ('oldest', 'Oldest first'), ('amount', 'Highest amount')])
                      PopupMenuItem(value: id, child: Text(tr(label), style: inter(14, id == _sort ? 700 : 500))),
                  ],
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: kCardLine)),
                    child: const Icon(LucideIcons.arrowUpDown, size: 18),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              if (list != null)
                Text(
                  '${list.length} ${tr(list.length == 1 ? 'purchase' : 'purchases')}${from != null ? ' · ${dayMonth(from)} – ${dayMonth(to ?? _today)}' : ''} · ${money(total)}',
                  key: const ValueKey('past-summary'),
                  style: inter(13, 600, color: kMuted),
                ),
              const SizedBox(height: 8),
              if (_error != null && list == null)
                Text(_error!, style: inter(14, 500, color: kMuted))
              else if (list == null)
                const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
              else if (list.isEmpty)
                Padding(padding: const EdgeInsets.all(24), child: Text(tr('No purchases in these dates.'), textAlign: TextAlign.center, style: inter(14, 500, color: kMuted)))
              else
                for (final p in list)
                  InvCard(
                    key: ValueKey('past-${p.s('receipt_document_id')}'),
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PurchaseBillScreen(api: widget.api, receiptId: p.s('receipt_document_id'))));
                      if (mounted) _load();
                    },
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(p.t('posted_at') == null ? '' : dayMonth(p.t('posted_at')!, year: true), style: inter(12.5, 700, color: kMuted))),
                        Text(
                          p.b('bill_saved') ? tr(_payWord[p.s('payment_status')] ?? '') : tr('Bill to enter'),
                          style: inter(12, 700, color: !p.b('bill_saved') ? const Color(0xFFB45309) : p.s('payment_status') == 'paid' ? const Color(0xFF15803D) : kInk),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      Row(children: [
                        Expanded(child: Text(p.s('supplier_name').isEmpty ? tr('No supplier') : p.s('supplier_name'), style: inter(15.5, 800))),
                        Text(p.no('total_minor') == null ? '—' : money(p.n('total_minor')), style: inter(15.5, 800)),
                      ]),
                      const SizedBox(height: 3),
                      Text(
                        [
                          p.s('doc_no'),
                          if (p.s('po_ref').isNotEmpty) p.s('po_ref'),
                          if (p.s('invoice_no').isNotEmpty) '${tr('Invoice')} ${p.s('invoice_no')}',
                          '${p.n('items')} ${tr(p.n('items') == 1 ? 'item' : 'items')}',
                          if ((p.no('credit_minor') ?? 0) > 0) '${tr('Credit')} ${money(p.n('credit_minor'))}',
                        ].join(' · '),
                        style: inter(12, 400, color: kMuted),
                      ),
                    ]),
                  ),
            ]),
          ),
        ),
      ]),
    );
  }
}
