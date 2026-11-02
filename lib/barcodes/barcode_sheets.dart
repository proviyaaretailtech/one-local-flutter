import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:pdf/widgets.dart' as pw;

import '../auth/partner_api.dart';
import '../orders/order_widgets.dart';
import '../orders/orders_api.dart' show rupees;
import '../stock/label_pdf.dart';
import '../stock/labels_screens.dart' show printLabelPdf;
import '../devices/print_service.dart' show defaultPrinterFor, labelSizeFor, printLabelsDirect;
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'barcodes_api.dart';

// The one "Make barcode" sheet (founder, 30 Oct 2026): the same on the Barcodes page and on the Bill, so a vendor learns it once.
// Printing is always optional and always the second button.

/// Prints barcode stickers (50 × 30 mm) through the device's print screen. Tests replace [printLabelPdf].
/// [size]: Standard (the 50 × 30 mm sticker) or Large (3 × 2 in).
Future<void> printBarcodeLabels(List<(LabelData, int)> labels, {LabelSize size = LabelSize.product}) async {
  // the default label printer (Settings → Devices): a network one prints them straight away
  if (await printLabelsDirect(labels)) return;
  size = labelSizeFor(await defaultPrinterFor('label'), size);
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

// A loose item's weight is typed in grams or kilograms (founder, 1 Nov 2026: "300 gm and stuff"): a g / kg switch beside the field.

/// The weight typed, in grams: [unit] 'g' takes whole grams, 'kg' up to 3 decimals. Null when empty or outside 1 g to 99.999 kg.
int? gramsOf(String text, String unit) {
  final v = double.tryParse(text.trim());
  if (v == null || v <= 0) return null;
  final g = unit == 'g' ? v.round() : (v * 1000).round();
  return g < 1 || g > 99999 ? null : g;
}

/// [grams] written for [unit]: 300 → "300" (g) or "0.3" (kg).
String weightFor(int grams, String unit) {
  if (unit == 'g') return '$grams';
  final kg = (grams / 1000).toStringAsFixed(3);
  return kg.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// What a weight field accepts in each unit: whole grams up to 99999, or kg with up to 3 decimals.
List<TextInputFormatter> weightFormatters(String unit) =>
    [FilteringTextInputFormatter.allow(unit == 'g' ? RegExp(r'^\d{0,5}') : RegExp(r'^\d{0,2}(\.\d{0,3})?'))];

/// g | kg, as the field's suffix. Switching keeps the weight: 300 g becomes 0.3 kg.
class WeightUnitSwitch extends StatelessWidget {
  const WeightUnitSwitch({super.key, required this.unit, required this.onChanged, this.keyPrefix = 'weigh-unit'});
  final String unit;
  final ValueChanged<String> onChanged;
  final String keyPrefix;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: 8),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: const Color(0xFFF1F3EE), borderRadius: BorderRadius.circular(10)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final u in const ['g', 'kg'])
            GestureDetector(
              key: ValueKey('$keyPrefix-$u'),
              onTap: () => onChanged(u),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: unit == u ? kInk : Colors.transparent, borderRadius: BorderRadius.circular(8)),
                child: Text(u, style: inter(14, 800, color: unit == u ? Colors.white : kMuted)),
              ),
            ),
        ]),
      );
}

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
  String _unit = 'kg';
  bool _busy = false;
  String? _error;

  /// The weight typed, in grams, or null.
  int? get _grams => gramsOf(_kg.text, _unit);

  num get _amount => ((widget.item.price * (_grams ?? 0) / 1000) * 100).round() / 100;

  bool _check() {
    setState(() => _error = _grams == null ? tr(_unit == 'g' ? 'Enter the weight in grams, from 1 to 99999.' : 'Enter the weight in kg, from 0.001 to 99.999.') : null);
    return _grams != null;
  }

  /// g ↔ kg: the weight typed stays the same weight.
  void _setUnit(String u) {
    if (u == _unit) return;
    final g = _grams;
    setState(() {
      _unit = u;
      _kg.text = g == null ? '' : weightFor(g, u);
      _error = null;
    });
  }

  /// A quick weight: 250 g and 500 g in grams, whole kilos in kg.
  void _quick(int grams) => setState(() {
        _unit = grams < 1000 ? 'g' : 'kg';
        _kg.text = weightFor(grams, _unit);
        _error = null;
      });

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
          keyboardType: TextInputType.numberWithOptions(decimal: _unit == 'kg'),
          inputFormatters: weightFormatters(_unit),
          style: inter(22, 800),
          decoration: InputDecoration(
            labelText: tr('Weight'),
            hintText: _unit == 'g' ? '300' : '1.250',
            errorText: _error,
            suffixIcon: WeightUnitSwitch(unit: _unit, onChanged: _setUnit),
            suffixIconConstraints: const BoxConstraints(minHeight: 40),
          ),
          onChanged: (_) => setState(() => _error = null),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (label, key, grams) in const [('250 g', '0.25', 250), ('500 g', '0.5', 500), ('1 kg', '1', 1000), ('2 kg', '2', 2000), ('5 kg', '5', 5000)])
            ActionChip(key: ValueKey('weigh-$key'), label: Text(label, style: inter(13, 700)), onPressed: () => _quick(grams)),
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
