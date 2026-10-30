import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart' show PartnerApiException;
import '../barcodes/barcode_sheets.dart' show itemLabel, printBarcodeLabels;
import '../barcodes/barcode_ui.dart' show LabelCountStepper;
import '../barcodes/barcodes_api.dart';
import '../inventory/inventory_api.dart';
import '../inventory/inventory_widgets.dart';
import '../orders/order_widgets.dart' show OrdersTopBar, kSoftField;
import '../purchasing/add_supplier_sheet.dart';
import '../purchasing/purchasing_api.dart';
import '../stock/update_stock_screen.dart' show UpdateStockScreenTones;
import '../ui/barcode_scanner.dart';
import '../ui/theme.dart';
import 'catalogue_api.dart';
import 'category_units.dart';
import 'catalogue_widgets.dart';
import 'item_photo.dart';
import 'item_form_screen.dart';
import 'item_sheets.dart' show parsePriceMinor;
import 'price_basis.dart';
import 'sku_api.dart';
import 'sku_picker.dart';
import '../media/media_api.dart';
import '../ui/item_name.dart';
import '../ui/i18n.dart';

/// Quick Add (founder's sketch, 26 Oct 2026): one screen adds a product with everything it needs — photo, name, barcode, cost · MRP ·
/// price (coloured like Item → Stock), margin, its usual supplier (from the phone's contacts if new) and how many are in stock now — so
/// nothing is entered again in Stock or Purchase. The SKU is made from its subcategory, brand and size (never the name). Returns the new item.
class QuickAddScreen extends StatefulWidget {
  QuickAddScreen({super.key, required this.api, this.photos = const DeviceItemPhotos(), this.category, this.barcode, this.name, this.receiving = false, InventoryApi? inventory, PurchasingApi? purchasing, BarcodesApi? barcodes, SkuApi? skus, MediaApi? media})
      : inventory = inventory ?? InventoryApi(),
        barcodes = barcodes ?? BarcodesApi(),
        skus = skus ?? SkuApi(rpc: api.rpc),
        media = media ?? MediaApi(),
        purchasing = purchasing ?? PurchasingApi();
  final CatalogueApi api;
  final ItemPhotoService photos;
  final InventoryApi inventory;
  final PurchasingApi purchasing;
  final BarcodesApi barcodes;
  final SkuApi skus;
  final MediaApi media;

  /// The category it goes into (from a category's "New category" or the Bill), shown as a chip.
  final String? category;

  /// A scanned barcode no product has yet, filled in.
  final String? barcode;

  /// A name searched for that no product has (Add purchase's "Create new item"), filled in.
  final String? name;

  /// Opened from a receipt note (founder, 26 Oct 2026: an unknown item in a delivery): no "In stock now", the receipt counts it.
  final bool receiving;

  @override
  State<QuickAddScreen> createState() => _QuickAddScreenState();
}

const kSellingUnits = ['pc', 'pack', 'kg', 'g', 'l', 'ml', 'dozen', 'box'];

class _QuickAddScreenState extends State<QuickAddScreen> {
  // typed in capitals, at most 25 characters; saved in Title Case
  late final _name = TextEditingController(text: ItemNameFormatter.clean(widget.name?.trim() ?? ''));
  late final _barcode = TextEditingController(text: widget.barcode ?? '');
  final _cost = TextEditingController(), _mrp = TextEditingController(), _price = TextEditingController(), _qty = TextEditingController();
  late final _category = TextEditingController(text: widget.category ?? '');
  final _key = CatalogueApi.newKey(); // one key per screen: a retried tap never adds twice
  final _stockKey = InventoryApi.newKey();
  bool _busy = false;

  /// The SKU's parts (founder's OL SKU sheet, 31 Oct 2026), and the OneLocal product the barcode matched (its SKU is reused).
  SkuParts? _parts;
  MasterProduct? _matched;
  int _lookupSeq = 0;

  /// No barcode on the product: make the store's own code (200…) when it is saved, and print its label if asked.
  bool _makeCode = false;
  int _labels = 1; // how many labels of the new code to print (0: none)
  String _unit = 'pc';

  /// Clothes and the like: the size it comes in (the unit stays pc); null when sizes do not apply.
  String? _size;

  /// The categories this store registered with (listed first), and units the store typed on this screen.
  List<String> _myCats = const [];
  final _customUnits = <String>[];
  bool _unitTouched = false; // a unit picked by hand stays when the category changes, if it fits

  /// MRP-based (printed MRP) or store-based (own price); it follows the selling unit until the person picks one.
  PriceBasis _basis = PriceBasis.mrp;
  bool _basisTouched = false, _priceTouched = false;
  final _markup = TextEditingController();
  String? _error;
  ItemPhoto? _photo;
  List<Facts>? _suppliers;
  Facts? _supplier;

  @override
  void initState() {
    super.initState();
    _loadSuppliers();
    _loadStoreCategories();
    if (_category.text.isNotEmpty) _unit = unitsFor(_category.text).units.first;
    // a barcode scanned before this screen opened (Add purchase): OneLocal may already know the product
    if (_barcode.text.trim().isNotEmpty) _barcodeChanged();
  }

  Future<void> _loadStoreCategories() async {
    try {
      final c = await widget.api.storeCategories();
      if (mounted) setState(() => _myCats = c);
    } catch (_) {} // the full list still shows
  }

  /// The category from a list: the store's own categories first, then the rest, then one the store types.
  Future<void> _pickCategory() async {
    final mine = _myCats.where(kCategoryUnits.containsKey).toList();
    final picked = await pickOne<String>(context, tr('Product category'), [
      for (final c in mine) (c, c, tr('Your store')),
      for (final c in kCategoryUnits.keys) if (!mine.contains(c)) (c, c, null),
      if (_category.text.trim().isNotEmpty && !kCategoryUnits.containsKey(_category.text.trim())) (_category.text.trim(), _category.text.trim(), tr('Typed')),
      ('+new', '+ ${tr('New category')}', tr('Type your own')),
    ], current: _category.text.trim().isEmpty ? null : _category.text.trim());
    if (picked == null || !mounted) return;
    var cat = picked;
    if (picked == '+new') {
      final typed = (await askNote(context, tr('New category'), hint: tr('For example Biscuits'), action: tr('Use')))?.trim();
      if (typed == null || typed.isEmpty || !mounted) return;
      cat = typed.length > 60 ? typed.substring(0, 60) : typed;
    }
    setState(() {
      _category.text = cat;
      // the units follow the category: one that does not fit it goes
      final fit = unitsFor(cat);
      if (!_unitTouched || _size != null || (!fit.units.contains(_unit) && !_customUnits.contains(_unit))) _setUnit(fit.units.first);
      if (fit.sizes.isEmpty || (_size != null && !fit.sizes.contains(_size))) _size = null;
    });
  }

  void _setUnit(String u) {
    _unit = u;
    if (!_basisTouched) _basis = basisForUnit(u);
  }

  /// Units (and sizes) that fit the category, and a custom one.
  Future<void> _pickUnit() async {
    final fit = unitsFor(_category.text);
    final current = _size != null ? 'size:$_size' : _unit;
    final picked = await pickOne<String>(context, fit.sizes.isEmpty ? tr('Unit') : tr('Size or unit'), [
      for (final s in fit.sizes) ('size:$s', '${tr('Size')} $s', tr('Counted in pieces')),
      for (final u in {...fit.units, ..._customUnits, if (!fit.units.contains(_unit)) _unit}) (u, unitName(u), null),
      ('+unit', '+ ${tr('Add a custom unit')}', tr('For example roll, sheet, bundle')),
    ], current: current);
    if (picked == null || !mounted) return;
    _unitTouched = true;
    if (picked == '+unit') {
      final typed = await askNote(context, tr('Custom unit'), hint: tr('For example roll'), action: tr('Use'));
      if (typed == null || !mounted) return;
      final u = cleanUnit(typed);
      if (u == null) return showToast(context, tr('A unit is a short word in letters, like roll or sheet (up to 12).'));
      return setState(() {
        if (!_customUnits.contains(u)) _customUnits.add(u);
        _size = null;
        _setUnit(u);
      });
    }
    setState(() {
      if (picked.startsWith('size:')) {
        _size = picked.substring(5);
        _setUnit('pc');
      } else {
        _size = null;
        _setUnit(picked);
      }
    });
  }

  String get _unitLabel => _size != null ? '${tr('Size')} $_size · pc' : unitName(_unit);

  @override
  void dispose() {
    for (final c in [_name, _barcode, _cost, _mrp, _price, _qty, _category, _markup]) {
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

  void _nameChanged(String v) => setState(() {});

  /// Barcode first: a pack OneLocal already knows brings its subcategory, brand, size and SKU (and its name when none is typed).
  Future<void> _barcodeChanged() async {
    final code = _barcode.text.trim();
    final mine = ++_lookupSeq;
    if (!RegExp(r'^[0-9]{8,14}$').hasMatch(code)) {
      if (_matched != null) setState(() => _matched = null);
      return;
    }
    try {
      final m = await widget.skus.lookup(code);
      if (!mounted || mine != _lookupSeq) return;
      setState(() {
        _matched = m;
        if (m != null) {
          _basis = PriceBasis.mrp;
          _basisTouched = true;
          if (_name.text.trim().isEmpty) _name.text = ItemNameFormatter.clean(m.name);
        }
      });
    } catch (_) {} // not found or offline: the SKU is chosen by hand
  }

  String? _problem() {
    if (_name.text.trim().length < 2) return 'Enter the product name.';
    if (_priceMinor == null) return 'Enter the selling price.';
    if (_basis == PriceBasis.mrp && _mrpMinor != null && _priceMinor! > _mrpMinor!) return 'The price cannot be above the MRP.';
    if (_qty.text.trim().isNotEmpty && (_stock == null || _stock! < 0)) return 'Enter how many you have, or leave it blank.';
    return skuProblem(_parts);
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
    if (code != null && code.trim().isNotEmpty && mounted) {
      setState(() => _barcode.text = code.trim());
      _barcodeChanged();
    }
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
    final CatItem made;
    try {
      made = await _saveOnce();
    } on CatalogueApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
      return;
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not add the product. Try again.';
        });
      }
      return;
    }
    await _after(made);
  }

  Future<CatItem> _saveOnce() => widget.api.save({
        'mode': 'quick',
        'name': titleCase(_name.text),
        // the database makes the SKU from these, never from the name
        'sku_parts': _parts!.toJson(),
        'price_minor': _priceMinor,
        'price_basis': _basis.name,
        // store-based: no printed MRP; the database keeps the selling price as the MRP
        if (_basis == PriceBasis.mrp) 'mrp_minor': ?_mrpMinor,
        'cost_minor': ?_costMinor,
        if (!_makeCode && _barcode.text.trim().isNotEmpty) 'barcode': _barcode.text.trim(),
        'selling_unit': _unit,
        if (_size != null) 'unit_description': sizeNote(_size!),
        if (_category.text.trim().isNotEmpty) 'category': _category.text.trim(),
      }, key: _key);

  /// The photo, stock and supplier of the saved product.
  Future<void> _after(CatItem item) async {
    final missed = <String>[];
    if (_makeCode) {
      try {
        final bc = await widget.barcodes.make(item.id);
        item = CatItem({...item.raw, 'barcode': bc.barcode, 'barcode_source': bc.barcodeSource ?? 'generated', 'has_barcode': true});
        if (_labels > 0) {
          try {
            await printBarcodeLabels([(itemLabel(bc), _labels)]);
          } catch (_) {
            missed.add('the label could not be printed (print it from Barcodes)');
          }
        }
      } catch (e) {
        missed.add(e is PartnerApiException ? e.message : 'the barcode could not be made (make it from Barcodes)');
      }
    }
    final inv = item.raw['inventory_item_id']?.toString();
    if (_photo != null) {
      try {
        await widget.photos.attach(item.id, _photo!);
      } catch (e) {
        missed.add(e is ItemPhotoUnavailable ? e.message : 'the photo could not be saved');
      }
    }
    // a new OneLocal product (its barcode, brand, unit, SKU) waits for Master review with its photo; approved, other stores list from it
    if (_photo != null && _basis == PriceBasis.mrp && _matched == null && _barcode.text.trim().isNotEmpty && !missed.any((m) => m.contains('photo'))) {
      try {
        await widget.media.offer(item.id);
      } catch (_) {} // it can be offered again from Product photos
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
              _skuCard(),
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

  /// "Store barcode · made when you save", how many labels to print, and a way back to typing one.
  Widget _storeCodeBox() => Container(
        key: const ValueKey('quick-store-code'),
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
        decoration: BoxDecoration(color: const Color(0xFFF1FAE8), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFCDEFA8))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(LucideIcons.barcode, size: 18, color: kInk),
            const SizedBox(width: 8),
            Expanded(child: Text(tr('Store barcode · made when you save'), style: inter(14, 700))),
            IconButton(
              key: const ValueKey('quick-make-code-undo'),
              tooltip: tr('Scan or type a barcode instead'),
              onPressed: _busy ? null : () => setState(() => _makeCode = false),
              icon: const Icon(LucideIcons.x, size: 18, color: kMuted),
            ),
          ]),
          Text(tr('A 200… code for this store only, so it scans at the Bill and in purchases.'), style: inter(12, 500, color: kMuted, height: 1.35)),
          const Padding(padding: EdgeInsets.fromLTRB(0, 10, 8, 10), child: Divider(height: 1, color: Color(0xFFCDEFA8))),
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 4),
            child: LabelCountStepper(
              key: const ValueKey('quick-labels'),
              keyPrefix: 'quick-labels',
              value: _labels,
              enabled: !_busy,
              hint: _labels == 0 ? 'No label: print it later from Barcodes.' : 'Printed as soon as the product is saved.',
              onChanged: (v) => setState(() => _labels = v),
            ),
          ),
        ]),
      );

  /// The SKU: subcategory, brand / item code and size; made by the system, never typed.
  Widget _skuCard() => _card([
        Text(tr('SKU'), style: inter(12.5, 700, color: kMuted)),
        const SizedBox(height: 6),
        SkuPicker(
          key: const ValueKey('quick-sku'),
          api: widget.skus,
          basis: _basis,
          matched: _matched,
          barcode: _barcode.text.trim().isEmpty ? null : _barcode.text.trim(),
          onChanged: (p) => setState(() => _parts = p),
        ),
      ]);

  /// Photo, name and barcode.
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
              InvInput(key: const ValueKey('quick-name'), controller: _name, hint: tr('For example PARLE-G'), formatters: itemNameFormatters, onChanged: _nameChanged),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${tr('Capital letters, up to')} $kItemNameMax · ${_name.text.length}/$kItemNameMax', key: const ValueKey('quick-name-count'), style: inter(11.5, 500, color: kMuted)),
              ),
            ]),
          ),
        ]),
        _label(tr('Barcode')),
        if (_makeCode)
          _storeCodeBox()
        else ...[
          InvInput(
            key: const ValueKey('quick-barcode'),
            controller: _barcode,
            hint: tr('Scan or type'),
            prefixIcon: LucideIcons.barcode,
            onChanged: (_) {
              setState(() {});
              _barcodeChanged();
            },
            suffix: IconButton(key: const ValueKey('quick-scan'), tooltip: tr('Scan a barcode'), onPressed: _busy ? null : _scan, icon: const Icon(LucideIcons.scanBarcode, size: 20, color: kInk)),
          ),
          // no barcode on the pack (loose or homemade goods): the store makes its own
          if (_barcode.text.trim().isEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('quick-make-code'),
                onPressed: _busy ? null : () => setState(() => _makeCode = true),
                icon: const Icon(LucideIcons.wandSparkles, size: 16, color: kLink),
                label: Text(tr('No barcode? Make a store barcode'), style: inter(13.5, 700, color: kLink)),
              ),
            ),
        ],
        if (_category.text.isNotEmpty && widget.category != null) ...[
          const SizedBox(height: 10),
          Align(alignment: Alignment.centerLeft, child: InvDotChip('Category: ${widget.category}', bg: kLimeSoftH, fg: kInk)),
        ] else ...[
          _label(tr('Category')),
          InvPickBox(
            key: const ValueKey('quick-category'),
            value: _category.text.trim().isEmpty ? tr('Choose a category (optional)') : _category.text.trim(),
            semantic: 'Category',
            onTap: _busy ? null : _pickCategory,
          ),
        ],
        // the units (and sizes) that fit the category
        _label(unitsFor(_category.text).sizes.isEmpty ? tr('Unit') : tr('Size or unit')),
        InvPickBox(key: const ValueKey('quick-unit'), value: _unitLabel, semantic: 'Unit', onTap: _busy ? null : _pickUnit),
      ]);

  /// Cost · MRP · Price side by side, coloured like Item → Stock: price = MRP green, below yellow, above red; margin below 5% red.
  void _setBasis(PriceBasis b) => setState(() {
        _basis = b;
        _basisTouched = true;
        _syncMarkup();
      });

  /// MRP-based: the selling price starts at the MRP until it is typed.
  void _mrpChanged() {
    if (!_priceTouched) _price.text = _mrp.text;
    _syncMarkup();
  }

  /// Store-based: cost + markup % sets the price; a typed price shows its markup.
  void _markupChanged() {
    final cost = num.tryParse(_cost.text.trim()), pct = num.tryParse(_markup.text.trim());
    if (cost != null && cost > 0 && pct != null) {
      final v = priceFromMarkup(cost, pct);
      _price.text = v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);
      _priceTouched = true;
    }
  }

  void _syncMarkup() {
    final m = markupPct(num.tryParse(_cost.text.trim()), num.tryParse(_price.text.trim()));
    _markup.text = m == null ? '' : pctText(m);
  }

  Widget _prices() {
    final store = _basis == PriceBasis.store;
    final tone = store ? null : UpdateStockScreenTones.tone(_priceMinor, _mrpMinor);
    final margin = UpdateStockScreenTones.margin(_priceMinor, _costMinor);
    Widget box(String label, TextEditingController c, String key, {(Color, Color, String)? colour, String unit = '₹', bool after = false, ValueChanged<String>? onChanged}) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr(label), style: inter(12.5, 700, color: kMuted)),
            const SizedBox(height: 6),
            Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(color: colour?.$1 ?? Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: colour?.$2 ?? const Color(0xFFD9DBD5), width: colour == null ? 1 : 1.4)),
              child: Row(children: [
                if (!after) ...[Text(unit, style: inter(15, 600, color: kMuted)), const SizedBox(width: 4)],
                Expanded(
                  child: TextField(
                    key: ValueKey(key),
                    controller: c,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (v) => setState(() => onChanged?.call(v)),
                    style: inter(15, 700),
                    decoration: const InputDecoration.collapsed(hintText: '0'),
                  ),
                ),
                if (after) Text(unit, style: inter(15, 600, color: kMuted)),
              ]),
            ),
          ]),
        );
    return _card([
      Text(tr('How is it priced?'), style: inter(12.5, 700, color: kMuted)),
      const SizedBox(height: 6),
      PriceBasisPicker(key: const ValueKey('quick-basis'), value: _basis, onChanged: _busy ? null : _setBasis, keyPrefix: 'quick-basis'),
      const SizedBox(height: 12),
      Row(children: [
        box('Cost', _cost, 'quick-cost', onChanged: (_) => store && _markup.text.trim().isNotEmpty ? _markupChanged() : _syncMarkup()),
        const SizedBox(width: 8),
        if (store)
          box('Markup', _markup, 'quick-markup', unit: '%', after: true, onChanged: (_) => _markupChanged())
        else
          box('MRP', _mrp, 'quick-mrp', onChanged: (_) => _mrpChanged()),
        const SizedBox(width: 8),
        box(store ? 'Selling price' : 'Price', _price, 'quick-price', colour: tone, onChanged: (_) {
          _priceTouched = true;
          _syncMarkup();
        }),
      ]),
      if (store)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(tr('No printed MRP: this price is used as the MRP.'), style: inter(11.5, 500, color: kMuted)),
        ),
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
