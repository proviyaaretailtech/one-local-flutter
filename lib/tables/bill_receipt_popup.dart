import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../ui/theme.dart';
import 'bill_api.dart' show billItems, billAddOns;

// The bill as the machine prints it (founder, 28 Oct 2026): a paper slip with torn edges, in a till font. It shows the outlet, table,
// bill number and time, every dish with its quantity, rate and amount (takeaway dishes marked), subtotal, discount, CGST and SGST
// (the GST split in half), service charge, round off, the total, and PAID or UNPAID. [printBillSlip] sends the same slip as an 80 mm receipt.
// An order is one order of `rst_bill_view`; the view is the whole answer (outlet and table).

/// Prints the receipt PDF (tests replace it).
Future<void> Function(Uint8List pdf, String name) printReceiptPdf = (pdf, name) => Printing.layoutPdf(onLayout: (_) async => pdf, name: name);

/// Sends the bill straight to the printer as the 80 mm slip (the Checkout's Print button). False when the printer could not be opened.
Future<bool> printBillSlip({required Facts view, required Facts order}) async {
  try {
    await printReceiptPdf(await _pdf(_Lines(view, order)), 'Bill ${order.s('display_no')}.pdf');
    return true;
  } catch (_) {
    return false;
  }
}

/// The slip's lines, shared by the screen and the printout.
class _Lines {
  _Lines(Facts view, this.o)
      : outlet = (view.m('location').so('name') ?? '').trim(),
        table = view.m('table').so('label'),
        seats = view.m('table').n('seats').toInt();
  final Facts o;
  final String outlet;
  final String? table;
  final int seats;

  String get when {
    final t = DateTime.tryParse(o.s('created_at'))?.toLocal() ?? DateTime.now();
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '${t.day.toString().padLeft(2, '0')} ${m[t.month - 1]} ${t.year}  $h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  num get gst => o.n('gst_amount');
  String get halfPct {
    final p = o.n('gst_pct') / 2;
    return p == p.roundToDouble() ? '${p.toInt()}' : p.toStringAsFixed(1);
  }

  bool get paid => o.n('due') <= 0 && o.n('total') > 0;

  /// Label and amount rows under the dishes; zero rows are left out (subtotal and total always show).
  List<(String, num)> get sums => [
        ('Subtotal', o.n('subtotal')),
        if (o.n('discount') != 0) ('Discount${o.so('coupon_code') == null ? '' : ' (${o.s('coupon_code')})'}', -o.n('discount')),
        if (gst != 0) ('CGST @ $halfPct%', gst / 2),
        if (gst != 0) ('SGST @ $halfPct%', gst / 2),
        if (o.n('service_charge') != 0) ('Service charge', o.n('service_charge')),
        if (o.n('round_off') != 0) ('Round off', o.n('round_off')),
      ];
}

String _amt(num v) => v.toStringAsFixed(2);

/// The paper slip itself, as it sits on the table's order page (founder, 28 Oct 2026: the bill is the page; its buttons sit under it).
class BillSlip extends StatelessWidget {
  const BillSlip({super.key, required this.view, required this.order});
  final Facts view, order;

  @override
  Widget build(BuildContext context) {
    final l = _Lines(view, order);
    final mono = inter(13, 500, height: 1.35).copyWith(fontFamily: 'monospace', color: const Color(0xFF1C1C1C));
    final bold = mono.copyWith(fontWeight: FontWeight.w800);
    Widget dashes() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          // a dashed rule across the whole slip (a row of hyphens stopped short of the edge)
          child: const SizedBox(height: 1, width: double.infinity, child: CustomPaint(painter: _Dashes())),
        );
    Widget row(String left, String right, {TextStyle? style, Key? key}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.5),
          child: Row(key: key, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(left, style: style ?? mono)),
            Text(right, style: style ?? mono),
          ]),
        );
    final items = billItems(order);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: DecoratedBox(
          decoration: const BoxDecoration(boxShadow: [BoxShadow(color: Color(0x1F000000), blurRadius: 18, offset: Offset(0, 6))]),
          child: ClipPath(
                clipper: _TornEdges(),
                child: Container(
                  key: const ValueKey('bill-receipt'),
                  color: const Color(0xFFFFFEF8),
                  padding: const EdgeInsets.fromLTRB(20, 26, 20, 28),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(l.outlet.isEmpty ? 'BILL' : l.outlet.toUpperCase(), textAlign: TextAlign.center, style: bold.copyWith(fontSize: 16)),
                    Text('TAX INVOICE', textAlign: TextAlign.center, style: mono.copyWith(fontSize: 11.5, color: const Color(0xFF555555))),
                    dashes(),
                    row('Bill No: ${order.s('display_no')}', l.table == null ? '' : 'Table: ${l.table}', key: const ValueKey('receipt-no')),
                    row(l.when, l.seats > 0 ? '${l.seats} Pax' : ''),
                    dashes(),
                    row('Item', 'Amount', style: bold),
                    for (final i in items) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('${i.s('name')}${(i.so('variant') ?? '').isEmpty ? '' : ' (${i.s('variant')})'}${i.b('takeaway') ? '  [TAKEAWAY]' : ''}',
                            style: mono.copyWith(fontWeight: FontWeight.w600)),
                      ),
                      // add-ons and combos chosen with the dish (0625), each priced for one dish
                      for (final (what, price) in billAddOns(i)) row('  $what', '@${_amt(price)}', style: mono.copyWith(fontSize: 12, color: const Color(0xFF555555))),
                      row('  ${i.n('qty').toInt()} x ${_amt(i.n('unit_price'))}', _amt(i.n('line_total'))),
                    ],
                    dashes(),
                    for (final (k, v) in l.sums) row(k, _amt(v)),
                    dashes(),
                    row('TOTAL', '₹ ${_amt(order.n('total'))}', style: bold.copyWith(fontSize: 16), key: const ValueKey('receipt-total')),
                    if (order.n('paid') > 0 && !l.paid) row('Paid', _amt(order.n('paid'))),
                    if (order.n('paid') > 0 && !l.paid) row('Due', _amt(order.n('due')), style: bold),
                    dashes(),
                    Center(
                      child: Container(
                        key: const ValueKey('receipt-status'),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                        decoration: BoxDecoration(border: Border.all(color: l.paid ? const Color(0xFF15803D) : const Color(0xFFB91C1C), width: 1.5)),
                        child: Text(l.paid ? 'PAID' : 'UNPAID', style: bold.copyWith(color: l.paid ? const Color(0xFF15803D) : const Color(0xFFB91C1C))),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text('${items.fold<int>(0, (a, i) => a + i.n('qty').toInt())} items · Thank you! Visit again', textAlign: TextAlign.center, style: mono.copyWith(fontSize: 12)),
                    const SizedBox(height: 8),
                    // a barcode-like strip from the bill number, as a printed slip has
                    Center(child: CustomPaint(size: const Size(180, 30), painter: _Bars(order.s('display_no')))),
                  ]),
                ),
          ),
        ),
      ),
    );
  }
}

/// Zig-zag top and bottom, like paper torn off the roll.
class _TornEdges extends CustomClipper<Path> {
  @override
  Path getClip(Size s) {
    const tooth = 10.0, depth = 6.0;
    final p = Path()..moveTo(0, depth);
    for (var x = 0.0; x < s.width; x += tooth) {
      p
        ..lineTo(x + tooth / 2, 0)
        ..lineTo(x + tooth, depth);
    }
    p.lineTo(s.width, s.height - depth);
    for (var x = s.width; x > 0; x -= tooth) {
      p
        ..lineTo(x - tooth / 2, s.height)
        ..lineTo(x - tooth, s.height - depth);
    }
    return p..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// A barcode-looking strip drawn from the bill number (decoration; not a scannable code).
class _Bars extends CustomPainter {
  _Bars(this.code);
  final String code;
  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()..color = const Color(0xFF1C1C1C);
    var x = 0.0;
    var i = 0;
    final units = code.codeUnits.isEmpty ? [7, 3, 5] : code.codeUnits;
    while (x < s.width) {
      final u = units[i % units.length] + i;
      final w = 1.0 + (u % 3);
      canvas.drawRect(Rect.fromLTWH(x, 0, w, s.height), p);
      x += w + 1.5 + ((u >> 2) % 3);
      i++;
    }
  }

  @override
  bool shouldRepaint(covariant _Bars old) => old.code != code;
}

/// The same slip as an 80 mm roll receipt.
Future<Uint8List> _pdf(_Lines l) async {
  final o = l.o;
  final doc = pw.Document();
  final mono = pw.Font.courier(), monoBold = pw.Font.courierBold();
  pw.Widget t(String s, {bool b = false, double size = 9, pw.TextAlign align = pw.TextAlign.left}) =>
      pw.Text(s, textAlign: align, style: pw.TextStyle(font: b ? monoBold : mono, fontSize: size));
  pw.Widget r(String a, String b, {bool bold = false, double size = 9}) =>
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [pw.Expanded(child: t(a, b: bold, size: size)), t(b, b: bold, size: size)]);
  final dash = t('-' * 42);
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.roll80,
    margin: const pw.EdgeInsets.all(10),
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      t(l.outlet.isEmpty ? 'BILL' : l.outlet.toUpperCase(), b: true, size: 12, align: pw.TextAlign.center),
      t('TAX INVOICE', align: pw.TextAlign.center),
      dash,
      r('Bill No: ${o.s('display_no')}', l.table == null ? '' : 'Table: ${l.table}'),
      r(l.when, l.seats > 0 ? '${l.seats} Pax' : ''),
      dash,
      r('Item', 'Amount', bold: true),
      for (final i in billItems(o)) ...[
        t('${i.s('name')}${(i.so('variant') ?? '').isEmpty ? '' : ' (${i.s('variant')})'}${i.b('takeaway') ? ' [TAKEAWAY]' : ''}', b: true),
        for (final (what, price) in billAddOns(i)) r('  ${what.replaceAll('×', 'x')}', '@${_amt(price)}'),
        r('  ${i.n('qty').toInt()} x ${_amt(i.n('unit_price'))}', _amt(i.n('line_total'))),
      ],
      dash,
      for (final (k, v) in l.sums) r(k, _amt(v)),
      dash,
      r('TOTAL', 'Rs ${_amt(o.n('total'))}', bold: true, size: 11),
      dash,
      t(l.paid ? 'PAID' : 'UNPAID', b: true, align: pw.TextAlign.center),
      t('Thank you! Visit again', align: pw.TextAlign.center),
    ]),
  ));
  return doc.save();
}

/// A dashed rule, edge to edge, as a till slip has between its parts.
class _Dashes extends CustomPainter {
  const _Dashes();
  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = const Color(0xFF9A9A9A)
      ..strokeWidth = 1;
    for (var x = 0.0; x < s.width; x += 7) {
      canvas.drawLine(Offset(x, 0), Offset((x + 4).clamp(0, s.width), 0), p);
    }
  }

  @override
  bool shouldRepaint(covariant _Dashes old) => false;
}
