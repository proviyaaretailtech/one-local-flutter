import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// The two label sizes: product stickers (50 × 30 mm) and shelf-edge strips (80 × 40 mm).
enum LabelSize {
  product(50, 30, 'Product label · 50 × 30 mm'),
  shelf(80, 40, 'Shelf label · 80 × 40 mm'),
  // the shelf label sizes people pick (thermal label rolls are sold in inches)
  small(50.8, 25.4, 'Small · 2 × 1 in', short: 'Small (2"×1")'),
  medium(76.2, 50.8, 'Medium · 3 × 2 in', short: 'Medium (3"×2")'),
  large(101.6, 76.2, 'Large · 4 × 3 in', short: 'Large (4"×3")');

  const LabelSize(this.widthMm, this.heightMm, this.title, {this.short = ''});
  final double widthMm, heightMm;
  final String title, short;

  /// Room for big type, two name lines and the shelf line.
  bool get roomy => heightMm >= 40;

  PdfPageFormat get format => PdfPageFormat(widthMm * PdfPageFormat.mm, heightMm * PdfPageFormat.mm, marginAll: 2 * PdfPageFormat.mm);
}

/// What one label shows. Prices are in paise; [code] goes into the barcode (the product's barcode, else its System Code).
class LabelData {
  const LabelData({required this.name, required this.priceMinor, required this.code, required this.systemCode, this.mrpMinor, this.unit = 'pc', this.store = '', this.shelf, this.category = ''});
  final String name, code, systemCode, unit, store, category;
  final int priceMinor;
  final int? mrpMinor;

  /// What the customer saves against the MRP, when the price is below it.
  int? get savingMinor => mrpMinor != null && mrpMinor! > priceMinor ? mrpMinor! - priceMinor : null;

  /// Shelf labels: where the product sits ("Shelf A-01").
  final String? shelf;
}

/// "₹40" / "₹40.50" (with [rupee] false: "Rs 40", for a PDF font without the ₹ sign).
String labelMoney(int minor, {bool rupee = true}) {
  final whole = minor % 100 == 0;
  final v = whole ? '${minor ~/ 100}' : (minor / 100).toStringAsFixed(2);
  return rupee ? '₹$v' : 'Rs $v';
}

/// Code 128 only carries plain ASCII; anything else becomes '-' so the barcode always draws.
String labelBarcodeData(String code) => code.trim().replaceAll(RegExp(r'[^\x20-\x7E]'), '-');

/// One page per label, sized for a label printer (most print one label per page). [copies] repeats a label. [font] / [bold] should carry the
/// ₹ sign (the app's Inter); without them the built-in font is used and prices read "Rs 40". [offer]: the offer label, with "Offer price",
/// the MRP struck through and "Save ₹5" when the price is below the MRP.
Future<Uint8List> buildLabelsPdf(List<(LabelData label, int copies)> labels, {required LabelSize size, pw.Font? font, pw.Font? bold, bool offer = false}) async {
  final doc = pw.Document(title: size == LabelSize.product ? 'Product labels' : 'Shelf labels', author: 'OneLocal');
  final rupee = font != null;
  pw.TextStyle st(double s, {bool strong = false, PdfColor? color, bool strike = false}) => pw.TextStyle(
        font: strong ? (bold ?? font) : font,
        fontBold: bold,
        fontSize: s,
        fontWeight: strong ? pw.FontWeight.bold : pw.FontWeight.normal,
        color: color,
        decoration: strike ? pw.TextDecoration.lineThrough : null,
      );
  final shelf = size.roomy, large = size == LabelSize.large;
  for (final (l, copies) in labels) {
    final save = offer ? l.savingMinor : null;
    for (var i = 0; i < copies; i++) {
      doc.addPage(pw.Page(
        pageFormat: size.format,
        build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          if (l.store.isNotEmpty || (shelf && l.category.isNotEmpty))
            pw.Row(children: [
              pw.Expanded(child: pw.Text(l.store.toUpperCase(), style: st(shelf ? 6.5 : 5, strong: true, color: PdfColors.grey700), maxLines: 1)),
              if (shelf && l.category.isNotEmpty) pw.Text(l.category.toUpperCase(), style: st(6, color: PdfColors.grey700), maxLines: 1),
            ]),
          pw.Text(l.name, style: st(large ? 14 : (shelf ? 11 : 8), strong: true), maxLines: shelf ? 2 : 1),
          pw.SizedBox(height: shelf ? 2 : 1),
          if (offer && shelf) pw.Text('OFFER PRICE', style: st(5.5, color: PdfColors.grey700)),
          pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text(labelMoney(l.priceMinor, rupee: rupee), style: st(large ? 26 : (shelf ? 20 : 13), strong: true)),
            pw.SizedBox(width: 4),
            if (l.mrpMinor != null && l.mrpMinor! > l.priceMinor)
              pw.Padding(padding: const pw.EdgeInsets.only(bottom: 2), child: pw.Text('MRP ${labelMoney(l.mrpMinor!, rupee: rupee)}', style: st(shelf ? 7 : 5.5, color: PdfColors.grey700, strike: true))),
            if (save != null) ...[
              pw.SizedBox(width: 4),
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.6), borderRadius: pw.BorderRadius.circular(6)),
                child: pw.Text('SAVE ${labelMoney(save, rupee: rupee)}', style: st(shelf ? 6.5 : 5, strong: true)),
              ),
            ],
            pw.Spacer(),
            pw.Padding(padding: const pw.EdgeInsets.only(bottom: 2), child: pw.Text('per ${l.unit}', style: st(shelf ? 7 : 5.5, color: PdfColors.grey700))),
          ]),
          pw.Spacer(),
          pw.BarcodeWidget(
            barcode: pw.Barcode.code128(),
            data: labelBarcodeData(l.code),
            height: shelf ? 9 * PdfPageFormat.mm : 7 * PdfPageFormat.mm,
            drawText: true,
            textStyle: st(shelf ? 6.5 : 5),
          ),
          if (shelf && (l.shelf ?? '').isNotEmpty) ...[
            pw.SizedBox(height: 1),
            pw.Text('${l.shelf} · ${l.systemCode}', style: st(6, color: PdfColors.grey700), maxLines: 1),
          ],
        ]),
      ));
    }
  }
  return doc.save();
}
