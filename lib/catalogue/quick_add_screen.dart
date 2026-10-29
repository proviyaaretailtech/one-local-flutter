import 'dart:math';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart' show PartnerApiException;
import '../inventory/inventory_api.dart';
import '../inventory/inventory_widgets.dart';
import '../orders/order_widgets.dart' show OrdersTopBar, kSoftField;
import '../purchasing/add_supplier_sheet.dart';
import '../purchasing/purchasing_api.dart';
import '../stock/update_stock_screen.dart' show UpdateStockScreenTones;
import '../ui/barcode_scanner.dart';
import '../ui/theme.dart';
import 'catalogue_api.dart';
import 'catalogue_widgets.dart';
import 'item_photo.dart';
import 'item_form_screen.dart';
import 'item_sheets.dart' show parsePriceMinor;
import '../ui/i18n.dart';

/// Quick Add (founder's sketch, 26 Oct 2026): one screen adds a product with everything it needs — photo, name, barcode, cost · MRP ·
/// price (coloured like Item → Stock), margin, its usual supplier (from the phone's contacts if new) and how many are in stock now — so
/// nothing is entered again in Stock or Purchase. The System Code is made from the name. Returns the new item.
class QuickAddScreen extends StatefulWidget {
  QuickAddScreen({super.key, required this.api, this.photos = const DeviceItemPhotos(), this.category, this.barcode, this.receiving = false, InventoryApi? inventory, PurchasingApi? purchasing})
      : inventory = inventory ?? InventoryApi(),
        purchasing = purchasing ?? PurchasingApi();
  final CatalogueApi api;
  final ItemPhotoService photos;
  final InventoryApi inventory;
  final PurchasingApi purchasing;

  /// The category it goes into (from a category's "New category" or the Bill), shown as a chip.
  final String? category;

  /// A scanned barcode no product has yet, filled in.
  final String? barcode;

  /// Opened from a receipt note (founder, 26 Oct 2026: an unknown item in a delivery): no "In stock now", the receipt counts it.
  final bool receiving;

  @override
  State<QuickAddScreen> createState() => _QuickAddScreenState();
}

const kSellingUnits = ['pc', 'pack', 'kg', 'g', 'l', 'ml', 'dozen', 'box'];

/// A System Code from the product's name: its first letters and numbers, then three digits ("Aashirvaad Atta" → AASHIR-482).
String systemCodeFor(String name, [Random? rand]) {
  final letters = name.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  final head = letters.isEmpty ? 'ITEM' : letters.substring(0, min(6, letters.length));
  return '$head-${100 + (rand ?? Random()).nextInt(900)}';
}

class _QuickAddScreenState extends State<QuickAddScreen> {
  final _name = TextEditingController(), _sku = TextEditingController();
  late final _barcode = TextEditingController(text: widget.barcode ?? '');
  final _cost = TextEditingController(), _mrp = TextEditingController(), _price = TextEditingController(), _qty = TextEditingController();
  late final _category = TextEditingController(text: widget.category ?? '');
  final _key = CatalogueApi.newKey(); // one key per screen: a retried tap never adds twice
  final _stockKey = InventoryApi.newKey();
  bool _skuTouched = false, _editSku = false, _busy = false;
  String _unit = 'pc';
  String? _error;
  ItemPhoto? _photo;
  List<Facts>? _suppliers;
  Facts? _supplier;

  @override
  void initState() {
    super.initState();
    _loadSuppliers();
  }

  @override
  void dispose() {
    for (final c in [_name, _sku, _barcode, _cost, _mrp, _price, _qty, _category]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadSuppliers() async {
    try {
      final s = await widget.purchasing.suppliers();
      if (mounted) setState(() => _suppliers = s);
    } catch (_) {
      if (mounted) setState(() => _suppliers = const []); // a role without purchasing still adds products
    }
  }

  int? get _costMinor => parsePriceMinor(_cost.text);
  int? get _mrpMinor => parsePriceMinor(_mrp.text);
  int? get _priceMinor => parsePriceMinor(_price.text);
  num? get _stock => num.tryParse(_qty.text.trim());

  void _nameChanged(String v) {
    if (!_skuTouched) _sku.text = v.trim().isEmpty ? '' : systemCodeFor(v);
    setState(() {});
  }

  String? _problem() {
    if (_name.text.trim().length < 2) return 'Enter the product name.';
    if (_sku.text.trim().isEmpty) return 'Enter a System Code.';
    if (_priceMinor == null) return 'Enter the selling price.';
    if (_mrpMinor != null && _priceMinor! > _mrpMinor!) return 'The price cannot be above the MRP.';
    if (_qty.text.trim().isNotEmpty && (_stock == null || _stock! < 0)) return 'Enter how many you have, or leave it blank.';
    return null;
  }

  Future<void> _pickPhoto() async {
    try {
      final p = await widget.photos.capture(context);
      if (p != null && mounted) setState(() => _photo = p);
    } catch (e) {
      if (mounted) showToast(context, e is ItemPhotoUnavailable ? e.message : 'That photo could not be opened.');
    }
  }

  Future<void> _scan() async {
    final code = await scanBarcodeOrType(context);
    if (code != null && code.trim().isNotEmpty && mounted) setState(() => _barcode.text = code.trim());
  }

  Future<void> _pickSupplier() async {
    final list = _suppliers ?? const <Facts>[];
    if (list.isEmpty) return _addSupplier();
    final id = await pickOne<String>(context, 'Usual supplier', [
      for (final s in list) (s.s('id'), s.s('name'), [s.s('city'), s.s('phone')].where((x) => x.isNotEmpty).join(' · ').ifEmptyNull),
    ], current: _supplier?.s('id'));
    if (id != null && mounted) setState(() => _supplier = list.firstWhere((s) => s.s('id') == id));
  }

  Future<void> _addSupplier() async {
    final s = await showAddSupplier(context, widget.purchasing);
    if (s == null || !mounted) return;
    setState(() {
      _suppliers = [...?_suppliers, s];
      _supplier = s;
    });
  }

  /// Saves the product, then its photo, stock and supplier. The product is added even when one of those cannot be saved; the toast
  /// says which, so it can be done from Stock or Purchase.
  Future<void> _save() async {
    final p = _problem();
    if (p != null) return setState(() => _error = p);
    setState(() {
      _busy = true;
      _error = null;
    });
    final CatItem item;
    try {
      item = await widget.api.save({
        'mode': 'quick',
        'name': _name.text.trim(),
        'sku': _sku.text.trim(),
        'price_minor': _priceMinor,
        'mrp_minor': ?_mrpMinor,
        'cost_minor': ?_costMinor,
        if (_barcode.text.trim().isNotEmpty) 'barcode': _barcode.text.trim(),
        'selling_unit': _unit,
        if (_category.text.trim().isNotEmpty) 'category': _category.text.trim(),
      }, key: _key);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is CatalogueApiException ? e.message : 'Could not add the product. Try again.';
        });
      }
      return;
    }
    final missed = <String>[];
    final inv = item.raw['inventory_item_id']?.toString();
    if (_photo != null) {
      try {
        await widget.photos.attach(item.id, _photo!);
      } catch (e) {
        missed.add(e is ItemPhotoUnavailable ? e.message : 'the photo could not be saved');
      }
    }
    if (!widget.receiving && (_stock ?? 0) > 0 && inv != null) {
      try {
        await widget.inventory.openingStock(inv, _stock!, key: _stockKey);
      } catch (e) {
        missed.add(e is PartnerApiException ? e.message : 'the stock could not be saved (add it in Item → Stock)');
      }
    }
    if (_supplier != null && inv != null) {
      try {
        await widget.purchasing.setItemSupplier(inv, _supplier!.s('id'), priceMinor: _costMinor);
      } catch (e) {
        missed.add(e is PartnerApiException ? e.message : 'the supplier could not be linked');
      }
    }
    if (!mounted) return;
    // the screen that opened Quick Add says "added"; this only speaks when a part did not save
    if (missed.isNotEmpty) showToast(context, '${item.name} added, but ${missed.join('; ')}.');
    Navigator.of(context).pop(item);
  }

  // ---------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: Column(children: [
          OrdersTopBar(title: tr(widget.receiving ? 'New item' : 'Quick add'), onBack: () => Navigator.of(context).maybePop()),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: [
              _identity(),
              const SizedBox(height: 10),
              _prices(),
              const SizedBox(height: 10),
              _stockAndSupplier(),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('quick-more'),
                  onPressed: _busy ? null : _moreDetails,
                  icon: const Icon(LucideIcons.slidersHorizontal, size: 15, color: kLink),
                  label: Text(tr('More details (tax, brand, storage)'), style: inter(13, 700, color: kLink)),
                ),
              ),
            ]),
          ),
          Material(
            color: Colors.white,
            elevation: 8,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(tr(_error!), key: const ValueKey('quick-error'), style: inter(12.5, 600, color: kRedText))),
                  InvPrimary(tr('Add product'), key: const ValueKey('quick-save'), busy: _busy, onPressed: _busy ? null : _save),
                ]),
              ),
            ),
          ),
        ]),
      );

  Future<void> _moreDetails() async {
    // the full form, for the rare item that needs tax, brand or storage now; its own save adds the item
    final made = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ItemFormScreen(api: widget.api, barcode: _barcode.text.trim().isEmpty ? null : _barcode.text.trim())));
    if (made == true && mounted) Navigator.of(context).pop();
  }

  Widget _card(List<Widget> children) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: kCardLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );

  Widget _label(String t) => Padding(padding: const EdgeInsets.only(top: 10, bottom: 6), child: Text(tr(t), style: inter(12.5, 700, color: kMuted)));

  /// Photo, name (with its System Code) and barcode.
  Widget _identity() => _card([
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 92,
            height: 92,
            child: _photo == null
                ? AddPhotoBox(key: const ValueKey('quick-photo-add'), onTap: _busy ? null : _pickPhoto, height: 92)
                : InkWell(
                    key: const ValueKey('quick-photo-replace'),
                    borderRadius: BorderRadius.circular(14),
                    onTap: _busy ? null : _pickPhoto,
                    child: Container(
                      decoration: BoxDecoration(color: kSoftField, borderRadius: BorderRadius.circular(14), border: Border.all(color: kCardLine)),
                      clipBehavior: Clip.antiAlias,
                      child: Image.memory(_photo!.bytes, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.imageOff, color: kMuted)),
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Product name'), style: inter(12.5, 700, color: kMuted)),
              const SizedBox(height: 6),
              InvInput(key: const ValueKey('quick-name'), controller: _name, hint: tr('For example Parle-G 100g'), onChanged: _nameChanged),
              const SizedBox(height: 6),
              if (_editSku)
                InvInput(
                  key: const ValueKey('quick-sku'),
                  controller: _sku,
                  hint: tr('System Code'),
                  onChanged: (_) => setState(() => _skuTouched = true),
                )
              else
                InkWell(
                  key: const ValueKey('quick-sku-change'),
                  onTap: () => setState(() => _editSku = true),
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: 'System Code ${_sku.text.isEmpty ? '· made from the name' : _sku.text}', style: inter(12, 500, color: kMuted)),
                    TextSpan(text: '  Change', style: inter(12, 700, color: kLink)),
                  ])),
                ),
            ]),
          ),
        ]),
        _label(tr('Barcode')),
        InvInput(
          key: const ValueKey('quick-barcode'),
          controller: _barcode,
          hint: tr('Scan or type'),
          prefixIcon: LucideIcons.barcode,
          suffix: IconButton(key: const ValueKey('quick-scan'), tooltip: tr('Scan a barcode'), onPressed: _busy ? null : _scan, icon: const Icon(LucideIcons.scanBarcode, size: 20, color: kInk)),
        ),
        if (_category.text.isNotEmpty && widget.category != null) ...[
          const SizedBox(height: 10),
          Align(alignment: Alignment.centerLeft, child: InvDotChip('Category: ${widget.category}', bg: kLimeSoftH, fg: kInk)),
        ] else ...[
          _label(tr('Category (optional)')),
          InvInput(key: const ValueKey('quick-category'), controller: _category, hint: tr('For example Biscuits')),
        ],
      ]);

  /// Cost · MRP · Price side by side, coloured like Item → Stock: price = MRP green, below yellow, above red; margin below 5% red.
  Widget _prices() {
    final tone = UpdateStockScreenTones.tone(_priceMinor, _mrpMinor);
    final margin = UpdateStockScreenTones.margin(_priceMinor, _costMinor);
    Widget box(String label, TextEditingController c, String key, {(Color, Color, String)? colour}) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr(label), style: inter(12.5, 700, color: kMuted)),
            const SizedBox(height: 6),
            Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(color: colour?.$1 ?? Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: colour?.$2 ?? const Color(0xFFD9DBD5), width: colour == null ? 1 : 1.4)),
              child: Row(children: [
                Text('₹', style: inter(15, 600, color: kMuted)),
                const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    key: ValueKey(key),
                    controller: c,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    style: inter(15, 700),
                    decoration: const InputDecoration.collapsed(hintText: '0'),
                  ),
                ),
              ]),
            ),
          ]),
        );
    return _card([
      Row(children: [
        box('Cost', _cost, 'quick-cost'),
        const SizedBox(width: 8),
        box('MRP', _mrp, 'quick-mrp'),
        const SizedBox(width: 8),
        box('Price', _price, 'quick-price', colour: tone),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        if (tone != null) Text(tr(tone.$3), key: const ValueKey('quick-tone'), style: inter(12.5, 700, color: tone.$2)),
        const Spacer(),
        Container(
          key: const ValueKey('quick-margin'),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: margin == null ? kGreyBg : (margin.pct < 5 ? kRedBgH : const Color(0xFFEBFAE0)),
            borderRadius: BorderRadius.circular(99),
          ),
          child: Text(
            margin == null ? 'Margin —' : 'Margin ₹${(margin.amount / 100).toStringAsFixed(margin.amount % 100 == 0 ? 0 : 2)} · ${margin.pct.toStringAsFixed(1)}%',
            style: inter(12.5, 700, color: margin == null ? kMuted : (margin.pct < 5 ? kRedText : kPostedText)),
          ),
        ),
      ]),
    ]);
  }

  /// Usual supplier (+ add from contacts), the selling unit and how many are in stock now.
  Widget _stockAndSupplier() => _card([
        Text(tr('Supplier'), style: inter(12.5, 700, color: kMuted)),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: InvPickBox(
              key: const ValueKey('quick-supplier'),
              value: _supplier?.s('name') ?? (_suppliers == null ? 'Loading suppliers…' : 'Choose the usual supplier (optional)'),
              semantic: 'Supplier',
              onTap: _busy || _suppliers == null ? null : _pickSupplier,
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: kLimeSoftH,
            shape: const CircleBorder(side: BorderSide(color: kLimeH)),
            child: InkWell(
              key: const ValueKey('quick-supplier-add'),
              customBorder: const CircleBorder(),
              onTap: _busy ? null : _addSupplier,
              child: const SizedBox(width: 46, height: 46, child: Icon(LucideIcons.userPlus, size: 20, color: kInk)),
            ),
          ),
        ]),
        _label(tr('Sold in')),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final u in kSellingUnits) ...[
              ChoiceChip(
                key: ValueKey('quick-unit-$u'),
                label: Text(u, style: inter(13, _unit == u ? 700 : 500)),
                selected: _unit == u,
                showCheckmark: false,
                selectedColor: kLimeH,
                backgroundColor: Colors.white,
                side: BorderSide(color: _unit == u ? kLimeH : kCardLine),
                onSelected: (_) => setState(() => _unit = u),
              ),
              const SizedBox(width: 6),
            ],
          ]),
        ),
        if (!widget.receiving) ...[
        _label(tr('In stock now')),
        Row(children: [
          Expanded(child: InvInput(key: const ValueKey('quick-qty'), controller: _qty, number: true, hint: tr('How many you have (optional)'), onChanged: (_) => setState(() {}))),
          const SizedBox(width: 10),
          Text(_unit, style: inter(14, 700, color: kMuted)),
        ]),
        ],
      ]);
}

extension on String {
  String? get ifEmptyNull => isEmpty ? null : this;
}
