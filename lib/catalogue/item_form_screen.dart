import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../ui/barcode_scanner.dart';
import '../ui/theme.dart';
import 'catalogue_api.dart';
import 'catalogue_format.dart';
import 'catalogue_widgets.dart';
import 'item_photo.dart';
import '../media/media_api.dart';
import '../media/product_photos_screen.dart' show pickStandardPhoto;
import 'item_sheets.dart' show parsePriceMinor;
import '../ui/i18n.dart';

/// Figma "Item Creation" (Store Standard / Screens): identity, units and storage, tax and pricing, then a save checklist.
/// Also used to change an existing item (Quick edit, Edit catalogue details): [item] pre-fills the form and carries its version.
/// The screen only collects and sends; the database decides what is valid (tax needed to save, price not above MRP, unique SKU and barcode).
class ItemFormScreen extends StatefulWidget {
  const ItemFormScreen({super.key, this.api, this.item, this.onNavigate, this.photos = const DeviceItemPhotos(), this.scan = scanBarcode, this.barcode, this.media});
  final CatalogueApi? api;
  final CatItem? item;
  final ValueChanged<String>? onNavigate;

  /// A new product's barcode, already known (a scanned code no product has yet).
  final String? barcode;

  /// Choosing the product photo, removing its background, attaching it to the saved item.
  final ItemPhotoService photos;

  /// The Standard pool of approved photos (30 Oct 2026); null: the live one.
  final MediaApi? media;

  /// The barcode field's scan button: opens the camera and answers the code read (null when closed).
  final Future<String?> Function(BuildContext) scan;
  @override
  State<ItemFormScreen> createState() => _ItemFormScreenState();
}

class _ItemFormScreenState extends State<ItemFormScreen> {
  late final CatalogueApi _api = widget.api ?? CatalogueApi();
  final _name = TextEditingController(), _sku = TextEditingController(), _category = TextEditingController(), _brand = TextEditingController(), _barcode = TextEditingController();
  final _netQty = TextEditingController(), _packUnits = TextEditingController(text: '1'), _hsn = TextEditingController();
  final _cost = TextEditingController(), _price = TextEditingController(), _mrp = TextEditingController();
  final _keyIdentity = GlobalKey(), _keyUnits = GlobalKey(), _keyPricing = GlobalKey(), _keyReview = GlobalKey();
  ItemPhoto? _photo; // a new photo picked here, put on the item when it is saved
  late String? _savedUrl = widget.item?.imageUrl; // the photo the item already has
  bool _dropSaved = false; // "Remove photo" on the saved one: taken off when the item is saved
  bool _photoBusy = false;
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
    } else if (widget.barcode != null) {
      _barcode.text = widget.barcode!;
    }
    for (final c in [_name, _sku, _category, _barcode, _netQty, _hsn, _cost, _price, _mrp]) {
      c.addListener(() => setState(() {}));
    }
    _scroll.addListener(_followScroll);
  }

  @override
  void dispose() {
    for (final c in [_name, _sku, _category, _brand, _barcode, _netQty, _packUnits, _hsn, _cost, _price, _mrp]) {
      c.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- steps that follow the scroll
  final _scroll = ScrollController();
  final _formKey = GlobalKey();
  final _chipKeys = List.generate(4, (_) => GlobalKey());
  int _active = 0;
  bool _jumping = false;
  List<GlobalKey> get _sections => [_keyIdentity, _keyUnits, _keyPricing, _keyReview];

  /// The current step is the last section whose top has reached the top of the form (the end of the form counts as the last).
  void _followScroll() {
    if (_jumping) return;
    final form = _formKey.currentContext?.findRenderObject() as RenderBox?;
    if (form == null || !form.attached) return;
    final top = form.localToGlobal(Offset.zero).dy;
    var at = 0;
    for (var i = 0; i < _sections.length; i++) {
      final box = _sections[i].currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.attached && box.localToGlobal(Offset.zero).dy - top <= 72) at = i;
    }
    final p = _scroll.position;
    if (p.pixels >= p.maxScrollExtent - 4 && p.maxScrollExtent > 0) at = _sections.length - 1;
    _setActive(at);
  }

  void _setActive(int i) {
    if (i == _active) return;
    setState(() => _active = i);
    // keep the current step's chip in view in the row
    final chip = _chipKeys[i].currentContext;
    if (chip != null) Scrollable.ensureVisible(chip, duration: const Duration(milliseconds: 200), alignment: 0.5);
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

  /// A tap on a step: highlight it now, then scroll its section to the top (the scroll does not move the highlight meanwhile).
  Future<void> _goto(GlobalKey k) async {
    _setActive(_sections.indexOf(k));
    final c = k.currentContext;
    if (c == null) return;
    _jumping = true;
    await Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 250), alignment: 0.02);
    _jumping = false;
  }

  String? _nullIfBlank(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save({required bool draft}) async {
    final price = parsePriceMinor(_price.text);
    if (_name.text.trim().isEmpty) return showToast(context, tr('Enter the product name.'));
    if (_sku.text.trim().isEmpty) return showToast(context, 'Enter the System Code.');
    if (price == null) return showToast(context, tr('Enter the selling price.'));
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
      // The photo goes on (or comes off) once the item exists; when that fails the item is still saved, and the toast says why.
      String? photoNote;
      try {
        if (_photo != null) {
          await widget.photos.attach(saved.id, _photo!);
        } else if (_dropSaved) {
          await widget.photos.remove(saved.id);
        }
      } catch (e) {
        photoNote = e is ItemPhotoUnavailable ? e.message : 'The photo could not be saved.';
      }
      if (!mounted) return;
      final done = draft ? '${saved.name} saved as a draft.' : '${saved.name} saved.';
      showToast(context, photoNote == null ? done : '$done $photoNote');
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

  // ---------------------------------------------------------------- photo
  Future<void> _pickPhoto() async {
    try {
      final p = await widget.photos.capture(context);
      if (p != null && mounted) setState(() => _photo = p);
    } catch (e) {
      if (mounted) showToast(context, e is ItemPhotoUnavailable ? e.message : 'That photo could not be opened.');
    }
  }

  Future<void> _removeBackground() async {
    final p = _photo;
    if (p == null) return;
    setState(() => _photoBusy = true);
    try {
      final clean = await widget.photos.removeBackground(p);
      if (mounted) setState(() => _photo = clean);
    } catch (e) {
      if (mounted) showToast(context, e is ItemPhotoUnavailable ? e.message : 'The background could not be removed.');
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  /// A photo OneLocal approved for this product (Standard pool), put on the saved item at once.
  Future<void> _standardPhoto() async {
    final item = widget.item;
    if (item == null) return;
    final url = await pickStandardPhoto(context, widget.media ?? MediaApi(), itemId: item.id, itemName: _name.text.trim().isEmpty ? item.name : _name.text.trim());
    if (url == null || !mounted) return;
    setState(() {
      _savedUrl = url;
      _photo = null;
      _dropSaved = false;
    });
    showToast(context, 'Standard photo put on the item.');
  }

  Widget _standardLink() => widget.item == null
      ? const SizedBox.shrink()
      : _smallAction(LucideIcons.images, 'Use a standard photo', _photoBusy ? null : _standardPhoto, const ValueKey('item-photo-standard'));

  Widget _photoBox() {
    final p = _photo, saved = _savedUrl;
    Widget frame(Widget image) => Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(color: kSoftField, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFDADCD5))),
          clipBehavior: Clip.antiAlias,
          child: image,
        );
    const broken = Icon(LucideIcons.imageOff, color: kMuted);
    if (p == null && saved != null) {
      // The photo this item already has: replace it or take it off (background removal needs the original file, so not here).
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        frame(Image.network(saved, key: const ValueKey('item-photo-saved'), fit: BoxFit.contain, errorBuilder: (_, _, _) => broken)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _smallAction(LucideIcons.refreshCw, 'Replace photo', _pickPhoto, const ValueKey('item-photo-replace')),
            _standardLink(),
            _smallAction(LucideIcons.trash2, 'Remove photo', () => setState(() {
              _savedUrl = null;
              _dropSaved = true;
            }), const ValueKey('item-photo-remove'), danger: true),
          ]),
        ),
      ]);
    }
    if (p == null) {
      if (widget.item == null) return AddPhotoBox(key: const ValueKey('item-photo-add'), onTap: _pickPhoto);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [AddPhotoBox(key: const ValueKey('item-photo-add'), onTap: _pickPhoto), _standardLink()]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      frame(Image.memory(p.bytes, fit: BoxFit.contain, errorBuilder: (_, _, _) => broken)),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (p.backgroundRemoved) const Padding(padding: EdgeInsets.only(bottom: 6), child: DotChip('Background removed', bg: kSoftField, fg: kMuted)),
          _smallAction(LucideIcons.sparkles, _photoBusy ? 'Removing background…' : 'Remove background (AI)', _photoBusy || p.backgroundRemoved ? null : _removeBackground, const ValueKey('item-photo-bg')),
          _smallAction(LucideIcons.refreshCw, 'Replace photo', _photoBusy ? null : _pickPhoto, const ValueKey('item-photo-replace')),
          _smallAction(LucideIcons.trash2, 'Remove photo', _photoBusy ? null : () => setState(() => _photo = null), const ValueKey('item-photo-remove'), danger: true),
        ]),
      ),
    ]);
  }

  Widget _smallAction(IconData icon, String label, VoidCallback? onTap, Key key, {bool danger = false}) => InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Icon(icon, size: 16, color: onTap == null ? kMuted : danger ? kError : kLink),
            const SizedBox(width: 8),
            Text(label, style: inter(13, 600, color: onTap == null ? kMuted : danger ? kError : kLink)),
          ]),
        ),
      );

  // ---------------------------------------------------------------- pieces
  /// One numbered section: a number badge (a tick once its required fields are filled), the title, a line on what it is for.
  Widget _section(Key? key, int n, String title, String hint, bool done, List<Widget> children) => Container(
        key: key,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE3E5DF))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            _badge(n, done),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: inter(16, 700)),
                Text(hint, style: inter(12, 400, color: kMuted)),
              ]),
            ),
          ]),
          const SizedBox(height: 6),
          ...children,
        ]),
      );

  Widget _badge(int n, bool done, {double size = 26}) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: done ? kLime : kSoftField, shape: BoxShape.circle),
        child: done ? Icon(LucideIcons.check, size: size * 0.55, color: kDark) : Text('$n', style: inter(12, 700, color: kMuted)),
      );

  Widget _label(String t) => Padding(padding: const EdgeInsets.only(top: 12, bottom: 6), child: Text(t, style: inter(13, 600, color: kMuted)));

  /// A label over its field, so two can sit side by side.
  Widget _field(String label, Widget field) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_label(label), field]);

  Widget _pair(Widget a, Widget b) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: a), const SizedBox(width: 10), Expanded(child: b)]);

  BoxDecoration _box(bool bad) =>
      BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: bad ? kError : const Color(0xFFDADCD5), width: bad ? 1.5 : 1));

  Widget _input(TextEditingController c, String hint, {TextInputType? type, List<TextInputFormatter>? formatters, bool bad = false, Widget? trailing}) => Container(
        height: 46,
        padding: EdgeInsets.only(left: 12, right: trailing == null ? 12 : 4),
        alignment: Alignment.centerLeft,
        decoration: _box(bad),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: c,
              keyboardType: type,
              inputFormatters: formatters,
              style: inter(14, 400),
              decoration: plainInput.copyWith(hintText: hint, hintStyle: inter(14, 400, color: bad ? kError : kMuted)),
            ),
          ),
          ?trailing,
        ]),
      );

  // ---------------------------------------------------------------- barcode scan
  Future<void> _scanBarcode() async {
    final code = await widget.scan(context);
    if (code == null || code.isEmpty || !mounted) return;
    setState(() => _barcode.text = code);
    showToast(context, 'Barcode $code added.');
  }

  Widget _scanButton() => IconButton(
        key: const ValueKey('item-barcode-scan'),
        tooltip: tr('Scan barcode with camera'),
        onPressed: _busy ? null : _scanBarcode,
        style: IconButton.styleFrom(backgroundColor: kDark, minimumSize: const Size(38, 38), fixedSize: const Size(38, 38), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
        icon: const Icon(LucideIcons.scanBarcode, size: 20, color: Color(0xFFA1FE2F)),
      );

  Widget _dropdown<T>({required T? value, required List<(T, String)> items, required ValueChanged<T?> onChanged, String hint = 'Select', bool bad = false}) => Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: _box(bad),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            isExpanded: true,
            icon: const Icon(LucideIcons.chevronDown, size: 16, color: kMuted),
            hint: Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 400, color: bad ? kError : kMuted)),
            style: inter(14, 400),
            items: [for (final (v, l) in items) DropdownMenuItem<T>(value: v, child: Text(l, maxLines: 1, overflow: TextOverflow.ellipsis))],
            onChanged: onChanged,
          ),
        ),
      );

  Widget _kv(String k, String v, {Color vc = kInk}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [Expanded(child: Text(k, style: inter(13, 400, color: kMuted))), Text(v, style: inter(14, 700, color: vc))]),
      );

  Widget _check(bool done, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(done ? LucideIcons.circleCheck : LucideIcons.circle, size: 18, color: done ? kLink : kMuted),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: inter(13, done ? 600 : 400, color: done ? kInk : kMuted))),
        ]),
      );

  static final _money = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))];
  static const _decimal = TextInputType.numberWithOptions(decimal: true);

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
    // Which sections have their required fields filled (the steps tick off as the person goes).
    final identityDone = _name.text.trim().isNotEmpty && _sku.text.trim().isNotEmpty && _category.text.trim().isNotEmpty && _barcode.text.trim().isNotEmpty;
    final unitsDone = netQty != null && num.tryParse(_packUnits.text.trim()) != null;
    final pricingDone = !taxOpen && price != null;
    final title = _editing ? 'Edit Item' : 'Item Creation';
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        OrdersTopBar(title: tr('Item'), onBack: () => Navigator.of(context).maybePop()),
        // The steps stay in view: where you are, what is done, a tap jumps to it.
        Container(
          color: kBg,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final (i, label, done) in [
                (0, 'Product', identityDone),
                (1, 'Units', unitsDone),
                (2, 'Tax & price', pricingDone),
                (3, 'Review', identityDone && unitsDone && pricingDone),
              ])
                _StepChip(i + 1, label, done, _active == i, () => _goto(_sections[i]), _badge, key: _chipKeys[i]),
            ]),
          ),
        ),
        // One scrolling column (every section is built, so a step can always jump to it and the scroll can tell where you are).
        Expanded(
          child: SingleChildScrollView(
            key: _formKey,
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: inter(22, 800)),
            const SizedBox(height: 4),
            Text(_editing ? 'Change this catalogue item. Stock is not changed here.' : 'Prepare a new catalogue item without changing live stock.', style: inter(13, 400, color: kMuted)),
            const SizedBox(height: 2),
            Text(_editing ? '${widget.item!.sku} · ${statusLabel(widget.item!)} · Tax ${widget.item!.taxVerified ? 'verified' : 'not verified'}' : 'New item · Unsaved draft · Tax validation required', style: inter(12, 600, color: kMuted)),
            const SizedBox(height: 14),
            _section(_keyIdentity, 1, 'Item identity', 'Photo, name and the codes that find this product', identityDone, [
              const SizedBox(height: 6),
              _photoBox(),
              _field('Product name *', _input(_name, 'Product name')),
              _field('System Code *', _input(_sku, 'Unique System Code, for example OC-200-PK')),
              _pair(_field('Category *', _input(_category, 'Snacks')), _field('Brand', _input(_brand, 'Add brand'))),
              _field('Barcode *', _input(_barcode, 'Scan or type the barcode', trailing: _scanButton())),
              const SizedBox(height: 6),
              Text(_barcode.text.trim().isEmpty ? 'Without a barcode this item cannot be found by scan.' : 'Identifier has no saved catalogue link. Confirm uniqueness again when saving.',
                  style: inter(12, 400, color: kMuted, height: 1.35)),
            ]),
            _section(_keyUnits, 2, 'Units & storage', 'How it is sold, packed and kept', unitsDone, [
              _pair(
                _field('Selling unit *', _dropdown<String>(value: _unit, items: sellingUnits, onChanged: (v) => setState(() => _unit = v ?? 'pc'))),
                _field('Storage', _dropdown<String>(value: _storage.isEmpty ? null : _storage, items: [for (final s in _storages) (s, s)], hint: 'Dry shelf', onChanged: (v) => setState(() => _storage = v ?? ''))),
              ),
              _label(tr('Net quantity *')),
              Row(children: [
                Expanded(flex: 3, child: _input(_netQty, '200', type: _decimal, formatters: _money)),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: _dropdown<String>(value: _netUnit, items: [for (final u in netUnits) (u, u)], onChanged: (v) => setState(() => _netUnit = v ?? 'g'))),
              ]),
              _label('Purchase-to-sale conversion *'),
              Row(children: [
                Text('1 pack =', style: inter(14, 400)),
                const SizedBox(width: 10),
                SizedBox(width: 84, child: _input(_packUnits, '1', type: _decimal, formatters: _money)),
                const SizedBox(width: 10),
                Text(tr('selling unit'), style: inter(14, 400)),
              ]),
              const SizedBox(height: 6),
              _kv('Opening stock', 'Not added · 0 units'),
            ]),
            _section(_keyPricing, 3, 'Tax & pricing', taxOpen ? 'Draft pricing · Not effective until tax is set' : 'Tax details entered', pricingDone, [
              _pair(
                _field('HSN / tax category *',
                    _input(_hsn, 'Tax category', bad: taxOpen && _hsn.text.trim().isEmpty && _error != null, type: TextInputType.number, formatters: [FilteringTextInputFormatter.digitsOnly])),
                _field('GST rate *',
                    _dropdown<num>(value: _gst, items: [for (final g in gstSlabs) (g, '${qty(g)}%')], hint: tr('Required'), bad: _gst == null && _error != null, onChanged: (v) => setState(() => _gst = v))),
              ),
              _pair(_field('Purchase cost · ex tax (₹)', _input(_cost, '₹24.00', type: _decimal, formatters: _money)), _field('MRP (₹)', _input(_mrp, '₹45.00', type: _decimal, formatters: _money))),
              _field('Selling price · tax inclusive (₹) *', _input(_price, '₹40.00', type: _decimal, formatters: _money)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(color: kSoftField, borderRadius: BorderRadius.circular(12)),
                child: Column(children: [_kv('Unit selling price', unitPrice ?? '—'), _kv('Margin', margin)]),
              ),
            ]),
            if (_error != null && _bannerOpen)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
                decoration: BoxDecoration(color: kBadBg, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE9908A))),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Padding(padding: EdgeInsets.only(top: 1), child: Icon(LucideIcons.circleX, size: 20, color: kBadText)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_errorTitle ?? 'Could not save the item', style: inter(14, 700)),
                      const SizedBox(height: 2),
                      Text(_error!, style: inter(13, 400, color: const Color(0xFF9A6B68), height: 1.35)),
                    ]),
                  ),
                  IconButton(tooltip: tr('Dismiss'), onPressed: () => setState(() => _bannerOpen = false), icon: const Icon(LucideIcons.x, size: 16, color: kMuted)),
                ]),
              ),
            _section(_keyReview, 4, 'Save checklist', 'What is still needed before this item can be sold', identityDone && unitsDone && pricingDone, [
              const SizedBox(height: 4),
              _check(_name.text.trim().isNotEmpty && _category.text.trim().isNotEmpty && _sku.text.trim().isNotEmpty, 'Name, category and System Code completed'),
              _check(_barcode.text.trim().isNotEmpty, 'Barcode entered'),
              _check(mrp != null && cost != null && !taxOpen, 'Verify pack MRP, cost and tax'),
              _check(_photo != null || _savedUrl != null, 'Product photo added (optional)'),
              _check(_editing, 'Save item before receiving or printing labels'),
            ]),
            Text(tr('A draft is not sold and does not change stock. Stock is received in Stock.'), style: inter(12, 400, color: kMuted, height: 1.35)),
          ]),
          ),
        ),
        // Save stays in reach wherever the person is on the form.
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Color(0xFFE3E5DF)))),
          child: Row(children: [
            Expanded(child: OutlineButton(tr('Save draft only'), onPressed: _busy ? null : () => _save(draft: true), height: 48)),
            const SizedBox(width: 10),
            Expanded(child: DarkButton(tr('Save item'), busy: _busy, onPressed: () => _save(draft: false))),
          ]),
        ),
        PosBottomNav(active: 'item', onTap: _tab),
      ]),
    );
  }
}

/// A step of the form at the top: its number (a tick when done), its name; a tap scrolls to it.
/// A step of the form at the top. [current] (the section on screen) is the dark chip; [done] shows a tick in its badge.
class _StepChip extends StatelessWidget {
  const _StepChip(this.n, this.label, this.done, this.current, this.onTap, this.badge, {super.key});
  final int n;
  final String label;
  final bool done, current;
  final VoidCallback onTap;
  final Widget Function(int n, bool done, {double size}) badge;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Semantics(
          button: true,
          selected: current,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
              decoration: BoxDecoration(
                color: current ? kDark : Colors.white,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: current ? kDark : done ? kLime : const Color(0xFFE3E5DF)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (current && !done)
                  Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: kLime, shape: BoxShape.circle),
                    child: Text('$n', style: inter(12, 700, color: kDark)),
                  )
                else
                  badge(n, done, size: 22),
                const SizedBox(width: 6),
                Text(label, style: inter(13, current ? 700 : 600, color: current ? Colors.white : kInk)),
              ]),
            ),
          ),
        ),
      );
}
