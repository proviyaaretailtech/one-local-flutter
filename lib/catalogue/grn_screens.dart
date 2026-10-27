import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_nav.dart';
import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'catalogue_api.dart';
import 'catalogue_format.dart';
import 'catalogue_widgets.dart';
import 'item_sheets.dart' show parsePriceMinor;
import '../inventory/inventory_widgets.dart' show dayMonth;
import '../ui/i18n.dart';
import '../stock/lot_labels_screen.dart' show offerLotLabels;
import '../ui/purchase_steps.dart';

String _m(num minor) => money(minor, fixed: true);

String _errText(Object e) => e is CatalogueApiException ? e.message : 'Could not reach the server. Check the connection and try again.';

void _tab(BuildContext context, String id, {String active = 'bill'}) {
  if (id == active) return;
  switch (id) {
    case 'home':
      HomeNav.go(context, HomeNav.home, 'Home');
    case 'item':
      HomeNav.go(context, HomeNav.items, 'Items');
    case 'bill':
      HomeNav.go(context, HomeNav.bill, 'Bill');
    case 'stock':
      HomeNav.go(context, HomeNav.stock, 'Stock');
    default:
      HomeNav.go(context, null, 'Online orders');
  }
}

// ================================================================ GRN Dashboard (Figma "01 — GRN Dashboard")
class GrnDashboardScreen extends StatefulWidget {
  const GrnDashboardScreen({super.key, required this.receiptId, this.api});
  final String receiptId;
  final CatalogueApi? api;
  @override
  State<GrnDashboardScreen> createState() => _GrnDashboardState();
}

/// The items ticked as received on Check delivery, per delivery, for as long as the app is open.
final _ticked = <String, Set<String>>{};

class _GrnDashboardState extends State<GrnDashboardScreen> {
  Set<String> get _ticks => _ticked.putIfAbsent(widget.receiptId, () => <String>{});
  late final CatalogueApi _api = widget.api ?? CatalogueApi();
  GrnView? _v;
  String? _error;
  bool _busy = false;
  String? _choice; // accept_claim_credit | accept_as_received
  final _claimRef = TextEditingController(), _evidence = TextEditingController(), _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load(open: true);
  }

  @override
  void dispose() {
    _claimRef.dispose();
    _evidence.dispose();
    _note.dispose();
    super.dispose();
  }

  void _adopt(GrnView v) {
    _v = v;
    _error = null;
    final r = v.resolution;
    _choice = (r['selected'] as String?) ?? _choice ?? (v.options.firstWhere((o) => o['enabled'] == true, orElse: () => const {})['code'] as String?);
    if (r['claim_ref'] != null && _claimRef.text.isEmpty) _claimRef.text = r['claim_ref'].toString();
    if (r['claim_evidence'] != null && _evidence.text.isEmpty) _evidence.text = r['claim_evidence'].toString();
    if (r['note'] != null && _note.text.isEmpty) _note.text = r['note'].toString();
  }

  Future<void> _load({bool open = false}) async {
    try {
      GrnView v;
      if (open) {
        try {
          v = await _api.grnOpen(widget.receiptId);
        } on CatalogueApiException catch (e) {
          if (e.status != 403) rethrow; // a role that may only read opens the existing GRN
          v = await _api.grn(widget.receiptId);
        }
      } else {
        v = await _api.grn(widget.receiptId);
      }
      if (mounted) setState(() => _adopt(v));
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    }
  }

  Future<void> _do(Future<GrnView> Function() call, {String? done, void Function(GrnView v)? then}) async {
    setState(() => _busy = true);
    try {
      final v = await call();
      if (!mounted) return;
      setState(() {
        _adopt(v);
        _busy = false;
      });
      if (v.voided) {
        showToast(context, 'The receipt or invoice changed after it was resolved. Resolve the exceptions again.');
      } else {
        if (done != null) showToast(context, done);
        then?.call(v);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, _errText(e));
      if (e is CatalogueApiException && e.stale) _load();
    }
  }

  Future<void> _finish(GrnView v, bool self) async {
    setState(() => _busy = true);
    try {
      var cur = v;
      if (cur.exceptions > 0 && cur.resolution['valid'] != true) {
        final choice = _choice ?? 'accept_as_received';
        if (choice == 'accept_claim_credit' && (_claimRef.text.trim().length < 3 || _evidence.text.trim().length < 3)) {
          throw const CatalogueApiException(0, 'Enter the supplier claim reference and evidence, or accept the goods as received.', null);
        }
        // a waived difference needs a word; "as delivered" unless the person wrote one
        final note = _note.text.trim().length >= 3 ? _note.text : 'Accepted as delivered';
        cur = await _api.grnResolve(cur.receiptId, version: cur.version, resolution: choice, claimRef: _claimRef.text, evidence: _evidence.text, note: choice == 'accept_as_received' ? note : _note.text);
      }
      cur = await _api.grnRequestApproval(cur.receiptId, version: cur.version);
      if (self) cur = await _api.grnDecide(cur.receiptId, version: cur.version, approve: true);
      if (!mounted) return;
      setState(() {
        _adopt(cur);
        _busy = false;
      });
      showToast(context, self ? 'Bill matched. Stock added.' : 'Sent to the owner for approval.');
      if (self) _labelsAfterApproval(cur);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, _errText(e));
      _load();
    }
  }

  // after the voucher is matched and the lot received (founder, 26 Oct 2026): ask whether to print its labels
  void _labelsAfterApproval(GrnView v) {
    if (v.status == 'approved') offerLotLabels(context, v.receiptId);
  }

  Future<String?> _askNote(String title, String hint) => showDialog<String>(context: context, builder: (_) => _NoteDialog(title: title, hint: hint));

  // ---------------------------------------------------------------- pieces
  // Long values (24 × ₹30.00 = ₹720.00) wrap onto a second line instead of shrinking to an unreadable size.
  Widget _kv(String k, String v, {Color vc = kInk, Color kc = kMuted, double size = 14}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 5, child: Text(k, style: inter(size, 400, color: kc))),
          const SizedBox(width: 12),
          Expanded(flex: 6, child: Text(v, textAlign: TextAlign.right, style: inter(size, 700, color: vc))),
        ]),
      );

  Widget _statusChip(GrnView v) {
    final (label, bg, fg) = switch (v.status) {
      'approved' => ('Approved', kLimeSoft, kGreenText),
      'cancelled' => ('Cancelled', const Color(0xFFEEF1EA), kMuted),
      'approval_due' => ('Approval due', const Color(0xFFEEF1EA), kInk),
      _ => (v.exceptions > 0 && v.resolution['valid'] != true ? 'Review' : 'Ready', const Color(0xFFEEF1EA), kInk),
    };
    return DotChip(label, bg: bg, fg: fg, big: true);
  }

  // ---------------------------------------------------------------- the items table (founder, 26 Oct 2026)
  // One row per item: billed and received quantities, rate and amount, its GST, and a tick to mark it checked on arrival. A row opens
  // its full comparison. Under the rows: the bill's amount, GST and total, and what was received.
  static const _cols = [44.0, 44.0, 58.0, 66.0, 34.0]; // bill, rcvd, rate, amount, tick

  Widget _cell(String t, double w, {TextStyle? style, TextAlign align = TextAlign.right}) =>
      SizedBox(width: w, child: Text(t, textAlign: align, maxLines: 1, overflow: TextOverflow.ellipsis, style: style ?? inter(12.5, 600)));

  Widget _itemsTable(List<GrnRow> rows, GrnView v) {
    final bill = v.hasInvoice;
    num billed = 0, tax = 0, received = 0, receivedTax = 0;
    for (final r in rows) {
      final amount = bill ? ((r.invoice?['amount_minor'] as num?) ?? 0) : r.acceptedQty * (r.refUnitMinor ?? 0);
      billed += amount;
      tax += amount * r.gstPct / 100;
      final got = bill ? r.acceptedValueMinor : amount;
      received += got;
      receivedTax += got * r.gstPct / 100;
    }
    final head = inter(11, 700, color: kMuted);
    final ticked = rows.where((r) => _ticks.contains(r.itemId)).length;
    return OrderCardBox(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(tr('Items'), style: inter(15, 800))),
          Text('$ticked / ${rows.length} ${tr('checked')}', key: const ValueKey('check-ticked'), style: inter(12, 700, color: ticked == rows.length && rows.isNotEmpty ? kGreenText : kMuted)),
          const SizedBox(width: 6),
        ]),
        if (!bill) Padding(padding: const EdgeInsets.only(top: 2), child: Text(tr('No supplier bill yet: rates are from the order or the product cost.'), style: inter(11.5, 500, color: kWarnText))),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Text(tr('Item'), style: head)),
          _cell(tr('Bill'), _cols[0], style: head),
          _cell(tr('Rcvd'), _cols[1], style: head),
          _cell(tr('Rate'), _cols[2], style: head),
          _cell(tr('Amount'), _cols[3], style: head),
          SizedBox(width: _cols[4]),
        ]),
        const Divider(height: 14, color: Color(0xFFE3E5DF)),
        for (final r in rows) _itemRow(r, bill),
        const SizedBox(height: 4),
        if (bill) ...[
          _sum(tr('Bill amount (before GST)'), _m(billed)),
          _sum(tr('GST'), _m(tax.round())),
          _sum(tr('Bill total'), _m((billed + tax).round()), strong: true),
          const Divider(height: 14, color: Color(0xFFE3E5DF)),
          _sum(tr('Received value (with GST)'), _m((received + receivedTax).round()), strong: true, color: received < billed ? kWarnText : kInk),
        ] else ...[
          _sum(tr('Estimated value (before GST)'), _m(billed.round())),
          _sum(tr('GST'), _m(tax.round())),
          _sum(tr('Estimated total'), _m((billed + tax).round()), strong: true),
        ],
        // the supplier's bill: entered here, prefilled from the count; editable until it is sent for approval
        if (v.status == 'matching') ...[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: bill
                ? OutlineButton(tr('Edit supplier bill'), height: 44, key: const ValueKey('check-enter-bill'), onPressed: _busy ? null : () => _enterBill(v, rows))
                : DarkButton(tr('Enter supplier bill'), height: 46, key: const ValueKey('check-enter-bill'), onPressed: _busy ? null : () => _enterBill(v, rows)),
          ),
        ],
      ]),
    );
  }

  Widget _sum(String k, String v, {bool strong = false, Color color = kInk}) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 3, 6, 3),
        child: Row(children: [
          Expanded(child: Text(k, style: inter(12.5, strong ? 700 : 400, color: strong ? color : kMuted))),
          Text(v, style: inter(strong ? 14 : 12.5, strong ? 800 : 600, color: color)),
        ]),
      );

  Widget _itemRow(GrnRow r, bool bill) {
    final inv = r.invoice, rec = r.received;
    final price = invoiceUnitMinor(inv) ?? (rec?['unit_cost_minor'] as num?) ?? r.refUnitMinor ?? 0;
    final billQty = inv?['qty'] as num?, recQty = (rec?['qty'] as num?) ?? 0;
    final rejected = (rec?['rejected_qty'] as num?) ?? 0;
    // before the bill there is nothing to differ from; only damaged units are worth a word
    final differs = bill ? r.state != 'matched' : rejected > 0;
    final on = _ticks.contains(r.itemId);
    final tone = r.severity == 'red' ? kBadText : kWarnText;
    return InkWell(
      key: ValueKey('check-row-${r.itemId}'),
      onTap: () => _rowDetail(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(13, 700, height: 1.2)),
              Text([if (differs) bill ? tr(_stateText(r)) : '${qty(rejected)} ${tr('damaged')}', if (r.gstPct > 0) 'GST ${qty(r.gstPct)}%'].join(' · ').ifEmpty(tr(bill ? 'Matches' : 'Counted')),
                  maxLines: 2, style: inter(11, 500, color: differs ? tone : kMuted)),
            ]),
          ),
          _cell(billQty == null ? '—' : qty(billQty), _cols[0]),
          _cell(qty(recQty), _cols[1], style: inter(12.5, 800, color: bill && differs && billQty != recQty ? tone : kInk)),
          _cell(price == 0 ? '—' : money(price), _cols[2], style: inter(12, 500, color: kMuted)),
          _cell(inv != null ? money(inv['amount_minor'] as num) : (!bill && price > 0 ? money((r.acceptedQty * price).round()) : '—'), _cols[3], style: inter(12.5, 700, color: bill ? kInk : kMuted)),
          SizedBox(
            width: _cols[4],
            child: Center(
              child: InkWell(
                key: ValueKey('check-tick-${r.itemId}'),
                customBorder: const CircleBorder(),
                onTap: () => setState(() => on ? _ticks.remove(r.itemId) : _ticks.add(r.itemId)),
                child: Semantics(
                  checked: on,
                  label: '${r.name} received',
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: on ? const Color(0xFF22A355) : Colors.white,
                      border: Border.all(color: on ? const Color(0xFF22A355) : const Color(0xFFC9CDC4), width: 1.6),
                    ),
                    child: on ? const Icon(LucideIcons.check, size: 14, color: Colors.white) : null,
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  /// Enter (or correct) the supplier's bill: number, date, and per product the billed quantity and rate, prefilled from the count and
  /// the order price, so a bill that matches needs no typing beyond its number.
  Future<void> _enterBill(GrnView v, List<GrnRow> rows) async {
    final lines = [
      for (final r in rows)
        if (r.received != null || r.invoice != null)
          (
            r: r,
            qty: TextEditingController(text: qty((r.invoice?['qty'] as num?) ?? (r.received?['qty'] as num?) ?? 0).replaceAll(',', '')),
            rate: TextEditingController(text: (() {
              final p = invoiceUnitMinor(r.invoice) ?? r.refUnitMinor;
              return p == null ? '' : (p % 100 == 0 ? '${p ~/ 100}' : (p / 100).toStringAsFixed(2));
            })()),
          ),
    ];
    final supplier = TextEditingController(text: v.supplier), number = TextEditingController(text: v.invoiceNo);
    var date = DateTime.now();
    String? problem;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          num total = 0;
          for (final l in lines) {
            total += (num.tryParse(l.qty.text) ?? 0) * (parsePriceMinor(l.rate.text) ?? 0);
          }
          Widget box(TextEditingController c, String hint, {Key? key, bool number = false, double? width}) => SizedBox(
                width: width,
                height: 42,
                child: TextField(
                  key: key,
                  controller: c,
                  keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
                  textAlign: number ? TextAlign.right : TextAlign.start,
                  onChanged: (_) => set(() {}),
                  style: inter(14, 600),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: inter(13, 400, color: kMuted),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFDADCD5))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFDADCD5))),
                  ),
                ),
              );
          return Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(tr('Supplier bill'), style: inter(19, 800)),
                Text(tr('Check each line against the paper bill. Rates are before GST.'), style: inter(12.5, 400, color: kMuted)),
                const SizedBox(height: 12),
                box(supplier, tr('Supplier'), key: const ValueKey('bill-supplier')),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: box(number, tr('Bill no.'), key: const ValueKey('bill-number'))),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('bill-date'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42), side: const BorderSide(color: Color(0xFFDADCD5)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                    onPressed: () async {
                      final d = await showDatePicker(context: ctx, initialDate: date, firstDate: DateTime.now().subtract(const Duration(days: 365)), lastDate: DateTime.now());
                      if (d != null) set(() => date = d);
                    },
                    icon: const Icon(LucideIcons.calendar, size: 15, color: kInk),
                    label: Text(dayMonth(date), style: inter(13, 700)),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: Text(tr('Item'), style: inter(11, 700, color: kMuted))),
                  SizedBox(width: 64, child: Text(tr('Qty'), textAlign: TextAlign.right, style: inter(11, 700, color: kMuted))),
                  const SizedBox(width: 6),
                  SizedBox(width: 76, child: Text(tr('Rate ₹'), textAlign: TextAlign.right, style: inter(11, 700, color: kMuted))),
                ]),
                const SizedBox(height: 6),
                for (final l in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(children: [
                      Expanded(child: Text(l.r.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(13, 600))),
                      box(l.qty, '0', key: ValueKey('bill-qty-${l.r.itemId}'), number: true, width: 64),
                      const SizedBox(width: 6),
                      box(l.rate, '0', key: ValueKey('bill-rate-${l.r.itemId}'), number: true, width: 76),
                    ]),
                  ),
                const Divider(height: 18),
                Row(children: [
                  Expanded(child: Text(tr('Bill amount (before GST)'), style: inter(13, 600, color: kMuted))),
                  Text(_m(total.round()), key: const ValueKey('bill-total'), style: inter(15, 800)),
                ]),
                if (problem != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(tr(problem!), key: const ValueKey('bill-error'), style: inter(12.5, 600, color: kBadText))),
                const SizedBox(height: 12),
                DarkButton(tr('Save bill'), key: const ValueKey('bill-save'), onPressed: () {
                  if (supplier.text.trim().isEmpty) return set(() => problem = 'Enter the supplier name.');
                  if (number.text.trim().isEmpty) return set(() => problem = 'Enter the bill number.');
                  final bad = lines.where((l) => (num.tryParse(l.qty.text) ?? 0) > 0 && parsePriceMinor(l.rate.text) == null);
                  if (bad.isNotEmpty) return set(() => problem = 'Enter the rate for ${bad.first.r.name}.');
                  if (!lines.any((l) => (num.tryParse(l.qty.text) ?? 0) > 0)) return set(() => problem = 'Enter at least one billed quantity.');
                  Navigator.pop(ctx, true);
                }),
              ]),
            ),
          );
        },
      ),
    );
    if (saved != true || !mounted) return;
    await _do(
      () => _api.grnInvoiceSave(v.receiptId, supplier: supplier.text, invoiceNo: number.text, date: date, poRef: v.poRef, lines: [
        for (final l in lines)
          if ((num.tryParse(l.qty.text) ?? 0) > 0)
            (itemId: l.r.raw['item_id']?.toString(), name: l.r.name, qty: num.parse(l.qty.text), unitPriceMinor: parsePriceMinor(l.rate.text)!),
      ]),
      done: 'Supplier bill saved. The items are matched against it.',
    );
  }

  Future<void> _rowDetail(GrnRow r) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: kBg,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (ctx) => SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: _lineCard(r))),
      );

  Widget _lineCard(GrnRow r) {
    final inv = r.invoice, rec = r.received;
    final price = invoiceUnitMinor(inv) ?? (rec?['unit_cost_minor'] as num?) ?? 0;
    final unit = (inv?['unit'] ?? rec?['unit'] ?? 'units').toString();
    final recQty = (rec?['qty'] as num?) ?? 0, rej = (rec?['rejected_qty'] as num?) ?? 0;
    return OrderCardBox(
      radius: 24,
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(r.name, style: inter(19, 700)),
        Text(_stateText(r), style: inter(14, 400, color: r.severity == 'ok' ? kMuted : (r.severity == 'red' ? kBadText : kWarnText))),
        const SizedBox(height: 8),
        if (inv != null) _kv('Invoice / received', '${qty(inv['qty'] as num)} / ${qty(recQty)} $unit'),
        _kv('Accepted / rejected', '${qty(r.acceptedQty)} / ${qty(rej)} $unit'),
        if (inv != null) _kv('Unit cost (billed, ex tax)', _m(price)),
        if (inv != null) ...[
          const Divider(height: 22, color: Color(0xFFE3E5DF)),
          _kv('Invoice amount', '${qty(inv['qty'] as num)} × ${_m(price)} = ${_m(inv['amount_minor'] as num)}'),
          _kv('Accepted goods value', '${qty(r.acceptedQty)} × ${_m(price)} = ${_m(r.acceptedValueMinor)}'),
          if (r.claimMinor > 0) _kv('Supplier claim', '${qty(r.shortfallQty)} × ${_m(price)} = ${_m(r.claimMinor)}', vc: kBadText),
        ],
      ]),
    );
  }

  String _stateText(GrnRow r) => switch (r.state) {
        'matched' => 'Matches the invoice',
        'short' => 'Received less than invoiced',
        'over' => 'Received more than invoiced',
        'price_diff' => 'Price differs from the invoice',
        'rejected' => 'Some units were rejected',
        'missing' => 'Invoiced but not received',
        _ => 'Received but not on the invoice',
      };

  Widget _field(TextEditingController c, String hint, {bool enabled = true}) => Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFDADCD5))),
        child: TextField(controller: c, enabled: enabled, style: inter(16, 400), decoration: plainInput.copyWith(hintText: hint, hintStyle: inter(16, 400, color: kMuted))),
      );

  Widget _label(String t) => Padding(padding: const EdgeInsets.only(top: 12, bottom: 8), child: Text(t, style: inter(14, 700, color: kMuted)));

  String _optionLabel(Map<String, dynamic> o) => o['code'] == 'accept_claim_credit'
      ? 'Accept ${qty(o['accepted_units'] as num)} · Claim credit for ${qty(o['claim_units'] as num)}'
      : 'Accept ${qty(o['accepted_units'] as num)} as received';

  Widget _resolveCard(GrnView v) {
    final open = v.status == 'matching';
    final valid = v.resolution['valid'] == true;
    final claim = _choice == 'accept_claim_credit';
    final waive = _choice == 'accept_as_received' && v.claimMinor > 0;
    return OrderCardBox(
      radius: 24,
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Text(tr('Resolve exceptions'), style: inter(19, 700))), DotChip(valid ? 'Resolved' : 'Review', bg: valid ? kLimeSoft : const Color(0xFFEEF1EA), fg: valid ? kGreenText : kInk, big: true)]),
        const SizedBox(height: 10),
        Text('${v.exceptions} ${v.exceptions == 1 ? 'line differs' : 'lines differ'} from the invoice. Choose how to settle ${v.exceptions == 1 ? 'it' : 'them'} before owner approval.', style: inter(16, 400, height: 1.35)),
        _label(tr('Resolution')),
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFDADCD5))),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _choice,
              isExpanded: true,
              icon: const Icon(LucideIcons.chevronDown, size: 18),
              style: inter(16, 400),
              items: [for (final o in v.options) DropdownMenuItem(value: o['code'] as String, enabled: o['enabled'] == true, child: Text(_optionLabel(o), style: inter(16, 400, color: o['enabled'] == true ? kInk : kMuted)))],
              onChanged: open ? (c) => setState(() => _choice = c) : null,
            ),
          ),
        ),
        if (claim) ...[
          _label(tr('Supplier claim reference')),
          _field(_claimRef, 'CLM-105', enabled: open),
          _label('Evidence'),
          _field(_evidence, 'Seal inspection · 2 photos', enabled: open),
          const SizedBox(height: 6),
          Text('Claim: ${_m(v.claimMinor)} requested', style: inter(15, 600)),
        ],
        if (waive) ...[_label('Why is the claim of ${_m(v.claimMinor)} waived?'), _field(_note, 'Reason', enabled: open)],

      ]),
    );
  }

  // An invoiced line that never arrived comes back with no item and nothing accepted: nothing would be posted for it, so it is not listed.
  Widget _previewCard(GrnView v) => OrderCardBox(
        radius: 24,
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Posting preview'), style: inter(19, 700)),
          Text(tr('Only on owner approval'), style: inter(14, 400, color: kMuted)),
          const SizedBox(height: 8),
          for (final p in v.preview.where((p) => p['name'] != null)) ...[
            Text(p['name'].toString(), style: inter(15, 600)),
            if (p['stock_now'] != null) _kv('Stock', '${qty(p['stock_now'] as num)} → ${qty((p['stock_now'] as num) + (p['accepted_qty'] as num))} ${p['unit'] ?? ''}') else _kv('Added to stock', '+${qty(p['accepted_qty'] as num)} ${p['unit'] ?? ''}'),
            if (((p['rejected_qty'] as num?) ?? 0) > 0) _kv('Rejected · not posted', '${qty(p['rejected_qty'] as num)} ${p['unit'] ?? ''}'),
          ],
          if (v.preview.every((p) => p['name'] == null)) Text(tr('Nothing counted yet.'), style: inter(15, 400, color: kMuted)),
          const SizedBox(height: 6),
          Text('Rejected units stay out of stock and are claimed from the supplier. Drafts do not change posted stock.', style: inter(14, 400, color: kMuted, height: 1.35)),
        ]),
      );

  Widget _checklistCard(GrnView v) => OrderCardBox(
        radius: 24,
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Confirm Receiving & Approval', style: inter(19, 700)),
          const SizedBox(height: 8),
          for (final c in v.checklist)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 24, child: Icon(c['done'] == true ? LucideIcons.check : LucideIcons.circle, size: c['done'] == true ? 18 : 13, color: kInk)),
                const SizedBox(width: 6),
                Expanded(child: Text(_checkText(c), style: inter(16, 400))),
              ]),
            ),
        ]),
      );

  String _checkText(Map<String, dynamic> c) {
    final label = c['label'].toString();
    switch (c['key']) {
      case 'count':
        final by = (c['by'] as Map?)?['name'];
        return by == null ? label : '$label by $by';
      case 'lot':
        final lot = c['detail'], exp = c['expiry_date'];
        return lot == null ? label : '$label · $lot${exp == null ? '' : ' / $exp'}';
      case 'claim':
        return '${_m((c['claim_minor'] as num?) ?? 0)} supplier claim recorded';
      case 'approval':
        return c['done'] == true ? 'Owner approved · stock posted' : 'Owner approval pending • nothing posted';
      default:
        return label;
    }
  }

  Widget _actions(GrnView v) {
    if (v.status == 'approved') return DarkButton(tr('Approved · stock posted'), onPressed: null);
    if (v.status == 'cancelled') return const DarkButton('Receipt cancelled · nothing posted', onPressed: null);
    if (v.status == 'approval_due') {
      return Column(children: [
        if (v.can('can_approve')) DarkButton(tr('Approve and post stock'), busy: _busy, onPressed: () => _do(() => _api.grnDecide(v.receiptId, version: v.version, approve: true), done: 'Approved. Stock posted.', then: _labelsAfterApproval)) else DarkButton(tr('Waiting for owner approval'), onPressed: null),
        if (v.can('can_reject')) ...[
          const SizedBox(height: 10),
          OutlineButton(tr('Send back'), height: 52, onPressed: _busy ? null : () async {
            final note = await _askNote('Why is it sent back?', 'Reason');
            if (note != null) await _do(() => _api.grnDecide(v.receiptId, version: v.version, approve: false, note: note), done: 'Sent back to matching.');
          }),
        ],
      ]);
    }
    // one step (founder, 26 Oct 2026): settle the differences as chosen above, then the owner's tap adds the stock; anyone else's
    // match goes to the owner
    final self = v.actions['self_approve'] == true;
    return Column(children: [
      DarkButton(tr(self ? 'Match bill & add stock' : 'Send to owner for approval'), key: const ValueKey('check-finish'), busy: _busy, onPressed: v.hasInvoice && !_busy ? () => _finish(v, self) : null),
      if (!v.hasInvoice) Padding(padding: const EdgeInsets.only(top: 8), child: Text(tr('Enter the supplier bill first.'), textAlign: TextAlign.center, style: inter(14, 500, color: kWarnText))),
      if (v.decisionNote != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Sent back: ${v.decisionNote}', textAlign: TextAlign.center, style: inter(14, 500, color: kBadText))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    // every line, the differences first: the whole invoice-against-count comparison is on this one page (no separate matching screen)
    final shown = v == null ? const <GrnRow>[] : [...v.rows.where((r) => r.state != 'matched'), ...v.rows.where((r) => r.state == 'matched')];
    final matched = v?.rows.where((r) => r.state == 'matched').length ?? 0;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        // "Check delivery" (founder, 26 Oct 2026): one page per delivery, no tab strip
        OrdersTopBar(title: tr('Match bill'), onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: [
              if (_error != null && v == null)
                Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 400, color: kMuted))))
              else if (v == null)
                const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
              else ...[
                const PurchaseSteps(3),
                // the purchase card, in a green gradient (founder, 26 Oct 2026)
                Container(
                  key: const ValueKey('check-header'),
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF14532D), Color(0xFF2F8F4E)]),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(v.grnNo, style: inter(21, 800, color: Colors.white)),
                          Text([v.docNo, if (v.poRef.isNotEmpty) v.poRef, if (v.invoiceNo.isNotEmpty) v.invoiceNo].join(' / '), style: inter(14, 400, color: Colors.white70)),
                        ]),
                      ),
                      _statusChip(v),
                    ]),
                    const SizedBox(height: 8),
                    _kv('Supplier', v.supplier.isEmpty ? '—' : v.supplier, kc: Colors.white70, vc: Colors.white),
                    _kv('Approver', [v.approver['name'], if (v.approver['role'] == 'org_owner') 'Owner'].whereType<String>().join(' · ').ifEmpty('—'), kc: Colors.white70, vc: Colors.white),
                    _kv('Posting status', v.posted ? 'Posted' : 'Not posted', kc: Colors.white70, vc: Colors.white),
                  ]),
                ),
                const SizedBox(height: 12),
                OutlineButton(tr('Open the count'), height: 50, onPressed: () => HomeNav.receipt == null ? showToast(context, 'The count opens from Item → Purchase.') : HomeNav.receipt!(context, v.receiptId)),
                const SizedBox(height: 14),
                // the items are always listed; before the supplier's bill is in, the rate and amount are estimates from the order or the cost
                if (!v.hasInvoice) ...[
                  _itemsTable(shown, v),
                  const SizedBox(height: 12),
                ] else ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6, left: 4),
                    child: Text('Invoice vs counted · $matched match${v.exceptions > 0 ? ' · ${v.exceptions} ${v.exceptions == 1 ? 'differs' : 'differ'}' : ''}', key: const ValueKey('check-summary'), style: inter(14, 700, color: kMuted)),
                  ),
                  _itemsTable(shown, v),
                  const SizedBox(height: 12),
                  if (v.exceptions > 0) ...[_resolveCard(v), const SizedBox(height: 12)],
                ],
                _previewCard(v),
                const SizedBox(height: 12),
                _checklistCard(v),
                const SizedBox(height: 14),
                _actions(v),
                // after approval the goods are in stock: the optional next steps, as buttons (founder, 26 Oct 2026)
                if (v.status == 'approved') ...[
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: OutlineButton(tr('Put away'), height: 48, key: const ValueKey('check-putaway'), onPressed: () => _openStep(context, 'putaway', id: v.receiptId))),
                    const SizedBox(width: 10),
                    Expanded(child: OutlineButton(tr('Print labels'), height: 48, key: const ValueKey('check-labels'), onPressed: () => _openStep(context, 'lot_labels', id: v.receiptId))),
                  ]),
                ],
                const SizedBox(height: 12),
                Text(tr('Check against the invoice → owner approves → stock is added. Nothing changes stock before approval.'), style: inter(14, 400, color: kMuted, height: 1.4)),
              ],
            ]),
          ),
        ),
        PosBottomNav(active: 'stock', onTap: (id) => _tab(context, id, active: 'stock')),
      ]),
    );
  }
}

/// Asks for a short reason (sending a GRN back). Owns its text controller so it is disposed with the dialog, not before it.
class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.title, required this.hint});
  final String title, hint;
  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _c = TextEditingController();
  bool _empty = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: Colors.white,
        title: Text(widget.title, style: inter(18, 700)),
        content: TextField(controller: _c, autofocus: true, maxLength: 200, style: inter(16, 400), decoration: InputDecoration(hintText: widget.hint, errorText: _empty ? 'Say why it is sent back.' : null)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Cancel'), style: inter(15, 600, color: kMuted))),
          TextButton(onPressed: () {
                if (_c.text.trim().isEmpty) return setState(() => _empty = true);
                Navigator.of(context).pop(_c.text.trim());
              },
              child: Text(tr('Send back'), style: inter(15, 700, color: kBadText))),
        ],
      );
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

// ================================================================ GRN home (the side menu's GRN entry)
/// "Deliveries to check": a count of where counted deliveries stand and one card per delivery. Tapping a card opens its Check delivery
/// page (invoice against what was counted, settle differences, owner approval).
class GrnQueueScreen extends StatefulWidget {
  const GrnQueueScreen({super.key, this.api, this.onReceive});
  final CatalogueApi? api;

  /// Opens Receiving (count a delivery and send it to be checked). Null: the Stock tab.
  final void Function(BuildContext context)? onReceive;
  @override
  State<GrnQueueScreen> createState() => _GrnQueueState();
}

class _GrnQueueState extends State<GrnQueueScreen> {
  late final CatalogueApi _api = widget.api ?? CatalogueApi();
  List<GrnQueueRow>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _api.grnQueue();
      if (!mounted) return;
      setState(() {
        _rows = r;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    }
  }

  void _receive() => widget.onReceive != null ? widget.onReceive!(context) : HomeNav.go(context, HomeNav.stock, 'Stock');

  Future<void> _open(GrnQueueRow r) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => GrnDashboardScreen(receiptId: r.receiptId, api: _api)));
    if (mounted) _load();
  }

  static bool _done(GrnQueueRow r) => r.reviewStatus == 'approved' || r.reviewStatus == 'cancelled';

  String _label(GrnQueueRow r) => switch (r.reviewStatus) {
        'approved' => 'Approved',
        'cancelled' => 'Cancelled',
        'approval_due' => 'Approval due',
        'matching' => r.hasInvoice ? ((r.exceptions ?? 0) > 0 ? '${r.exceptions} to review' : 'Matches') : 'Needs invoice',
        _ => 'Not opened',
      };

  Widget _stat(String label, int n, {bool alert = false}) => Expanded(
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE3E5DF))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$n', style: inter(24, 800, color: alert && n > 0 ? kWarnText : kInk)),
            const SizedBox(height: 2),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 500, color: kMuted)),
          ]),
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Text(k, style: inter(14, 400, color: kMuted)),
          const SizedBox(width: 12),
          Expanded(child: Text(v, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 600))),
        ]),
      );

  Widget _card(GrnQueueRow r) {
    final refs = [if (r.grnNo.isNotEmpty) r.docNo, if (r.poRef.isNotEmpty) r.poRef, if (r.invoiceNo.isNotEmpty) r.invoiceNo].join(' / ');
    final approved = r.reviewStatus == 'approved';
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: () => _open(r),
      child: OrderCardBox(
        radius: 24,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.grnNo.isEmpty ? r.docNo : r.grnNo, style: inter(18, 800)),
                if (refs.isNotEmpty) Text(refs, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13, 400, color: kMuted)),
              ]),
            ),
            const SizedBox(width: 8),
            DotChip(_label(r), bg: approved ? kLimeSoft : const Color(0xFFEEF1EA), fg: approved ? kGreenText : kInk),
          ]),
          const SizedBox(height: 8),
          _kv('Supplier', r.supplier.isEmpty ? 'Not entered' : r.supplier),
          _kv('Supplier invoice', r.hasInvoice ? (r.invoiceNo.isEmpty ? 'Entered' : r.invoiceNo) : 'Not entered'),
          _kv('Posting status', approved ? 'Posted' : (r.reviewStatus == 'cancelled' ? 'Nothing posted' : 'Not posted')),
        ]),
      ),
    );
  }

  Widget _group(String title, List<GrnQueueRow> rows) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(4, 18, 4, 8), child: Text(title, style: inter(14, 700, color: kMuted))),
        for (final r in rows) Padding(padding: const EdgeInsets.only(bottom: 12), child: _card(r)),
      ]);

  Widget _empty() => OrderCardBox(
        radius: 24,
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: kLimeSoft, borderRadius: BorderRadius.circular(14)),
            child: const Icon(LucideIcons.packageCheck, size: 22, color: kGreenText),
          ),
          const SizedBox(height: 12),
          Text(tr('No deliveries to check'), style: inter(18, 700)),
          const SizedBox(height: 4),
          Text(tr('When a delivery arrives, count it in Receiving and send it to be checked. It shows up here to match against the supplier invoice.'),
              style: inter(14, 400, color: kMuted, height: 1.4)),
          const SizedBox(height: 14),
          for (final (i, step) in const ['Count the delivery in Receiving', 'Match it against the supplier invoice', 'Owner approves · stock is posted'].indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(color: Color(0xFFEEF1EA), shape: BoxShape.circle),
                  child: Text('${i + 1}', style: inter(12, 700)),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(step, style: inter(14, 500))),
              ]),
            ),
          const SizedBox(height: 6),
          DarkButton(tr('Receive stock'), onPressed: _receive),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final review = rows?.where((r) => !_done(r) && r.reviewStatus != 'approval_due').toList() ?? const <GrnQueueRow>[];
    final due = rows?.where((r) => r.reviewStatus == 'approval_due').toList() ?? const <GrnQueueRow>[];
    final done = rows?.where(_done).toList() ?? const <GrnQueueRow>[];
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        // one list, no tab strip (founder, 26 Oct 2026): each delivery opens its one Check delivery page
        OrdersTopBar(title: tr('Deliveries to check'), onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
              Text(tr('Each delivery you counted is checked against the supplier invoice, then the owner approves it.'), style: inter(13.5, 400, color: kMuted, height: 1.35)),
              const SizedBox(height: 12),
              if (_error != null && rows == null)
                Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 400, color: kMuted))))
              else if (rows == null)
                const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
              else ...[
                Row(children: [
                  _stat('To review', review.length, alert: true),
                  const SizedBox(width: 10),
                  _stat('Approval due', due.length, alert: true),
                  const SizedBox(width: 10),
                  _stat('Posted', done.length),
                ]),
                if (rows.isEmpty) ...[const SizedBox(height: 14), _empty()],
                if (review.isNotEmpty) _group('Needs review', review),
                if (due.isNotEmpty) _group('Waiting for owner approval', due),
                if (done.isNotEmpty) _group('Done in the last 30 days', done),
                if (rows.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('Drafts do not change posted stock. Stock changes only when the owner approves.', style: inter(13, 400, color: kMuted, height: 1.4)),
                ],
              ],
            ]),
          ),
        ),
        PosBottomNav(active: 'stock', onTap: (id) => _tab(context, id, active: 'stock')),
      ]),
    );
  }
}

/// The billed unit price of one product. When the invoice bills it on several lines at different prices (`price_mixed`), the database
/// sends no single price, so the average (amount / quantity) is shown; the row is a price difference either way.
num? invoiceUnitMinor(Map<String, dynamic>? inv) {
  if (inv == null) return null;
  final p = inv['unit_price_minor'] as num?;
  if (p != null) return p;
  final amount = inv['amount_minor'] as num?, q = inv['qty'] as num?;
  return amount == null || q == null || q == 0 ? null : (amount / q).round();
}

/// The optional steps after an approved delivery, Putaway ([id]: that delivery) and Shelf labels: stock pages, reached through the
/// shared hook.
void _openStep(BuildContext context, String page, {String? id}) {
  final open = HomeNav.stockPage;
  if (open == null) return showToast(context, 'This opens from Item → Stock.');
  open(context, page, itemId: id);
}
