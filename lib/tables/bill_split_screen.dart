import 'package:flutter/material.dart';

import '../inventory/inventory_api.dart';
import '../inventory/inventory_widgets.dart' show kNavyH, qty;
import '../ui/theme.dart';
import 'bill_api.dart';
import 'bill_pay_screen.dart';
import 'bill_widgets.dart';
import 'table_widgets.dart';
import 'tables_api.dart';

/// Figma Journey 5 "Split the bill" (node 18:710), step 2: Equal, By item or By amount; one part per guest, each with its own payment
/// method. The database works out each guest's amount (`rst_bill_split`: to the paisa, GST and discount follow the items) and keeps the plan;
/// each part is paid separately through the Checkout screen; the table closes only when every part is paid. A plan can be changed until
/// the first guest pays.
class BillSplitScreen extends StatefulWidget {
  const BillSplitScreen({super.key, required this.env, required this.tableId, required this.orderId, this.bill});
  final TablesEnv env;
  final String tableId, orderId;
  final BillApi? bill;
  @override
  State<BillSplitScreen> createState() => _BillSplitScreenState();
}

class _BillSplitScreenState extends State<BillSplitScreen> {
  late final BillApi _api = widget.bill ?? BillApi();
  Facts? _v;
  String? _error, _formError;
  bool _busy = false, _editing = false;
  String _mode = 'equal';
  int _guests = 2;
  final List<String> _methods = ['cash', 'cash'];
  final Map<String, int> _itemGuest = {}; // order item id -> guest index (0-based)
  final List<TextEditingController> _amounts = [TextEditingController(), TextEditingController()];
  String? _key; // the key of a split request that got no answer, re-sent on the next tap

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _amounts) {
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

  void _setGuests(int n) {
    if (n < 2 || n > 20) return;
    setState(() {
      _guests = n;
      while (_methods.length < n) {
        _methods.add('cash');
      }
      while (_amounts.length < n) {
        _amounts.add(TextEditingController());
      }
      _itemGuest.updateAll((_, g) => g >= n ? n - 1 : g);
      _formError = null;
    });
  }

  Future<void> _save() async {
    final o = _order!;
    final parts = <Map<String, Object?>>[];
    for (var g = 0; g < _guests; g++) {
      final p = <String, Object?>{'label': 'Guest ${g + 1}', 'method': _methods[g]};
      if (_mode == 'amount') {
        final a = typedAmount(_amounts[g].text);
        if (a == null || a <= 0) return setState(() => _formError = 'Enter an amount for Guest ${g + 1}.');
        p['amount'] = a;
      }
      if (_mode == 'item') {
        final ids = [for (final i in o.l('items')) if ((_itemGuest[i.s('id')] ?? 0) == g) i.s('id')];
        if (ids.isEmpty) return setState(() => _formError = 'Give Guest ${g + 1} at least one item.');
        p['item_ids'] = ids;
      }
      parts.add(p);
    }
    setState(() {
      _busy = true;
      _formError = null;
    });
    final key = _key ??= BillApi.newKey();
    try {
      await _api.split(o.s('id'), mode: _mode, guests: _mode == 'equal' ? _guests : null, parts: parts, key: key);
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
          _modes(split != null && !_editing ? split.s('mode') : _mode, enabled: _editing),
          const SizedBox(height: 14),
          if (split != null && !_editing) ...[
            for (final p in split.l('parts')) _partCard(p),
          ] else
            ..._form(o),
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: kAvailBg, borderRadius: BorderRadius.circular(14)),
            child: Text('Each part is paid separately. The table closes when all parts are paid.', style: inter(14.5, 500)),
          ),
          if (_formError != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_formError!, key: const ValueKey('split-error'), style: inter(14.5, 500, color: kError))),
          if (split != null && !_editing && open.isNotEmpty)
            DarkLimeButton('Take payment · ${open.first.s('label')}', key: const ValueKey('take-payment'), onPressed: () => _pay(open.first)),
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

  Widget _modes(String mode, {required bool enabled}) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: const Color(0xFFF0F1EE), borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          for (final (m, label) in const [('equal', 'Equal'), ('item', 'By item'), ('amount', 'By amount')])
            Expanded(
              child: Semantics(
                button: true,
                selected: m == mode,
                child: InkWell(
                  key: ValueKey('mode-$m'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: enabled ? () => setState(() => _mode = m) : null,
                  child: Container(
                    height: 42,
                    alignment: Alignment.center,
                    decoration: m == mode ? BoxDecoration(color: kNavyH, borderRadius: BorderRadius.circular(10)) : null,
                    child: Text(label, style: inter(14.5, 600, color: m == mode ? Colors.white : kInk)),
                  ),
                ),
              ),
            ),
        ]),
      );

  Widget _partCard(Facts p) {
    final paid = p.s('status') == 'paid';
    final label = p.s('label');
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
          child: Text(label.isEmpty ? 'G' : label[0].toUpperCase(), style: inter(17, 700, color: paid ? kAvailText : kResText)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: inter(17, 700)),
            Text(paid ? 'Paid by ${methodName(p.so('paid_method') ?? p.s('method'))}' : 'Pays by ${methodName(p.s('method'))}', style: inter(13.5, 400, color: paid ? kAvailText : kMuted)),
          ]),
        ),
        Text(money(p.n('amount')), style: inter(18, 700)),
      ]),
    );
  }

  List<Widget> _form(Facts o) => [
        Row(children: [
          Expanded(child: Text('Guests', style: inter(16, 600))),
          IconButton(key: const ValueKey('guests-minus'), onPressed: () => _setGuests(_guests - 1), icon: const Icon(Icons.remove_circle_outline)),
          Text('$_guests', key: const ValueKey('guests-count'), style: inter(18, 700)),
          IconButton(key: const ValueKey('guests-plus'), onPressed: () => _setGuests(_guests + 1), icon: const Icon(Icons.add_circle_outline)),
        ]),
        if (_mode == 'item')
          BillCard(title: 'WHO HAD WHAT', children: [
            for (final i in o.l('items')) ...[
              BillLine('${qty(i.n('qty'))} × ${i.s('name')}', money(i.n('line_total'))),
              ChoiceRow(
                keyPrefix: 'item-${i.s('id')}',
                options: [for (var g = 0; g < _guests; g++) ('$g', 'Guest ${g + 1}')],
                selected: '${_itemGuest[i.s('id')] ?? 0}',
                onSelect: (g) => setState(() => _itemGuest[i.s('id')] = int.parse(g)),
              ),
              const SizedBox(height: 10),
            ],
          ]),
        BillCard(title: 'EACH GUEST PAYS BY', children: [
          for (var g = 0; g < _guests; g++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Guest ${g + 1}', style: inter(15.5, 700)),
                const SizedBox(height: 6),
                if (_mode == 'amount') ...[
                  BillField(fieldKey: ValueKey('amount-$g'), controller: _amounts[g], hint: 'Amount', keyboard: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() {})),
                  const SizedBox(height: 6),
                ],
                ChoiceRow(
                  keyPrefix: 'guest-$g-method',
                  options: const [('cash', 'Cash'), ('card', 'Card'), ('upi', 'UPI')],
                  selected: _methods[g],
                  onSelect: (m) => setState(() => _methods[g] = m),
                ),
              ]),
            ),
          if (_mode == 'amount') ...[
            const Divider(height: 18, color: kLine),
            BillLine('Left to share', money(o.n('due') - [for (var g = 0; g < _guests; g++) typedAmount(_amounts[g].text) ?? 0].fold<num>(0, (a, b) => a + b)),
                valueKey: const ValueKey('left-to-share')),
          ],
          if (_mode == 'equal') Padding(padding: const EdgeInsets.only(top: 6), child: Text('The bill is shared equally; the last guest takes any paise left over.', style: inter(13, 400, color: kMuted))),
        ]),
      ];
}
