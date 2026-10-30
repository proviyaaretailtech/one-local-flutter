import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:pdf/widgets.dart' as pw;

import '../auth/partner_api.dart';
import '../orders/order_widgets.dart';
import '../orders/orders_api.dart' show rupees;
import '../stock/label_pdf.dart';
import '../stock/labels_screens.dart' show printLabelPdf;
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'barcodes_api.dart';

// The one "Make barcode" sheet (founder, 30 Oct 2026): the same on the Barcodes page and on the Bill, so a vendor learns it once.
// Printing is always optional and always the second button.

/// Prints barcode stickers (50 × 30 mm) through the device's print screen. Tests replace [printLabelPdf].
/// [size]: Standard (the 50 × 30 mm sticker) or Large (3 × 2 in).
Future<void> printBarcodeLabels(List<(LabelData, int)> labels, {LabelSize size = LabelSize.product}) async {
  pw.Font? font;
  try {
    font = pw.Font.ttf(await rootBundle.load('fonts/Inter.ttf'));
  } catch (_) {}
  final pdf = await buildLabelsPdf(labels, size: size, font: font, bold: font);
  await printLabelPdf(pdf, 'Barcode labels');
}

LabelData itemLabel(BcItem i, {String store = ''}) => LabelData(
      name: i.name,
      priceMinor: (i.price * 100).round(),
      code: i.barcode ?? i.sku,
      systemCode: i.loose && i.plu != null ? 'PLU ${i.plu}' : i.sku,
      mrpMinor: i.mrpMinor,
      unit: i.loose ? 'kg' : 'pc',
      store: store,
    );

/// A barcode drawn on screen with its digits under it.
class BarcodeView extends StatelessWidget {
  const BarcodeView(this.code, {super.key, this.height = 64});
  final String code;
  final double height;
  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('barcode-view'),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(height: height, width: double.infinity, child: SvgPicture.string(pw.Barcode.code128().toSvg(labelBarcodeData(code), width: 400, height: 80, drawText: false), fit: BoxFit.fill)),
          const SizedBox(height: 6),
          SelectableText(code, style: inter(15, 700, height: 1.1).copyWith(letterSpacing: 1.5)),
        ]),
      );
}

String _err(Object e, String fallback) => e is PartnerApiException ? e.message : fallback;

/// Weighs one pack of a loose item: type the weight (or tap a common one), see the amount. With [canAdd] the pack can go straight onto the
/// bill (answers the grams); "Print weigh label" prints the 21-code sticker (answers the grams too, after printing).
Future<int?> showWeighSheet(BuildContext context, BarcodesApi api, BcItem item, {String store = '', bool canAdd = true}) =>
    showOrderSheet<int>(context, title: 'Weigh ${item.name}', body: (_) => _Weigh(api: api, item: item, store: store, canAdd: canAdd));

class _Weigh extends StatefulWidget {
  const _Weigh({required this.api, required this.item, required this.store, required this.canAdd});
  final BarcodesApi api;
  final BcItem item;
  final String store;
  final bool canAdd;
  @override
  State<_Weigh> createState() => _WeighState();
}

class _WeighState extends State<_Weigh> {
  final _kg = TextEditingController();
  bool _busy = false;
  String? _error;

  /// The weight typed, in grams (kg with up to 3 decimals), or null.
  int? get _grams {
    final v = double.tryParse(_kg.text.trim());
    if (v == null || v <= 0) return null;
    final g = (v * 1000).round();
    return g < 1 || g > 99999 ? null : g;
  }

  num get _amount => ((widget.item.price * (_grams ?? 0) / 1000) * 100).round() / 100;

  bool _check() {
    setState(() => _error = _grams == null ? tr('Enter the weight in kg, from 0.001 to 99.999.') : null);
    return _grams != null;
  }

  Future<void> _print() async {
    if (!_check()) return;
    setState(() => _busy = true);
    try {
      final l = await widget.api.weighLabel(widget.item.id, _grams!);
      await printBarcodeLabels([
        (LabelData(name: '${l.item.name} · ${l.weightText}', priceMinor: (l.amount * 100).round(), code: l.code, systemCode: 'PLU ${l.item.plu ?? ''} · ${rupees(l.pricePerKg)}/kg', unit: 'pack', store: widget.store), 1),
      ]);
      if (mounted) Navigator.pop(context, l.weightG);
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not make the label. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${rupees(widget.item.price)} per kg', style: inter(13, 500, color: kMuted)),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('weigh-kg'),
          controller: _kg,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,2}(\.\d{0,3})?'))],
          style: inter(22, 800),
          decoration: InputDecoration(labelText: tr('Weight'), suffixText: 'kg', errorText: _error),
          onChanged: (_) => setState(() => _error = null),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (label, kg) in const [('250 g', '0.25'), ('500 g', '0.5'), ('1 kg', '1'), ('2 kg', '2'), ('5 kg', '5')])
            ActionChip(
              key: ValueKey('weigh-$kg'),
              label: Text(label, style: inter(13, 700)),
              onPressed: () => setState(() {
                _kg.text = kg;
                _error = null;
              }),
            ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Text(tr('Amount'), style: inter(15, 700)),
          const Spacer(),
          Text(_grams == null ? '—' : rupees(_amount), key: const ValueKey('weigh-amount'), style: inter(22, 800, color: kGreenText)),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          if (widget.canAdd) ...[
            Expanded(flex: 3, child: DarkCta(key: const ValueKey('weigh-add'), label: tr('Add to bill'), onPressed: _busy ? null : () => _check() ? Navigator.pop(context, _grams) : null)),
            const SizedBox(width: 10),
          ],
          Expanded(flex: 2, child: LightCta(key: const ValueKey('weigh-print'), label: tr(widget.canAdd ? 'Print label' : 'Print weigh label'), onPressed: _busy ? null : _print)),
        ]),
      ]);
}
