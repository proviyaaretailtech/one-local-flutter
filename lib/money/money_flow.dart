import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/partner_api.dart';
import '../onboarding/document_picker.dart';
import '../purchasing/add_supplier_sheet.dart' show pickPhoneContact;
import '../ui/app_header.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart';
import '../ui/whatsapp.dart';
import 'money_style.dart';
import 'store_money.dart';

export '../ui/whatsapp.dart' show whatsAppLink;

// Money in / Money out (founder's sketches, 28 Oct 2026): the total for the dates chosen, Add money (or Pay money) and a PDF of the list,
// Cash / UPI / Card chips, then the entries. The add form: type, amount, date, how it moved, the party (from contacts), a proof photo,
// and Generate receipt / WhatsApp / SMS / Save entry. A receipt can be shared on WhatsApp, printed or sent by SMS.

/// The phone's document scanner for a proof photo (Android): it finds the paper's edges and straightens it. Tests replace these.
bool Function() canScanProof = () => !kIsWeb && Platform.isAndroid;
Future<PickedDocument?> Function() scanProof = () async {
  final scanner = DocumentScanner(
    options: DocumentScannerOptions(documentFormats: {DocumentFormat.jpeg}, mode: ScannerMode.filter, pageLimit: 1, isGalleryImport: false),
  );
  try {
    final path = (await scanner.scanDocument()).images?.firstOrNull;
    if (path == null) return null;
    return PickedDocument(name: 'proof.jpg', bytes: await File(path).readAsBytes(), contentType: 'image/jpeg');
  } catch (_) {
    return null; // closed without a photo, or no camera
  } finally {
    await scanner.close();
  }
};
Future<PickedDocument?> Function() pickProofFile = () => const DevicePicker().pick();

/// Opens a link outside the app (WhatsApp, SMS, a UPI app, a proof photo). False when nothing could open it.
Future<bool> Function(Uri uri) openMoneyLink = (uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
};
Future<void> Function(Uint8List pdf, String name) printMoneyPdf = (pdf, name) => Printing.layoutPdf(onLayout: (_) async => pdf, name: name);
Future<void> Function(Uint8List pdf, String name) shareMoneyPdf = (pdf, name) => Printing.sharePdf(bytes: pdf, filename: name);

String _digits(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');



Uri smsLink(String phone, String text) {
  final d = _digits(phone);
  return Uri(scheme: 'sms', path: d.length >= 10 ? '+91${d.substring(d.length - 10)}' : '', queryParameters: {'body': text});
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// An Indian mobile number as people write it: 86683 20699.
String prettyPhone(String phone) {
  final d = _digits(phone);
  if (d.length < 10) return phone.trim();
  final last = d.substring(d.length - 10);
  return '${last.substring(0, 5)} ${last.substring(5)}';
}

String _pdfRs(num? minor) => rs(minor).replaceAll('₹', 'Rs. '); // the built-in PDF font has no rupee sign

/// The app's fonts for PDFs (Inter, Poppins Bold): they carry the ₹ sign. Null where they cannot be loaded.
Future<(pw.Font, pw.Font)?> _pdfFonts() async {
  try {
    return (pw.Font.ttf(await rootBundle.load('fonts/Inter.ttf')), pw.Font.ttf(await rootBundle.load('fonts/Poppins-Bold.ttf')));
  } catch (_) {
    return null;
  }
}

const _monthsLong = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

/// The Money in / Money out report (founder, 28 Oct 2026, a report-style layout): a dark band with the shop and OneLocal, the title and
/// dates, a summary card (total, then cash / UPI / card / bank), the entries as a table with a grand total, when it was made, and a footer
/// band with the page number.
Future<Uint8List> moneyReportPdf({
  required String direction,
  required DateTime from,
  required DateTime to,
  required List<Map<String, dynamic>> rows,
  Map<String, dynamic> shop = const {},
  String filter = 'All',
  DateTime? generatedAt,
}) async {
  final fonts = await _pdfFonts();
  final money = fonts == null ? _pdfRs : rs;
  final isIn = direction == 'in';
  final now = generatedAt ?? DateTime.now();
  const ink = PdfColor.fromInt(0xFF111827), grey = PdfColor.fromInt(0xFF6B7280), line = PdfColor.fromInt(0xFFE5E7EB), head = PdfColor.fromInt(0xFFF3F4F6);
  const deep = PdfColor.fromInt(0xFF16181D), lime = PdfColor.fromInt(0xFFD2F64B);
  final accent = isIn ? const PdfColor.fromInt(0xFF15803D) : const PdfColor.fromInt(0xFFC62828);
  pw.TextStyle t(double size, {bool strong = false, PdfColor color = ink}) =>
      pw.TextStyle(fontSize: size, color: color, font: strong ? fonts?.$2 : fonts?.$1, fontWeight: strong ? pw.FontWeight.bold : null);

  String longDay(DateTime d) => '${d.day} ${_monthsLong[d.month - 1]} ${d.year}';
  String time(Map<String, dynamic> r) {
    final at = DateTime.tryParse('${r['created_at'] ?? ''}')?.toLocal();
    if (at == null) return '';
    final h = at.hour % 12 == 0 ? 12 : at.hour % 12;
    return '$h:${at.minute.toString().padLeft(2, '0')} ${at.hour < 12 ? 'AM' : 'PM'}';
  }

  num sum(Iterable<Map<String, dynamic>> rs) => rs.fold<num>(0, (s, r) => s + ((r['amount_minor'] as num?) ?? 0));
  final total = sum(rows);
  String fam(Map<String, dynamic> r) => '${r['family'] ?? ''}'.isNotEmpty ? '${r['family']}' : '${r['method'] ?? r['account'] ?? ''}';
  final split = [
    for (final (id, label) in const [('cash', 'Cash'), ('upi', 'UPI'), ('card', 'Card'), ('bank', 'Bank')])
      if (id != 'bank' || rows.any((r) => fam(r) == 'bank')) (label, sum(rows.where((r) => fam(r) == id))),
  ];
  final shopName = '${shop['name'] ?? ''}'.trim();

  pw.Widget cell(String text, {bool strong = false, PdfColor? color, pw.TextAlign align = pw.TextAlign.left, String? sub}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 6),
        child: pw.Column(crossAxisAlignment: align == pw.TextAlign.right ? pw.CrossAxisAlignment.end : pw.CrossAxisAlignment.start, children: [
          pw.Text(text, textAlign: align, style: t(8.5, strong: strong, color: color ?? ink)),
          if (sub != null && sub.isNotEmpty) pw.Text(sub, textAlign: align, style: t(7, color: grey)),
        ]),
      );

  final doc = pw.Document(title: '${isIn ? 'Money In' : 'Money Out'} Report');
  doc.addPage(pw.MultiPage(
    pageTheme: pw.PageTheme(
      pageFormat: PdfPageFormat.a4.copyWith(marginLeft: 32, marginRight: 32, marginTop: 70, marginBottom: 56),
      buildBackground: (ctx) => pw.FullPage(
        ignoreMargins: true,
        child: pw.Column(children: [
          pw.Container(
            height: 44,
            color: deep,
            padding: const pw.EdgeInsets.symmetric(horizontal: 32),
            child: pw.Row(children: [
              pw.Expanded(child: pw.Text(shopName.isEmpty ? 'Your shop' : shopName, style: t(11, strong: true, color: PdfColors.white))),
              pw.Text('One', style: t(13, strong: true, color: PdfColors.white)),
              pw.Text('Local', style: t(13, strong: true, color: lime)),
            ]),
          ),
          pw.Spacer(),
          pw.Container(
            height: 36,
            color: deep,
            padding: const pw.EdgeInsets.symmetric(horizontal: 32),
            child: pw.Row(children: [
              pw.Expanded(child: pw.Text('Made with OneLocal  ·  Your local shop, online', style: t(8, color: PdfColors.white))),
              pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: t(8, color: PdfColors.white)),
            ]),
          ),
        ]),
      ),
    ),
    build: (ctx) => [
      pw.Center(child: pw.Text('${isIn ? 'Money In' : 'Money Out'} Report', style: t(16, strong: true))),
      pw.SizedBox(height: 2),
      pw.Center(child: pw.Text(from == to ? '(${longDay(from)})' : '(${longDay(from)} – ${longDay(to)})', style: t(9.5, color: grey))),
      if ('${shop['address'] ?? ''}'.trim().isNotEmpty) ...[
        pw.SizedBox(height: 2),
        pw.Center(child: pw.Text('${shop['address']}', textAlign: pw.TextAlign.center, style: t(7.5, color: grey))),
      ],
      pw.SizedBox(height: 16),
      // the summary card: the total, then each way the money moved
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 12),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: line), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8))),
        child: pw.Row(children: [
          for (final (i, (label, value)) in [(isIn ? 'Total received' : 'Total paid', total), ...split].indexed) ...[
            if (i > 0) pw.Container(width: 1, height: 30, color: line),
            pw.Expanded(
              child: pw.Column(children: [
                pw.Text(label, style: t(8, color: grey)),
                pw.SizedBox(height: 4),
                pw.Text(money(value), style: t(i == 0 ? 12 : 10.5, strong: true, color: i == 0 ? accent : ink)),
              ]),
            ),
          ],
        ]),
      ),
      pw.SizedBox(height: 12),
      pw.Text('No. of entries: ${rows.length} ($filter)', style: t(8.5, strong: true)),
      pw.SizedBox(height: 6),
      pw.Table(
        border: pw.TableBorder.all(color: line, width: 0.8),
        columnWidths: const {0: pw.FlexColumnWidth(1.3), 1: pw.FlexColumnWidth(1.1), 2: pw.FlexColumnWidth(2.2), 3: pw.FlexColumnWidth(1.6), 4: pw.FlexColumnWidth(0.9), 5: pw.FlexColumnWidth(1.2)},
        children: [
          pw.TableRow(decoration: const pw.BoxDecoration(color: head), repeat: true, children: [
            cell('Date & time', strong: true),
            cell('Receipt no.', strong: true),
            cell(isIn ? 'Received from' : 'Paid to', strong: true),
            cell('Type', strong: true),
            cell('Method', strong: true),
            cell(isIn ? 'Amount in' : 'Amount out', strong: true, align: pw.TextAlign.right),
          ]),
          for (final r in rows)
            pw.TableRow(children: [
              cell(dayMonth('${r['date']}'), sub: time(r)),
              cell('${r['no'] ?? '-'}'),
              cell(r['auto'] == true ? 'Sales (POS)' : '${r['party'] ?? ''}'.trim().ifEmpty('-'), strong: true, sub: '${r['party_phone'] ?? ''}'.trim().isEmpty ? null : prettyPhone('${r['party_phone']}')),
              cell(entryType(r)),
              cell(kMethodNames['${r['method']}'] ?? '${r['method'] ?? ''}'),
              cell(money(r['amount_minor'] as num?), strong: true, color: accent, align: pw.TextAlign.right),
            ]),
        ],
      ),
      pw.Container(
        margin: const pw.EdgeInsets.only(top: 6),
        padding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 8),
        decoration: pw.BoxDecoration(color: head, border: pw.Border.all(color: line, width: 0.8)),
        child: pw.Row(children: [
          pw.Expanded(child: pw.Text('Grand Total', style: t(9.5, strong: true))),
          pw.Text(money(total), style: t(10.5, strong: true, color: accent)),
        ]),
      ),
      pw.SizedBox(height: 10),
      pw.Text(
        'Report generated: ${time({'created_at': now.toIso8601String()})}  |  ${now.day} ${_months[now.month - 1]}\'${(now.year % 100).toString().padLeft(2, '0')}',
        style: t(8, color: grey),
      ),
    ],
  ));
  return doc.save();
}

// ------------------------------------------------------------------------------------------------------------------- receipt
/// One entry as a receipt: what the summary shows and shares.
class MoneyReceipt {
  const MoneyReceipt(this.e, {this.shop = const {}});
  final Map<String, dynamic> e;

  /// The shop on the receipt: name, address, phone, GSTIN (from the Money home).
  final Map<String, dynamic> shop;
  String get shopName => '${shop['name'] ?? ''}'.trim();
  String get shopAddress => '${shop['address'] ?? ''}'.trim();
  String get shopPhone => prettyPhone('${shop['phone'] ?? ''}');
  bool get isIn => e['direction'] == 'in';
  String get no => '${e['no'] ?? ''}';
  String get party => '${e['party'] ?? ''}'.trim();
  String get phone => '${e['party_phone'] ?? ''}'.trim();
  String get method => kMethodNames['${e['method'] ?? e['account']}'] ?? '${e['method'] ?? ''}';
  num get amount => (e['amount_minor'] as num?) ?? 0;

  List<(String, String)> get lines => [
        ('Type', entryType(e)),
        ('Paid by', tr(method)),
        if (party.isNotEmpty || phone.isNotEmpty) (isIn ? 'Received from' : 'Paid to', [party, phone].where((s) => s.isNotEmpty).join(' · ')),
        if ('${e['category'] ?? ''}'.isNotEmpty && !kOtherKinds.contains(e['kind'])) ('Head', tr('${e['category']}')),
        ('Date', dayMonth('${e['date']}')),
        if (no.isNotEmpty) ('Receipt no.', no),
        if ('${e['reference'] ?? ''}'.isNotEmpty) ('Reference', '${e['reference']}'),
        if ('${e['note'] ?? ''}'.isNotEmpty) ('Note', '${e['note']}'),
      ];

  /// When it happened: the entry's day, and the time it was saved.
  String get when {
    final d = DateTime.tryParse('${e['date'] ?? ''}');
    final at = DateTime.tryParse('${e['created_at'] ?? ''}')?.toLocal();
    if (d == null) return '';
    final day = '${d.day} ${_months[d.month - 1]} ${d.year}';
    if (at == null) return day;
    final h = at.hour % 12 == 0 ? 12 : at.hour % 12;
    return '$day, $h:${at.minute.toString().padLeft(2, '0')} ${at.hour < 12 ? 'AM' : 'PM'}';
  }

  /// The message for WhatsApp and SMS (founder's pick, format C, 28 Oct 2026): the thank-you, the shop, the receipt box, a number to call.
  String get text {
    final who = [party, if (phone.isNotEmpty) party.isEmpty ? prettyPhone(phone) : '(${prettyPhone(phone)})'].where((s) => s.isNotEmpty).join(' ');
    return [
      isIn ? '🛍️ *${tr('Thank you for shopping with us!')}*' : '🤝 *${tr('Thank you for doing business with us!')}*',
      '',
      if (shopName.isNotEmpty) '*$shopName*',
      if (shopAddress.isNotEmpty) shopAddress,
      if (shopName.isNotEmpty || shopAddress.isNotEmpty) '',
      '┌ ${tr('Receipt')} $no'.trimRight(),
      if (when.isNotEmpty) '│ $when',
      if (who.isNotEmpty) '│ ${tr(isIn ? 'From' : 'To')}: $who',
      '│ ${tr('For')}: ${entryType(e)}',
      if (method.isNotEmpty) '│ ${tr('Paid by')}: ${tr(method)}',
      if ('${e['reference'] ?? ''}'.isNotEmpty) '│ ${tr('Reference')}: ${e['reference']}',
      '└ *${tr('Total')}: ${rs(amount)}* ✅',
      if (shopPhone.isNotEmpty) ...['', '${tr('Questions? Call')} $shopPhone'],
      '',
      '_OneLocal · ${tr('Your local shop, online')}_',
    ].join('\n');
  }

  /// The printed receipt, ticket style (founder's inspiration, 28 Oct 2026): the shop, a tick and "Thank you!", a torn-ticket line, the
  /// receipt no. and amount, date and time, who paid and how, another torn line, the receipt no. as a barcode, and OneLocal. Black and
  /// grey only, for counter printers (80 mm roll). Inter and Poppins carry the ₹ sign; without them it falls back to "Rs.".
  Future<Uint8List> pdf() async {
    pw.Font? regular, bold;
    try {
      regular = pw.Font.ttf(await rootBundle.load('fonts/Inter.ttf'));
      bold = pw.Font.ttf(await rootBundle.load('fonts/Poppins-Bold.ttf'));
    } catch (_) {}
    final money = regular == null ? _pdfRs : rs;
    const grey = PdfColor.fromInt(0xFF6B7280), soft = PdfColor.fromInt(0xFFF3F4F6), line = PdfColor.fromInt(0xFFC7CBD1);
    pw.TextStyle t(double size, {bool strong = false, PdfColor color = PdfColors.black}) => pw.TextStyle(fontSize: size, color: color, font: strong ? bold : regular, fontWeight: strong ? pw.FontWeight.bold : null);
    pw.Widget label(String s, {pw.TextAlign align = pw.TextAlign.left}) => pw.Text(s.toUpperCase(), textAlign: align, style: t(6.5, color: grey).copyWith(letterSpacing: 0.6));

    // the torn-ticket line: a half circle cut into each side, dashes between
    pw.Widget tear() => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 10),
          child: pw.Row(children: [
            pw.Container(width: 7, height: 14, decoration: const pw.BoxDecoration(color: line, borderRadius: pw.BorderRadius.only(topRight: pw.Radius.circular(7), bottomRight: pw.Radius.circular(7)))),
            pw.SizedBox(width: 4),
            pw.Expanded(child: pw.Container(height: 1, decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: line, width: 1, style: pw.BorderStyle.dashed))))),
            pw.SizedBox(width: 4),
            pw.Container(width: 7, height: 14, decoration: const pw.BoxDecoration(color: line, borderRadius: pw.BorderRadius.only(topLeft: pw.Radius.circular(7), bottomLeft: pw.Radius.circular(7)))),
          ]),
        );

    final who = [party, if (phone.isNotEmpty) prettyPhone(phone)].where((s) => s.isNotEmpty);
    final doc = pw.Document(title: 'Receipt $no');
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.roll80.copyWith(marginLeft: 8, marginRight: 8, marginTop: 14, marginBottom: 14),
      build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        if (shopName.isNotEmpty) pw.Text(shopName, textAlign: pw.TextAlign.center, style: t(12, strong: true)),
        if (shopAddress.isNotEmpty) pw.Text(shopAddress, textAlign: pw.TextAlign.center, style: t(7, color: grey)),
        if (shopPhone.isNotEmpty || '${shop['gstin'] ?? ''}'.isNotEmpty)
          pw.Text([if (shopPhone.isNotEmpty) 'Ph $shopPhone', if ('${shop['gstin'] ?? ''}'.isNotEmpty) 'GSTIN ${shop['gstin']}'].join('  ·  '), textAlign: pw.TextAlign.center, style: t(7, color: grey)),
        pw.SizedBox(height: 12),
        // the tick in a black circle
        pw.Center(
          child: pw.CustomPaint(
            size: const PdfPoint(30, 30),
            painter: (canvas, size) {
              canvas
                ..setFillColor(PdfColors.black)
                ..drawEllipse(15, 15, 15, 15)
                ..fillPath()
                ..setStrokeColor(PdfColors.white)
                ..setLineWidth(2.4)
                ..setLineCap(PdfLineCap.round)
                ..setLineJoin(PdfLineJoin.round)
                ..moveTo(9, 15.5)
                ..lineTo(13.5, 11)
                ..lineTo(21.5, 19.5)
                ..strokePath();
            },
          ),
        ),
        pw.SizedBox(height: 8),
        pw.Text('Thank you!', textAlign: pw.TextAlign.center, style: t(16, strong: true)),
        pw.SizedBox(height: 2),
        pw.Text(isIn ? 'Your payment has been received' : 'The payment has been made', textAlign: pw.TextAlign.center, style: t(8, color: grey)),
        tear(),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              label('Receipt no.'),
              pw.SizedBox(height: 2),
              pw.Text(no.isEmpty ? '-' : no, style: t(9.5, strong: true)),
            ]),
          ),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            label(isIn ? 'Amount received' : 'Amount paid', align: pw.TextAlign.right),
            pw.SizedBox(height: 2),
            pw.Text(money(amount), style: t(13, strong: true)),
          ]),
        ]),
        pw.SizedBox(height: 9),
        label('Date & time'),
        pw.SizedBox(height: 2),
        pw.Text(when.isEmpty ? dayMonth('${e['date']}') : when.replaceAll(', ', '  ·  '), style: t(9, strong: true)),
        pw.SizedBox(height: 10),
        // who paid and how, in a soft box with the method as a badge
        pw.Container(
          padding: const pw.EdgeInsets.all(8),
          decoration: const pw.BoxDecoration(color: soft, borderRadius: pw.BorderRadius.all(pw.Radius.circular(7))),
          child: pw.Row(children: [
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              decoration: const pw.BoxDecoration(color: PdfColors.black, borderRadius: pw.BorderRadius.all(pw.Radius.circular(5))),
              child: pw.Text(method.isEmpty ? '-' : method.toUpperCase(), style: t(7, strong: true, color: PdfColors.white)),
            ),
            pw.SizedBox(width: 8),
            pw.Expanded(
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Text(who.isEmpty ? entryType(e) : who.first, style: t(9, strong: true)),
                pw.Text([if (who.length > 1) who.last, if (who.isNotEmpty) entryType(e)].join('  ·  ').ifEmpty(isIn ? 'Money in' : 'Money out'), style: t(7.5, color: grey)),
              ]),
            ),
          ]),
        ),
        if ('${e['reference'] ?? ''}'.isNotEmpty || '${e['note'] ?? ''}'.isNotEmpty) ...[
          pw.SizedBox(height: 6),
          if ('${e['reference'] ?? ''}'.isNotEmpty) pw.Text('Ref: ${e['reference']}', style: t(7.5, color: grey)),
          if ('${e['note'] ?? ''}'.isNotEmpty) pw.Text('${e['note']}', style: t(7.5, color: grey)),
        ],
        tear(),
        if (no.isNotEmpty)
          pw.Center(child: pw.BarcodeWidget(barcode: pw.Barcode.code128(), data: no, width: 150, height: 40, drawText: true, textPadding: 4, textStyle: t(7, color: grey))),
        pw.SizedBox(height: 10),
        pw.Text(isIn ? 'Thank you for shopping with us!' : 'Thank you for doing business with us!', textAlign: pw.TextAlign.center, style: t(8.5, strong: true)),
        pw.SizedBox(height: 1),
        pw.Text('OneLocal  ·  Your local shop, online', textAlign: pw.TextAlign.center, style: t(7, color: grey)),
      ]),
    ));
    return doc.save();
  }
}

/// The transaction summary (sketch): the entry, the total, and WhatsApp / Print / SMS.
Future<void> showMoneyReceipt(BuildContext context, Map<String, dynamic> entry, {StoreMoneyApi? api, Map<String, dynamic> shop = const {}}) => showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true, // above the bottom bar
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => _ReceiptSheet(r: MoneyReceipt(entry, shop: shop), api: api),
    );

class _ReceiptSheet extends StatelessWidget {
  const _ReceiptSheet({required this.r, this.api});
  final MoneyReceipt r;
  final StoreMoneyApi? api;

  Future<void> _open(BuildContext context, Uri uri, String fail) async {
    if (!await openMoneyLink(uri) && context.mounted) showToast(context, tr(fail));
  }

  Future<void> _proof(BuildContext context) async {
    try {
      final url = await api!.proofLink('${r.e['id']}');
      if (context.mounted) await _open(context, Uri.parse(url), 'Could not open the photo.');
    } catch (e) {
      if (context.mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not open the photo.'));
    }
  }

  Widget _share(String label, IconData icon, Key key, VoidCallback onTap) => Expanded(
        child: OutlinedButton.icon(
          key: key,
          onPressed: onTap,
          icon: Icon(icon, size: 17, color: kInk),
          label: Text(tr(label), style: inter(13.5, 700)),
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        ),
      );

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(key: const ValueKey('money-receipt'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Transaction summary'), style: inter(19, 800)),
            if (r.shopName.isNotEmpty) Text([r.shopName, r.shopAddress].where((s) => s.isNotEmpty).join(' · '), style: inter(12.5, 500, color: kMuted)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(tr(r.isIn ? 'MONEY IN' : 'MONEY OUT'), textAlign: TextAlign.center, style: inter(13, 800, color: r.isIn ? kMoneyGreen : kMoneyRed)),
                const Divider(height: 18),
                for (final (k, v) in r.lines)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(width: 110, child: Text(tr(k), style: inter(13, 500, color: kMuted))),
                      Expanded(child: Text(v, textAlign: TextAlign.right, style: inter(13.5, 600))),
                    ]),
                  ),
                const Divider(height: 18),
                Row(children: [
                  Expanded(child: Text(tr('Total'), style: inter(15, 800))),
                  Text(rs(r.amount), key: const ValueKey('receipt-total'), style: inter(20, 800)),
                ]),
              ]),
            ),
            if (r.e['has_proof'] == true && r.e['id'] != null && api != null)
              TextButton.icon(
                key: const ValueKey('receipt-proof'),
                onPressed: () => _proof(context),
                icon: const Icon(LucideIcons.image, size: 17, color: kLink),
                label: Text(tr('View proof photo'), style: inter(13.5, 700, color: kLink)),
              ),
            const SizedBox(height: 12),
            Row(children: [
              _share('WhatsApp', LucideIcons.messageCircle, const ValueKey('receipt-whatsapp'), () => _open(context, whatsAppLink(r.phone, r.text), 'Could not open WhatsApp.')),
              const SizedBox(width: 8),
              _share('Print', LucideIcons.printer, const ValueKey('receipt-print'), () async {
                try {
                  await printMoneyPdf(await r.pdf(), 'receipt-${r.no}.pdf');
                } catch (_) {
                  if (context.mounted) showToast(context, tr('Could not print. Check the printer.'));
                }
              }),
              const SizedBox(width: 8),
              _share('SMS', LucideIcons.messageSquare, const ValueKey('receipt-sms'), () => _open(context, smsLink(r.phone, r.text), 'Could not open messages.')),
            ]),
          ]),
        ),
      );
}

// ------------------------------------------------------------------------------------------------------------------- contacts
/// A person to pay or get paid by.
typedef MoneyContact = ({String? id, String name, String phone, String upiId});

/// Choose a contact: saved contacts, people already in the books, the phone's contacts, or a new one. Null when closed.
Future<MoneyContact?> chooseMoneyContact(BuildContext context, StoreMoneyApi api) => showModalBottomSheet<MoneyContact>(
      context: context,
      useRootNavigator: true, // above the bottom bar
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _ContactSheet(api: api),
    );

/// Add or change a contact's name, phone and UPI ID; the saved contact, or null when closed.
Future<MoneyContact?> editMoneyContact(BuildContext context, StoreMoneyApi api, {MoneyContact? contact}) => showModalBottomSheet<MoneyContact>(
      context: context,
      useRootNavigator: true, // above the bottom bar
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _ContactForm(api: api, contact: contact),
    );

class _ContactSheet extends StatefulWidget {
  const _ContactSheet({required this.api});
  final StoreMoneyApi api;
  @override
  State<_ContactSheet> createState() => _ContactSheetState();
}

class _ContactSheetState extends State<_ContactSheet> {
  final _q = TextEditingController();
  Map<String, dynamic>? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.contacts(q: _q.text);
      if (mounted) {
        setState(() {
          _data = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : tr('Could not load contacts.'));
    }
  }

  Future<void> _fromPhone() async {
    try {
      final c = await pickPhoneContact();
      if (c == null || !mounted) return;
      final saved = await editMoneyContact(context, widget.api, contact: (id: null, name: c.name, phone: c.phone, upiId: ''));
      if (saved != null && mounted) Navigator.of(context).pop(saved);
    } catch (_) {
      if (mounted) showToast(context, tr('Contacts open in the phone app. Add the contact here instead.'));
    }
  }

  Future<void> _new() async {
    final saved = await editMoneyContact(context, widget.api, contact: _q.text.trim().isEmpty ? null : (id: null, name: _q.text.trim(), phone: '', upiId: ''));
    if (saved != null && mounted) Navigator.of(context).pop(saved);
  }

  Widget _tile(MoneyContact c, {required Key key, bool saved = true}) => ListTile(
        key: key,
        contentPadding: EdgeInsets.zero,
        leading: CircleAvatar(
          backgroundColor: const Color(0xFFEFFAE3),
          child: Text(c.name.isEmpty ? '?' : c.name.characters.first.toUpperCase(), style: inter(15, 800, color: kMoneyGreen)),
        ),
        title: Text(c.name, style: inter(14.5, 700)),
        subtitle: Text([c.phone, c.upiId].where((s) => s.isNotEmpty).join(' · ').ifEmpty(tr(saved ? 'No phone or UPI ID yet' : 'In your books')),
            style: inter(12, 500, color: kMuted)),
        onTap: () => Navigator.of(context).pop(c),
      );

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final saved = (d?['contacts'] as List? ?? const []).cast<Map>();
    final recent = (d?['recent'] as List? ?? const []).cast<Map>();
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 16, 18, 12 + MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(key: const ValueKey('contact-sheet'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('Select a contact'), style: inter(19, 800)),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('contact-search'),
            controller: _q,
            onChanged: (_) => _load(),
            style: inter(14.5, 500),
            decoration: InputDecoration(
              isDense: true,
              hintText: tr('Search name, phone or UPI ID'),
              prefixIcon: const Icon(LucideIcons.search, size: 18),
              filled: true,
              fillColor: kBg,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextButton.icon(
                key: const ValueKey('contact-new'),
                onPressed: _new,
                icon: const Icon(LucideIcons.userPlus, size: 17, color: kLink),
                label: Text(tr('New contact'), style: inter(13.5, 700, color: kLink)),
              ),
            ),
            if (!kIsWeb)
              Expanded(
                child: TextButton.icon(
                  key: const ValueKey('contact-phone'),
                  onPressed: _fromPhone,
                  icon: const Icon(LucideIcons.bookUser, size: 17, color: kLink),
                  label: Text(tr('From phone'), style: inter(13.5, 700, color: kLink)),
                ),
              ),
          ]),
          Flexible(
            child: _error != null && d == null
                ? Text(_error!, style: inter(13.5, 500, color: kMuted))
                : d == null
                    ? const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
                    : ListView(shrinkWrap: true, children: [
                        if (saved.isEmpty && recent.isEmpty)
                          Padding(padding: const EdgeInsets.all(16), child: Text(tr('No contacts yet. Add one.'), textAlign: TextAlign.center, style: inter(13.5, 500, color: kMuted))),
                        for (final c in saved)
                          _tile((id: '${c['id']}', name: '${c['name']}', phone: '${c['phone'] ?? ''}', upiId: '${c['upi_id'] ?? ''}'), key: ValueKey('contact-${c['id']}')),
                        if (recent.isNotEmpty) ...[
                          Padding(padding: const EdgeInsets.only(top: 8, bottom: 2), child: Text(tr('FROM YOUR BOOKS'), style: inter(11, 700, color: kMuted))),
                          for (final c in recent)
                            _tile((id: null, name: '${c['name']}', phone: '${c['phone'] ?? ''}', upiId: ''), key: ValueKey('contact-recent-${c['name']}'), saved: false),
                        ],
                      ]),
          ),
        ]),
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class _ContactForm extends StatefulWidget {
  const _ContactForm({required this.api, this.contact});
  final StoreMoneyApi api;
  final MoneyContact? contact;
  @override
  State<_ContactForm> createState() => _ContactFormState();
}

class _ContactFormState extends State<_ContactForm> {
  late final _name = TextEditingController(text: widget.contact?.name ?? '');
  late final _phone = TextEditingController(text: widget.contact?.phone ?? '');
  late final _upi = TextEditingController(text: widget.contact?.upiId ?? '');
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _phone, _upi]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return showToast(context, tr('Enter the name.'));
    setState(() => _busy = true);
    try {
      final c = await widget.api.saveContact(id: widget.contact?.id, name: _name.text.trim(), phone: _phone.text.trim(), upiId: _upi.text.trim());
      if (mounted) Navigator.of(context).pop((id: '${c['id']}', name: '${c['name']}', phone: '${c['phone'] ?? ''}', upiId: '${c['upi_id'] ?? ''}'));
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not save. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(18, 16, 18, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(key: const ValueKey('contact-form'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr(widget.contact?.id == null ? 'New contact' : 'Edit contact'), style: inter(19, 800)),
          const SizedBox(height: 12),
          TextField(key: const ValueKey('contact-name'), controller: _name, style: inter(15, 600), decoration: moneyField('Name')),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('contact-phone-no'),
            controller: _phone,
            keyboardType: TextInputType.phone,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]'))],
            style: inter(15, 600),
            decoration: moneyField('Phone (optional)'),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('contact-upi'),
            controller: _upi,
            keyboardType: TextInputType.emailAddress,
            style: inter(15, 600),
            decoration: moneyField('UPI ID (to pay with GPay / PhonePe)').copyWith(hintText: 'name@okhdfcbank'),
          ),
          const SizedBox(height: 14),
          FilledButton(
            key: const ValueKey('contact-save'),
            onPressed: _busy ? null : _save,
            style: FilledButton.styleFrom(backgroundColor: kPrimary, padding: const EdgeInsets.symmetric(vertical: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            child: Text(_busy ? '…' : tr('Save contact'), style: inter(15.5, 700, color: Colors.white)),
          ),
        ]),
      );
}

InputDecoration moneyField(String label, {String? prefix, Widget? suffix}) => InputDecoration(
      isDense: true,
      labelText: tr(label),
      prefixText: prefix,
      suffixIcon: suffix,
      filled: true,
      fillColor: kBg,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
    );

// ------------------------------------------------------------------------------------------------------------------- list
/// Money in (or out): the total for the dates, Add money and the PDF, Cash / UPI / Card, then the entries. Pops true when something changed.
class MoneyFlowScreen extends StatefulWidget {
  const MoneyFlowScreen({super.key, required this.api, required this.direction, this.canRecord = true, this.canVoid = false, this.today, this.shop = const {}});
  final StoreMoneyApi api;
  final Map<String, dynamic> shop;
  final String direction; // in | out
  final bool canRecord, canVoid;
  final DateTime? today;
  @override
  State<MoneyFlowScreen> createState() => _MoneyFlowScreenState();
}

class _MoneyFlowScreenState extends State<MoneyFlowScreen> {
  String _range = 'today';
  DateTimeRange? _custom;
  String _family = 'all';
  List<Map<String, dynamic>>? _rows;
  String? _error;
  bool _changed = false;

  bool get _in => widget.direction == 'in';

  DateTime get _today {
    final t = widget.today ?? DateTime.now();
    return DateTime(t.year, t.month, t.day);
  }

  (DateTime, DateTime) get _dates => switch (_range) {
        'week' => (_today.subtract(Duration(days: _today.weekday - 1)), _today),
        'month' => (DateTime(_today.year, _today.month, 1), _today),
        'day' when _custom != null => (_custom!.start, _custom!.end),
        _ => (_today, _today),
      };

  String get _rangeLabel => switch (_range) {
        'week' => tr('This week'),
        'month' => tr('This month'),
        'day' when _dates.$1 == _today.subtract(const Duration(days: 1)) => tr('Yesterday'),
        'day' => dayMonth(isoDay(_dates.$1)),
        _ => tr('Today'),
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final (from, to) = _dates;
    try {
      final r = await widget.api.entries(from: isoDay(from), to: isoDay(to), direction: widget.direction, method: _family);
      if (mounted) {
        setState(() {
          _rows = r;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : tr('Could not load the entries.'));
    }
  }

  List<Map<String, dynamic>> get _counted =>
      (_rows ?? const []).where((r) => r['status'] != 'void' && r['kind'] != 'transfer_in' && r['kind'] != 'transfer_out').toList();
  num get _total => _counted.fold<num>(0, (s, r) => s + ((r['amount_minor'] as num?) ?? 0));

  /// The date pill opens a small calendar (founder, 28 Oct 2026): tap a day, or Today / This week / This month under it.
  Future<void> _pickRange() async {
    final pick = await showDialog<(String, DateTime?)>(
      context: context,
      builder: (c) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(key: const ValueKey('range-calendar'), mainAxisSize: MainAxisSize.min, children: [
            Theme(
              data: Theme.of(c).copyWith(colorScheme: Theme.of(c).colorScheme.copyWith(primary: kMoneyDeep, onPrimary: kMoneyLime)),
              child: CalendarDatePicker(
                initialDate: _dates.$1,
                firstDate: _today.subtract(const Duration(days: 730)),
                lastDate: _today,
                onDateChanged: (d) => Navigator.pop(c, ('day', d)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
              child: MoneyPills(
                keyPrefix: 'range',
                options: [('today', tr('Today')), ('week', tr('This week')), ('month', tr('This month'))],
                selected: _range,
                onSelect: (id) => Navigator.pop(c, (id, null)),
              ),
            ),
          ]),
        ),
      ),
    );
    if (pick == null || !mounted) return;
    final (range, day) = pick;
    setState(() {
      if (day != null && day == _today) {
        _range = 'today';
      } else {
        _range = range;
        if (day != null) _custom = DateTimeRange(start: day, end: day);
      }
      _rows = null;
    });
    _load();
  }

  Future<void> _add() async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => MoneyEntryScreen(api: widget.api, direction: widget.direction, shop: widget.shop)));
    if (saved == true && mounted) {
      _changed = true;
      _load();
    }
  }

  Future<void> _pdf() async {
    final (from, to) = _dates;
    try {
      final pdf = await moneyReportPdf(
        direction: widget.direction,
        from: from,
        to: to,
        rows: _counted,
        shop: widget.shop,
        filter: _family == 'all' ? 'All' : kMethodNames[_family] ?? _family,
      );
      await shareMoneyPdf(pdf, '${_in ? 'money-in' : 'money-out'}-${isoDay(from)}-${isoDay(to)}.pdf');
    } catch (_) {
      if (mounted) showToast(context, tr('Could not make the PDF. Try again.'));
    }
  }

  Future<void> _void(Map<String, dynamic> e) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${tr('Cancel')} ${e['no']}?', style: inter(18, 700)),
        content: TextField(key: const ValueKey('void-reason'), controller: reason, decoration: InputDecoration(labelText: tr('Why?'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Keep'), style: inter(14, 600))),
          TextButton(key: const ValueKey('void-confirm'), onPressed: () => Navigator.pop(c, true), child: Text(tr('Cancel entry'), style: inter(14, 700, color: kMoneyRed))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.api.voidEntry('${e['id']}', reason.text.trim());
      _changed = true;
      _load();
    } catch (err) {
      if (mounted) showToast(context, err is PartnerApiException ? err.message : tr('Could not cancel it. Try again.'));
    }
  }

  Widget _row(Map<String, dynamic> r) {
    final isVoid = r['status'] == 'void';
    final auto = r['auto'] == true;
    final party = '${r['party'] ?? ''}'.trim(), phone = '${r['party_phone'] ?? ''}'.trim();
    final method = '${r['method'] ?? r['account']}';
    final title = auto ? tr('Sales') : party.isNotEmpty ? party : phone.isNotEmpty ? phone : entryType(r);
    final sub = [
      tr(kMethodNames[method] ?? method),
      if (!auto && (party.isNotEmpty || phone.isNotEmpty)) entryType(r),
      dayMonth('${r['date']}'),
      if (r['no'] != null) '${r['no']}',
    ].join(' · ');
    return Container(
      key: ValueKey('flow-${r['id'] ?? '${r['date']}-$method'}'),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: moneyCard(),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: auto ? null : () => showMoneyReceipt(context, r, api: widget.api, shop: widget.shop),
          onLongPress: (!auto && !isVoid && widget.canVoid) ? () => _void(r) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: _in ? const Color(0xFFF0FBD0) : const Color(0xFFFDECEC), borderRadius: BorderRadius.circular(14)),
                child: Icon(party.isNotEmpty || phone.isNotEmpty ? LucideIcons.user : (kMethodIcons[method] ?? LucideIcons.wallet), size: 19, color: _in ? kMoneyGreen : kMoneyRed),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(
                      child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: inter(14.5, 700, color: isVoid ? kMuted : kInk).copyWith(decoration: isVoid ? TextDecoration.lineThrough : null)),
                    ),
                    if (r['has_proof'] == true) ...[const SizedBox(width: 5), const Icon(LucideIcons.paperclip, size: 13, color: kMuted)],
                  ]),
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 500, color: kMuted)),
                  if (isVoid) Text('${tr('Cancelled')}: ${r['void_reason'] ?? ''}', style: inter(11.5, 600, color: kMoneyRed)),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(rs(r['amount_minor'] as num?), style: inter(15.5, 800, color: isVoid ? kMuted : kInk)),
                const SizedBox(height: 3),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_in ? LucideIcons.arrowDownLeft : LucideIcons.arrowUpRight, size: 12, color: isVoid ? kMuted : (_in ? kMoneyGreen : kMoneyRed)),
                  const SizedBox(width: 2),
                  Text(tr(isVoid ? 'Cancelled' : _in ? 'In' : 'Out'), style: inter(11, 700, color: isVoid ? kMuted : (_in ? kMoneyGreen : kMoneyRed))),
                ]),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        backgroundColor: kBg,
        body: Column(children: [
          AppHeader(title: tr(_in ? 'Money in' : 'Money out'), onBack: () => Navigator.of(context).pop(_changed)),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(key: ValueKey('money-flow-${widget.direction}'), padding: const EdgeInsets.fromLTRB(14, 12, 14, 28), children: [
                MoneyDarkCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(tr(_in ? 'Money in' : 'Money out'), style: inter(13.5, 500, color: const Color(0xFFB8BCC4)))),
                      Material(
                        color: kMoneyDeepSoft,
                        borderRadius: BorderRadius.circular(40),
                        child: InkWell(
                          key: const ValueKey('flow-range'),
                          borderRadius: BorderRadius.circular(40),
                          onTap: _pickRange,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(LucideIcons.calendar, size: 14, color: kMoneyLime),
                              const SizedBox(width: 6),
                              Text(_rangeLabel, style: inter(12.5, 700, color: Colors.white)),
                              const SizedBox(width: 2),
                              const Icon(LucideIcons.chevronDown, size: 14, color: Colors.white),
                            ]),
                          ),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    FittedBox(fit: BoxFit.scaleDown, child: Text(rs(_total), key: const ValueKey('flow-total'), style: inter(38, 800, color: Colors.white))),
                    const SizedBox(height: 4),
                    Row(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: _in ? kMoneyLime : const Color(0xFFFF8A8A), borderRadius: BorderRadius.circular(40)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(_in ? LucideIcons.arrowDownLeft : LucideIcons.arrowUpRight, size: 12, color: kMoneyDeep),
                          const SizedBox(width: 3),
                          Text('${_counted.length} ${tr(_counted.length == 1 ? 'entry' : 'entries')}', style: inter(11.5, 800, color: kMoneyDeep)),
                        ]),
                      ),
                    ]),
                    const SizedBox(height: 18),
                    Row(children: [
                      Expanded(
                        child: FilledButton(
                          key: const ValueKey('flow-add'),
                          onPressed: widget.canRecord ? _add : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: kMoneyLime,
                            disabledBackgroundColor: kMoneyDeepSoft,
                            padding: const EdgeInsets.symmetric(vertical: 15),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Text(tr(_in ? 'Add money' : 'Pay money'), style: inter(15.5, 800, color: kMoneyDeep)),
                            const SizedBox(width: 8),
                            Icon(_in ? LucideIcons.arrowDownLeft : LucideIcons.arrowUpRight, size: 18, color: kMoneyDeep),
                          ]),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Material(
                        color: kMoneyDeepSoft,
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          key: const ValueKey('flow-pdf'),
                          borderRadius: BorderRadius.circular(16),
                          onTap: rows == null ? null : _pdf,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(LucideIcons.fileDown, size: 18, color: Colors.white),
                              const SizedBox(width: 6),
                              Text('PDF', style: inter(14, 700, color: Colors.white)),
                            ]),
                          ),
                        ),
                      ),
                    ]),
                  ]),
                ),
                const SizedBox(height: 16),
                MoneyPills(
                  keyPrefix: 'flow-method',
                  options: [('all', tr('All')), ('cash', tr('Cash')), ('upi', tr('UPI')), ('card', tr('Card'))],
                  selected: _family,
                  onSelect: (id) {
                    setState(() => _family = id);
                    _load();
                  },
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 8),
                  child: Text(tr(_in ? 'Money received' : 'Money paid'), style: inter(16, 800)),
                ),
                if (_error != null && rows == null)
                  Text(_error!, style: inter(13.5, 500, color: kMuted))
                else if (rows == null)
                  const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
                else if (rows.isEmpty)
                  Padding(padding: const EdgeInsets.all(24), child: Text(tr('Nothing in these dates.'), textAlign: TextAlign.center, style: inter(13.5, 500, color: kMuted)))
                else
                  for (final r in rows) _row(r),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------------------------- add
/// Add money in (or pay money out), the sketch's form. Pops true once saved. Opened from Dues it comes with the customer or the bill.
class MoneyEntryScreen extends StatefulWidget {
  const MoneyEntryScreen({super.key, required this.api, required this.direction, this.kind, this.bill, this.party, this.shop = const {}});
  final StoreMoneyApi api;
  final Map<String, dynamic> shop;
  final String direction;
  final String? kind, party;
  final Map<String, dynamic>? bill;
  @override
  State<MoneyEntryScreen> createState() => _MoneyEntryScreenState();
}

class _MoneyEntryScreenState extends State<MoneyEntryScreen> {
  bool get _in => widget.direction == 'in';
  late String _kind = widget.kind ?? (_in ? 'goods_sale' : 'expense');
  String _method = 'cash';
  String _from = 'cash', _to = 'bank'; // Account transfer
  String? _category;
  DateTime _date = DateTime.now();
  late final _amount = TextEditingController(text: widget.bill == null ? '' : (((widget.bill!['due_minor'] as num?) ?? 0) / 100).toStringAsFixed(2).replaceAll('.00', ''));
  late final _party = TextEditingController(text: widget.party ?? (widget.bill?['supplier'] as String?) ?? '');
  final _phone = TextEditingController(), _ref = TextEditingController(), _other = TextEditingController();
  final _key = StoreMoneyApi.newKey();
  PickedDocument? _proof;
  String? _proofPath;
  Map<String, dynamic>? _saved; // the entry once saved: the actions after the first do not save it again
  bool _busy = false;

  /// The types to choose from, and Account transfer (the store's own money from one account to another).
  List<(String, String)> get _kinds {
    final all = _in ? kMoneyIn : kMoneyOut;
    return [...all.where((k) => !kOtherKinds.contains(k.$1)), ('transfer', 'Account transfer'), ...all.where((k) => kOtherKinds.contains(k.$1))]; // Other last
  }
  bool get _transfer => _kind == 'transfer';
  bool get _isOther => kOtherKinds.contains(_kind);

  @override
  void dispose() {
    for (final c in [_amount, _party, _phone, _ref, _other]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _contact() async {
    final c = await chooseMoneyContact(context, widget.api);
    if (c == null || !mounted) return;
    setState(() {
      _party.text = c.name;
      _phone.text = c.phone;
    });
  }

  Future<void> _addProof() async {
    final how = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true, // above the bottom bar
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (canScanProof())
            ListTile(key: const ValueKey('proof-camera'), leading: const Icon(LucideIcons.camera), title: Text(tr('Take photo'), style: inter(15, 600)), onTap: () => Navigator.pop(c, 'camera')),
          ListTile(key: const ValueKey('proof-upload'), leading: const Icon(LucideIcons.upload), title: Text(tr('Upload from phone'), style: inter(15, 600)), onTap: () => Navigator.pop(c, 'upload')),
        ]),
      ),
    );
    if (how == null) return;
    final d = how == 'camera' ? await scanProof() : await pickProofFile();
    if (d != null && mounted) {
      setState(() {
        _proof = d;
        _proofPath = null;
      });
    }
  }

  /// Saves the entry once (the same key every time) and returns it, or null when something is missing or it failed.
  Future<Map<String, dynamic>?> _save() async {
    if (_saved != null) return _saved;
    final amt = num.tryParse(_amount.text.trim());
    if (amt == null || amt <= 0) {
      showToast(context, tr('Enter the amount.'));
      return null;
    }
    if (_transfer && _from == _to) {
      showToast(context, tr('Choose two different accounts.'));
      return null;
    }
    if (_isOther && _other.text.trim().isEmpty) {
      showToast(context, tr('Say what the money was for.'));
      return null;
    }
    final needsParty = _kind == 'due_received' || _kind == 'supplier_payment';
    if (needsParty && _party.text.trim().isEmpty && widget.bill == null) {
      showToast(context, tr('Say who paid or who was paid.'));
      return null;
    }
    setState(() => _busy = true);
    try {
      if (_proof != null && _proofPath == null) _proofPath = await widget.api.uploadProof(_proof!);
      final body = _transfer
          ? <String, Object?>{'kind': 'transfer', 'account': _from, 'to_account': _to, 'amount_minor': (amt * 100).round(), 'entry_date': isoDay(_date), 'reference': _ref.text.trim()}
          : <String, Object?>{
        'kind': _kind,
        'method': _method,
        'amount_minor': (amt * 100).round(),
        'entry_date': isoDay(_date),
        if (_kind == 'expense') 'category': _category ?? '',
        if (_isOther) 'category': _other.text.trim(),
        'party': _party.text.trim(),
        'party_phone': _phone.text.trim(),
        'reference': _ref.text.trim(),
        'proof_path': _proofPath,
        if (widget.bill != null) 'bill_receipt_id': widget.bill!['receipt_document_id'],
      };
      final r = await widget.api.record(body, key: _key);
      _saved = {
        ...body,
        'id': r['id'],
        'no': r['no'],
        'date': r['date'] ?? isoDay(_date),
        'direction': widget.direction,
        'party': _party.text.trim().isEmpty ? (widget.bill?['supplier'] ?? '') : _party.text.trim(),
        'has_proof': _proofPath != null,
        'created_at': DateTime.now().toIso8601String(),
      };
      return _saved;
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not save. Check your connection and try again.'));
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAndClose() async {
    if (await _save() == null || !mounted) return;
    showToast(context, tr('Saved.'));
    Navigator.of(context).pop(true);
  }

  Future<void> _receipt() async {
    final e = await _save();
    if (e == null || !mounted) return;
    await showMoneyReceipt(context, e, api: widget.api, shop: widget.shop);
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _send(bool whatsapp) async {
    final e = await _save();
    if (e == null || !mounted) return;
    final r = MoneyReceipt(e, shop: widget.shop);
    if (!await openMoneyLink(whatsapp ? whatsAppLink(r.phone, r.text) : smsLink(r.phone, r.text)) && mounted) {
      showToast(context, tr(whatsapp ? 'Saved. Could not open WhatsApp.' : 'Saved. Could not open messages.'));
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: Column(children: [
          AppHeader(
            title: tr(widget.bill != null ? 'Pay supplier bill' : _in ? 'Add money' : 'Pay money'),
            onBack: () => Navigator.of(context).pop(_saved != null),
          ),
          Expanded(
            child: ListView(key: const ValueKey('money-entry'), padding: const EdgeInsets.fromLTRB(16, 14, 16, 24), children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: kLine)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (widget.bill == null) ...[
                    DropdownButtonFormField<String>(
                      key: const ValueKey('entry-kind'),
                      initialValue: _kind,
                      isExpanded: true,
                      decoration: moneyField('Type'),
                      items: [for (final (id, label) in _kinds) DropdownMenuItem(value: id, child: Text(tr(label), style: inter(14.5, 600)))],
                      onChanged: _saved != null ? null : (v) => setState(() => _kind = v ?? _kind),
                    ),
                    // Other: the owner types their own type
                    if (_isOther) ...[
                      const SizedBox(height: 8),
                      TextField(
                        key: const ValueKey('entry-other'),
                        controller: _other,
                        enabled: _saved == null,
                        autofocus: true,
                        maxLength: 40,
                        textCapitalization: TextCapitalization.sentences,
                        style: inter(14.5, 600),
                        decoration: moneyField('Type your own').copyWith(counterText: '', hintText: tr(_in ? 'e.g. Scrap sold, Rent received' : 'e.g. Donation, Shop repairs')),
                      ),
                    ],
                    const SizedBox(height: 10),
                  ],
                  Row(children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        key: const ValueKey('entry-amount'),
                        controller: _amount,
                        enabled: _saved == null,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                        style: inter(18, 700),
                        decoration: moneyField('Amount', prefix: '₹ '),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: InkWell(
                        key: const ValueKey('entry-date'),
                        onTap: _saved != null
                            ? null
                            : () async {
                                final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime.now().subtract(const Duration(days: 365)), lastDate: DateTime.now());
                                if (d != null) setState(() => _date = d);
                              },
                        child: InputDecorator(decoration: moneyField('Date'), child: Text(dayMonth(isoDay(_date)), style: inter(15, 600))),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  if (_transfer) ...[
                    for (final (label, value, prefix, set) in [
                      ('From', _from, 'entry-from', (String v) => _from = v),
                      ('To', _to, 'entry-to', (String v) => _to = v),
                    ]) ...[
                      Text(tr(label), style: inter(12.5, 700, color: kMuted)),
                      const SizedBox(height: 4),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        for (final e in kAccountNames.entries)
                          ChoiceChip(
                            key: ValueKey('$prefix-${e.key}'),
                            avatar: Icon(kAccountIcons[e.key], size: 15),
                            label: Text(tr(e.value), style: inter(12.5, 600)),
                            selected: value == e.key,
                            onSelected: _saved != null ? null : (_) => setState(() => set(e.key)),
                          ),
                      ]),
                      const SizedBox(height: 10),
                    ],
                    TextField(key: const ValueKey('entry-ref'), controller: _ref, enabled: _saved == null, style: inter(14.5, 600), decoration: moneyField('Reference / UTR (optional)')),
                  ] else ...[
                  Text(tr(_in ? 'Received by' : 'Paid by'), style: inter(12.5, 700, color: kMuted)),
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final m in const ['cash', 'upi', 'gpay', 'phonepe', 'card', 'bank'])
                      ChoiceChip(
                        key: ValueKey('entry-method-$m'),
                        avatar: Icon(kMethodIcons[m], size: 15),
                        label: Text(tr(kMethodNames[m]!), style: inter(12.5, 600)),
                        selected: _method == m,
                        onSelected: _saved != null ? null : (_) => setState(() => _method = m),
                      ),
                  ]),
                  if (_kind == 'expense') ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      key: const ValueKey('entry-category'),
                      initialValue: _category,
                      isExpanded: true,
                      decoration: moneyField('Expense head'),
                      items: [for (final h in kExpenseHeads) DropdownMenuItem(value: h, child: Text(tr(h), style: inter(14, 600)))],
                      onChanged: _saved != null ? null : (v) => setState(() => _category = v),
                    ),
                  ],
                  const SizedBox(height: 10),
                  TextField(
                    key: const ValueKey('entry-party'),
                    controller: _party,
                    enabled: _saved == null,
                    style: inter(14.5, 600),
                    decoration: moneyField(_in ? 'Party (who paid)' : 'Party (who was paid)',
                        suffix: IconButton(key: const ValueKey('entry-contact'), tooltip: tr('Contacts'), onPressed: _saved != null ? null : _contact, icon: const Icon(LucideIcons.userRound, size: 20))),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const ValueKey('entry-phone'),
                    controller: _phone,
                    enabled: _saved == null,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]'))],
                    style: inter(14.5, 600),
                    decoration: moneyField('Phone (for WhatsApp / SMS)'),
                  ),
                  const SizedBox(height: 10),
                  TextField(key: const ValueKey('entry-ref'), controller: _ref, enabled: _saved == null, style: inter(14.5, 600), decoration: moneyField('Reference / UTR (optional)')),
                  ],
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const ValueKey('entry-proof'),
                        onPressed: _saved != null ? null : _addProof,
                        icon: Icon(_proof == null ? LucideIcons.camera : LucideIcons.check, size: 17, color: _proof == null ? kInk : kMoneyGreen),
                        label: Text(_proof == null ? tr('Proof') : tr('Proof added'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13.5, 700)),
                        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      ),
                    ),
                    if (_proof != null && _saved == null)
                      IconButton(key: const ValueKey('entry-proof-remove'), tooltip: tr('Remove photo'), onPressed: () => setState(() {
                          _proof = null;
                          _proofPath = null;
                        }), icon: const Icon(LucideIcons.x, size: 18)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const ValueKey('entry-receipt'),
                        onPressed: _busy ? null : _receipt,
                        icon: const Icon(LucideIcons.receipt, size: 17, color: kInk),
                        label: Text(tr('Generate receipt'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13.5, 700)),
                        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      ),
                    ),
                  ]),
                  if (_proof != null && _proof!.contentType.startsWith('image/')) ...[
                    const SizedBox(height: 8),
                    ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(_proof!.bytes, key: const ValueKey('entry-proof-preview'), height: 120, fit: BoxFit.cover)),
                  ],
                  const SizedBox(height: 14),
                  Row(children: [
                    IconButton.outlined(
                      key: const ValueKey('entry-whatsapp'),
                      tooltip: tr('Save and send on WhatsApp'),
                      onPressed: _busy ? null : () => _send(true),
                      style: IconButton.styleFrom(padding: const EdgeInsets.all(13), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      icon: const Icon(LucideIcons.messageCircle, size: 20, color: kMoneyGreen),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      key: const ValueKey('entry-sms'),
                      onPressed: _busy ? null : () => _send(false),
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      child: Text(tr('SMS'), style: inter(14, 700)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        key: const ValueKey('entry-save'),
                        onPressed: _busy ? null : _saveAndClose,
                        style: FilledButton.styleFrom(backgroundColor: kPrimary, padding: const EdgeInsets.symmetric(vertical: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        child: Text(_busy ? '…' : tr('Save entry'), style: inter(15, 700, color: Colors.white)),
                      ),
                    ),
                  ]),
                ]),
              ),
            ]),
          ),
        ]),
      );
}
