import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/net_guard.dart';
import '../inventory/inventory_api.dart';
import '../inventory/inv_env.dart';
import '../inventory/inventory_widgets.dart';
import '../stock/stock_env.dart' show OrderWant;
import '../ui/theme.dart';
import 'purchasing_api.dart';
import 'purchasing_widgets.dart';
import 'simple_purchase.dart' show chooseSupplier, scanForPurchase;
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

/// A new purchase order (Figma "Restaurant Purchase", used by every business): supplier, the items to buy with their prices, the estimated total (before GST) and "Generate PO" (live at once, no approval).
class PoCreateScreen extends StatefulWidget {
  const PoCreateScreen({super.key, required this.env, this.want = const []});
  final PurEnv env;

  /// Items to put on the order straight away (from Reorder or Purchase's "Need to order"): the supplier who has prices for most of
  /// them is chosen, and each line takes that supplier's price.
  final List<OrderWant> want;
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
        if (_lines.isEmpty && widget.want.isNotEmpty) _fill(o);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = errorSentence(e));
    }
  }

  void _fill(Facts o) {
    final ids = {for (final w in widget.want) w.itemId};
    final count = <String, int>{};
    for (final p in o.l('prices')) {
      if (ids.contains(p.s('material_id'))) count[p.s('supplier_id')] = (count[p.s('supplier_id')] ?? 0) + 1;
    }
    if (count.isNotEmpty) _supplierId = (count.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    for (final w in widget.want) {
      final p = _price(o, w.itemId);
      _lines.add(PoDraftLine(itemId: w.itemId, name: w.name, unit: w.unit.isEmpty ? 'unit' : w.unit, qty: w.qty, unitCostMinor: p?.n('price_minor').toInt() ?? 0, priceId: p?.so('price_id')));
    }
  }

  /// A new supplier: lines without a price take this supplier's.
  void _repriceLines(Facts o) {
    for (final (i, l) in _lines.indexed) {
      final p = _price(o, l.itemId);
      if (p != null && (l.unitCostMinor == 0 || l.priceId != null)) {
        _lines[i] = PoDraftLine(itemId: l.itemId, name: l.name, unit: l.unit, qty: l.qty, unitCostMinor: p.n('price_minor').toInt(), gstPct: l.gstPct, priceId: p.so('price_id'));
      }
    }
  }

  /// A line on the order: change its quantity or price.
  Future<void> _editLine(int i) async {
    final l = _lines[i];
    final line = await _lineSheet(Facts({'id': l.itemId, 'name': l.name, 'unit': l.unit}), l.unitCostMinor, l.priceId, qty: l.qty);
    if (line != null && mounted) setState(() => _lines[i] = line);
  }

  int get _estimate => _lines.fold(0, (a, l) => a + l.totalMinor);

  String? _supplierName(Facts o) {
    for (final s in o.l('suppliers')) {
      if (s.s('id') == _supplierId) return s.s('name');
    }
    return _supplierLabel;
  }

  /// The name of a supplier just added from contacts, until the reload knows them.
  String? _supplierLabel;

  Facts? _price(Facts o, String itemId) {
    for (final p in o.l('prices')) {
      if (p.s('supplier_id') == _supplierId && p.s('material_id') == itemId) return p;
    }
    return null;
  }

  /// The supplier (founder, 29 Oct 2026): the same sheet as Received, with your suppliers and "Add from phone contacts"; a contact
  /// picked there is saved as a supplier, then the order screen reloads to know them and their prices.
  Future<void> _pickSupplier(Facts o) async {
    final s = await chooseSupplier(context, env.api, subtitle: 'Who are you ordering from?');
    if (s == null || !mounted || s.s('id').isEmpty || s.s('id') == _supplierId) return;
    setState(() {
      _supplierId = s.s('id');
      _supplierLabel = s.s('name');
      _repriceLines(o);
    });
    if (!o.l('suppliers').any((x) => x.s('id') == _supplierId)) await _load(); // a new one, from contacts
  }

  /// A line for [item]: one more if it is on the order already, else 1 at the supplier's price (0: "tap to add the price").
  void _addOne(Facts o, Facts item) {
    final i = _lines.indexWhere((l) => l.itemId == item.s('id'));
    if (i >= 0) {
      _lines[i].qty += 1;
      return;
    }
    final known = _price(o, item.s('id'));
    _lines.add(PoDraftLine(
      itemId: item.s('id'),
      name: item.s('name'),
      unit: item.s('unit').isEmpty ? 'unit' : item.s('unit'),
      qty: 1,
      unitCostMinor: known?.n('price_minor').toInt() ?? 0,
      priceId: known?.so('price_id'),
    ));
  }

  /// Items from your list (founder, 29 Oct 2026): tick as many as you need; each comes in at 1, tap a line to change it.
  Future<void> _addItem(Facts o) async {
    final picked = await showModalBottomSheet<List<Facts>>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _ItemPicker(
        items: o.l('items'),
        onOrder: {for (final l in _lines) l.itemId},
        priceOf: (id) => _price(o, id)?.n('price_minor').toInt(),
        scan: () => _scanned(o),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() {
      for (final item in picked) {
        _addOne(o, item);
      }
    });
  }

  /// Scans a barcode and finds the item it belongs to; null (with a toast) when none does.
  Future<Facts?> _scanned(Facts o) async {
    final code = await scanForPurchase(context);
    if (code == null || code.trim().isEmpty || !mounted) return null;
    try {
      final found = await env.api.findItems(code.trim());
      final item = found.where((i) => i.s('barcode') == code.trim() || i.s('sku').toLowerCase() == code.trim().toLowerCase()).firstOrNull;
      if (item == null && mounted) showToast(context, '${tr('No item has barcode')} ${code.trim()}. ${tr('Add it in Items first.')}');
      return item;
    } catch (e) {
      if (mounted) showToast(context, e.toString());
      return null;
    }
  }

  /// Scan straight onto the order: each scan adds one.
  Future<void> _scanToOrder(Facts o) async {
    final item = await _scanned(o);
    if (item == null || !mounted) return;
    setState(() => _addOne(o, item));
    showToast(context, '${item.s('name')} ${tr('added')}.');
  }

  Future<PoDraftLine?> _lineSheet(Facts item, int priceMinor, String? priceId, {num? qty}) {
    final qtyC = TextEditingController(text: qty == null ? '' : qty1(qty).replaceFirst(RegExp(r'\.0$'), ''));
    final priceC = TextEditingController(text: priceMinor > 0 ? (priceMinor / 100).toString().replaceFirst(RegExp(r'\.0$'), '') : '');
    return showModalBottomSheet<PoDraftLine>(
      context: context,
      useRootNavigator: true,
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
          InvPrimary(tr(qty == null ? 'Add to order' : 'Update'), key: const ValueKey('po-line-save'), onPressed: () {
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
      // one step (founder, 28 Oct 2026): the order is live at once, no approval; back to the list, where it waits with its day counter
      final po = await env.api.create(supplierId: _supplierId!, lines: _lines.map((l) => l.toJson()).toList(), key: _key);
      _key = PurchasingApi.newKey();
      if (!mounted) return;
      showToast(context, '${po.number} ${tr('generated')}. ${tr('Mark it Received when the goods come.')}');
      Navigator.of(context).maybePop(po);
    } catch (e) {
      if (mounted) showToast(context, errorSentence(e));
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
          if (canRecord)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                Expanded(
                  child: InvSecondary(tr('Add items'), key: const ValueKey('po-add-items'), onPressed: _supplierId == null ? () => showToast(context, 'Choose a supplier first.') : () => _addItem(o)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: InvSecondary(tr('Scan barcode'), key: const ValueKey('po-scan'), onPressed: _supplierId == null ? () => showToast(context, 'Choose a supplier first.') : () => _scanToOrder(o)),
                ),
              ]),
            ),
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
      InvPrimary(tr('Generate PO'), key: const ValueKey('po-place'), busy: _busy, onPressed: (!canRecord || _supplierId == null || _lines.isEmpty) ? null : _create),
      if (!canRecord) InvNote(tr('Your role can look at purchase orders but not create them.')),
    ];
  }

  Widget _lineRow(PoDraftLine l, int i) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: InkWell(
            key: ValueKey('po-line-${l.itemId}'),
            onTap: () => _editLine(i),
            onLongPress: l.priceId == null ? null : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SupplierPriceScreen(env: env, priceId: l.priceId!))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.name, style: inter(18, 600)),
              const SizedBox(height: 3),
              Text(
                l.unitCostMinor == 0
                    ? '${qty1(l.qty).replaceFirst(RegExp(r'\.0$'), '')} ${l.unit == 'unit' ? 'units' : l.unit} · ${tr('tap to add the price')}'
                    : '${qty1(l.qty).replaceFirst(RegExp(r'\.0$'), '')} ${l.unit == 'unit' ? 'units' : l.unit} · ${money(l.unitCostMinor)}/${l.unit}',
                style: inter(14.5, 400, color: l.unitCostMinor == 0 ? kAmberText : kMuted),
              ),
            ]),
          ),
        ),
        Text(money(l.totalMinor), style: inter(18, 700)),
        Semantics(
          button: true,
          label: 'Remove ${l.name}',
          child: IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(LucideIcons.x, size: 16, color: kMuted),
            onPressed: () {
              final gone = _lines[i];
              setState(() => _lines.removeAt(i));
              // the dark pill with Undo (lib/ui/motion.dart's toast), instead of asking first
              showToast(context, '${gone.name} ${tr('removed')}', actionLabel: tr('Undo'), onAction: () {
                if (mounted) setState(() => _lines.insert(i.clamp(0, _lines.length), gone));
              });
            },
          ),
        ),
      ]);
}

/// Your items to tick for the order (founder, 29 Oct 2026): search by name or code, scan a barcode to tick one, the supplier's last
/// price beside each, and "Add N items". Items already on the order are marked.
class _ItemPicker extends StatefulWidget {
  const _ItemPicker({required this.items, required this.onOrder, required this.priceOf, required this.scan});
  final List<Facts> items;
  final Set<String> onOrder;
  final int? Function(String itemId) priceOf;
  final Future<Facts?> Function() scan;
  @override
  State<_ItemPicker> createState() => _ItemPickerState();
}

class _ItemPickerState extends State<_ItemPicker> {
  final _q = TextEditingController();
  final _picked = <String, Facts>{};

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  void _toggle(Facts i) => setState(() => _picked.containsKey(i.s('id')) ? _picked.remove(i.s('id')) : _picked[i.s('id')] = i);

  Future<void> _scan() async {
    final item = await widget.scan();
    if (item == null || !mounted) return;
    setState(() => _picked[item.s('id')] = widget.items.where((i) => i.s('id') == item.s('id')).firstOrNull ?? item);
    showToast(context, '${item.s('name')} ${tr('ticked')}.');
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.text.trim().toLowerCase();
    final list = widget.items.where((i) => q.isEmpty || i.s('name').toLowerCase().contains(q) || i.s('sku').toLowerCase().contains(q)).toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.88),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: Container(margin: const EdgeInsets.only(top: 10), width: 40, height: 4, decoration: BoxDecoration(color: kCardLine, borderRadius: BorderRadius.circular(99)))),
          Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 10), child: Text(tr('Add items'), style: inter(19, 800))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('po-item-search'),
                  controller: _q,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: tr('Search your items'),
                    prefixIcon: const Icon(LucideIcons.search, size: 18, color: kMuted),
                    filled: true,
                    fillColor: Colors.white,
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kCardLine)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kCardLine)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: kInk,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  key: const ValueKey('po-item-scan'),
                  borderRadius: BorderRadius.circular(14),
                  onTap: _scan,
                  child: const SizedBox(width: 48, height: 48, child: Icon(LucideIcons.scanBarcode, color: Color(0xFFD2F64B))),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: list.isEmpty
                ? Padding(padding: const EdgeInsets.all(24), child: Text(tr(widget.items.isEmpty ? 'No items yet. Add them in Items.' : 'No item matches.'), textAlign: TextAlign.center, style: inter(14, 500, color: kMuted)))
                : ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    itemCount: list.length,
                    itemBuilder: (_, k) {
                      final i = list[k];
                      final on = _picked.containsKey(i.s('id'));
                      final price = widget.priceOf(i.s('id'));
                      final already = widget.onOrder.contains(i.s('id'));
                      return InkWell(
                        key: ValueKey('po-pick-${i.s('id')}'),
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _toggle(i),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                          child: Row(children: [
                            Icon(on ? LucideIcons.squareCheck : LucideIcons.square, size: 22, color: on ? kPostedText : kMuted),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(i.s('name'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(15, 600)),
                                Text(
                                  [unitWord(i.s('unit')), if (i.s('sku').isNotEmpty) i.s('sku'), if (already) tr('on the order: +1')].join(' · '),
                                  style: inter(12.5, 400, color: kMuted),
                                ),
                              ]),
                            ),
                            Text(price == null || price == 0 ? tr('no price') : '${money(price)}/${i.s('unit').isEmpty ? 'unit' : i.s('unit')}', style: inter(13, 600, color: price == null || price == 0 ? kMuted : kInk)),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: InvPrimary(
                _picked.isEmpty ? tr('Tick the items to order') : '${tr('Add')} ${_picked.length} ${tr(_picked.length == 1 ? 'item' : 'items')}',
                key: const ValueKey('po-pick-add'),
                onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, _picked.values.toList()),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
