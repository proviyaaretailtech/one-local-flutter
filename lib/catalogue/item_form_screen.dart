import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'catalogue_api.dart';
import 'catalogue_format.dart';
import 'catalogue_widgets.dart';
import 'item_sheets.dart' show parsePriceMinor;

/// Figma "Item Creation" (Store Standard / Screens): identity, units and storage, tax and pricing, then a save checklist.
/// Also used to change an existing item (Quick edit, Edit catalogue details): [item] pre-fills the form and carries its version.
/// The screen only collects and sends; the database decides what is valid (tax needed to save, price not above MRP, unique SKU and barcode).
class ItemFormScreen extends StatefulWidget {
  const ItemFormScreen({super.key, this.api, this.item, this.onNavigate});
  final CatalogueApi? api;
  final CatItem? item;
  final ValueChanged<String>? onNavigate;
  @override
  State<ItemFormScreen> createState() => _ItemFormScreenState();
}

class _ItemFormScreenState extends State<ItemFormScreen> {
  late final CatalogueApi _api = widget.api ?? CatalogueApi();
  final _name = TextEditingController(), _sku = TextEditingController(), _category = TextEditingController(), _brand = TextEditingController(), _barcode = TextEditingController();
  final _netQty = TextEditingController(), _packUnits = TextEditingController(text: '1'), _hsn = TextEditingController();
  final _cost = TextEditingController(), _price = TextEditingController(), _mrp = TextEditingController();
  final _keyIdentity = GlobalKey(), _keyPricing = GlobalKey(), _keyReview = GlobalKey();
  late final String _saveKey = CatalogueApi.newKey();
  String _unit = 'pc', _netUnit = 'g';
  num? _gst;
  String _storage = '';
  bool _busy = false, _bannerOpen = true;
  String? _error, _errorTitle;

  static const _storages = ['Ambient · Dry shelf', 'Ambient', 'Chilled', 'Frozen'];

  bool get _editing => widget.item != null;

  String _rupees(int? minor) => minor == null ? '' : (minor % 100 == 0 ? '${minor ~/ 100}' : (minor / 100).toStringAsFixed(2));

  @override
  void initState() {
    super.initState();
    final i = widget.item;
    if (i != null) {
      _name.text = i.name;
      _sku.text = i.sku;
      _category.text = i.category;
      _brand.text = i.brand ?? '';
      _barcode.text = i.barcode ?? '';
      _unit = i.sellingUnit;
      _netQty.text = i.netQty == null ? '' : qty(i.netQty!);
      _netUnit = i.netQtyUnit ?? 'g';
      _packUnits.text = qty(i.purchasePackUnits);
      _storage = i.storage ?? '';
      _hsn.text = i.hsn ?? '';
      _gst = i.gstPct;
      _cost.text = _rupees(i.costMinor);
      _price.text = _rupees(i.priceMinor);
      _mrp.text = _rupees(i.mrpMinor);
    }
    for (final c in [_name, _sku, _category, _barcode, _netQty, _hsn, _cost, _price, _mrp]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _sku, _category, _brand, _barcode, _netQty, _packUnits, _hsn, _cost, _price, _mrp]) {
      c.dispose();
    }
    super.dispose();
  }

  void _tab(String id) {
    if (id == 'item') {
      Navigator.of(context).maybePop();
    } else if (widget.onNavigate != null) {
      widget.onNavigate!(id);
    } else {
      showToast(context, 'That part of the app is not built yet.');
    }
  }

  void _goto(GlobalKey k) {
    final c = k.currentContext;
    if (c != null) Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 250), alignment: 0.02);
  }

  String? _nullIfBlank(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save({required bool draft}) async {
    final price = parsePriceMinor(_price.text);
    if (_name.text.trim().isEmpty) return showToast(context, 'Enter the product name.');
    if (_sku.text.trim().isEmpty) return showToast(context, 'Enter the SKU.');
    if (price == null) return showToast(context, 'Enter the selling price.');
    final mrp = _mrp.text.trim().isEmpty ? null : parsePriceMinor(_mrp.text);
    final cost = _cost.text.trim().isEmpty ? null : parsePriceMinor(_cost.text);
    if (_mrp.text.trim().isNotEmpty && mrp == null) return showToast(context, 'The MRP is not a price.');
    if (_cost.text.trim().isNotEmpty && cost == null) return showToast(context, 'The purchase cost is not a price.');
    final netQty = _netQty.text.trim().isEmpty ? null : num.tryParse(_netQty.text.trim());
    if (_netQty.text.trim().isNotEmpty && netQty == null) return showToast(context, 'The net quantity is not a number.');
    final pack = num.tryParse(_packUnits.text.trim());
    if (pack == null) return showToast(context, 'The purchase conversion is not a number.');
    final fields = <String, dynamic>{
      'mode': 'full',
      'draft': draft,
      'name': _name.text.trim(),
      'sku': _sku.text.trim(),
      'category': _nullIfBlank(_category),
      'brand': _nullIfBlank(_brand),
      'barcode': _nullIfBlank(_barcode),
      'price_minor': price,
      'mrp_minor': mrp,
      'cost_minor': cost,
      'hsn': _nullIfBlank(_hsn),
      'gst_pct': _gst,
      'selling_unit': _unit,
      'net_qty': netQty,
      'net_qty_unit': netQty == null ? null : _netUnit,
      'purchase_pack_units': pack,
      'storage': _storage.isEmpty ? null : _storage,
      'version': ?(_editing ? widget.item!.version : null),
    };
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await _api.save(fields, id: widget.item?.id, key: _saveKey);
      if (!mounted) return;
      showToast(context, draft ? '${saved.name} saved as a draft.' : '${saved.name} saved.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _bannerOpen = true;
        if (e is CatalogueApiException) {
          _error = e.message;
          _errorTitle = e.taxRequired ? 'Complete tax details to save item' : e.stale ? 'This item changed on another device' : 'Could not save the item';
        } else {
          _error = 'Could not save the item. Check the connection and try again.';
          _errorTitle = 'Could not save the item';
        }
      });
    }
  }

  // ---------------------------------------------------------------- pieces
  Widget _card(Key? key, String title, {Widget? chip, required List<Widget> children}) => Container(
        key: key,
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22), border: Border.all(color: const Color(0xFFE3E5DF))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [Expanded(child: Text(title, style: inter(18, 700))), ?chip]),
          const SizedBox(height: 8),
          ...children,
        ]),
      );

  Widget _label(String t) => Padding(padding: const EdgeInsets.only(top: 10, bottom: 8), child: Text(t, style: inter(14, 600, color: kMuted)));

  Widget _input(TextEditingController c, String hint, {TextInputType? type, List<TextInputFormatter>? formatters, bool bad = false}) => Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: bad ? kError : const Color(0xFFDADCD5), width: bad ? 1.5 : 1)),
        child: TextField(
          controller: c,
          keyboardType: type,
          inputFormatters: formatters,
          style: inter(16, 400),
          decoration: plainInput.copyWith(hintText: hint, hintStyle: inter(16, 400, color: bad ? kError : kMuted)),
        ),
      );

  Widget _dropdown<T>({required T? value, required List<(T, String)> items, required ValueChanged<T?> onChanged, String hint = 'Select', bool bad = false}) => Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: bad ? kError : const Color(0xFFDADCD5), width: bad ? 1.5 : 1)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            isExpanded: true,
            icon: const Icon(LucideIcons.chevronDown, size: 18, color: kMuted),
            hint: Text(hint, style: inter(16, 400, color: bad ? kError : kMuted)),
            style: inter(16, 400),
            items: [for (final (v, l) in items) DropdownMenuItem<T>(value: v, child: Text(l))],
            onChanged: onChanged,
          ),
        ),
      );

  Widget _kv(String k, String v, {Color vc = kInk}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [Expanded(child: Text(k, style: inter(15, 400, color: kMuted))), Text(v, style: inter(16, 700, color: vc))]),
      );

  Widget _check(bool done, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 24, child: Icon(done ? LucideIcons.check : LucideIcons.circle, size: done ? 18 : 14, color: kInk)),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: inter(16, 400))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final price = parsePriceMinor(_price.text), mrp = parsePriceMinor(_mrp.text), cost = parsePriceMinor(_cost.text);
    final netQty = num.tryParse(_netQty.text.trim());
    final taxOpen = _hsn.text.trim().isEmpty || _gst == null;
    // display only: price per kg or per litre from the net quantity
    String? unitPrice;
    if (price != null && netQty != null && netQty > 0) {
      final base = switch (_netUnit) { 'g' => netQty / 1000, 'kg' => netQty, 'ml' => netQty / 1000, 'l' => netQty, _ => null };
      if (base != null) unitPrice = '${money((price / base).round())} / ${_netUnit == 'g' || _netUnit == 'kg' ? 'kg' : 'L'}';
    }
    String margin = 'Pending tax verification';
    if (price != null && cost != null && _gst != null && price > 0) {
      final net = price / (1 + _gst! / 100);
      margin = '${money((net - cost).round())} · ${((net - cost) / net * 100).toStringAsFixed(1)}%';
    }
    final title = _editing ? 'Edit Item' : 'Item Creation';
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        OrdersTopBar(title: 'VINII Store POS', onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 16), children: [
            Text(title, style: inter(26, 800)),
            const SizedBox(height: 6),
            Text(_editing ? 'Change this catalogue item. Stock is not changed here.' : 'Prepare a new catalogue item without changing live stock.', style: inter(15, 400, color: kMuted)),
            const SizedBox(height: 4),
            Text(_editing ? '${widget.item!.sku} · ${statusLabel(widget.item!)} · Tax ${widget.item!.taxVerified ? 'verified' : 'not verified'}' : 'New item · Unsaved draft · Tax validation required', style: inter(14, 600, color: kMuted)),
            const SizedBox(height: 14),
            Row(children: [
              _TabChip('Identity', true, () => _goto(_keyIdentity)),
              const SizedBox(width: 10),
              _TabChip('Pricing', false, () => _goto(_keyPricing)),
              const SizedBox(width: 10),
              _TabChip('Review', false, () => _goto(_keyReview)),
            ]),
            const SizedBox(height: 14),
            _card(_keyIdentity, 'Item identity', chip: const DotChip('Draft', bg: kSoftField, fg: kMuted), children: [
              _label('Product name *'),
              _input(_name, 'Product name'),
              _label('SKU *'),
              _input(_sku, 'Unique SKU, for example OC-200-PK'),
              _label('Category *'),
              _input(_category, 'Snacks'),
              _label('Brand'),
              _input(_brand, 'Not provided · Add brand'),
              _label('Barcode *'),
              _input(_barcode, 'Scan or type the barcode'),
              const SizedBox(height: 8),
              Text(_barcode.text.trim().isEmpty ? 'Without a barcode this item cannot be found by scan.' : 'Identifier has no saved catalogue link. Confirm uniqueness again when saving.', style: inter(14, 400, color: kMuted, height: 1.35)),
            ]),
            _card(null, 'Units & storage', children: [
              _label('Selling unit *'),
              _dropdown<String>(value: _unit, items: sellingUnits, onChanged: (v) => setState(() => _unit = v ?? 'pc')),
              _label('Net quantity *'),
              Row(children: [
                Expanded(flex: 3, child: _input(_netQty, '200', type: const TextInputType.numberWithOptions(decimal: true), formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))])),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: _dropdown<String>(value: _netUnit, items: [for (final u in netUnits) (u, u)], onChanged: (v) => setState(() => _netUnit = v ?? 'g'))),
              ]),
              _label('Purchase-to-sale conversion *'),
              Row(children: [
                Text('1 pack =', style: inter(16, 400)),
                const SizedBox(width: 10),
                SizedBox(width: 90, child: _input(_packUnits, '1', type: const TextInputType.numberWithOptions(decimal: true), formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))])),
                const SizedBox(width: 10),
                Text('selling unit', style: inter(16, 400)),
              ]),
              _label('Storage'),
              _dropdown<String>(value: _storage.isEmpty ? null : _storage, items: [for (final s in _storages) (s, s)], hint: 'Ambient · Dry shelf', onChanged: (v) => setState(() => _storage = v ?? '')),
              const SizedBox(height: 8),
              _kv('Opening stock', 'Not added · 0 units'),
            ]),
            _card(_keyPricing, 'Tax & pricing', children: [
              Text(taxOpen ? 'Draft pricing · Not effective' : 'Tax details entered', style: inter(14, 400, color: kMuted)),
              _label('HSN / tax category *'),
              _input(_hsn, 'Required · Select verified tax category', bad: taxOpen && _hsn.text.trim().isEmpty && _error != null, type: TextInputType.number, formatters: [FilteringTextInputFormatter.digitsOnly]),
              _label('GST rate *'),
              _dropdown<num>(value: _gst, items: [for (final g in gstSlabs) (g, '${qty(g)}%')], hint: 'Not verified · Required before saving', bad: _gst == null && _error != null, onChanged: (v) => setState(() => _gst = v)),
              _label('Purchase cost · ex tax (₹)'),
              _input(_cost, '₹24.00', type: const TextInputType.numberWithOptions(decimal: true), formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]),
              _label('Selling price · tax inclusive (₹) *'),
              _input(_price, '₹40.00', type: const TextInputType.numberWithOptions(decimal: true), formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]),
              _label('MRP (₹)'),
              _input(_mrp, '₹45.00', type: const TextInputType.numberWithOptions(decimal: true), formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]),
              const SizedBox(height: 6),
              _kv('Unit selling price', unitPrice ?? '—'),
              _kv('Margin', margin),
            ]),
            if (_error != null && _bannerOpen)
              Container(
                margin: const EdgeInsets.only(bottom: 14),
                padding: const EdgeInsets.fromLTRB(14, 14, 6, 14),
                decoration: BoxDecoration(color: kBadBg, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFE9908A))),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Padding(padding: EdgeInsets.only(top: 2), child: Icon(LucideIcons.circleX, size: 24, color: kBadText)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_errorTitle ?? 'Could not save the item', style: inter(17, 700)),
                      const SizedBox(height: 4),
                      Text(_error!, style: inter(15, 400, color: const Color(0xFF9A6B68), height: 1.35)),
                    ]),
                  ),
                  IconButton(tooltip: 'Dismiss', onPressed: () => setState(() => _bannerOpen = false), icon: const Icon(LucideIcons.x, size: 18, color: kMuted)),
                ]),
              ),
            _card(_keyReview, 'Save checklist', children: [
              const SizedBox(height: 4),
              _check(_name.text.trim().isNotEmpty && _category.text.trim().isNotEmpty && _sku.text.trim().isNotEmpty, 'Name, category and SKU completed'),
              _check(_barcode.text.trim().isNotEmpty, 'Barcode entered'),
              _check(mrp != null && cost != null && !taxOpen, 'Verify pack MRP, cost and tax'),
              _check(_editing, 'Save item before receiving or printing labels'),
            ]),
            DarkButton('Complete tax validation', busy: _busy, onPressed: () => _save(draft: false)),
            const SizedBox(height: 12),
            OutlineButton('Save draft only', onPressed: _busy ? null : () => _save(draft: true), height: 56),
            const SizedBox(height: 12),
            Text('A draft is not sold and does not change stock. Stock is received in Stock.', style: inter(14, 400, color: kMuted, height: 1.35)),
          ]),
        ),
        PosBottomNav(active: 'item', onTap: _tab),
      ]),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip(this.label, this.on, this.onTap);
  final String label;
  final bool on;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(color: on ? kLime : Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: on ? kLime : const Color(0xFFE3E5DF))),
          child: Text(label, style: inter(15, on ? 700 : 500, color: on ? kDark : kInk)),
        ),
      );
}
