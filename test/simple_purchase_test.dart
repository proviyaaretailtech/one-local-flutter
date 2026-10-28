import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/purchasing/purchasing_api.dart';
import 'package:vinii_pos/purchasing/simple_purchase.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart' show toast;

// The simplified purchase (founder, 28 Oct 2026): Received with quantities and MRP, the bill, past purchases.

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

class Fake {
  final requests = <http.Request>[];
  Map<String, dynamic> body(String fn) => jsonDecode(requests.lastWhere((r) => fnOf(r) == fn).body) as Map<String, dynamic>;
  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
  late final api = PurchasingApi(baseUrl: 'http://t.test', accessToken: () => 't', client: MockClient((r) async {
    requests.add(r);
    final b = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
    return switch (fnOf(r)) {
      'pur_item_find' => ok({
          'items': b['q'] == '8901234567890'
              ? [{'id': 'i9', 'name': 'Parle-G 250g', 'sku': 'PG250', 'mrp_minor': 2500, 'cost_minor': 2100}]
              : [{'id': 'i7', 'name': 'Amul Butter 500g', 'sku': 'AMB500', 'mrp_minor': 29000, 'cost_minor': 26000}],
        }),
      'pur_receive_post' => ok({'document_id': 'rcv1', 'doc_no': 'RCV-012', 'replayed': false}),
      'pur_bill_get' => ok({
          'receipt': {'id': 'rcv1', 'doc_no': 'RCV-012', 'status': 'posted', 'supplier_name': 'Metro', 'po_ref': 'SPO-1', 'posted_at': '2026-10-28T10:00:00Z',
            'lines': [{'inventory_item_id': 'i1', 'name': 'Aashirvaad Atta 5kg', 'qty': 18}]},
          'bill': {'supplier_name': 'Metro', 'invoice_no': '', 'saved': false, 'payment_status': 'unpaid', 'paid_minor': 0,
            'lines': [{'inventory_item_id': 'i1', 'name': 'Aashirvaad Atta 5kg', 'qty': 18, 'rate_minor': 26550, 'discount_pct': 0, 'gst_pct': 5}], 'credit_lines': []},
        }),
      'pur_bill_save' => ok({'receipt': {'id': 'rcv1'}, 'bill': {'saved': true}}),
      'pur_history' => ok({
          'purchases': [
            {'receipt_document_id': 'rcv1', 'doc_no': 'RCV-012', 'posted_at': '2026-10-28T10:00:00Z', 'supplier_name': 'Metro', 'po_ref': 'SPO-1', 'invoice_no': 'INV-77',
              'total_minor': 491800, 'credit_minor': 53100, 'payment_status': 'paid', 'bill_saved': true, 'items': 1, 'units': 18},
          ],
        }),
      _ => ok({}),
    };
  }));
}

final _po = PurchaseOrder({
  'id': 'po1', 'number': 'SPO-1', 'status': 'Approved', 'supplier': {'name': 'Metro'}, 'days_waiting': 4,
  'lines': [
    {'material_id': 'i1', 'name': 'Aashirvaad Atta 5kg', 'code': 'AAT5KG', 'ordered_qty': 20, 'received_qty': 0, 'rejected_qty': 0, 'unit_cost_minor': 27000, 'mrp_minor': 31000},
    {'material_id': 'i2', 'name': 'Tata Salt 1kg', 'code': 'TS1', 'ordered_qty': 10, 'received_qty': 0, 'rejected_qty': 0, 'unit_cost_minor': 2200},
  ],
});

Future<void> show(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(780, 4000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: w));
  await t.pumpAndSettle();
}

Future<void> tapKey(WidgetTester t, String key) async {
  // a message from the last tap would sit over the bottom bar's button
  t.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)).removeCurrentSnackBar();
  await t.pump();
  final f = find.byKey(ValueKey(key));
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  group('Received', () {
    testWidgets('the order\'s items come in with what is still due, their MRP and price; a line without MRP stops it', (t) async {
      final f = Fake();
      String? opened;
      await show(t, ReceiveGoodsScreen(api: f.api, po: _po, openBill: (_, id) => opened = id));
      expect(find.text('SPO-1 · Metro'), findsOneWidget);
      expect(t.widget<TextField>(find.byKey(const ValueKey('recv-qty-0'))).controller!.text, '20');
      expect(t.widget<TextField>(find.byKey(const ValueKey('recv-mrp-0'))).controller!.text, '310');
      expect(t.widget<TextField>(find.byKey(const ValueKey('recv-cost-0'))).controller!.text, '270');
      // Tata Salt has no MRP yet: Mark received refuses, and says which line
      await tapKey(t, 'recv-mark-received');
      expect(f.calls('pur_receive_post'), isEmpty);
      expect(find.text('Add the MRP to add this to stock.'), findsOneWidget);
      // fewer atta came; the salt gets its MRP
      await t.enterText(find.byKey(const ValueKey('recv-qty-0')), '18');
      await t.enterText(find.byKey(const ValueKey('recv-mrp-1')), '28');
      await t.pumpAndSettle();
      expect(find.text('2 fewer than ordered'), findsOneWidget);
      await tapKey(t, 'recv-mark-received');
      final b = f.body('pur_receive_post');
      expect(b['po_id'], 'po1');
      expect(b['lines'], [
        {'inventory_item_id': 'i1', 'qty': 18, 'mrp': 310, 'cost': 270, 'ordered_qty': 20},
        {'inventory_item_id': 'i2', 'qty': 10, 'mrp': 28, 'cost': 22, 'ordered_qty': 10},
      ]);
      expect(f.calls('pur_receive_post').single.headers['Idempotency-Key'], startsWith('pur-'));
      expect(opened, 'rcv1'); // then the bill
    });

    testWidgets('the empty line at the end adds an extra item: search by name, or scan its barcode', (t) async {
      final f = Fake();
      scanForPurchase = (_) async => '8901234567890';
      addTearDown(() => scanForPurchase = (c) async => null);
      await show(t, ReceiveGoodsScreen(api: f.api, po: _po, openBill: (_, _) {}));
      await t.enterText(find.byKey(const ValueKey('recv-find')), 'amul');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('recv-new-product')), findsOneWidget); // not there? make it
      await tapKey(t, 'recv-hit-i7');
      expect(find.text('Amul Butter 500g'), findsOneWidget);
      expect(find.text('Not on order'), findsOneWidget);
      expect(t.widget<TextField>(find.byKey(const ValueKey('recv-mrp-2'))).controller!.text, '290');
      await tapKey(t, 'recv-scan');
      expect(f.body('pur_item_find')['q'], '8901234567890');
      expect(find.text('Parle-G 250g'), findsOneWidget);
      expect(find.text('Not on order'), findsNWidgets(2));
    });

    testWidgets('Add purchase (no order): asks who it came from, then sends the supplier', (t) async {
      final f = Fake();
      await show(t, ReceiveGoodsScreen(api: f.api, openBill: (_, _) {}));
      expect(find.text('Add purchase'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('recv-find')), 'amul');
      await t.pumpAndSettle();
      await tapKey(t, 'recv-hit-i7');
      await tapKey(t, 'recv-mark-received');
      expect(toast('Enter who the goods came from.'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('recv-supplier')), 'Metro');
      await tapKey(t, 'recv-mark-received');
      expect(f.body('pur_receive_post'), containsPair('supplier_name', 'Metro'));
      expect(f.body('pur_receive_post').containsKey('po_id'), isFalse);
    });
  });

  group('Purchase bill', () {
    testWidgets('the lines from the delivery; totals with discount and GST; payment and a credit note are saved', (t) async {
      final f = Fake();
      await show(t, PurchaseBillScreen(api: f.api, receiptId: 'rcv1', justReceived: true));
      expect(find.textContaining('Stock added'), findsOneWidget);
      expect(find.text('Aashirvaad Atta 5kg'), findsOneWidget);
      // 18 × ₹265.50 = ₹4,779; 5% GST ₹238.95; total ₹5,018
      expect(find.text('₹5,018'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('bill-disc-0')), '2');
      await t.pumpAndSettle();
      expect(find.text('₹4,918'), findsOneWidget);
      await tapKey(t, 'bill-save');
      expect(toast('Enter the invoice number.'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('bill-invoice')), 'INV-77');
      await tapKey(t, 'bill-pay-paid');
      await tapKey(t, 'credit-add');
      await t.enterText(find.byKey(const ValueKey('credit-name-0')), 'Atta');
      await t.enterText(find.byKey(const ValueKey('credit-amount-0')), '531');
      await t.pumpAndSettle();
      await tapKey(t, 'bill-save');
      final b = f.body('pur_bill_save');
      expect(b['invoice_no'], 'INV-77');
      expect(b['payment_status'], 'paid');
      expect(b['lines'], [{'inventory_item_id': 'i1', 'name': 'Aashirvaad Atta 5kg', 'qty': 18, 'rate': 265.5, 'discount_pct': 2, 'gst_pct': 5}]);
      expect(b['credit_lines'], [{'name': 'Atta', 'qty': null, 'reason': 'short', 'amount': 531}]);
    });
  });

  group('Past purchases', () {
    testWidgets('this month by default; this week, last month and newest / amount sorting ask the server', (t) async {
      final f = Fake();
      await show(t, PastPurchasesScreen(api: f.api, today: DateTime(2026, 10, 28)));
      expect(f.body('pur_history'), containsPair('from', '2026-10-01'));
      expect(f.body('pur_history'), containsPair('to', '2026-10-28'));
      expect(find.text('Metro'), findsOneWidget);
      expect(find.text('₹4,918'), findsOneWidget);
      expect(find.textContaining('Invoice INV-77'), findsOneWidget);
      await tapKey(t, 'chip-week');
      expect(f.body('pur_history'), containsPair('from', '2026-10-26')); // Monday
      await tapKey(t, 'chip-last_month');
      expect(f.body('pur_history'), containsPair('from', '2026-09-01'));
      expect(f.body('pur_history'), containsPair('to', '2026-09-30'));
      await tapKey(t, 'past-sort');
      await t.tap(find.text('Highest amount').last);
      await t.pumpAndSettle();
      expect(f.body('pur_history'), containsPair('sort', 'amount'));
    });
  });

  test('a Facts line reads its numbers', () => expect(Facts({'n': '3'}).n('n'), 3));
}
