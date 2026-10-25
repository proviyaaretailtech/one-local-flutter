import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_nav.dart';
import '../orders/order_widgets.dart';
import '../ui/barcode_scanner.dart';
import '../ui/theme.dart';
import 'catalogue_api.dart';
import 'catalogue_format.dart';
import 'catalogue_widgets.dart';
import 'item_photo.dart';

/// "5" / "5.5" / "₹5.50" typed by a person, as paise. Null when it is not a price. This only reads what was typed; the database checks the value.
int? parsePriceMinor(String text) {
  final t = text.replaceAll('₹', '').replaceAll(',', '').trim();
  if (!RegExp(r'^\d{1,9}(\.\d{1,2})?$').hasMatch(t)) return null;
  final parts = t.split('.');
  final paise = parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0;
  return int.parse(parts[0]) * 100 + paise;
}

// ---------------------------------------------------------------- About this product (tap an item)
Future<void> showAbout(BuildContext context, CatItem item, {required VoidCallback onOpen}) {
  // The product first (name, SKU when it has one), then its facts as label / value rows in one card, then the action.
  Widget fact(String k, String v, {bool strong = false}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          Text(k, style: inter(13, 400, color: kMuted)),
          const SizedBox(width: 12),
          Expanded(child: Text(v, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(strong ? 16 : 14, strong ? 700 : 600))),
        ]),
      );
  return showCatSheet<void>(
    context,
    title: 'About this product',
    body: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: kSoftField, borderRadius: BorderRadius.circular(12)),
          child: const Icon(LucideIcons.package, size: 22, color: kMuted),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.name, style: inter(16, 700), maxLines: 2, overflow: TextOverflow.ellipsis),
            if (item.sku.isNotEmpty) Text('System Code ${item.sku}', style: inter(12, 400, color: kMuted)),
          ]),
        ),
      ]),
      const SizedBox(height: 14),
      Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE3E5DF))),
        child: Column(children: [
          fact('Selling price', money(item.priceMinor), strong: true),
          const Divider(height: 1, color: Color(0xFFF1F2EE)),
          fact('Category', item.category.isEmpty ? 'Not set' : item.category),
          const Divider(height: 1, color: Color(0xFFF1F2EE)),
          fact('Pack size', packSize(item) == '—' ? 'Not set' : packSize(item)),
        ]),
      ),
      const SizedBox(height: 10),
      Row(children: [
        const Icon(LucideIcons.info, size: 14, color: kMuted),
        const SizedBox(width: 6),
        Expanded(child: Text('Check the pack and System Code before selecting.', style: inter(12, 400, color: kMuted))),
      ]),
      const SizedBox(height: 16),
      DarkButton('View product details', onPressed: () {
        Navigator.of(ctx).pop();
        onOpen();
      }),
    ]),
  );
}

// ---------------------------------------------------------------- Detail drawer
/// Returns the item when the person taps "Edit catalogue details".
Future<CatItem?> showDetailDrawer(BuildContext context, CatalogueApi api, CatItem item) {
  return showModalBottomSheet<CatItem>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _DetailDrawer(api: api, item: item),
  );
}

class _DetailDrawer extends StatefulWidget {
  const _DetailDrawer({required this.api, required this.item});
  final CatalogueApi api;
  final CatItem item;
  @override
  State<_DetailDrawer> createState() => _DetailDrawerState();
}

class _DetailDrawerState extends State<_DetailDrawer> {
  late CatItem _item = widget.item;

  @override
  void initState() {
    super.initState();
    widget.api.get(widget.item.id).then((fresh) {
      if (mounted) setState(() => _item = fresh);
    }).catchError((_) {});
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(k, style: inter(17, 400, color: kMuted)),
          const SizedBox(width: 16),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: inter(17, 700))),
        ]),
      );

  /// "Stock movements": opens the product's movements in Stock (every sale, delivery and correction) on top of these details, when it
  /// has a stock record; Back comes back here.
  Widget _movementsLink(BuildContext sheet, CatItem i) {
    final inv = (i.raw['inventory_item_id'] ?? '').toString();
    final open = HomeNav.stockPage;
    if (inv.isEmpty || open == null) return _row('Stock movements', inv.isEmpty ? 'No stock record' : '—');
    return InkWell(
      key: const ValueKey('item-stock-movements'),
      onTap: () => open(sheet, 'movements', itemId: inv),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          Text('Stock movements', style: inter(16, 400, color: kMuted)),
          const SizedBox(width: 16),
          Expanded(child: Text('View ›', textAlign: TextAlign.right, style: inter(17, 700, color: kLink))),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final i = _item;
    final stock = i.stockQty == null ? 'Not loaded' : '${qty(i.stockQty!)} ${unitShort(i.sellingUnit)}';
    return DraggableScrollableSheet(
      initialChildSize: 0.94,
      maxChildSize: 0.97,
      minChildSize: 0.5,
      expand: false,
      builder: (ctx, scroll) => Container(
        decoration: const BoxDecoration(color: kBg, borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
        child: SafeArea(
          top: false,
          child: ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(20, 16, 20, 20), children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 18, 16, 22),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(28)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(i.name, style: inter(26, 800)),
                      const SizedBox(height: 4),
                      Text('${i.sku} · ${i.category.isEmpty ? 'No category' : i.category}', style: inter(16, 400, color: kMuted)),
                    ]),
                  ),
                  IconButton(tooltip: 'Close', style: IconButton.styleFrom(backgroundColor: kSoftField), onPressed: () => Navigator.of(ctx).pop(), icon: const Icon(LucideIcons.x, size: 22)),
                ]),
                const Divider(height: 28, color: Color(0xFFE3E5DF)),
                const Kick('Catalogue record'),
                const SizedBox(height: 6),
                _row('Selling price', money(i.priceMinor)),
                _row('System Code', i.sku),
                _row('Category', i.category.isEmpty ? '—' : i.category),
                _row('Pack size', packSize(i)),
                const Divider(height: 28, color: Color(0xFFE3E5DF)),
                const Kick('Record information'),
                const SizedBox(height: 6),
                _row('Product name', i.name),
                _row('Record type', i.kind == 'combo' ? 'Combo' : 'Product'),
                _row('Price currency', i.currency),
                _row('Unit description', i.unitDescription ?? '—'),
                _row('Stock quantities', stock),
                _movementsLink(ctx, i),
              ]),
            ),
            const SizedBox(height: 16),
            Text('Catalogue details only. Inventory quantities and movement history are kept in Stock.', style: inter(16, 400, color: kMuted, height: 1.4)),
            const SizedBox(height: 16),
            Material(
              color: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0xFFE3E5DF))),
              child: InkWell(
                customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                onTap: () => showImageViewer(context, i),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Product image', style: inter(19, 700)),
                        const SizedBox(height: 3),
                        Text('View the existing catalogue photo', style: inter(15, 400, color: kMuted)),
                      ]),
                    ),
                    const Icon(LucideIcons.image, size: 26, color: kMuted),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 16),
            DarkButton('Edit catalogue details', onPressed: () => Navigator.of(ctx).pop(i), height: 60),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- image viewer
Future<void> showImageViewer(BuildContext context, CatItem item) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(item.name, style: inter(19, 700)),
          const SizedBox(height: 14),
          if (item.imageUrl != null && item.imageUrl!.isNotEmpty)
            ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.network(item.imageUrl!, height: 260, fit: BoxFit.contain, errorBuilder: (_, _, _) => _noPhoto()))
          else
            _noPhoto(),
          const SizedBox(height: 16),
          OutlineButton('Close', onPressed: () => Navigator.of(ctx).pop(), height: 48),
        ]),
      ),
    ),
  );
}

Widget _noPhoto() => Container(
      height: 160,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: kSoftField, borderRadius: BorderRadius.circular(16)),
      child: Text('No photo saved for this item yet.', style: inter(15, 400, color: kMuted)),
    );

// ---------------------------------------------------------------- Quick add product
/// [category]: the product goes into this category (made with the first product when it is new), shown at the top of the form.
Future<CatItem?> showQuickAdd(BuildContext context, CatalogueApi api, {ItemPhotoService photos = const DeviceItemPhotos(), String? category}) =>
    showDialog<CatItem>(context: context, builder: (_) => _QuickAdd(api: api, photos: photos, category: category));

class _QuickAdd extends StatefulWidget {
  const _QuickAdd({required this.api, required this.photos, this.category});
  final CatalogueApi api;
  final ItemPhotoService photos;
  final String? category;
  @override
  State<_QuickAdd> createState() => _QuickAddState();
}

class _QuickAddState extends State<_QuickAdd> {
  final _name = TextEditingController(), _sku = TextEditingController(), _price = TextEditingController();
  final _key = CatalogueApi.newKey(); // one key for this dialog: a retried tap never adds twice
  bool _busy = false;
  String? _error;
  ItemPhoto? _photo; // optional; goes on the item once it exists, like on Item creation

  bool get _ready => _name.text.trim().isNotEmpty && _sku.text.trim().isNotEmpty && parsePriceMinor(_price.text) != null;

  @override
  void dispose() {
    _name.dispose();
    _sku.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final item = await widget.api.save({'mode': 'quick', 'name': _name.text.trim(), 'sku': _sku.text.trim(), 'price_minor': parsePriceMinor(_price.text), 'category': ?widget.category}, key: _key);
      // The product is added either way; when the photo cannot be saved the toast says why.
      if (_photo != null) {
        try {
          await widget.photos.attach(item.id, _photo!);
        } catch (e) {
          if (mounted) showToast(context, '${item.name} added. ${e is ItemPhotoUnavailable ? e.message : 'The photo could not be saved.'}');
        }
      }
      if (mounted) Navigator.of(context).pop(item);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is CatalogueApiException ? e.message : 'Could not add the product. Try again.';
        });
      }
    }
  }

  Future<void> _pickPhoto() async {
    try {
      final p = await widget.photos.pick();
      if (p != null && mounted) setState(() => _photo = p);
    } catch (e) {
      if (mounted) showToast(context, e is ItemPhotoUnavailable ? e.message : 'That photo could not be opened.');
    }
  }

  Widget _photoField() {
    final p = _photo;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Product photo', style: inter(13, 600)),
      const SizedBox(height: 6),
      if (p == null)
        AddPhotoBox(key: const ValueKey('quick-photo-add'), onTap: _busy ? null : _pickPhoto, height: 110)
      else
        Row(children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: kSoftField, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFDADCD5))),
            clipBehavior: Clip.antiAlias,
            child: Image.memory(p.bytes, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Icon(LucideIcons.imageOff, color: kMuted)),
          ),
          const SizedBox(width: 12),
          TextButton.icon(
            key: const ValueKey('quick-photo-replace'),
            onPressed: _busy ? null : _pickPhoto,
            icon: const Icon(LucideIcons.refreshCw, size: 15, color: kInk),
            label: Text('Replace', style: inter(13, 600)),
          ),
          TextButton.icon(
            key: const ValueKey('quick-photo-remove'),
            onPressed: _busy ? null : () => setState(() => _photo = null),
            icon: const Icon(LucideIcons.trash2, size: 15, color: kError),
            label: Text('Remove', style: inter(13, 600, color: kError)),
          ),
        ]),
    ]);
  }

  Widget _field(String label, TextEditingController c, String hint, {TextInputType? type, List<TextInputFormatter>? formatters}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: inter(13, 600)),
        const SizedBox(height: 6),
        Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFDADCD5))),
          alignment: Alignment.centerLeft,
          child: TextField(
            controller: c,
            keyboardType: type,
            inputFormatters: formatters,
            onChanged: (_) => setState(() {}),
            style: inter(14, 400),
            decoration: plainInput.copyWith(hintText: hint, hintStyle: inter(14, 400, color: kMuted)),
          ),
        ),
      ]);

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: Colors.white,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('Quick add product', style: inter(20, 700))),
              IconButton(tooltip: 'Close', onPressed: () => Navigator.of(context).pop(), icon: const Icon(LucideIcons.x, size: 20, color: kMuted)),
            ]),
            Text('Create a catalogue record. Fill in all required fields to continue.', style: inter(13, 400, color: kMuted, height: 1.35)),
            const SizedBox(height: 14),
            Row(children: [Text('Record', style: inter(13, 400, color: kMuted)), const Spacer(), Text(widget.category == null ? 'New product' : 'Category: ${widget.category}', style: inter(13, 700))]),
            const SizedBox(height: 14),
            _field('Product name *', _name, 'Enter product name'),
            const SizedBox(height: 14),
            _field('System Code *', _sku, 'Enter unique System Code'),
            const SizedBox(height: 14),
            _field('Selling price (₹) *', _price, 'Enter price', type: const TextInputType.numberWithOptions(decimal: true), formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]),
            const SizedBox(height: 14),
            _photoField(),
            const SizedBox(height: 14),
            if (_error != null)
              Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_error!, style: inter(12, 500, color: kError)))
            else if (!_ready)
              Padding(padding: const EdgeInsets.only(bottom: 10), child: Text('Required fields are blank · Not ready to add', style: inter(12, 400, color: kMuted))),
            // Cancel and Add side by side, the app's usual button height.
            Row(children: [
              Expanded(child: OutlineButton('Cancel', onPressed: _busy ? null : () => Navigator.of(context).pop(), height: 48)),
              const SizedBox(width: 10),
              Expanded(
                child: Material(
                  color: _ready ? kPrimary : const Color(0xFFE5E7EB),
                  borderRadius: BorderRadius.circular(24),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: _ready && !_busy ? _add : null,
                    child: SizedBox(
                      height: 48,
                      child: Center(
                        child: _busy
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: kLime))
                            : Text('Add product', style: inter(14, 700, color: _ready ? kLime : kMuted)),
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ]),
        ),
      );
}

// ---------------------------------------------------------------- Scan barcode
/// [initialCode]: a code already read (for example by the camera) that is looked up as the sheet opens, so a miss shows its message here.
Future<CatItem?> showScanSheet(BuildContext context, CatalogueApi api, {Future<String?> Function(BuildContext) scan = scanBarcode, String? initialCode}) =>
    showDialog<CatItem>(context: context, barrierColor: Colors.black54, builder: (_) => _ScanSheet(api: api, scan: scan, initialCode: initialCode));

class _ScanSheet extends StatefulWidget {
  const _ScanSheet({required this.api, required this.scan, this.initialCode});
  final CatalogueApi api;
  final Future<String?> Function(BuildContext) scan;
  final String? initialCode;
  @override
  State<_ScanSheet> createState() => _ScanSheetState();
}

class _ScanSheetState extends State<_ScanSheet> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final c = widget.initialCode?.trim() ?? '';
    if (c.isNotEmpty) {
      _code.text = c;
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _find(); });
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final item = await widget.api.lookup(_code.text);
      if (mounted) Navigator.of(context).pop(item);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is CatalogueApiException ? e.message : 'Could not look that code up. Try again.';
        });
      }
    }
  }

  // The camera reads the code (with a beep), which is filled in and looked up at once; a closed camera leaves the sheet as it was.
  Future<void> _camera() async {
    final code = await widget.scan(context);
    if (code == null || code.isEmpty || !mounted) return;
    setState(() => _code.text = code);
    await _find();
  }

  // Products carry barcodes (EAN / UPC), so this is a barcode lookup: tap the viewfinder to scan with the camera, or type the number.
  @override
  Widget build(BuildContext context) {
    final ready = _code.text.trim().isNotEmpty;
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('Scan barcode', style: inter(20, 700))),
            IconButton(tooltip: 'Close', onPressed: () => Navigator.of(context).pop(), icon: const Icon(LucideIcons.x, size: 20, color: kMuted)),
          ]),
          Text('Point the camera at the product\'s barcode, or type the number below.', style: inter(13, 400, color: kMuted, height: 1.35)),
          const SizedBox(height: 14),
          _BarcodeViewfinder(onTap: _busy ? null : _camera),
          const SizedBox(height: 16),
          Text('Barcode or System Code', style: inter(13, 600, color: kMuted)),
          const SizedBox(height: 6),
          Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: _error != null ? kError : const Color(0xFFDADCD5))),
            child: Row(children: [
              const Icon(LucideIcons.scanBarcode, size: 18, color: kMuted),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _code,
                  autofocus: true,
                  onChanged: (_) => setState(() => _error = null),
                  onSubmitted: (_) => ready && !_busy ? _find() : null,
                  style: inter(14, 400),
                  decoration: plainInput.copyWith(hintText: 'e.g. 8901058851298', hintStyle: inter(14, 400, color: kMuted)),
                ),
              ),
            ]),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: inter(12, 500, color: kError))),
          const SizedBox(height: 14),
          Material(
            color: ready ? kPrimary : const Color(0xFFE5E7EB),
            borderRadius: BorderRadius.circular(24),
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: ready && !_busy ? _find : null,
              child: SizedBox(
                height: 48,
                child: Center(
                  child: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: kLime))
                      : Text('Find product', style: inter(14, 700, color: ready ? kLime : kMuted)),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// A barcode's viewfinder: a dark panel with a wide, short guide (lime corners) and a scan line across it. Tap it to scan with the camera.
class _BarcodeViewfinder extends StatelessWidget {
  const _BarcodeViewfinder({required this.onTap});
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xFF1B2420),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('scan-camera'),
          onTap: onTap,
          child: SizedBox(
            height: 168,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox(
                width: 240,
                height: 96,
                child: Stack(children: [
                  for (final a in const [Alignment.topLeft, Alignment.topRight, Alignment.bottomLeft, Alignment.bottomRight])
                    Align(alignment: a, child: _Corner(a)),
                  Center(child: Icon(LucideIcons.barcode, size: 52, color: Colors.white.withValues(alpha: 0.28))),
                  Center(child: Container(height: 2, margin: const EdgeInsets.symmetric(horizontal: 10), color: kLime.withValues(alpha: 0.85))),
                ]),
              ),
              Positioned(
                bottom: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: kLime, borderRadius: BorderRadius.circular(999)),
                  child: Row(children: [
                    const Icon(LucideIcons.camera, size: 14, color: kDark),
                    const SizedBox(width: 6),
                    Text('Tap to scan with camera', style: inter(12, 700, color: kDark)),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      );
}

class _Corner extends StatelessWidget {
  const _Corner(this.a);
  final Alignment a;
  @override
  Widget build(BuildContext context) {
    const side = BorderSide(color: kLime, width: 3);
    return SizedBox(
      width: 22,
      height: 22,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: a.y < 0 ? side : BorderSide.none,
            bottom: a.y > 0 ? side : BorderSide.none,
            left: a.x < 0 ? side : BorderSide.none,
            right: a.x > 0 ? side : BorderSide.none,
          ),
        ),
      ),
    );
  }
}
