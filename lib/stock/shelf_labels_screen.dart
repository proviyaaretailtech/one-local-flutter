import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pdf/widgets.dart' as pw;

import '../catalogue/catalogue_api.dart';
import '../home/home_nav.dart';
import '../ui/theme.dart';
import 'label_pdf.dart';
import 'labels_screens.dart' show printLabelPdf, shareLabelPdf;
import 'stock_env.dart';
import 'stock_kit.dart';
import '../ui/i18n.dart';

/// Figma "Shelf Labels" (Receiving → Putaway → Shelf labels): pick a product, a label style and a size, then see the label at its real
/// shape and print as many as the shelf needs. Printing goes through the device's print screen, which lists every printer it can use.
class ShelfLabelsScreen extends StatefulWidget {
  const ShelfLabelsScreen({super.key, required this.env, this.itemId});
  final StockEnv env;

  /// A product to start with (its inventory id), as from a product's page.
  final String? itemId;
  @override
  State<ShelfLabelsScreen> createState() => _ShelfLabelsScreenState();
}

/// The two label styles: the everyday price tag, and the offer label that shows the saving against the MRP.
enum ShelfLabelStyle {
  standard('Standard price tag', 'Most used'),
  offer('Offer label', 'Shows the saving');

  const ShelfLabelStyle(this.title, this.note);
  final String title, note;
}

class _ShelfLabelsScreenState extends State<ShelfLabelsScreen> {
  StockEnv get env => widget.env;
  final _search = TextEditingController();
  Timer? _debounce;
  List<CatItem>? _items;
  String? _error;
  CatItem? _picked;
  var _style = ShelfLabelStyle.standard;
  var _size = LabelSize.medium;
  var _copies = 1;
  var _preview = false; // Choose, then Preview
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final l = await env.catalogue.list(q: _search.text, status: 'active', pageSize: 8);
      if (!mounted) return;
      setState(() {
        _items = l.items;
        _error = null;
        // a product handed in (a product's page) starts picked
        _picked ??= l.items.where((i) => widget.itemId != null && i.raw['inventory_item_id'] == widget.itemId).firstOrNull;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  LabelData _label(CatItem it, {String? barcode}) {
    final code = (barcode ?? it.barcode ?? '').trim();
    return LabelData(
      name: it.name,
      priceMinor: it.priceMinor,
      mrpMinor: it.mrpMinor,
      code: code.isEmpty ? it.sku : code,
      systemCode: it.sku,
      unit: it.sellingUnit,
      store: HomeNav.storeName ?? '',
      category: it.category,
    );
  }

  /// Builds the labels and hands them to the print screen (or the share sheet), with a small "getting them ready" sheet meanwhile.
  Future<void> _out(Future<void> Function(Uint8List, String) send) async {
    final it = _picked;
    if (it == null) return;
    setState(() => _busy = true);
    var cancelled = false;
    final ready = showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(key: const ValueKey('labels-progress'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Icon(LucideIcons.printer, size: 18, color: kInk),
              const SizedBox(width: 8),
              Expanded(child: Text('Getting $_copies label${_copies == 1 ? '' : 's'} ready…', style: inter(16, 700))),
            ]),
            const SizedBox(height: 12),
            ClipRRect(borderRadius: BorderRadius.circular(99), child: const LinearProgressIndicator(minHeight: 6, color: kLimeH, backgroundColor: kGreyBg)),
            const SizedBox(height: 8),
            Text('${it.name} · ${_style.title} · ${_size.short}. Your print screen opens next: choose the label printer there.', style: inter(12.5, 400, color: kMuted, height: 1.35)),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const ValueKey('labels-cancel'),
                onPressed: () {
                  cancelled = true;
                  Navigator.of(ctx).pop();
                },
                child: Text(tr('Cancel'), style: inter(14, 700, color: kRedText)),
              ),
            ),
          ]),
        ),
      ),
    );
    try {
      String? barcode;
      try {
        barcode = (await env.catalogue.lookup(it.sku)).barcode; // the list leaves the barcode out
      } catch (_) {}
      pw.Font? font;
      try {
        font = pw.Font.ttf(await rootBundle.load('fonts/Inter.ttf'));
      } catch (_) {}
      final pdf = await buildLabelsPdf([(_label(it, barcode: barcode), _copies)], size: _size, font: font, bold: font, offer: _style == ShelfLabelStyle.offer);
      if (cancelled || !mounted) return;
      Navigator.of(context).pop(); // the "ready" sheet
      await send(pdf, 'shelf-labels.pdf');
      if (mounted) showToast(context, '$_copies label${_copies == 1 ? '' : 's'} sent to the print screen.');
    } catch (_) {
      if (!cancelled && mounted) {
        Navigator.of(context).pop();
        showToast(context, 'The labels could not be made. Try again.');
      }
    } finally {
      await ready;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => StockScaffold(
        env: env,
        title: tr('Shelf labels'),
        onRefresh: _load,
        children: [
          _steps(),
          const SizedBox(height: 12),
          if (_preview && _picked != null) ..._previewStep(_picked!) else ..._chooseStep(),
        ],
      );

  /// Choose · Preview, side by side like the Stock & price / Store & app switch.
  Widget _steps() => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kCardLine)),
        child: Row(children: [
          for (final (id, label, icon) in [(false, 'Choose', LucideIcons.layoutTemplate), (true, 'Preview', LucideIcons.scanEye)])
            Expanded(
              child: Material(
                color: _preview == id ? kNavyH : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  key: ValueKey('labels-step-${label.toLowerCase()}'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: id && _picked == null ? () => showToast(context, 'Choose a product first.') : () => setState(() => _preview = id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(icon, size: 16, color: _preview == id ? kLimeH : kMuted),
                      const SizedBox(width: 6),
                      Text(label, style: inter(13.5, 700, color: _preview == id ? kLimeH : kMuted)),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      );

  // ---------------------------------------------------------------- choose
  List<Widget> _chooseStep() => [
        InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InvCardHead(tr('Product')),
          Container(
            height: 42,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(21), border: Border.all(color: const Color(0xFFD9DCD6))),
            child: Row(children: [
              const SizedBox(width: 12),
              const Icon(LucideIcons.search, size: 18, color: kMuted),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const ValueKey('labels-search'),
                  controller: _search,
                  style: inter(14, 400),
                  decoration: InputDecoration.collapsed(hintText: tr('Search name or System Code'), hintStyle: inter(14, 400, color: kMuted)),
                  onChanged: (_) {
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 300), _load);
                  },
                ),
              ),
              const SizedBox(width: 12),
            ]),
          ),
          const SizedBox(height: 8),
          if (_error != null && _items == null)
            Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: inter(13, 400, color: kRedText)))
          else if (_items == null)
            const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
          else if (_items!.isEmpty)
            Padding(padding: const EdgeInsets.all(8), child: Text(tr('No product matches.'), style: inter(13.5, 400, color: kMuted)))
          else
            for (final it in _items!) _productRow(it),
        ])),
        InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InvCardHead(tr('Label style')),
          for (final s in ShelfLabelStyle.values) _styleRow(s),
        ])),
        InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InvCardHead(tr('Label size')),
          Row(children: [
            for (final (i, s) in [LabelSize.small, LabelSize.medium, LabelSize.large].indexed) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(child: _sizeChip(s)),
            ],
          ]),
        ])),
        InvPrimary(tr('Preview label'), key: const ValueKey('labels-preview'), onPressed: _picked == null ? null : () => setState(() => _preview = true)),
        const SizedBox(height: 8),
      ];

  Widget _productRow(CatItem it) {
    final on = _picked?.id == it.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: on ? kLimeSoftH : kGreyBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: on ? kLimeH : Colors.transparent)),
        child: InkWell(
          key: ValueKey('labels-product-${it.id}'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _picked = it),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 700)),
                  Text('System Code ${it.sku}', style: inter(11.5, 400, color: kMuted)),
                ]),
              ),
              Text(labelMoney(it.priceMinor), style: inter(14, 700)),
              const SizedBox(width: 8),
              Icon(on ? LucideIcons.circleCheck : LucideIcons.circle, size: 20, color: on ? kPostedText : kMuted),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _styleRow(ShelfLabelStyle s) {
    final on = _style == s;
    final sample = _picked == null ? null : _label(_picked!);
    final offerText = sample?.savingMinor == null ? 'Offer ₹XX · MRP ₹XX · Save ₹X' : 'Offer ${labelMoney(sample!.priceMinor)} · MRP ${labelMoney(sample.mrpMinor!)} · Save ${labelMoney(sample.savingMinor!)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: on ? kLimeSoftH : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: on ? kLimeH : kCardLine)),
        child: InkWell(
          key: ValueKey('labels-style-${s.name}'),
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => _style = s),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text(s.title, style: inter(14, 700))),
                Text(s.note, style: inter(11.5, 500, color: kMuted)),
              ]),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                alignment: Alignment.center,
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(99), border: Border.all(color: kCardLine)),
                child: Text(s == ShelfLabelStyle.offer ? offerText : (sample == null ? 'Price ₹XX' : 'Price ${labelMoney(sample.priceMinor)}'), style: inter(11.5, 600, color: kMuted)),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _sizeChip(LabelSize s) {
    final on = _size == s;
    return Material(
      color: on ? kNavyH : Colors.white,
      shape: StadiumBorder(side: BorderSide(color: on ? kNavyH : kCardLine)),
      child: InkWell(
        key: ValueKey('labels-size-${s.name}'),
        customBorder: const StadiumBorder(),
        onTap: () => setState(() => _size = s),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(s.short, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 700, color: on ? kLimeH : kInk)),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- preview
  List<Widget> _previewStep(CatItem it) => [
        InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InvCardHead(tr('Print')),
          Text(it.name, style: inter(15, 700)),
          Text(['System Code ${it.sku}', if (it.category.isNotEmpty) it.category].join(' · '), style: inter(12, 400, color: kMuted)),
          const SizedBox(height: 10),
          InvLabel(tr('LABEL STYLE')),
          InvPickBox(
            value: _style.title,
            semantic: 'Label style',
            onTap: () async {
              final v = await pickOne<ShelfLabelStyle>(context, 'Label style', [for (final s in ShelfLabelStyle.values) (s, s.title, s.note)], current: _style);
              if (v != null) setState(() => _style = v);
            },
          ),
          const SizedBox(height: 8),
          InvLabel(tr('LABEL SIZE')),
          InvPickBox(
            value: _size.short,
            semantic: 'Label size',
            onTap: () async {
              final v = await pickOne<LabelSize>(context, 'Label size', [for (final s in [LabelSize.small, LabelSize.medium, LabelSize.large]) (s, s.short, null)], current: _size);
              if (v != null) setState(() => _size = v);
            },
          ),
          const SizedBox(height: 8),
          InvLabel(tr('HOW MANY')),
          InvStepper(value: _copies, min: 1, label: 'labels', onChanged: (v) => setState(() => _copies = v.toInt().clamp(1, 500))),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(flex: 2, child: InvPrimary(tr('Print labels'), key: const ValueKey('labels-print'), busy: _busy, onPressed: _busy ? null : () => _out(printLabelPdf))),
            const SizedBox(width: 10),
            Expanded(child: InvSecondary(tr('Back'), key: const ValueKey('labels-back'), onPressed: () => setState(() => _preview = false))),
          ]),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('labels-share'),
              onPressed: _busy ? null : () => _out(shareLabelPdf),
              icon: const Icon(LucideIcons.share2, size: 15, color: kLink),
              label: Text(tr('Share PDF'), style: inter(13, 700, color: kLink)),
            ),
          ),
        ])),
        InvCard(child: Column(children: [
          Text(tr('LABEL AT ITS REAL SHAPE'), style: inter(11, 700, color: kMuted)),
          const SizedBox(height: 10),
          ShelfLabelPreview(label: _label(it), size: _size, offer: _style == ShelfLabelStyle.offer),
          const SizedBox(height: 8),
          Text('${_size.title} sticker for a thermal label printer.', textAlign: TextAlign.center, style: inter(11.5, 400, color: kMuted)),
        ])),
        const SizedBox(height: 8),
      ];
}

/// One shelf label drawn on screen at the label's shape, as the PDF prints it.
class ShelfLabelPreview extends StatelessWidget {
  const ShelfLabelPreview({super.key, required this.label, required this.size, this.offer = false});
  final LabelData label;
  final LabelSize size;
  final bool offer;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, c) {
        // shown at its size against the large label, then drawn on a fixed 300-point-wide face and scaled, so nothing overflows
        final w = (c.maxWidth * size.widthMm / LabelSize.large.widthMm).clamp(170.0, c.maxWidth);
        const face = 300.0;
        final faceH = face * size.heightMm / size.widthMm;
        final save = offer ? label.savingMinor : null;
        return SizedBox(
          key: const ValueKey('label-preview'),
          width: w,
          height: w * size.heightMm / size.widthMm,
          child: FittedBox(
            child: Container(
              width: face,
              height: faceH,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: kInk, width: 1.6)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(label.store.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(10, 800, color: kPostedText))),
                  if (size.roomy && label.category.isNotEmpty) Text(label.category.toUpperCase(), style: inter(9, 600, color: kMuted)),
                ]),
                Text(label.name, maxLines: size.roomy ? 2 : 1, overflow: TextOverflow.ellipsis, style: inter(size.roomy ? 17 : 15, 800, height: 1.15)),
                if (offer && size.roomy) Padding(padding: const EdgeInsets.only(top: 4), child: Text('OFFER PRICE', style: inter(8.5, 600, color: kMuted))),
                Row(children: [
                  Text(labelMoney(label.priceMinor), style: inter(size.roomy ? 30 : 24, 800, height: 1.1)),
                  const SizedBox(width: 6),
                  if (label.mrpMinor != null && label.mrpMinor! > label.priceMinor)
                    Flexible(child: Text('MRP ${labelMoney(label.mrpMinor!)}', maxLines: 1, style: inter(10, 500, color: kMuted).copyWith(decoration: TextDecoration.lineThrough))),
                  if (save != null) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: kLimeSoftH, borderRadius: BorderRadius.circular(99), border: Border.all(color: kPostedText)),
                      child: Text('SAVE ${labelMoney(save)}', style: inter(9, 800, color: kPostedText)),
                    ),
                  ],
                ]),
                const Spacer(),
                SizedBox(
                  height: size.roomy ? 30 : 22,
                  width: double.infinity,
                  child: SvgPicture.string(pw.Barcode.code128().toSvg(labelBarcodeData(label.code), width: 400, height: 60, drawText: false), fit: BoxFit.fill),
                ),
                const SizedBox(height: 2),
                Row(children: [
                  Expanded(child: Text(label.code, maxLines: 1, style: inter(9, 500))),
                  Text('per ${label.unit} · incl. taxes', style: inter(8.5, 400, color: kMuted)),
                ]),
              ]),
            ),
          ),
        );
      });
}
