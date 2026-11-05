import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../home/home_nav.dart';
import '../stock/label_pdf.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart' show showToast;
import 'bill_receipt.dart';
import 'devices_api.dart';
import 'printer_router.dart' show PrinterRouter, printTargetsEpoch;

// Printing through the Device manager (founder, 31 Oct 2026): a bill goes to the default receipt printer and labels to the default
// label printer. A network printer gets the job straight away (ESC/POS for receipts, TSPL for labels: no print dialog); a Bluetooth,
// USB or "phone's print service" printer gets it through the print dialog at its paper or label size; with no printer set up, the
// print dialog as before.

/// The default printer for a job (receipt, label, kot), or null. The printers come from `pos_print_targets` (0660; `dev_printers` was
/// never in the database, so every print fell back to the dialog), kept for two minutes; tests replace it.
Future<StorePrinter?> Function(String job) defaultPrinterFor = _defaultPrinterFor;

/// Tests replace the print dialog for receipts.
Future<void> Function(Uint8List pdf, String name) printReceiptDialog = (pdf, name) => Printing.layoutPdf(onLayout: (_) async => pdf, name: name);

/// After a printer is added, changed or removed (the Device manager and Settings → Devices call it): every screen loads the printers again.
void forgetPrinters() => printTargetsEpoch++;

Future<StorePrinter?> _defaultPrinterFor(String job) async {
  try {
    return (await PrinterRouter.shared.targets()).forJob(job);
  } catch (_) {
    return null; // offline or not signed in: the print dialog
  }
}

/// Where a print went, said in a toast.
enum PrintRoute { direct, dialog }

// ------------------------------------------------------------------ receipts

/// Print the customer's bill from a screen: "Printed on Counter printer." when it went straight to the printer, and why when it fell
/// back to the print dialog.
Future<void> printBill(BuildContext context, BillReceipt bill) => _printing(context, (onFallback) => printBillReceipt(bill, onFallback: onFallback));

/// Print a plain-text slip (a cart's items for the packer), the same way.
Future<void> printSlip(BuildContext context, String text, {String title = 'Slip'}) =>
    _printing(context, (onFallback) => printReceiptText(text, title: title, store: HomeNav.storeName ?? '', onFallback: onFallback));

Future<void> _printing(BuildContext context, Future<({PrintRoute route, String printer})> Function(void Function(String why) onFallback) run) async {
  try {
    final r = await run((why) {
      if (context.mounted) showToast(context, '${tr(why)}. ${tr('Printing with the print dialog.')}');
    });
    if (r.route == PrintRoute.direct && context.mounted) showToast(context, '${tr('Printed on')} ${r.printer}.');
  } catch (_) {
    if (context.mounted) showToast(context, tr('Could not print. Check the printer in Settings → Devices.'));
  }
}

/// The customer's bill on the default receipt printer: a network printer straight away, otherwise the print dialog
/// with the ticket-style bill at the paper's width.
Future<({PrintRoute route, String printer})> printBillReceipt(BillReceipt bill, {void Function(String why)? onFallback}) async {
  final p = await defaultPrinterFor('receipt');
  if (p != null && p.direct && !kIsWeb) {
    try {
      final one = billEscPos(bill, printer: p);
      await sendRawToPrinter(p.host, p.port, [for (var i = 0; i < p.copies; i++) ...one]);
      return (route: PrintRoute.direct, printer: p.name);
    } catch (_) {
      onFallback?.call('${p.name} did not answer at ${p.host}:${p.port}');
    }
  }
  await printReceiptDialog(await billReceiptPdf(bill, paperMm: p?.paperMm ?? 80), 'Receipt ${bill.billNo}');
  return (route: PrintRoute.dialog, printer: p?.name ?? '');
}

/// Prints a plain-text bill on the default receipt printer. Answers where it went; a network printer that does not
/// answer falls back to the print dialog (the error is in [onFallback]).
Future<({PrintRoute route, String printer})> printReceiptText(
  String text, {
  String title = 'Receipt',
  String store = '',
  void Function(String why)? onFallback,
}) async {
  final p = await defaultPrinterFor('receipt');
  if (p != null && p.direct && !kIsWeb) {
    try {
      final one = escPosReceipt(text, store: store, printer: p);
      await sendRawToPrinter(p.host, p.port, [for (var i = 0; i < p.copies; i++) ...one]);
      return (route: PrintRoute.direct, printer: p.name);
    } catch (_) {
      onFallback?.call('${p.name} did not answer at ${p.host}:${p.port}');
    }
  }
  await printReceiptDialog(await receiptPdf(text, store: store, paperMm: p?.paperMm ?? 80), title);
  return (route: PrintRoute.dialog, printer: p?.name ?? '');
}

/// ESC/POS: the store's name in bold and centred, the bill's lines wrapped to the paper (32 or 48 characters), feed, cut.
List<int> escPosReceipt(String text, {String store = '', required StorePrinter printer}) {
  final cols = printer.paperMm == 58 ? 32 : 48;
  List<int> ascii(String s) => s.replaceAll('₹', 'Rs ').codeUnits.map((c) => c < 128 ? c : 0x3F).toList();
  final one = <int>[0x1B, 0x40]; // reset
  if (store.isNotEmpty) {
    one.addAll([0x1B, 0x61, 0x01, 0x1B, 0x45, 0x01]); // centre, bold
    one.addAll(ascii(store.toUpperCase()));
    one.addAll([0x0A, 0x1B, 0x45, 0x00, 0x1B, 0x61, 0x00]); // bold off, left
  }
  for (final raw in text.split('\n')) {
    var line = raw;
    while (line.length > cols) {
      one.addAll(ascii(line.substring(0, cols)));
      one.add(0x0A);
      line = line.substring(cols);
    }
    one.addAll(ascii(line));
    one.add(0x0A);
  }
  one.addAll([0x1B, 0x64, 0x04]); // feed
  if (printer.autoCut) one.addAll([0x1D, 0x56, 0x42, 0x00]);
  return one;
}

/// The bill as a roll the width of the receipt paper (58 or 80 mm), for the print dialog.
Future<Uint8List> receiptPdf(String text, {String store = '', int paperMm = 80}) async {
  pw.Font? mono;
  try {
    mono = pw.Font.ttf(await rootBundle.load('fonts/Inter.ttf'));
  } catch (_) {}
  final doc = pw.Document();
  final format = paperMm == 58 ? PdfPageFormat.roll57 : PdfPageFormat.roll80;
  doc.addPage(
    pw.Page(
      pageFormat: format.copyWith(
        marginLeft: 3 * PdfPageFormat.mm,
        marginRight: 3 * PdfPageFormat.mm,
        marginTop: 4 * PdfPageFormat.mm,
        marginBottom: 6 * PdfPageFormat.mm,
      ),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (store.isNotEmpty)
            pw.Center(
              child: pw.Text(
                store,
                style: pw.TextStyle(font: mono, fontSize: 10, fontWeight: pw.FontWeight.bold),
              ),
            ),
          if (store.isNotEmpty) pw.SizedBox(height: 4),
          for (final l in text.split('\n')) pw.Text(l.replaceAll('₹', 'Rs '), style: pw.TextStyle(font: mono, fontSize: 8)),
        ],
      ),
    ),
  );
  return doc.save();
}

// ------------------------------------------------------------------ labels

/// The label size the default label printer's roll has, when the app has that size (else [fallback]).
LabelSize labelSizeFor(StorePrinter? p, LabelSize fallback) => switch (p?.labelSize) {
  '50x25' => LabelSize.small,
  '50x30' => LabelSize.product,
  '75x50' => LabelSize.medium,
  _ => fallback,
};

/// Labels straight to a network label printer (TSPL). False when there is none (or it did not answer), so the caller prints the PDF.
Future<bool> printLabelsDirect(List<(LabelData, int)> labels, {void Function(String why)? onFallback}) async {
  final p = await defaultPrinterFor('label');
  if (p == null || !p.direct || kIsWeb) return false;
  try {
    await sendRawToPrinter(p.host, p.port, tsplLabels(labels, printer: p));
    return true;
  } catch (_) {
    onFallback?.call('${p.name} did not answer at ${p.host}:${p.port}');
    return false;
  }
}

/// TSPL (TSC and most thermal label printers): the label size, then per label its name, price and barcode (EAN-13 for a 13-digit
/// code, Code 128 otherwise), PRINT with its copies. 203 dpi: 8 dots a millimetre.
List<int> tsplLabels(List<(LabelData, int)> labels, {required StorePrinter printer}) {
  final size = printer.labelSize.isEmpty ? '50x30' : printer.labelSize;
  final w = double.tryParse(size.split('x').first) ?? 50, h = double.tryParse(size.split('x').last) ?? 30;
  String clean(String s) => s.replaceAll('"', "'").replaceAll('₹', 'Rs ').runes.map((c) => c < 128 ? String.fromCharCode(c) : '?').join();
  final out = StringBuffer()
    ..write('SIZE ${w.toStringAsFixed(0)} mm,${h.toStringAsFixed(0)} mm\r\n')
    ..write('GAP 2 mm,0 mm\r\nDIRECTION 1\r\n');
  final dotsW = (w * 8).round(), dotsH = (h * 8).round();
  for (final (l, copies) in labels) {
    if (copies <= 0) continue;
    final ean = RegExp(r'^[0-9]{12,13}$').hasMatch(l.code);
    final barH = (dotsH * 0.38).round();
    out
      ..write('CLS\r\n')
      ..write('TEXT 16,10,"2",0,1,1,"${clean(l.name.length > (w / 2.2).floor() ? l.name.substring(0, (w / 2.2).floor()) : l.name)}"\r\n')
      ..write(
        'TEXT 16,${(dotsH * 0.2).round()},"3",0,1,1,"${clean(labelMoney(l.priceMinor, rupee: false))}${l.mrpMinor != null && l.mrpMinor! > l.priceMinor ? '  MRP ${clean(labelMoney(l.mrpMinor!, rupee: false))}' : ''}"\r\n',
      )
      ..write(
        'BARCODE ${((dotsW - (ean ? 230 : 260)) / 2).round().clamp(8, dotsW)},${(dotsH * 0.42).round()},"${ean ? 'EAN13' : '128'}",$barH,1,0,2,2,"${clean(l.code)}"\r\n',
      )
      ..write('PRINT 1,${copies.clamp(1, 999)}\r\n');
  }
  return out.toString().codeUnits;
}
