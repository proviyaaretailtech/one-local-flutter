import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/barcodes/barcode_sheets.dart' show printBarcodeLabels;
import 'package:vinii_pos/devices/bill_receipt.dart';
import 'package:vinii_pos/devices/devices_api.dart';
import 'package:vinii_pos/devices/print_service.dart';
import 'package:vinii_pos/orders/orders_api.dart' show rupees;
import 'package:vinii_pos/stock/label_pdf.dart';
import 'package:vinii_pos/stock/labels_screens.dart' show printLabelPdf;

// Printing through the Device manager (founder, 31 Oct 2026): bills to the default receipt printer, labels to the default label
// printer; a network printer straight away, the others through the print dialog at their size, none: the print dialog.

StorePrinter printer(String type, String connection, {int paper = 80, String label = '', bool cut = true}) => StorePrinter({
      'id': 'p', 'name': type == 'label' ? 'Label printer' : 'Counter printer', 'printer_type': type, 'connection': connection,
      'address': connection == 'lan' ? '192.168.1.50:9100' : '', 'paper_mm': paper, 'label_size': label, 'auto_cut': cut, 'is_default': true,
    });

void main() {
  late List<(String, List<int>)> raw;
  late List<String> dialogs;
  final realRaw = sendRawToPrinter, realDialog = printReceiptDialog, realLabel = printLabelPdf, realDefault = defaultPrinterFor;
  setUp(() {
    raw = [];
    dialogs = [];
    sendRawToPrinter = (host, port, bytes) async => raw.add(('$host:$port', bytes));
    printReceiptDialog = (Uint8List pdf, String name) async => dialogs.add(name);
    printLabelPdf = (Uint8List pdf, String name) async => dialogs.add(name);
  });
  tearDown(() {
    sendRawToPrinter = realRaw;
    printReceiptDialog = realDialog;
    printLabelPdf = realLabel;
    defaultPrinterFor = realDefault;
  });

  test('a bill on a network receipt printer: straight to its port, once, cut; no dialog', () async {
    defaultPrinterFor = (job) async => job == 'receipt' ? printer('receipt', 'lan', paper: 58) : null;
    final r = await printReceiptText('Receipt S-1001\n2 x Amul Butter 500g  ₹580\nTotal ₹580', store: 'Sharma General Store');
    expect(r.route, PrintRoute.direct);
    expect(raw.single.$1, '192.168.1.50:9100');
    final text = String.fromCharCodes(raw.single.$2);
    expect(RegExp('SHARMA GENERAL STORE').allMatches(text).length, 1); // one copy
    expect(text, contains('Rs 580')); // ₹ is not in the printer's font
    expect(dialogs, isEmpty);
  });

  test('a network printer that does not answer: the print dialog, and why', () async {
    defaultPrinterFor = (job) async => printer('receipt', 'lan');
    sendRawToPrinter = (host, port, bytes) async => throw Exception('refused');
    String? why;
    final r = await printReceiptText('Total ₹10', title: 'Receipt S-1', onFallback: (w) => why = w);
    expect(r.route, PrintRoute.dialog);
    expect(why, 'Counter printer did not answer at 192.168.1.50:9100');
    expect(dialogs, ['Receipt S-1']);
  });

  test('a Bluetooth receipt printer, or none: the print dialog', () async {
    defaultPrinterFor = (job) async => printer('receipt', 'bluetooth');
    expect((await printReceiptText('x', title: 'A')).route, PrintRoute.dialog);
    defaultPrinterFor = (job) async => null;
    expect((await printReceiptText('x', title: 'B')).route, PrintRoute.dialog);
    expect(dialogs, ['A', 'B']);
    expect(raw, isEmpty);
  });

  test('a USB printer on an OTG cable, or a paired Bluetooth one: straight to it, no dialog; one that fails: the dialog, and why', () async {
    final local = <String>[];
    final realLocal = sendLocalPrinter;
    addTearDown(() => sendLocalPrinter = realLocal);
    sendLocalPrinter = (address, bytes) async => local.add(address);
    StorePrinter on(String conn, String address) => StorePrinter({...printer('receipt', conn).raw, 'address': address});
    defaultPrinterFor = (job) async => on('usb', 'usb:04b8:0e28');
    expect((await printReceiptText('Total ₹10', store: 'S')).route, PrintRoute.direct);
    defaultPrinterFor = (job) async => on('bluetooth', '66:22:B1:0A:7C:01');
    expect((await printReceiptText('Total ₹10', store: 'S')).route, PrintRoute.direct);
    expect(local, ['usb:04b8:0e28', '66:22:B1:0A:7C:01']);
    expect(dialogs, isEmpty);

    sendLocalPrinter = (address, bytes) async => throw StateError('unplugged');
    String? why;
    expect((await printReceiptText('x', title: 'C', onFallback: (w) => why = w)).route, PrintRoute.dialog);
    expect(why, 'Counter printer did not answer');
    expect(dialogs, ['C']);
  });

  test('a bill the server did not round: 50 paise and up go to the next rupee, below that down', () {
    BillReceipt at(num total) => BillReceipt(store: 'S', billNo: 'P-1', when: '', lines: const [], subtotal: total, total: total);
    expect([at(142.5).roundedTotal, at(142.49).roundedTotal, at(142.75).roundedTotal, at(30).roundedTotal], [143, 142, 143, 30]);
    expect(at(142.49).totals.map((t) => t.$1), ['Subtotal', 'Round off', 'Total']);
    expect(at(30).totals.map((t) => t.$1), ['Subtotal', 'Total']);
  });

  test('ESC/POS: long lines wrap to the paper, no cut when auto cut is off', () {
    final bytes = escPosReceipt('X' * 40, printer: printer('receipt', 'lan', paper: 58, cut: false));
    final text = String.fromCharCodes(bytes);
    expect(text, contains('${'X' * 32}\n${'X' * 8}\n'));
    expect(bytes.sublist(bytes.length - 3), [0x1B, 0x64, 0x04]); // feed, no cut
  });

  const atta = LabelData(name: 'Aashirvaad Atta 5kg', priceMinor: 29500, mrpMinor: 31000, code: '2000000000015', systemCode: 'OL-ATT-ASH-5KG-01');

  test('TSPL labels: the roll size, name, price with MRP, EAN-13, and the copies', () {
    final t = String.fromCharCodes(tsplLabels([(atta, 3)], printer: printer('label', 'lan', label: '50x25')));
    expect(t, startsWith('SIZE 50 mm,25 mm\r\n'));
    expect(t, contains('"Rs 295  MRP Rs 310"'));
    expect(t, contains('"EAN13"'));
    expect(t, contains('"2000000000015"'));
    expect(t, contains('PRINT 1,3'));
  });

  test('barcode labels: a network label printer prints them straight away; a Bluetooth one gets the print dialog', () async {
    defaultPrinterFor = (job) async => job == 'label' ? printer('label', 'lan', label: '50x25') : null;
    await printBarcodeLabels([(atta, 1)]);
    expect(raw.single.$1, '192.168.1.50:9100');
    expect(dialogs, isEmpty);
    defaultPrinterFor = (job) async => job == 'label' ? printer('label', 'bluetooth', label: '50x25') : null;
    await printBarcodeLabels([(atta, 1)]);
    expect(dialogs, ['Barcode labels']);
  });

  group('receipt design', receiptDesign);

  test('the label size follows the printer\'s roll when the app has it', () {
    expect(labelSizeFor(printer('label', 'usb', label: '50x25'), LabelSize.product), LabelSize.small);
    expect(labelSizeFor(printer('label', 'usb', label: '75x50'), LabelSize.product), LabelSize.medium);
    expect(labelSizeFor(printer('label', 'usb', label: '38x25'), LabelSize.product), LabelSize.product);
    expect(labelSizeFor(null, LabelSize.large), LabelSize.large);
  });
}

// The customer's bill, ticket style (1 Nov 2026): the shop, "Thank you!", bill no and amount, date, the customer with how they paid,
// the items, the totals, the bill number as a barcode.
void receiptDesign() {
  TestWidgetsFlutterBinding.ensureInitialized(); // the app's fonts, for ₹
  const bill = BillReceipt(
    store: 'Sharma General Store', branch: 'Main', billNo: 'P-00028', when: '01 Nov 2026 · 12:53 PM', customer: 'Ishwari', phone: '9876543210', payment: 'Cash',
    lines: [(name: 'Salt 1 kg', qty: 1, amount: 30), (name: 'Basmati Rice Loose · 1.250 kg', qty: 1, amount: 112.5)],
    subtotal: 142.5, roundOff: 0.5, total: 143, paid: 143, tendered: 200, change: 57,
  );

  test('the receipt names the shop, the customer, their number and how they paid', () {
    expect(bill.phoneText, '+91 98765 43210');
    expect([for (final t in bill.totals) (t.$1, t.$2)], [('Subtotal', rupees(142.5)), ('Round off', '+${rupees(0.5)}'), ('Total', rupees(143)), ('Payment mode', 'Cash')]);
    expect(bill.qtyWord, '2 items · 2 units');
  });

  test('ESC/POS: the shop big, customer, number, paid by, the lines aligned, the bill number as a barcode', () {
    final bytes = billEscPos(bill, printer: printer('receipt', 'lan', paper: 58));
    final text = String.fromCharCodes(bytes);
    expect(text, contains('SHARMA GENERAL'));
    expect(text, contains('Customer: Ishwari'));
    expect(text, contains('Mobile:   +91 98765 43210'));
    expect(text, contains('Payment:  Cash'));
    expect(text.split('\n').where((l) => l.contains('Salt 1 kg')).single.length, 32); // the amount at the right edge
    expect(text, isNot(contains('Change')));
    expect(text, isNot(contains('{B'))); // no barcode
    expect(text, contains('OneLocal Partner store'));
    expect(text, isNot(contains('₹')));
  });

  test('the print dialog gets the ticket-style PDF when there is no network printer', () async {
    defaultPrinterFor = (job) async => printer('receipt', 'bluetooth', paper: 58);
    final names = <String>[];
    Uint8List? pdf;
    printReceiptDialog = (p, name) async {
      names.add(name);
      pdf = p;
    };
    final r = await printBillReceipt(bill);
    expect(r.route, PrintRoute.dialog);
    expect(names, ['Receipt P-00028']);
    expect(String.fromCharCodes(pdf!.take(5)), '%PDF-');
    const out = String.fromEnvironment('RECEIPT_PDF');
    if (out.isNotEmpty) File(out).writeAsBytesSync(pdf!);
  });
}
