import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/ui/invoice_input.dart';

// The supplier's invoice number (founder, 31 Oct 2026): capitals, numbers, - and / only, up to 16; small letters become capitals.

void main() {
  test('the founder\'s examples go in as they are', () {
    for (final v in ['INV001', 'ABC/2026/01', '001-2026', 'INV/26-27/001']) {
      expect(InvoiceNoFormatter.clean(v), v);
    }
  });

  test('small letters become capitals; spaces and other signs are dropped; 16 at most', () {
    expect(InvoiceNoFormatter.clean('inv/26-27/001'), 'INV/26-27/001');
    expect(InvoiceNoFormatter.clean('INV 001#@_.,'), 'INV001');
    expect(InvoiceNoFormatter.clean('ABCDEFGHIJKLMNOPQRS'), 'ABCDEFGHIJKLMNOP');
    expect(InvoiceNoFormatter.clean('ABCDEFGHIJKLMNOPQRS').length, kInvoiceNoMax);
  });

  testWidgets('typed into a box: capitals as you type, nothing made up', (t) async {
    final c = TextEditingController();
    await t.pumpWidget(MaterialApp(home: Scaffold(body: TextField(controller: c, inputFormatters: invoiceNoFormatters))));
    expect(c.text, ''); // no number is generated
    await t.enterText(find.byType(TextField), 'abc / 2026 / 01');
    expect(c.text, 'ABC/2026/01');
    await t.enterText(find.byType(TextField), 'inv/26-27/001-extra-long');
    expect(c.text, 'INV/26-27/001-EX');
  });
}
