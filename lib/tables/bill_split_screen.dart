import 'package:flutter/material.dart';

import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import 'bill_api.dart';
import 'bill_pay_screen.dart';
import 'bill_widgets.dart';
import 'table_widgets.dart';
import 'tables_api.dart';

/// "Split the bill" by how it is paid (founder, 27 Oct 2026): not per guest, but one bill paid partly by Cash, Card and UPI. The cashier
/// enters each method's amount; they must add up to what is due. It is the database's split by amount (`rst_bill_split`, one part per
/// method, carrying that method), so each part is taken through the Checkout screen and the table closes only when every part is paid.
/// A split can be changed until the first part is paid.
class BillSplitScreen extends StatefulWidget {
  const BillSplitScreen({super.key, required this.env, required this.tableId, required this.orderId, this.bill});
  final TablesEnv env;
  final String tableId, orderId;
  final BillApi? bill;
  @override
  State<BillSplitScreen> createState() => _BillSplitScreenState();
}

class _BillSplitScreenState extends State<BillSplitScreen> {
  static const _methods = [('cash', 'Cash'), ('card', 'Card'), ('upi', 'UPI')];
  late final BillApi _api = widget.bill ?? BillApi();
  Facts? _v;
  String? _error, _formError;
  bool _busy = false, _editing = false;
  final Map<String, TextEditingController> _amounts = {for (final (m, _) in _methods) m: TextEditingController()};
  String? _key; // the key of a split request that got no answer, re-sent on the next tap

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _amounts.values) {
      c.dispose();
    }
    super.dispose();
  }

  Facts? get _order {
    for (final o in _v?.l('orders') ?? const <Facts>[]) {
      if (o.s('id') == widget.orderId) return o;
    }
    return null;
  }

  Facts? get _split {
    final s = _order?.mo('split');
    return s != null && s.s('status') == 'active' ? s : null;
  }

  num get _entered => _amounts.values.fold<num>(0, (a, c) => a + (typedAmount(c.text) ?? 0));

  Future<void> _load() async {
    try {
      final v = await _api.view(widget.tableId);
      if (!mounted) return;
      setState(() {
        _v = v;
        _error = null;
        if (_split == null && _order != null) _editing = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = sayError(e));
    }
  }

  /// "Rest": this method takes whatever is still left to pay.
  void _fillRest(String method, num due) {
    final others = _amounts.entries.where((e) => e.key != method).fold<num>(0, (a, e) => a + (typedAmount(e.value.text) ?? 0));
    final rest = due - others;
    setState(() {
      _amounts[method]!.text = rest > 0 ? (rest == rest.roundToDouble() ? '${rest.toInt()}' : rest.toStringAsFixed(2)) : '';
      _formError = null;
    });
  }

  Future<void> _save() async {
    final o = _order!;
    final parts = <Map<String, Object?>>[];
    for (final (m, label) in _methods) {
      final text = _amounts[m]!.text.trim();
      if (text.isEmpty) continue;
      final a = typedAmount(text);
      if (a == null || a < 0) return setState(() => _formError = 'Enter a valid amount for $label.');
      if (a > 0) parts.add({'label': label, 'method': m, 'amount': a});
    }
    if (parts.length < 2) {
      return setState(() => _formError = 'Enter amounts for at least two of Cash, Card and UPI. Paying by one method? Use Complete Payment.');
    }
    final left = o.n('due') - _entered;
    if (left.abs() >= 0.005) {
      return setState(() => _formError = left > 0 ? '${money(left)} is still left to pay.' : 'That is ${money(-left)} more than the bill.');
    }
    setState(() {
      _busy = true;
      _formError = null;
    });
    final key = _key ??= BillApi.newKey();
    try {
      await _api.split(o.s('id'), mode: 'amount', parts: parts, key: key);
      _key = null;
      _editing = false;
      await _load();
    } on TablesApiException catch (e) {
      _key = null;
      if (mounted) setState(() => _formError = e.message);
    } catch (_) {
      if (mounted) setState(() => _formError = 'No answer from the server. Tap again to retry.');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pay(Facts part) async {
    final r = await Navigator.of(context).push<Facts>(MaterialPageRoute(builder: (_) => BillPayScreen(env: widget.env, tableId: widget.tableId, bill: _api, part: Facts({...part.raw, 'order_id': widget.orderId}))));
    if (!mounted) return;
    if (r != null) showToast(context, '${r.s('part_label')} paid ${money(r.n('amount'))}. ${money(r.n('due'))} still due.');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    final o = _order;
    final split = _split;
    final t = v?.m('table');
    final open = split?.l('parts').where((p) => p.s('status') == 'open').toList() ?? const <Facts>[];
    final paidAny = (split?.n('paid_parts') ?? 0) > 0;
    return TablesPage(
      env: widget.env,
      title: 'Split the bill',
      subtitle: t == null || o == null ? ' ' : 'Table ${t.s('label')} · ${money(o.n('due'))}',
      back: true,
      onRefresh: _load,
      children: [
        if (v == null && _error == null) tablesLoading(),
        if (_error != null) TablesError(_error!, onRetry: _load),
        if (v != null && o == null) Padding(padding: const EdgeInsets.all(24), child: Center(child: Text('This bill is already settled.', style: inter(15, 400, color: kMuted)))),
        if (v != null && o != null) ...[
          if (split != null && !_editing) ...[
            for (final p in split.l('parts')) _partCard(p),
          ] else
            _form(o),
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: kAvailBg, borderRadius: BorderRadius.circular(14)),
            child: Text('Each payment method is taken separately. The table closes when all are paid.', style: inter(14.5, 500)),
          ),
          if (_formError != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_formError!, key: const ValueKey('split-error'), style: inter(14.5, 500, color: kError))),
          if (split != null && !_editing && open.isNotEmpty)
            DarkLimeButton('Take payment · ${open.first.s('label')} ${money(open.first.n('amount'))}', key: const ValueKey('take-payment'), onPressed: () => _pay(open.first)),
          if (_editing) DarkLimeButton('Split the bill', key: const ValueKey('save-split'), busy: _busy, onPressed: v.m('can').b('split') ? _save : null),
          if (split != null && !_editing && !paidAny) ...[
            const SizedBox(height: 10),
            OutlineButtonT('Change split', height: 52, onPressed: () => setState(() => _editing = true)),
          ],
          if (!v.m('can').b('split') && _editing && v.m('unavailable').so('pay') != null)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(v.m('unavailable').s('pay'), style: inter(14, 400, color: kMuted))),
        ],
      ],
    );
  }

  Widget _partCard(Facts p) {
    final paid = p.s('status') == 'paid';
    final label = p.s('label');
    final method = p.so('paid_method') ?? p.s('method');
    return Container(
      key: ValueKey('part-${p.n('part_no')}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: paid ? kAvailBg : kResBg, borderRadius: BorderRadius.circular(12)),
          child: Text(label.isEmpty ? '·' : label[0].toUpperCase(), style: inter(17, 700, color: paid ? kAvailText : kResText)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: inter(17, 700)),
            // a split made before this change still names its guests: then say the method they pay by
            Text(
              paid
                  ? 'Paid by ${methodName(method)}'
                  : label.toLowerCase() == methodName(method).toLowerCase()
                      ? 'To be paid'
                      : 'Pays by ${methodName(method)}',
              style: inter(13.5, 400, color: paid ? kAvailText : kMuted),
            ),
          ]),
        ),
        Text(money(p.n('amount')), style: inter(18, 700)),
      ]),
    );
  }

  Widget _form(Facts o) {
    final left = o.n('due') - _entered;
    return BillCard(title: 'PAY BY', children: [
      for (final (m, label) in _methods)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            SizedBox(width: 64, child: Text(label, style: inter(15.5, 700))),
            Expanded(
              child: BillField(
                fieldKey: ValueKey('amount-$m'),
                controller: _amounts[m]!,
                hint: '₹0',
                keyboard: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() => _formError = null),
              ),
            ),
            TextButton(key: ValueKey('fill-$m'), onPressed: () => _fillRest(m, o.n('due')), child: Text('Rest', style: inter(14, 700, color: kLink))),
          ]),
        ),
      const Divider(height: 18, color: kLine),
      BillLine('Bill', money(o.n('due'))),
      BillLine(left >= 0 ? 'Left to pay' : 'Over by', money(left.abs()),
          valueKey: const ValueKey('left-to-pay'), valueColor: left.abs() < 0.005 ? kAvailText : kError),
    ]);
  }
}
