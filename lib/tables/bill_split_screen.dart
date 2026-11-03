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
///
/// It can also split per guest (founder, 3 Nov 2026), as the database always could: Equally (2 to 20 guests, the last guest takes the
/// paise left over) or By dish (every dish of the bill goes to one guest, who pays the share of the bill their dishes make up). Each guest's
/// part is then paid at Checkout by cash, card or UPI, the card or UPI with its reference number.
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
  static const _modes = [('amount', 'By payment method'), ('equal', 'Equally'), ('item', 'By dish')];
  late final BillApi _api = widget.bill ?? BillApi();
  Facts? _v;
  String? _error, _formError;
  bool _busy = false, _editing = false;
  final Map<String, TextEditingController> _amounts = {for (final (m, _) in _methods) m: TextEditingController()};
  String? _key; // the key of a split request that got no answer, re-sent on the next tap
  String _mode = 'amount';
  int _guests = 2;
  final Map<String, int> _dishGuest = {}; // order item id → guest (1-based), By dish
  String? _seeded; // the split the form was last filled from

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
      final v = await _api.view(widget.tableId, orderId: widget.orderId);
      if (!mounted) return;
      setState(() {
        _v = v;
        _error = null;
        if (_split == null && _order != null) _editing = true;
        // Change split starts from the split there is
        final s = _split;
        if (s != null && s.s('id') != _seeded && _modes.any((x) => x.$1 == s.s('mode'))) {
          _seeded = s.s('id');
          _mode = s.s('mode');
          _dishGuest.clear();
          if (_mode != 'amount') _guests = s.l('parts').length.clamp(2, 20);
          for (final p in s.l('parts')) {
            for (final id in p.raw['item_ids'] as List? ?? const []) {
              _dishGuest['$id'] = p.n('part_no').toInt();
            }
          }
        }
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

  /// By dish: one part per guest with their dishes' ids; a combo's ₹0 dishes (kept for the kitchen) go with the dish before them.
  List<Map<String, Object?>> _itemParts(Facts o) {
    final ids = <int, List<String>>{for (var g = 1; g <= _guests; g++) g: []};
    var last = 1;
    for (final i in o.l('items')) {
      final g = i.b('in_combo') ? last : _dishGuest[i.s('id')] ?? 1;
      if (!i.b('in_combo')) last = g;
      ids[g]!.add(i.s('id'));
    }
    return [for (var g = 1; g <= _guests; g++) {'label': 'Guest $g', 'item_ids': ids[g]}];
  }

  Future<void> _save() async {
    final o = _order!;
    if (_mode == 'equal') return _send('equal', guests: _guests, parts: const []);
    if (_mode == 'item') {
      final dishes = billItems(o);
      if (dishes.any((i) => (_dishGuest[i.s('id')] ?? 99) > _guests)) return setState(() => _formError = 'Choose a guest for every dish.');
      for (var g = 1; g <= _guests; g++) {
        if (!dishes.any((i) => _dishGuest[i.s('id')] == g && i.n('line_total') > 0)) return setState(() => _formError = 'Guest $g has no dish yet.');
      }
      return _send('item', parts: _itemParts(o));
    }
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
    return _send('amount', parts: parts);
  }

  Future<void> _send(String mode, {int? guests, required List<Map<String, Object?>> parts}) async {
    setState(() {
      _busy = true;
      _formError = null;
    });
    final key = _key ??= BillApi.newKey();
    try {
      await _api.split(_order!.s('id'), mode: mode, guests: guests, parts: parts, key: key);
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
    final place = billPlace(v);
    final open = split?.l('parts').where((p) => p.s('status') == 'open').toList() ?? const <Facts>[];
    final paidAny = (split?.n('paid_parts') ?? 0) > 0;
    return TablesPage(
      env: widget.env,
      title: 'Split the bill',
      subtitle: place == null || o == null ? ' ' : '$place · ${money(o.n('due'))}',
      back: true,
      onRefresh: _load,
      children: [
        if (v == null && _error == null) tablesLoading(),
        if (_error != null) TablesError(_error!, onRetry: _load),
        if (v != null && o == null) Padding(padding: const EdgeInsets.all(24), child: Center(child: Text('This bill is already settled.', style: inter(15, 400, color: kMuted)))),
        if (v != null && o != null) ...[
          if (split != null && !_editing) ...[
            for (final p in split.l('parts')) _partCard(p, o, split.s('mode')),
          ] else ...[
            _modePicker(),
            if (_mode == 'equal') _equalForm(o) else if (_mode == 'item') _dishForm(o) else _form(o),
          ],
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: kAvailBg, borderRadius: BorderRadius.circular(14)),
            child: Text(
              (split != null && !_editing ? split.s('mode') : _mode) == 'amount'
                  ? 'Each payment method is taken separately. The table closes when all are paid.'
                  : 'Each guest pays at Checkout by cash, card or UPI. The table closes when every guest has paid.',
              style: inter(14.5, 500),
            ),
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

  Widget _partCard(Facts p, Facts o, String mode) {
    final paid = p.s('status') == 'paid';
    final label = p.s('label');
    final method = p.so('paid_method') ?? p.s('method');
    final ids = {for (final x in p.raw['item_ids'] as List? ?? const []) '$x'};
    final dishes = [for (final i in billItems(o)) if (ids.contains(i.s('id'))) _dishName(i)];
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
                  : mode == 'item' && dishes.isNotEmpty
                      ? dishes.join(', ')
                      : mode != 'amount' || label.toLowerCase() == methodName(method).toLowerCase()
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

  static String _dishName(Facts i) => '${i.n('qty') > 1 ? '${i.n('qty').toInt()} × ' : ''}${i.s('name')}';

  Widget _chip(String key, String label, bool on, VoidCallback tap) => ChoiceChip(
        key: ValueKey(key),
        label: Text(label, style: inter(13, 700, color: on ? kLimeBtn : kInk)),
        selected: on,
        showCheckmark: false,
        selectedColor: kInk,
        backgroundColor: Colors.white,
        onSelected: (_) => setState(() {
          tap();
          _formError = null;
        }),
      );

  Widget _modePicker() => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (k, label) in _modes) _chip('split-mode-$k', label, _mode == k, () => _mode = k),
        ]),
      );

  Widget _guestStepper() => Row(children: [
        Expanded(child: Text('Guests', style: inter(15.5, 700))),
        IconButton(
          key: const ValueKey('guests-minus'),
          onPressed: _guests > 2 ? () => setState(() => _guests--) : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        SizedBox(width: 32, child: Text('$_guests', key: const ValueKey('guests-count'), textAlign: TextAlign.center, style: inter(18, 700))),
        IconButton(
          key: const ValueKey('guests-plus'),
          onPressed: _guests < 20 ? () => setState(() => _guests++) : null,
          icon: const Icon(Icons.add_circle_outline),
        ),
      ]);

  /// Equally: what each guest pays, to the paisa; the last guest takes the paise left over (as the database does).
  Widget _equalForm(Facts o) {
    final due = o.n('due');
    final each = (due * 100 / _guests).floor() / 100;
    final last = ((due - each * (_guests - 1)) * 100).round() / 100;
    return BillCard(title: 'SPLIT EQUALLY', children: [
      _guestStepper(),
      const Divider(height: 18, color: kLine),
      BillLine('Bill', money(due)),
      BillLine(each == last ? 'Each guest pays' : 'Guests 1–${_guests - 1} pay', money(each), valueKey: const ValueKey('equal-each'), bold: true),
      if (each != last) BillLine('Guest $_guests pays', money(last), valueKey: const ValueKey('equal-last')),
    ]);
  }

  /// By dish: each dish goes to one guest, who pays the share of the bill their dishes make up (the database works it out to the paisa).
  Widget _dishForm(Facts o) {
    final dishes = billItems(o);
    final gross = dishes.fold<num>(0, (a, i) => a + i.n('line_total'));
    num share(int g) => gross <= 0
        ? 0
        : (o.n('due') * dishes.where((i) => _dishGuest[i.s('id')] == g).fold<num>(0, (a, i) => a + i.n('line_total')) / gross * 100).round() / 100;
    return BillCard(title: 'SPLIT BY DISH', children: [
      _guestStepper(),
      const Divider(height: 18, color: kLine),
      for (final (n, i) in dishes.indexed)
        Padding(
          key: ValueKey('dish-$n'),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(_dishName(i), style: inter(15, 600))),
              Text(money(i.n('line_total')), style: inter(14.5, 500, color: kMuted)),
            ]),
            const SizedBox(height: 4),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (var g = 1; g <= _guests; g++) _chip('dish-$n-guest-$g', 'Guest $g', _dishGuest[i.s('id')] == g, () => _dishGuest[i.s('id')] = g),
            ]),
          ]),
        ),
      const Divider(height: 18, color: kLine),
      for (var g = 1; g <= _guests; g++) BillLine('Guest $g pays', money(share(g)), valueKey: ValueKey('guest-share-$g')),
    ]);
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
