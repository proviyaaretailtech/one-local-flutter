import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../orders/orders_api.dart' show OrderView, rupees;
import '../sell/sell_api.dart' show Receipt;
import 'devices_api.dart';

// The customer's printed bill (founder, 1 Nov 2026, after a ticket-style mock-up): the shop's name, "Thank you!", the bill number and
// amount, date and time, the customer (name, number) with how they paid, the items, the totals (rounded to the rupee by the store's
// bill settings, the round off shown), and "OneLocal Partner store" at the foot.
// The same bill as a PDF roll (print dialog) and as ESC/POS (a network receipt printer).

/// One bill, as the receipt prints it. Every figure is the server's.
class BillReceipt {
  const BillReceipt({
    required this.store,
    this.branch,
    required this.billNo,
    required this.when,
    this.customer = '',
    this.phone = '',
    this.payment = '',
    required this.lines,
    required this.subtotal,
    this.gst = 0,
    this.gstPct = 0,
    this.serviceCharge = 0,
    this.discount = 0,
    this.coupon,
    this.roundOff = 0,
    required this.total,
    this.paid = 0,
    this.tendered,
    this.change = 0,
    this.refunded = 0,
  });

  final String store, billNo, when, customer, phone, payment;
  final String? branch, coupon;
  final List<({String name, num qty, num amount})> lines;
  final num subtotal, gst, gstPct, serviceCharge, discount, roundOff, total, paid, change, refunded;
  final num? tendered;

  static num _n(Object? v) => v is num ? v : num.tryParse('${v ?? ''}') ?? 0;
  static List<({String name, num qty, num amount})> _lines(List<Map<String, dynamic>> items) => [
    for (final i in items) (name: '${i['name'] ?? ''}', qty: _n(i['qty']), amount: _n(i['amount'])),
  ];

  /// The bill the till just took payment for. [customer] and [phone] from the cart win over the order's.
  factory BillReceipt.fromOrder(OrderView v, {required String store, String? branch, String? customer, String? phone}) {
    final b = v.bill, p = v.payment;
    final name = (customer ?? '').trim().isNotEmpty ? customer!.trim() : v.customer;
    final method = '${p['method'] ?? ''}';
    return BillReceipt(
      store: store,
      branch: branch,
      billNo: v.displayNo,
      when: v.placedAt,
      customer: name == 'Guest' ? '' : name,
      phone: (phone ?? '').trim().isNotEmpty ? phone!.trim() : '${v.raw['customer_phone'] ?? ''}',
      payment: method == 'Not chosen' ? '' : method,
      lines: _lines(v.items),
      subtotal: _n(b['subtotal']),
      gst: _n(b['gst']),
      gstPct: _n(b['gst_pct']),
      serviceCharge: _n(b['service_charge']),
      discount: _n(b['discount']),
      coupon: v.raw['coupon_code'] as String?,
      roundOff: _n(b['round_off']),
      total: _n(b['total']),
      paid: _n(p['settled']) > 0 ? _n(p['settled']) : _n(b['total']),
      tendered: method.toLowerCase().contains('cash') && _n(p['tendered']) > 0 ? _n(p['tendered']) : null,
      change: _n(p['change']),
    );
  }

  /// A bill from Bill → History.
  factory BillReceipt.fromRecord(Receipt r, {required String store, String? branch}) => BillReceipt(
    store: store,
    branch: branch,
    billNo: r.displayNo,
    when: r.when,
    customer: r.customer == 'Guest' ? '' : r.customer,
    phone: r.customerPhone ?? '',
    payment: r.paid > 0 ? r.paymentMode : '',
    lines: _lines(r.items),
    subtotal: r.subtotal,
    gst: r.gstAmount,
    gstPct: r.gstPct,
    serviceCharge: r.serviceCharge,
    discount: r.discount,
    coupon: r.couponCode,
    roundOff: _n(r.raw['round_off']),
    total: r.total,
    paid: r.paid,
    refunded: r.refunded,
  );

  bool get isPaid => paid > 0;

  /// The total in whole rupees: the server's when it rounded (the store's setting), else rounded here, 50 paise and up to the next rupee.
  num get roundedTotal => roundOff != 0 || total == total.roundToDouble() ? total : (total + 0.0000001).round();
  num get shownRoundOff => roundOff != 0 ? roundOff : ((roundedTotal - total) * 100).round() / 100;
  String get pctText => gstPct == gstPct.roundToDouble() ? '${gstPct.toInt()}' : '$gstPct';
  String get qtyWord {
    final units = lines.fold<num>(0, (n, l) => n + l.qty);
    final u = units == units.roundToDouble() ? '${units.toInt()}' : '$units';
    return '${lines.length} ${lines.length == 1 ? 'item' : 'items'} · $u ${units == 1 ? 'unit' : 'units'}';
  }

  /// "9876543210" -> "+91 98765 43210"; anything else as given.
  String get phoneText {
    final d = phone.replaceAll(RegExp(r'\D'), '');
    final ten = d.length == 12 && d.startsWith('91') ? d.substring(2) : d;
    return ten.length == 10 ? '+91 ${ten.substring(0, 5)} ${ten.substring(5)}' : phone;
  }

  /// The totals, in order: (label, amount, bold).
  List<(String, String, bool)> get totals => [
    ('Subtotal', rupees(subtotal), false),
    if (gst != 0) ('GST ($pctText%)', rupees(gst), false),
    if (serviceCharge != 0) ('Service charge', rupees(serviceCharge), false),
    if (discount != 0) ('Discount${coupon == null ? '' : ' ($coupon)'}', '−${rupees(discount)}', false),
    if (shownRoundOff != 0) ('Round off', '${shownRoundOff < 0 ? '−' : '+'}${rupees(shownRoundOff.abs())}', false),
    ('Total', rupees(roundedTotal), true),
    if (payment.isNotEmpty) ('Payment mode', payment, false),
    if (refunded > 0) ('Refunded', '−${rupees(refunded)}', false),
  ];
}

String _qty(num q) => q == q.roundToDouble() ? '${q.toInt()}' : q.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');

// ------------------------------------------------------------------ the PDF roll (print dialog)

const _ink = PdfColor.fromInt(0xFF15171A),
    _muted = PdfColor.fromInt(0xFF6B7280),
    _soft = PdfColor.fromInt(0xFFF3F5F8),
    _line = PdfColor.fromInt(0xFFD5D9E0);
const _green = PdfColor.fromInt(0xFF1F6F3A), _lime = PdfColor.fromInt(0xFF4CAF1A);

/// The bill on a roll the width of the receipt paper (58 or 80 mm): ticket style.
Future<Uint8List> billReceiptPdf(BillReceipt r, {int paperMm = 80}) async {
  pw.Font? regular, bold;
  try {
    regular = pw.Font.ttf(await rootBundle.load('fonts/Inter.ttf'));
    bold = pw.Font.ttf(await rootBundle.load('fonts/Poppins-Bold.ttf'));
  } catch (_) {}
  String cur(String s) => regular == null ? s.replaceAll('₹', 'Rs ') : s; // no font with ₹: Rs
  final narrow = paperMm == 58;
  final k = narrow ? 0.82 : 1.0; // text scale for 58 mm paper
  pw.TextStyle t(double size, {bool strong = false, PdfColor color = _ink, double spacing = 0}) => pw.TextStyle(
    font: strong ? (bold ?? regular) : regular,
    fontBold: bold,
    fontSize: size * k,
    color: color,
    letterSpacing: spacing,
    lineSpacing: 1,
  );
  pw.Widget dashed() => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 8),
    child: pw.Row(
      children: [
        for (var i = 0; i < (narrow ? 26 : 38); i++)
          pw.Expanded(
            child: pw.Container(height: 0.8, margin: const pw.EdgeInsets.symmetric(horizontal: 1.2), color: _line),
          ),
      ],
    ),
  );
  pw.Widget label(String s) => pw.Text(s.toUpperCase(), style: t(6.5, color: _muted, spacing: 0.6));

  final doc = pw.Document(title: 'Receipt ${r.billNo}');
  final format = (narrow ? PdfPageFormat.roll57 : PdfPageFormat.roll80).copyWith(
    marginLeft: 4 * PdfPageFormat.mm,
    marginRight: 4 * PdfPageFormat.mm,
    marginTop: 5 * PdfPageFormat.mm,
    marginBottom: 8 * PdfPageFormat.mm,
  );
  doc.addPage(
    pw.Page(
      pageFormat: format,
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          // the shop
          pw.Text(r.store, textAlign: pw.TextAlign.center, style: t(13, strong: true)),
          if (r.branch != null && r.branch!.isNotEmpty)
            pw.Text(
              r.branch!,
              textAlign: pw.TextAlign.center,
              style: t(7.5, color: _muted),
            ),
          pw.SizedBox(height: 8),
          pw.Text(r.isPaid ? 'Thank you!' : 'Your bill', textAlign: pw.TextAlign.center, style: t(11, strong: true)),
          pw.Text(
            r.isPaid ? 'Your payment was received successfully' : 'Payment is still due',
            textAlign: pw.TextAlign.center,
            style: t(7.5, color: _muted),
          ),
          dashed(),
          // bill number and amount
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    label('Bill no'),
                    pw.SizedBox(height: 1),
                    pw.Text(r.billNo, style: t(9.5, strong: true)),
                  ],
                ),
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  label('Amount'),
                  pw.SizedBox(height: 1),
                  pw.Text(cur(rupees(r.roundedTotal)), style: t(9.5, strong: true)),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 6),
          label('Date & time'),
          pw.SizedBox(height: 1),
          pw.Text(r.when, style: t(8.5, strong: true)),
          pw.SizedBox(height: 7),
          // the customer and how they paid
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 6),
            decoration: pw.BoxDecoration(color: _soft, borderRadius: pw.BorderRadius.circular(5)),
            child: pw.Row(
              children: [
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(r.customer.isEmpty ? 'Walk-in customer' : r.customer, style: t(8.5, strong: true)),
                      if (r.phone.isNotEmpty) pw.Text(r.phoneText, style: t(7.5, color: _muted)),
                    ],
                  ),
                ),
                if (r.payment.isNotEmpty)
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: pw.BoxDecoration(
                      color: PdfColors.white,
                      border: pw.Border.all(color: _line, width: 0.6),
                      borderRadius: pw.BorderRadius.circular(8),
                    ),
                    child: pw.Text(r.payment, style: t(7, strong: true, color: _green)),
                  ),
              ],
            ),
          ),
          pw.SizedBox(height: 8),
          // the items
          pw.Row(
            children: [
              pw.Expanded(child: label('Item')),
              pw.SizedBox(
                width: 22 * k,
                child: pw.Align(alignment: pw.Alignment.centerRight, child: label('Qty')),
              ),
              pw.SizedBox(
                width: 44 * k,
                child: pw.Align(alignment: pw.Alignment.centerRight, child: label('Amount')),
              ),
            ],
          ),
          pw.Container(height: 0.6, color: _line, margin: const pw.EdgeInsets.only(top: 3, bottom: 2)),
          for (final l in r.lines)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 2),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Expanded(child: pw.Text(l.name, style: t(8))),
                  pw.SizedBox(
                    width: 22 * k,
                    child: pw.Text(_qty(l.qty), textAlign: pw.TextAlign.right, style: t(8)),
                  ),
                  pw.SizedBox(
                    width: 44 * k,
                    child: pw.Text(cur(rupees(l.amount)), textAlign: pw.TextAlign.right, style: t(8)),
                  ),
                ],
              ),
            ),
          pw.Text(r.qtyWord, style: t(6.5, color: _muted)),
          pw.Container(height: 0.6, color: _line, margin: const pw.EdgeInsets.symmetric(vertical: 4)),
          // the totals
          for (final (name, amount, strong) in r.totals)
            pw.Padding(
              padding: pw.EdgeInsets.symmetric(vertical: strong ? 3 : 1),
              child: pw.Row(
                children: [
                  pw.Expanded(
                    child: pw.Text(
                      name,
                      style: t(strong ? 10.5 : 8, strong: strong, color: strong ? _ink : _muted),
                    ),
                  ),
                  pw.Text(cur(amount), style: t(strong ? 10.5 : 8, strong: strong)),
                ],
              ),
            ),
          dashed(),
          // goodbye, and whose till it is
          pw.Text('Thank you for shopping with us', textAlign: pw.TextAlign.center, style: t(8, strong: true)),
          pw.Text(
            'Please visit again',
            textAlign: pw.TextAlign.center,
            style: t(7.5, color: _muted),
          ),
          pw.SizedBox(height: 10),
          pw.Center(
            child: pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: pw.BoxDecoration(color: _soft, borderRadius: pw.BorderRadius.circular(9)),
              child: pw.RichText(
                text: pw.TextSpan(
                  children: [
                    pw.TextSpan(text: 'One', style: t(8, strong: true)),
                    pw.TextSpan(
                      text: 'Local',
                      style: t(8, strong: true, color: _lime),
                    ),
                    pw.TextSpan(
                      text: '  Partner store',
                      style: t(7, color: _muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            'Billed with OneLocal',
            textAlign: pw.TextAlign.center,
            style: t(6.5, color: _muted),
          ),
        ],
      ),
    ),
  );
  return doc.save();
}

// ------------------------------------------------------------------ ESC/POS (a network receipt printer)

/// The same bill for a thermal printer: the shop's name big and centred, the bill in two aligned columns, the totals, "OneLocal
/// Partner store" at the foot, feed, cut. ₹ is not in the printer's font, so amounts print as "Rs".
List<int> billEscPos(BillReceipt r, {required StorePrinter printer}) {
  final cols = printer.paperMm == 58 ? 32 : 48;
  List<int> ascii(String s) => s.replaceAll('₹', 'Rs ').replaceAll('−', '-').replaceAll('·', '-').codeUnits.map((c) => c < 128 ? c : 0x3F).toList();
  String money(num v) => rupees(v).replaceAll('₹', 'Rs ');
  String pair(String left, String right) {
    final room = cols - right.length - 1;
    final l = left.length > room ? left.substring(0, room) : left;
    return '${l.padRight(room)} $right';
  }

  final b = <int>[0x1B, 0x40]; // reset
  void line([String s = '']) => b
    ..addAll(ascii(s))
    ..add(0x0A);
  void centre(bool on) => b.addAll([0x1B, 0x61, on ? 0x01 : 0x00]);
  void bold(bool on) => b.addAll([0x1B, 0x45, on ? 0x01 : 0x00]);
  void big(bool on) => b.addAll([0x1D, 0x21, on ? 0x11 : 0x00]); // double width and height
  final rule = '-' * cols;

  centre(true);
  big(true);
  bold(true);
  line(r.store.toUpperCase().length > cols ~/ 2 ? r.store.toUpperCase().substring(0, cols ~/ 2) : r.store.toUpperCase());
  big(false);
  bold(false);
  if (r.branch != null && r.branch!.isNotEmpty) line(r.branch!);
  line();
  bold(true);
  line(r.isPaid ? 'Thank you!' : 'Your bill');
  bold(false);
  line(r.isPaid ? 'Payment received' : 'Payment is still due');
  centre(false);
  line(rule);
  bold(true);
  line(pair('Bill no ${r.billNo}', money(r.roundedTotal)));
  bold(false);
  line(r.when);
  line(rule);
  line('Customer: ${r.customer.isEmpty ? 'Walk-in customer' : r.customer}');
  if (r.phone.isNotEmpty) line('Mobile:   ${r.phoneText}');
  if (r.payment.isNotEmpty) line('Payment:  ${r.payment}');
  line(rule);
  line(pair('Item', 'Qty      Amount'));
  line(rule);
  for (final l in r.lines) {
    final right = '${_qty(l.qty).padLeft(3)}  ${money(l.amount).padLeft(10)}';
    var name = l.name;
    while (name.length > cols - right.length - 1) {
      line(name.substring(0, cols - right.length - 1));
      name = name.substring(cols - right.length - 1);
    }
    line(pair(name, right));
  }
  line(r.qtyWord);
  line(rule);
  for (final (name, amount, strong) in r.totals) {
    bold(strong);
    line(pair(name, amount.replaceAll('₹', 'Rs ').replaceAll('−', '-')));
    bold(false);
  }
  line(rule);
  centre(true);
  bold(true);
  line('Thank you for shopping with us');
  bold(false);
  line('Please visit again');
  line();
  bold(true);
  line('OneLocal Partner store');
  bold(false);
  line('Billed with OneLocal');
  centre(false);
  b.addAll([0x1B, 0x64, 0x04]); // feed
  if (printer.autoCut) b.addAll([0x1D, 0x56, 0x42, 0x00]);
  return b;
}
