import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../auth/partner_api.dart';
import '../home/home_nav.dart';
import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import 'label_pdf.dart';
import 'stock_env.dart';
import 'stock_kit.dart';
import '../ui/i18n.dart';

/// Where finished label PDFs go: the phone / PC print screen (it lists every printer the device can use) and the share sheet.
/// Product and shelf labels both use them; tests replace them to catch the PDF instead.
Future<void> Function(Uint8List pdf, String name) printLabelPdf = (pdf, name) => Printing.layoutPdf(onLayout: (_) async => pdf, name: name);
Future<void> Function(Uint8List pdf, String name) shareLabelPdf = (pdf, name) => Printing.sharePdf(bytes: pdf, filename: name);

/// Figma "Product Label Printing": price + barcode stickers for chosen products, printed through the device's print screen.
class ProductLabelsScreen extends StatelessWidget {
  const ProductLabelsScreen({super.key, required this.env, this.itemId});
  final StockEnv env;
  final String? itemId;
  @override
  Widget build(BuildContext context) => _LabelsPage(env: env, itemId: itemId, size: LabelSize.product);
}

/// One chosen product: its label facts and how many copies.
class _Entry {
  _Entry({required this.itemId, required this.label, this.shelfId});
  final String itemId;
  LabelData label;
  int copies = 1;
  String? shelfId;
}

class _LabelsPage extends StatefulWidget {
  const _LabelsPage({required this.env, required this.itemId, required this.size});
  final StockEnv env;
  final String? itemId;
  final LabelSize size;
  @override
  State<_LabelsPage> createState() => _LabelsPageState();
}

class _LabelsPageState extends State<_LabelsPage> {
  StockEnv get env => widget.env;
  bool get _shelf => widget.size == LabelSize.shelf;
  final _entries = <_Entry>[];
  List<Facts> _bins = const [];
  bool _busy = false, _adding = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    if (_shelf) {
      try {
        final o = await env.api.options();
        if (mounted) setState(() => _bins = o.l('bins').where((b) => b.s('zone') != 'quarantine').toList());
      } catch (_) {}
    }
    final id = widget.itemId;
    if (id == null) return;
    try {
      final d = await env.api.stockDetail(id);
      await _add(d.m('item').s('id').isEmpty ? id : d.m('item').s('id'), d.m('item'), detail: d);
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : 'Could not open that product.');
    }
  }

  /// The label facts come from the catalogue (price, MRP, barcode), found by the item's System Code.
  Future<void> _add(String itemId, Facts item, {Facts? detail}) async {
    if (_entries.any((e) => e.itemId == itemId)) return showToast(context, '${item.s('name')} is already in the list.');
    setState(() => _adding = true);
    try {
      final c = await env.catalogue.lookup(item.s('sku'));
      String? shelfId;
      if (_shelf) {
        final d = detail ?? await env.api.stockDetail(itemId);
        shelfId = d.l('bins').where((b) => b.s('zone') != 'quarantine').map((b) => b.s('id')).firstOrNull ?? _bins.firstOrNull?.s('id');
      }
      final barcode = (c.barcode ?? item.s('barcode')).trim();
      final label = LabelData(
        name: c.name.isEmpty ? item.s('name') : c.name,
        priceMinor: c.priceMinor,
        mrpMinor: c.mrpMinor,
        code: barcode.isEmpty ? c.sku : barcode,
        systemCode: c.sku,
        unit: c.sellingUnit,
        store: HomeNav.storeName ?? '',
      );
      if (!mounted) return;
      setState(() => _entries.add(_Entry(itemId: itemId, label: label, shelfId: shelfId)));
    } on PartnerApiException catch (_) {
      if (mounted) showToast(context, '${item.s('name')} is not sold in the shop, so it has no price for a label.');
    } catch (_) {
      if (mounted) showToast(context, 'Could not reach the server. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _pick() async {
    final it = await pickItem(context, env.api);
    if (it == null || !mounted) return;
    await _add(it.s('id'), it);
  }

  String _shelfName(String? id) => _bins.where((b) => b.s('id') == id).map((b) => b.s('name')).firstOrNull ?? '';

  Future<void> _pickShelf(_Entry e) async {
    final v = await pickOne<String>(context, 'Where is it on display?', [for (final b in _bins) (b.s('id'), b.s('name'), b.s('code'))], current: e.shelfId);
    if (v != null) setState(() => e.shelfId = v);
  }

  List<(LabelData, int)> get _batch => [
        for (final e in _entries)
          (
            _shelf
                ? LabelData(name: e.label.name, priceMinor: e.label.priceMinor, mrpMinor: e.label.mrpMinor, code: e.label.code, systemCode: e.label.systemCode, unit: e.label.unit, store: e.label.store, shelf: _shelfName(e.shelfId))
                : e.label,
            e.copies,
          ),
      ];

  int get _total => _entries.fold(0, (n, e) => n + e.copies);

  Future<(pw.Font?, pw.Font?)> _fonts() async {
    try {
      final f = pw.Font.ttf(await rootBundle.load('fonts/Inter.ttf'));
      return (f, f);
    } catch (_) {
      return (null, null);
    }
  }

  Future<void> _out(Future<void> Function(Uint8List, String) send) async {
    if (_entries.isEmpty) return showToast(context, 'Add a product first.');
    setState(() => _busy = true);
    try {
      final (font, bold) = await _fonts();
      final pdf = await buildLabelsPdf(_batch, size: widget.size, font: font, bold: bold);
      await send(pdf, _shelf ? 'shelf-labels.pdf' : 'product-labels.pdf');
    } catch (_) {
      if (mounted) showToast(context, 'The labels could not be made. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => StockScaffold(
        env: env,
        title: _shelf ? 'Shelf labels' : 'Product labels',
        line: _shelf ? 'Big, clear price strips for the shelf edge.' : 'Price and barcode stickers for your products.',
        children: [
          InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InvCardHead(tr('Products'), subtitle: _entries.isEmpty ? 'Choose what to print labels for' : '$_total label${_total == 1 ? '' : 's'} for ${_entries.length} product${_entries.length == 1 ? '' : 's'}'),
            for (final e in _entries) _entry(e),
            if (_entries.isEmpty) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(tr('No products yet. Add one to see its label.'), style: inter(13.5, 400, color: kMuted))),
            InvSecondary(_adding ? 'Adding…' : (_entries.isEmpty ? 'Add a product' : 'Add another product'), onPressed: _adding ? null : _pick),
          ])),
          InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InvCardHead(tr('Label size')),
            StockRow(tr('Size'), widget.size.title),
            StockRow(tr('Barcode'), 'Product barcode, or its System Code'),
            StockRow(tr('Price'), 'Current selling price'),
            const SizedBox(height: 4),
            Text(tr('When you print, your phone or computer shows its print screen. Choose your label printer and paper there.'), style: inter(12.5, 400, color: kMuted, height: 1.4)),
          ])),
          if (_entries.isNotEmpty) ...[
            const InvSection('Preview'),
            Center(child: _LabelPreview(label: _batch.first.$1, size: widget.size)),
            const SizedBox(height: 14),
          ],
          InvPrimary(_entries.isEmpty ? 'Print labels' : 'Print $_total label${_total == 1 ? '' : 's'}', busy: _busy, onPressed: _busy ? null : () => _out(printLabelPdf)),
          InvSecondary(tr('Share PDF'), onPressed: _busy ? null : () => _out(shareLabelPdf)),
          const SizedBox(height: 8),
        ],
      );

  Widget _entry(_Entry e) => Container(
        key: ValueKey('label-entry-${e.itemId}'),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: BoxDecoration(color: kGreyBg, borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: InkWell(
                onTap: () => env.open(context, StockPage.item, itemId: e.itemId),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(e.label.name, style: inter(14.5, 700)),
                  Text('${e.label.systemCode} · ${labelMoney(e.label.priceMinor)} per ${e.label.unit}', style: inter(12.5, 400, color: kMuted)),
                ]),
              ),
            ),
            IconButton(tooltip: 'Remove ${e.label.name}', onPressed: () => setState(() => _entries.remove(e)), icon: const Icon(LucideIcons.x, size: 18, color: kMuted)),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Text(tr('Labels'), style: inter(13, 600)),
            const SizedBox(width: 12),
            InvStepper(value: e.copies, min: 1, label: 'labels for ${e.label.name}', onChanged: (v) => setState(() => e.copies = v.toInt().clamp(1, 500))),
          ]),
          if (_shelf) ...[
            const SizedBox(height: 8),
            InvPickBox(value: e.shelfId == null ? 'Choose the shelf' : _shelfName(e.shelfId), onTap: _bins.isEmpty ? null : () => _pickShelf(e), semantic: 'Shelf for ${e.label.name}'),
          ],
        ]),
      );
}

/// What one label looks like, drawn on screen at the label's shape (the PDF is built the same way).
class _LabelPreview extends StatelessWidget {
  const _LabelPreview({required this.label, required this.size});
  final LabelData label;
  final LabelSize size;
  @override
  Widget build(BuildContext context) {
    final shelf = size == LabelSize.shelf;
    final w = shelf ? 300.0 : 240.0;
    return Container(
      key: const ValueKey('label-preview'),
      width: w,
      height: w * size.heightMm / size.widthMm,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: kInk, width: 1.2)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (label.store.isNotEmpty) Text(label.store.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(9, 700, color: kMuted)),
        Text(label.name, maxLines: shelf ? 2 : 1, overflow: TextOverflow.ellipsis, style: inter(shelf ? 15 : 13, 800)),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(labelMoney(label.priceMinor), style: inter(shelf ? 26 : 20, 800)),
          const SizedBox(width: 6),
          if (label.mrpMinor != null && label.mrpMinor! > label.priceMinor)
            Text('MRP ${labelMoney(label.mrpMinor!)}', style: inter(10, 400, color: kMuted).copyWith(decoration: TextDecoration.lineThrough)),
          const Spacer(),
          Text('per ${label.unit}', style: inter(10, 400, color: kMuted)),
        ]),
        const Spacer(),
        // the same Code 128 the PDF prints
        SizedBox(
          height: shelf ? 26 : 20,
          width: double.infinity,
          child: SvgPicture.string(pw.Barcode.code128().toSvg(labelBarcodeData(label.code), width: 400, height: 60, drawText: false), fit: BoxFit.fill),
        ),
        Text(label.code, style: inter(9, 500)),
        if (shelf && (label.shelf ?? '').isNotEmpty) Text('${label.shelf} · ${label.systemCode}', style: inter(9, 400, color: kMuted)),
      ]),
    );
  }
}
