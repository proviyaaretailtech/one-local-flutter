import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart';
import '../inventory/inv_env.dart';
import '../inventory/inventory_widgets.dart';
import '../ui/theme.dart';
import 'po_grn_screen.dart';
import 'purchasing_api.dart';
import 'purchasing_widgets.dart';
import 'supplier_price_screen.dart';
import '../ui/i18n.dart';
import '../ui/purchase_steps.dart';

/// One item on the order being built. Only ids, quantities and prices in paise go to the server, which checks every one again.
class PoDraftLine {
  PoDraftLine({required this.itemId, required this.name, required this.unit, required this.qty, required this.unitCostMinor, this.gstPct = 0, this.priceId});
  final String itemId, name, unit;
  final String? priceId;
  num qty;
  int unitCostMinor;
  num gstPct;

  int get totalMinor => (qty * unitCostMinor).round();
  Map<String, Object?> toJson() => {'inventory_item_id': itemId, 'qty': qty, 'unit_cost_minor': unitCostMinor, 'gst_pct': gstPct};
}

/// A new purchase order (Figma "Restaurant Purchase", used by every business): supplier, the items to buy with their prices, the estimated total (before GST) and "Create purchase order".
class PoCreateScreen extends StatefulWidget {
  const PoCreateScreen({super.key, required this.env});
  final PurEnv env;
  @override
  State<PoCreateScreen> createState() => _PoCreateScreenState();
}

class _PoCreateScreenState extends State<PoCreateScreen> {
  PurEnv get env => widget.env;
  Facts? _o;
  String? _error;
  String? _supplierId;
  final _lines = <PoDraftLine>[];
  bool _busy = false;
  late String _key = PurchasingApi.newKey();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final o = await env.api.options();
      if (!mounted) return;
      setState(() {
        _o = o;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  int get _estimate => _lines.fold(0, (a, l) => a + l.totalMinor);

  String? _supplierName(Facts o) {
    for (final s in o.l('suppliers')) {
      if (s.s('id') == _supplierId) return s.s('name');
    }
    return null;
  }

  Facts? _price(Facts o, String itemId) {
    for (final p in o.l('prices')) {
      if (p.s('supplier_id') == _supplierId && p.s('material_id') == itemId) return p;
    }
    return null;
  }

  Future<void> _pickSupplier(Facts o) async {
    final id = await pickOne<String>(context, 'Supplier', [for (final s in o.l('suppliers')) (s.s('id'), s.s('name'), s.s('payment_terms'))], current: _supplierId);
    if (id != null && id != _supplierId) setState(() => _supplierId = id);
  }

  Future<void> _addItem(Facts o) async {
    final taken = _lines.map((l) => l.itemId).toSet();
    final items = o.l('items').where((i) => !taken.contains(i.s('id'))).toList();
    final id = await pickOne<String>(context, 'Add item', [for (final i in items) (i.s('id'), i.s('name'), unitWord(i.s('unit')))]);
    if (id == null || !mounted) return;
    final item = items.firstWhere((i) => i.s('id') == id);
    final known = _price(o, id);
    final line = await _lineSheet(item, known?.n('price_minor').toInt() ?? 0, known?.so('price_id'));
    if (line != null) setState(() => _lines.add(line));
  }

  Future<PoDraftLine?> _lineSheet(Facts item, int priceMinor, String? priceId) {
    final qtyC = TextEditingController();
    final priceC = TextEditingController(text: priceMinor > 0 ? (priceMinor / 100).toString().replaceFirst(RegExp(r'\.0$'), '') : '');
    return showModalBottomSheet<PoDraftLine>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(item.s('name'), style: inter(18, 700)),
          InvLabel('Quantity (${unitWord(item.s('unit'))})'),
          InvInput(controller: qtyC, number: true, hint: '0'),
          InvLabel('Price per ${item.s('unit')} (₹)'),
          InvInput(controller: priceC, number: true, hint: '0'),
          // no GST here (founder, 26 Oct 2026): the tax is taken from the supplier's bill and the product when goods are matched
          const SizedBox(height: 12),
          InvPrimary(tr('Add to order'), onPressed: () {
            final q = num.tryParse(qtyC.text.trim()), p = num.tryParse(priceC.text.trim());
            if (q == null || q <= 0 || p == null || p < 0) {
              showToast(ctx, 'Enter a quantity above zero and a price.');
              return;
            }
            Navigator.pop(ctx, PoDraftLine(itemId: item.s('id'), name: item.s('name'), unit: item.s('unit'), qty: q, unitCostMinor: (p * 100).round(), priceId: priceId));
          }),
        ]),
      ),
    );
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      var po = await env.api.create(supplierId: _supplierId!, lines: _lines.map((l) => l.toJson()).toList(), key: _key);
      _key = PurchasingApi.newKey();
      // Someone who may approve it (the owner, a business manager) does not ask themselves: it is approved straight away. Anyone
      // else's order, or one above the owner's own limit, waits for an approver (the server decides who may).
      var approved = false;
      if (po.can('approve')) {
        try {
          po = await env.api.act(po.id, 'approve');
          approved = true;
        } catch (_) {}
      }
      if (!mounted) return;
      showToast(context, approved ? '${po.number} placed. Receive it when the goods come.' : '${po.number} placed. It waits for the owner\'s approval.');
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => PoGrnScreen(env: env, orderId: po.id)));
    } catch (e) {
      if (mounted) showToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => InvScaffold(env: env.inv, onRefresh: _load, children: [
        const PurchaseSteps(1),
        InvTitle(tr('New purchase order')),
        InvLoad<Facts>(data: _o, error: _error, onRetry: _load, builder: _body),
      ]);

  List<Widget> _body(Facts o) {
    final open = o.n('open_count').toInt();
    final name = _supplierName(o);
    final canRecord = o.b('can_record');
    return [
      Padding(padding: const EdgeInsets.only(bottom: 10), child: Align(alignment: Alignment.centerLeft, child: PoChip('$open open ${open == 1 ? 'order' : 'orders'} already', bg: kMintBg, fg: kPostedText))),
      InvLabel(tr('SUPPLIER')),
      InvPickBox(value: name ?? 'Choose a supplier', semantic: 'Supplier', onTap: canRecord ? () => _pickSupplier(o) : null),
      const SizedBox(height: 10),
      InvCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Purchase items'), style: inter(20, 700)),
          const SizedBox(height: 8),
          if (_lines.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text(tr('No items yet.'), style: inter(14.5, 400, color: kMuted))),
          for (var i = 0; i < _lines.length; i++) ...[
            if (i > 0) const Divider(height: 18, color: kCardLine),
            _lineRow(_lines[i], i),
          ],
          if (canRecord) Padding(padding: const EdgeInsets.only(top: 8), child: InvSecondary(tr('Add item'), onPressed: _supplierId == null ? () => showToast(context, 'Choose a supplier first.') : () => _addItem(o))),
        ]),
      ),
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
        decoration: BoxDecoration(color: const Color(0xFFE8F5DC), borderRadius: BorderRadius.circular(22)),
        child: Row(children: [
          Expanded(child: Text(tr('Estimated total'), style: inter(17, 600))),
          Text(money(_estimate), style: inter(28, 700, color: kPostedText)),
        ]),
      ),
      InvPrimary(tr('Place order'), key: const ValueKey('po-place'), busy: _busy, onPressed: (!canRecord || _supplierId == null || _lines.isEmpty) ? null : _create),
      if (!canRecord) InvNote(tr('Your role can look at purchase orders but not create them.')),
    ];
  }

  Widget _lineRow(PoDraftLine l, int i) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: InkWell(
            onTap: l.priceId == null ? null : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SupplierPriceScreen(env: env, priceId: l.priceId!))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.name, style: inter(18, 600)),
              const SizedBox(height: 3),
              Text('${qty1(l.qty).replaceFirst(RegExp(r'\.0$'), '')} ${l.unit == 'unit' ? 'units' : l.unit} · ${money(l.unitCostMinor)}/${l.unit}', style: inter(14.5, 400, color: kMuted)),
            ]),
          ),
        ),
        Text(money(l.totalMinor), style: inter(18, 700)),
        Semantics(
          button: true,
          label: 'Remove ${l.name}',
          child: IconButton(visualDensity: VisualDensity.compact, icon: const Icon(LucideIcons.x, size: 16, color: kMuted), onPressed: () => setState(() => _lines.removeAt(i))),
        ),
      ]);
}
