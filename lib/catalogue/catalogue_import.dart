import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart' show PartnerApiException;
import '../inventory/inventory_api.dart';
import '../orders/order_widgets.dart' show OrdersTopBar;
import '../stock/closing_stock_screen.dart' show saveSpreadsheet;
import '../ui/i18n.dart';
import '../inventory/inventory_widgets.dart' show kCardLine, kLimeH, kPostedText;
import '../ui/theme.dart';
import '../ui/xlsx.dart';
import 'catalogue_api.dart';
import 'category_units.dart';
import 'price_basis.dart';
import 'sku_api.dart';

// Catalogue import (founder, 31 Oct 2026): fill the sample template in Excel (or any sheet saved as CSV), pick it, see every row checked
// — new, an update to an item the store already has (same SKU or barcode), or what is wrong with it — and add them all in one go. Each row
// is saved the way Quick add saves one product, so every rule (unique SKU and barcode, price not above MRP, units) is the database's too.
// The SKU is never typed for a new product (founder's OL SKU sheet): the database makes it from the subcategory, the brand / item and the
// size, taken from OneLocal's lists (a code or a name; a blank brand is LSE, loose / unbranded). An SKU in the file only finds the product
// to update; it never changes.

/// The template's columns, in order. * = needed.
const kImportColumns = ['Name*', 'Category', 'Unit', 'Price type', 'MRP', 'Selling price*', 'Cost', 'Barcode', 'Subcategory*', 'Brand / item', 'Size*', 'SKU', 'GST %', 'HSN', 'Opening stock'];

const _gstRates = <num>[0, 0.25, 3, 5, 12, 18, 28];

/// The sample template: the columns, how to fill them, and three example rows.
Uint8List catalogueTemplate() => buildXlsx('Catalogue', [
      kImportColumns,
      ['Parle-G 250g', 'Biscuits', 'pc', 'MRP', 30, 28, 24, '8901719110016', 'BIS', 'PRL', '250G', '', 18, '1905', 48],
      ['Basmati Rice Loose', 'Grocery', 'kg', 'Store', '', 90, 72, '', 'RIC', '', 'KG', '', 5, '1006', 25.5],
      ['Cotton Shirt', 'Fashion', 'pc', 'MRP', 799, 699, 450, '', 'CLM', '', 'PC', '', 5, '6205', 10],
    ], widths: const [28, 16, 8, 11, 9, 13, 9, 16, 13, 13, 9, 26, 7, 9, 13]);

/// Tests replace the file picker: a name and the bytes, or null.
Future<({String name, Uint8List bytes})?> Function() pickCatalogueFile = () async {
  final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['xlsx', 'csv']);
  if (f == null) return null;
  return (name: f.name, bytes: await f.readAsBytes());
};

/// One row of the file, checked: what it would save and what is wrong with it.
class ImportRow {
  ImportRow(this.line, this.cells);
  final int line; // the row number in the sheet, as Excel shows it
  final Map<String, String> cells;
  final problems = <String>[];
  CatItem? existing; // same SKU or barcode as an item the store has: an update
  Map<String, dynamic> fields = const {};
  num? openingStock;
  String status = 'pending'; // pending | saved | failed
  String? failure;

  String get name => cells['name'] ?? '';
  bool get ok => problems.isEmpty;
  bool get update => existing != null;
}

/// Reads the file into rows by their headers (any order, any case; the * and spaces do not matter).
List<ImportRow> parseCatalogueFile(String fileName, Uint8List bytes) {
  final table = fileName.toLowerCase().endsWith('.csv') ? readCsv(utf8.decode(bytes, allowMalformed: true)) : readXlsx(bytes);
  if (table.isEmpty) throw const FormatException('The file is empty.');
  String key(String h) => h.toLowerCase().replaceAll(RegExp(r'[^a-z%]'), '');
  const names = {
    'name': 'name', 'productname': 'name', 'itemname': 'name', 'category': 'category', 'unit': 'unit', 'sellingunit': 'unit',
    'pricetype': 'basis', 'pricebasis': 'basis', 'mrp': 'mrp', 'sellingprice': 'price', 'price': 'price', 'cost': 'cost', 'costprice': 'cost',
    'barcode': 'barcode', 'sku': 'sku', 'systemcode': 'sku', 'subcategory': 'sub', 'subcategorycode': 'sub', 'brand': 'brand', 'branditem': 'brand',
    'brandcode': 'brand', 'itemcode': 'brand', 'size': 'size', 'gst%': 'gst', 'gst': 'gst', 'hsn': 'hsn', 'openingstock': 'stock', 'stock': 'stock',
  };
  final header = [for (final h in table.first) names[key(h)]];
  if (!header.contains('name') || !header.contains('price')) {
    throw const FormatException('The first row needs the column names, at least "Name" and "Selling price". Download the sample template to see them.');
  }
  final rows = <ImportRow>[];
  for (var i = 1; i < table.length; i++) {
    final r = table[i];
    if (r.every((c) => c.trim().isEmpty)) continue;
    rows.add(ImportRow(i + 1, {
      for (var c = 0; c < header.length && c < r.length; c++)
        if (header[c] != null && r[c].trim().isNotEmpty) header[c]!: r[c].trim(),
    }));
  }
  if (rows.isEmpty) throw const FormatException('There are no products under the column names.');
  return rows;
}

/// Checks every row against the rules, the store's items (by SKU, then barcode) and OneLocal's SKU lists, and works out what each one saves.
void checkImportRows(List<ImportRow> rows, List<CatItem> catalogue, SkuOptions sku) {
  String norm(String v) => v.trim().toLowerCase();
  SkuSub? subOf(String v) => sku.subs.where((x) => norm(x.code) == norm(v) || norm(x.name) == norm(v)).firstOrNull;
  SkuBrand? brandOf(String v) => sku.brands.where((x) => norm(x.code) == norm(v) || norm(x.name) == norm(v)).firstOrNull;
  final units = ([...sku.units]..sort((a, b) => b.length - a.length)).map(RegExp.escape).join('|');
  final sizeShape = RegExp('^(([0-9]+X)?[0-9]+(\\.[0-9]+)?)?($units)\$');
  final bySku = {for (final i in catalogue) if (i.sku.isNotEmpty) i.sku.toLowerCase(): i};
  final byCode = {for (final i in catalogue) if ((i.barcode ?? '').isNotEmpty) i.barcode!: i};
  final seenSku = <String, int>{}, seenCode = <String, int>{};
  num? money(String? v) => v == null ? null : num.tryParse(v.replaceAll(RegExp(r'[₹,\s]'), ''));
  int? minor(num? v) => v == null ? null : (v * 100).round();

  for (final r in rows) {
    final c = r.cells, p = r.problems;
    final name = c['name'] ?? '';
    if (name.length < 2) p.add('Name is missing');
    if (name.length > 120) p.add('Name is over 120 letters');
    final price = money(c['price']), mrp = money(c['mrp']), cost = money(c['cost']);
    if (price == null || price < 0) p.add('Selling price is missing or not a number');
    if (c['mrp'] != null && (mrp == null || mrp < 0)) p.add('MRP is not a number');
    if (c['cost'] != null && (cost == null || cost < 0)) p.add('Cost is not a number');
    final unit = c['unit'] == null ? null : cleanUnit(c['unit']!);
    if (c['unit'] != null && unit == null) p.add('Unit "${c['unit']}" is not a short word like pc, kg or pair');
    final basisText = (c['basis'] ?? '').toLowerCase();
    final basis = basisText.startsWith('store') ? PriceBasis.store : basisText.startsWith('mrp') ? PriceBasis.mrp : basisForUnit(unit ?? 'pc');
    if (basisText.isNotEmpty && !basisText.startsWith('store') && !basisText.startsWith('mrp')) p.add('Price type is MRP or Store');
    if (basis == PriceBasis.mrp && mrp != null && price != null && price > mrp) p.add('Selling price is above the MRP');
    final gst = c['gst'] == null ? null : num.tryParse(c['gst']!.replaceAll('%', '').trim());
    if (c['gst'] != null && (gst == null || !_gstRates.contains(gst))) p.add('GST is 0, 0.25, 3, 5, 12, 18 or 28');
    final hsn = c['hsn'];
    if (hsn != null && !RegExp(r'^[0-9]{4,8}$').hasMatch(hsn)) p.add('HSN is 4 to 8 digits');
    final barcode = c['barcode'];
    if (barcode != null && (barcode.length < 4 || barcode.length > 48)) p.add('Barcode is 4 to 48 characters');
    final sku = c['sku'];
    final stock = c['stock'] == null ? null : num.tryParse(c['stock']!);
    if (c['stock'] != null && (stock == null || stock < 0)) p.add('Opening stock is not a number');

    // the same SKU or barcode twice in the file
    if (sku != null) {
      final before = seenSku[sku.toLowerCase()];
      if (before != null) p.add('SKU $sku is also on row $before');
      seenSku[sku.toLowerCase()] = r.line;
    }
    if (barcode != null) {
      final before = seenCode[barcode];
      if (before != null) p.add('Barcode $barcode is also on row $before');
      seenCode[barcode] = r.line;
    }
    // an item the store already has: by SKU first, then by barcode; both must point at the same item
    final viaSku = sku == null ? null : bySku[sku.toLowerCase()];
    final viaCode = barcode == null ? null : byCode[barcode];
    if (viaSku != null && viaCode != null && viaSku.id != viaCode.id) p.add('SKU and barcode belong to two different items');
    r.existing = viaSku ?? viaCode;
    if (sku != null && viaSku == null) p.add('SKU $sku is not one of your products. Leave SKU empty for a new product: it is made from the subcategory, brand and size');
    if (r.existing != null && stock != null) p.add('Opening stock is only for new items; count an existing item in Stock');
    // a new product: its SKU parts from OneLocal's lists
    SkuSub? sub;
    SkuBrand? brand;
    String? size;
    if (r.existing == null) {
      sub = c['sub'] == null ? null : subOf(c['sub']!);
      if (c['sub'] == null) {
        p.add('Subcategory is missing (a code like BIS, or its name)');
      } else if (sub == null) {
        p.add('Subcategory "${c['sub']}" is not on the OneLocal list');
      }
      brand = brandOf(c['brand'] ?? 'LSE');
      if (brand == null) p.add('Brand "${c['brand']}" is not on the OneLocal list yet: add it once in Quick add, then import');
      size = c['size']?.toUpperCase().replaceAll(RegExp(r'\s'), '');
      if (size == null) {
        p.add('Size is missing (like 500G, 1L, KG or PC)');
      } else if (!sizeShape.hasMatch(size)) {
        p.add('Size "${c['size']}" should be like 500G, 1L, 6X80G, KG or PC');
      }
    }
    if (!r.ok) continue;

    final store = basis == PriceBasis.store;
    r.openingStock = stock;
    r.fields = {
      'mode': 'quick',
      'name': name,
      if (r.existing == null) 'sku_parts': SkuParts(sub: sub!.code, slot3: brand!.code, size: size!).toJson() else 'version': r.existing!.version,
      'price_minor': minor(price),
      'price_basis': basis.name,
      if (!store && mrp != null) 'mrp_minor': minor(mrp),
      if (cost != null) 'cost_minor': minor(cost),
      'barcode': ?barcode,
      'selling_unit': ?unit,
      'category': ?c['category'],
      'gst_pct': ?gst,
      'hsn': ?hsn,
    };
  }
}

/// Import from Excel: pick the file, check every row, add them all.
class CatalogueImportScreen extends StatefulWidget {
  const CatalogueImportScreen({super.key, required this.api, InventoryApi? inventory, SkuApi? sku})
      : _inventory = inventory,
        _sku = sku;
  final CatalogueApi api;
  final InventoryApi? _inventory;
  final SkuApi? _sku;
  InventoryApi get inventory => _inventory ?? InventoryApi();
  SkuApi get sku => _sku ?? SkuApi();
  @override
  State<CatalogueImportScreen> createState() => _CatalogueImportScreenState();
}

class _CatalogueImportScreenState extends State<CatalogueImportScreen> {
  String? _file, _error;
  List<ImportRow>? _rows;
  String _show = 'all'; // all | new | update | problem
  bool _reading = false, _saving = false, _done = false;
  int _savedCount = 0;
  late final _session = CatalogueApi.newKey(); // with the row number, each row's key: a second Import of the same file saves nothing twice

  Future<void> _template() async {
    try {
      await saveSpreadsheet(catalogueTemplate(), 'catalogue-template.xlsx');
      if (mounted) showToast(context, tr('Sample template saved: catalogue-template.xlsx'));
    } catch (_) {
      if (mounted) showToast(context, tr('The template could not be saved.'));
    }
  }

  Future<void> _pick() async {
    final f = await pickCatalogueFile();
    if (f == null || !mounted) return;
    setState(() {
      _reading = true;
      _error = null;
      _rows = null;
      _done = false;
      _file = f.name;
    });
    try {
      final rows = parseCatalogueFile(f.name, f.bytes);
      final all = <CatItem>[];
      for (var page = 1; page <= 100; page++) {
        final l = await widget.api.list(page: page, pageSize: 100);
        all.addAll(l.items);
        if (l.items.length < 100) break;
      }
      checkImportRows(rows, all, await widget.sku.options());
      if (mounted) setState(() => _rows = rows);
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : tr('The file could not be checked. Try again.'));
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  /// Saves the good rows one by one (each with its own key), then the opening stock of the new ones.
  Future<void> _import() async {
    final rows = (_rows ?? const <ImportRow>[]).where((r) => r.ok && r.status != 'saved').toList();
    if (rows.isEmpty) return;
    setState(() => _saving = true);
    for (final r in rows) {
      try {
        final item = await widget.api.save(r.fields, id: r.existing?.id, key: '$_session-${r.line}');
        final inv = item.raw['inventory_item_id']?.toString();
        if (r.existing == null && (r.openingStock ?? 0) > 0 && inv != null) {
          try {
            await widget.inventory.openingStock(inv, r.openingStock!, key: '$_session-stock-${r.line}');
          } catch (e) {
            r.failure = 'Saved, but the opening stock was not: ${e is PartnerApiException ? e.message : 'try again in Stock'}';
          }
        }
        r.status = 'saved';
        _savedCount++;
      } catch (e) {
        r.status = 'failed';
        r.failure = e is PartnerApiException ? e.message : 'Could not save. Check your connection.';
      }
      if (mounted) setState(() {});
    }
    if (mounted) {
      setState(() {
        _saving = false;
        _done = true;
      });
    }
  }

  Widget _chip(String id, String label, int n) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          key: ValueKey('import-filter-$id'),
          label: Text('$label · $n', style: inter(13, _show == id ? 700 : 500)),
          selected: _show == id,
          showCheckmark: false,
          selectedColor: kLimeH,
          backgroundColor: Colors.white,
          onSelected: (_) => setState(() => _show = id),
        ),
      );

  Widget _rowCard(ImportRow r) {
    final (label, bg, fg) = r.status == 'saved'
        ? ('Saved', const Color(0xFFE8F7EC), const Color(0xFF15803D))
        : r.status == 'failed'
            ? ('Not saved', const Color(0xFFFDECEC), const Color(0xFFC62828))
            : !r.ok
                ? ('Fix', const Color(0xFFFDECEC), const Color(0xFFC62828))
                : r.update
                    ? ('Update', const Color(0xFFEAF2FF), const Color(0xFF1D4ED8))
                    : ('New', const Color(0xFFF1FAE8), kPostedText);
    final f = r.fields;
    return Container(
      key: ValueKey('import-row-${r.line}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kCardLine)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('${tr('Row')} ${r.line}', style: inter(11.5, 700, color: kMuted)),
          const SizedBox(width: 8),
          Expanded(child: Text(r.name.isEmpty ? '—' : r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14.5, 700))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
            child: Text(tr(label), style: inter(11.5, 700, color: fg)),
          ),
        ]),
        if (r.ok)
          Text(
            [
              if (f['price_minor'] != null) '₹${(f['price_minor'] as int) / 100}',
              if (f['mrp_minor'] != null) 'MRP ₹${(f['mrp_minor'] as int) / 100}',
              f['price_basis'] == 'store' ? tr('Store-based') : tr('MRP-based'),
              if (f['selling_unit'] != null) '${f['selling_unit']}',
              if (f['sku'] != null) 'SKU ${f['sku']}',
              if (r.update) '${tr('updates')} ${r.existing!.name}',
              if (r.openingStock != null) '${tr('stock')} ${r.openingStock}',
            ].join(' · '),
            style: inter(12, 500, color: kMuted),
          ),
        for (final p in r.problems) Text('• ${tr(p)}', style: inter(12.5, 600, color: const Color(0xFFC62828))),
        if (r.failure != null) Text(r.failure!, style: inter(12.5, 600, color: const Color(0xFFC62828))),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final good = rows?.where((r) => r.ok && r.status != 'saved').length ?? 0;
    final shown = rows?.where((r) => switch (_show) { 'new' => r.ok && !r.update, 'update' => r.ok && r.update, 'problem' => !r.ok || r.status == 'failed', _ => true }).toList();
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        OrdersTopBar(title: tr('Import from Excel'), onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: kCardLine)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(tr('Add many products at once'), style: inter(17, 800)),
                const SizedBox(height: 4),
                Text(
                  tr('1. Download the sample template.  2. Fill one product per row in Excel (or save your sheet as CSV).  3. Pick the file: every row is checked before anything is saved. A row with the SKU or barcode of a product you already have updates it.'),
                  style: inter(13, 500, color: kMuted, height: 1.4),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('import-template'),
                      onPressed: _template,
                      icon: const Icon(LucideIcons.download, size: 17),
                      label: Text(tr('Sample template')),
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('import-pick'),
                      onPressed: _reading || _saving ? null : _pick,
                      icon: const Icon(LucideIcons.upload, size: 17),
                      label: Text(tr(_file == null ? 'Choose file' : 'Choose another')),
                      style: FilledButton.styleFrom(backgroundColor: kPrimary, minimumSize: const Size.fromHeight(48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    ),
                  ),
                ]),
                if (_file != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_file!, style: inter(12.5, 600, color: kMuted))),
              ]),
            ),
            const SizedBox(height: 14),
            if (_reading) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(color: kPostedText))),
            if (_error != null)
              Container(
                key: const ValueKey('import-error'),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: const Color(0xFFFDECEC), borderRadius: BorderRadius.circular(14)),
                child: Text(_error!, style: inter(13.5, 600, color: const Color(0xFFC62828))),
              ),
            if (rows != null) ...[
              if (_done)
                Container(
                  key: const ValueKey('import-summary'),
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: const Color(0xFFE8F7EC), borderRadius: BorderRadius.circular(14)),
                  child: Text(
                    '${rows.where((r) => r.status == 'saved' && !r.update).length} ${tr('added')}, ${rows.where((r) => r.status == 'saved' && r.update).length} ${tr('updated')}, '
                    '${rows.where((r) => !r.ok || r.status == 'failed').length} ${tr('to fix')}.',
                    style: inter(14, 700, color: const Color(0xFF15803D)),
                  ),
                ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  _chip('all', tr('All'), rows.length),
                  _chip('new', tr('New'), rows.where((r) => r.ok && !r.update).length),
                  _chip('update', tr('Updates'), rows.where((r) => r.ok && r.update).length),
                  _chip('problem', tr('To fix'), rows.where((r) => !r.ok || r.status == 'failed').length),
                ]),
              ),
              const SizedBox(height: 10),
              for (final r in shown!) _rowCard(r),
            ],
          ]),
        ),
        if (rows != null)
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: kCardLine))),
              child: FilledButton(
                key: const ValueKey('import-go'),
                onPressed: _saving || good == 0 ? null : _import,
                style: FilledButton.styleFrom(backgroundColor: kPrimary, minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                child: Text(
                  _saving ? '${tr('Saving')} $_savedCount…' : good == 0 ? tr(_done ? 'Done' : 'Nothing to import') : '${tr('Import')} $good ${tr(good == 1 ? 'product' : 'products')}',
                  style: inter(15.5, 700, color: Colors.white),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
