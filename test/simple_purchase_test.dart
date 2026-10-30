import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/barcodes/barcodes_api.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/inventory/receiving_screen.dart' show newItemForReceiving;
import 'package:vinii_pos/money/store_money.dart' show StoreMoneyApi;
import 'package:vinii_pos/purchasing/purchase_item_entry.dart';
import 'package:vinii_pos/purchasing/add_supplier_sheet.dart' show pickPhoneContact;
import 'package:vinii_pos/purchasing/purchasing_api.dart';
import 'package:vinii_pos/purchasing/simple_purchase.dart';
import 'package:vinii_pos/stock/labels_screens.dart' show printLabelPdf;
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart' show toast;

// The simplified purchase (founder, 28 Oct 2026): Received with quantities and MRP, the bill, past purchases.

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

class Fake {
  final requests = <http.Request>[];
  bool replayed = false;
  Map<String, dynamic> body(String fn) => jsonDecode(requests.lastWhere((r) => fnOf(r) == fn).body) as Map<String, dynamic>;
  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
  late final api = PurchasingApi(baseUrl: 'http://t.test', accessToken: () => 't', client: MockClient((r) async {
    requests.add(r);
    final b = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
    return switch (fnOf(r)) {
      'pur_item_find' => ok({
          'items': b['q'] == '8901234567890'
              ? [{'id': 'i9', 'name': 'Parle-G 250g', 'sku': 'PG250', 'barcode': '8901234567890', 'mrp_minor': 2500, 'cost_minor': 2100, 'selling_unit': 'pc'}]
              : b['q'] == 'zzz' || b['q'] == '8900000000001'
                  ? []
                  : b['q'] == 'dal'
                      ? [{'id': 'i6', 'name': 'Toor Dal Loose', 'sku': 'TOORDAL', 'menu_item_id': 'm6', 'selling_unit': 'kg', 'cost_minor': 11000, 'price_minor': 13000}]
                  : b['q'] == 'rice'
                      ? [{'id': 'i5', 'name': 'Sona Masoori Rice', 'sku': 'SONA', 'barcode': '2000000000046', 'barcode_source': 'generated', 'plu': 4, 'selling_unit': 'kg', 'cost_minor': 5200, 'price_minor': 6000}]
                      : [{'id': 'i7', 'name': 'Amul Butter 500g', 'sku': 'AMB500', 'barcode': '8901262010016', 'mrp_minor': 29000, 'cost_minor': 26000, 'selling_unit': 'pc'}],
        }),
      'pur_supplier_list' => ok({
          'suppliers': [
            {'id': 's1', 'name': 'Metro Cash & Carry', 'phone': '9822001100', 'gstin': '27AABCM1234F1Z5', 'city': 'Pune'},
            {'id': 's2', 'name': 'Fresh Farms Dairy', 'phone': '9890112233', 'gstin': '', 'city': 'Latur'},
          ],
        }),
      'pur_item_browse' => ok(b['category_id'] == null
          ? {'categories': [{'id': 'c1', 'name': 'Biscuits', 'count': 2}, {'id': 'none', 'name': 'Other items', 'count': 1}], 'items': []}
          : {'categories': [], 'items': [
              {'id': 'i9', 'name': 'Parle-G 250g', 'sku': 'PG250', 'mrp_minor': 2500, 'cost_minor': 2100},
              {'id': 'i8', 'name': 'Good Day Cashew 100g', 'sku': 'GD100', 'mrp_minor': 3000, 'cost_minor': 2500, 'image_url': ''},
            ]}),
      'pur_supplier_save' => ok({'id': 's9', 'name': b['name'], 'phone': b['phone'], 'gstin': ''}),
      'pur_receive_post' => ok({'document_id': 'rcv1', 'doc_no': 'RCV-012', 'replayed': replayed}),
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

/// The search bar → [query] → the item → its quantity (and rate) → Add to purchase.
Future<void> addItem(WidgetTester t, String query, String id, {String qty = '1', String? rate, String? disc}) async {
  await t.enterText(find.byKey(const ValueKey('recv-find')), query);
  await t.pumpAndSettle();
  await tapKey(t, 'pick-$id');
  await t.enterText(find.byKey(const ValueKey('line-qty')), qty);
  if (rate != null) await t.enterText(find.byKey(const ValueKey('line-rate')), rate);
  if (disc != null) await t.enterText(find.byKey(const ValueKey('line-disc')), disc);
  await t.pumpAndSettle();
  await tapKey(t, 'line-add');
}

/// Review purchase → Confirm.
Future<void> confirm(WidgetTester t) async {
  await tapKey(t, 'recv-mark-received');
  expect(find.byKey(const ValueKey('recv-review')), findsOneWidget);
  await tapKey(t, 'recv-confirm');
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
      expect(f.calls('pur_receive_post'), isEmpty); // the review first: nothing saved yet
      expect(find.text('+ 18  Aashirvaad Atta 5kg'), findsOneWidget);
      await tapKey(t, 'review-back');
      await confirm(t);
      final b = f.body('pur_receive_post');
      expect(b['po_id'], 'po1');
      expect(b['lines'], [
        {'inventory_item_id': 'i1', 'qty': 18, 'mrp': 310, 'cost': 270, 'ordered_qty': 20, 'hsn': '', 'gst_pct': 0, 'discount_pct': 0},
        {'inventory_item_id': 'i2', 'qty': 10, 'mrp': 28, 'cost': 22, 'ordered_qty': 10, 'hsn': '', 'gst_pct': 0, 'discount_pct': 0},
      ]);
      expect(f.calls('pur_bill_save'), isEmpty); // no invoice number: the bill is entered later
      expect(f.calls('pur_receive_post').single.headers['Idempotency-Key'], startsWith('pur-'));
      expect(find.text('Stock added'), findsOneWidget); // the summary
      expect(find.text('RCV-012 · Metro'), findsOneWidget);
      await tapKey(t, 'done-bill');
      expect(opened, 'rcv1'); // then the bill
    });

    testWidgets('Add item: the store item found by name, its quantity and rate, then on the purchase with its SKU and maker barcode', (t) async {
      final f = Fake();
      await show(t, ReceiveGoodsScreen(api: f.api, po: _po, openBill: (_, _) {}));
      expect(find.text('Add items'), findsNothing); // the old add-items section is gone
      expect(find.byKey(const ValueKey('recv-dropdown')), findsNothing);
      expect(f.calls('pur_item_find'), isEmpty); // nothing typed yet
      await t.enterText(find.byKey(const ValueKey('recv-find')), 'amul');
      await t.pumpAndSettle();
      expect(find.textContaining('SKU AMB500 · Maker’s barcode 8901262010016'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('pick-mrp-i7'))).data, 'MRP ₹290');
      expect(find.text('Not in the list? Create new item'), findsOneWidget); // existing items first
      await tapKey(t, 'pick-i7');
      expect(find.byKey(const ValueKey('line-sheet')), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('line-facts'))).data, contains('Last bought at ₹260/pc'));
      await tapKey(t, 'line-add');
      expect(find.byKey(const ValueKey('line-error')), findsOneWidget); // no quantity yet
      await t.enterText(find.byKey(const ValueKey('line-qty')), '4');
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const ValueKey('line-total'))).data, '₹1,040');
      await tapKey(t, 'line-add');
      expect(find.text('Amul Butter 500g'), findsOneWidget);
      expect(find.text('Not on order'), findsOneWidget);
      expect(t.widget<TextField>(find.byKey(const ValueKey('recv-qty-2'))).controller!.text, '4');
      expect(t.widget<TextField>(find.byKey(const ValueKey('recv-mrp-2'))).controller!.text, '290');
      expect(find.textContaining('SKU AMB500'), findsOneWidget);
      // the same item again adds to its line, it is not a second line
      await addItem(t, 'amul', 'i7', qty: '2');
      expect(t.widget<TextField>(find.byKey(const ValueKey('recv-qty-2'))).controller!.text, '6');
      expect(find.byKey(const ValueKey('recv-line-3')), findsNothing);
    });

    testWidgets('scan: the maker barcode finds the store item at once; an unknown one offers a new item keeping that barcode', (t) async {
      final f = Fake();
      var code = '8901234567890';
      scanForPurchase = (_) async => code;
      addTearDown(() => scanForPurchase = (c) async => null);
      await show(t, ReceiveGoodsScreen(api: f.api, po: _po, openBill: (_, _) {}));
      await tapKey(t, 'recv-scan');
      expect(f.body('pur_item_find')['q'], '8901234567890');
      expect(find.byKey(const ValueKey('line-sheet')), findsOneWidget); // straight to its quantity
      await t.enterText(find.byKey(const ValueKey('line-qty')), '24');
      await tapKey(t, 'line-add');
      expect(find.text('Parle-G 250g'), findsOneWidget);
      code = '8900000000001';
      await tapKey(t, 'recv-scan');
      expect(find.byKey(const ValueKey('pick-none')), findsOneWidget);
      expect(find.textContaining('No item in your store has barcode 8900000000001'), findsOneWidget);
      expect(find.text('Create new item with barcode 8900000000001'), findsOneWidget);
      // the new item keeps the scanned code as its maker's barcode: no store code is offered for it
      final real = newItemForReceiving;
      String? askedCode;
      newItemForReceiving = (_, {name, barcode}) async {
        askedCode = barcode;
        return Facts({'id': 'inv-n', 'name': 'Tata Tea 250g', 'sku': 'TATATE-120', 'menu_item_id': 'm-n', 'selling_unit': 'pc', 'barcode': barcode, 'mrp_minor': 14000});
      };
      addTearDown(() => newItemForReceiving = real);
      await tapKey(t, 'pick-create');
      expect(askedCode, '8900000000001');
      expect(find.byKey(const ValueKey('newbc-sheet')), findsNothing);
      expect(find.textContaining('Maker’s barcode 8900000000001'), findsOneWidget);
    });

    testWidgets('loose goods: an existing store item reuses its SKU and store code, counted in kg with decimals', (t) async {
      final f = Fake();
      await show(t, ReceiveGoodsScreen(api: f.api, openBill: (_, _) {}));
      await t.enterText(find.byKey(const ValueKey('recv-find')), 'rice');
      await t.pumpAndSettle();
      expect(find.textContaining('SKU SONA · Store code 2000000000046 · PLU 4'), findsOneWidget);
      expect(find.textContaining('Bought by kg'), findsOneWidget);
      await tapKey(t, 'pick-i5');
      // no printed MRP on loose rice: its selling price per kg stands in
      expect(t.widget<TextField>(find.byKey(const ValueKey('line-mrp'))).controller!.text, '60');
      await t.enterText(find.byKey(const ValueKey('line-qty')), '12.5');
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const ValueKey('line-total'))).data, '₹650');
      await tapKey(t, 'line-add');
      expect(find.text('Qty (kg)'), findsOneWidget);
      expect(find.text('Rate/kg'), findsOneWidget);
      expect(t.widget<TextField>(find.byKey(const ValueKey('recv-qty-0'))).controller!.text, '12.5');
      await tapKey(t, 'recv-supplier');
      await tapKey(t, 'supplier-s2');
      await confirm(t);
      expect(f.body('pur_receive_post')['lines'], [
        {'inventory_item_id': 'i5', 'qty': 12.5, 'mrp': 60, 'cost': 52, 'ordered_qty': null, 'hsn': '', 'gst_pct': 0, 'discount_pct': 0, 'price_basis': 'store'},
      ]);
      expect(find.text('+12.5 kg'), findsOneWidget); // the summary
    });

    testWidgets('a new store item made inside the purchase: name filled in, a PLU for loose goods, an optional store barcode, then its quantity', (t) async {
      final f = Fake();
      String? askedName;
      final real = newItemForReceiving;
      newItemForReceiving = (_, {name, barcode}) async {
        askedName = name;
        return Facts({'id': 'inv-new', 'name': 'Farm Tomatoes', 'sku': 'FARMTO-311', 'menu_item_id': 'm-new', 'selling_unit': 'kg', 'price_minor': 4000});
      };
      final bc = <String>[];
      final realBc = purchaseBarcodes;
      purchaseBarcodes = () => BarcodesApi(baseUrl: 'http://b.test', accessToken: () => 't', client: MockClient((r) async {
            bc.add(fnOf(r));
            final item = {'menu_item_id': 'm-new', 'name': 'Farm Tomatoes', 'sku': 'FARMTO-311', 'price': 40, 'selling_unit': 'kg', 'loose': true, 'plu': 7};
            return ok(fnOf(r) == 'bc_make' ? {...item, 'barcode': '2000000000077', 'barcode_source': 'generated'} : item);
          }));
      addTearDown(() {
        newItemForReceiving = real;
        purchaseBarcodes = realBc;
      });
      await show(t, ReceiveGoodsScreen(api: f.api, openBill: (_, _) {}));
      await t.enterText(find.byKey(const ValueKey('recv-find')), 'zzz');
      await t.pumpAndSettle();
      expect(find.textContaining('No item matches “zzz”'), findsOneWidget);
      await tapKey(t, 'pick-create');
      expect(askedName, 'zzz');
      expect(bc, ['bc_set_loose']); // loose: it gets a PLU for weigh labels
      expect(find.byKey(const ValueKey('newbc-sheet')), findsOneWidget);
      await tapKey(t, 'newbc-labels-less'); // no label
      await tapKey(t, 'newbc-make');
      expect(bc, ['bc_set_loose', 'bc_make']);
      expect(t.widget<Text>(find.byKey(const ValueKey('line-facts'))).data, contains('Stock in kg'));
      expect(find.textContaining('SKU FARMTO-311 · Store code 2000000000077 · PLU 7'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('line-qty')), '8.25');
      await t.enterText(find.byKey(const ValueKey('line-rate')), '28');
      await tapKey(t, 'line-add');
      expect(find.text('Farm Tomatoes'), findsOneWidget);
      expect(t.widget<TextField>(find.byKey(const ValueKey('recv-qty-0'))).controller!.text, '8.25');
      expect(t.widget<TextField>(find.byKey(const ValueKey('recv-mrp-0'))).controller!.text, '40');
    });

    testWidgets('an item with no barcode: make its store barcode (and label) at the quantity step, or later from its line', (t) async {
      final f = Fake();
      final bc = <String>[];
      final printed = <String>[];
      final realBc = purchaseBarcodes, realPrint = printLabelPdf;
      purchaseBarcodes = () => BarcodesApi(baseUrl: 'http://b.test', accessToken: () => 't', client: MockClient((r) async {
            bc.add(fnOf(r));
            return ok({'menu_item_id': 'm6', 'name': 'Toor Dal Loose', 'sku': 'TOORDAL', 'price': 130, 'selling_unit': 'kg', 'loose': true, 'plu': 9,
              'barcode': '2000000000183', 'barcode_source': 'generated'});
          }));
      printLabelPdf = (pdf, name) async => printed.add(name);
      addTearDown(() {
        purchaseBarcodes = realBc;
        printLabelPdf = realPrint;
      });
      await show(t, ReceiveGoodsScreen(api: f.api, openBill: (_, _) {}));
      // at the quantity step
      await t.enterText(find.byKey(const ValueKey('recv-find')), 'dal');
      await t.pumpAndSettle();
      await tapKey(t, 'pick-i6');
      expect(find.text('No barcode'), findsOneWidget);
      await tapKey(t, 'line-make-code');
      expect(find.text('Make a barcode for Toor Dal Loose'), findsOneWidget);
      await tapKey(t, 'newbc-labels-more'); // two labels
      expect(find.text('Make barcode · print 2 labels'), findsOneWidget);
      await tapKey(t, 'newbc-make');
      expect(bc, ['bc_make']);
      expect(printed, ['Barcode labels']);
      expect(t.widget<Text>(find.byKey(const ValueKey('line-codes'))).data, contains('Store code 2000000000183'));
      expect(find.byKey(const ValueKey('line-make-code')), findsNothing);
      await t.enterText(find.byKey(const ValueKey('line-qty')), '5');
      await tapKey(t, 'line-add');
      expect(find.textContaining('Store code 2000000000183'), findsOneWidget); // on its line
      expect(find.byKey(const ValueKey('recv-make-code-0')), findsNothing);
    });

    testWidgets('Make barcode on a purchase line', (t) async {
      final f = Fake();
      final realBc = purchaseBarcodes;
      purchaseBarcodes = () => BarcodesApi(baseUrl: 'http://b.test', accessToken: () => 't', client: MockClient((r) async => ok({
            'menu_item_id': 'm6', 'name': 'Toor Dal Loose', 'sku': 'TOORDAL', 'price': 130, 'selling_unit': 'kg', 'plu': 9, 'barcode': '2000000000183', 'barcode_source': 'generated',
          })));
      addTearDown(() => purchaseBarcodes = realBc);
      await show(t, ReceiveGoodsScreen(api: f.api, openBill: (_, _) {}));
      await addItem(t, 'dal', 'i6', qty: '5');
      expect(find.byKey(const ValueKey('recv-make-code-0')), findsOneWidget);
      await tapKey(t, 'recv-make-code-0');
      await tapKey(t, 'newbc-labels-less'); // no label
      await tapKey(t, 'newbc-make');
      expect(find.textContaining('Store code 2000000000183'), findsOneWidget);
      expect(find.byKey(const ValueKey('recv-make-code-0')), findsNothing);
    });

    testWidgets('price type at the quantity step: MRP-based shows the MRP, store-based the selling price; each line sends it', (t) async {
      final f = Fake();
      await show(t, ReceiveGoodsScreen(api: f.api, openBill: (_, _) {}));
      await t.enterText(find.byKey(const ValueKey('recv-find')), 'rice');
      await t.pumpAndSettle();
      await tapKey(t, 'pick-i5');
      expect(find.text('Selling price per kg'), findsOneWidget); // loose rice: store-based
      expect(t.widget<TextField>(find.byKey(const ValueKey('line-mrp'))).controller!.text, '60');
      await tapKey(t, 'line-basis-mrp');
      expect(find.text('MRP'), findsWidgets);
      await t.enterText(find.byKey(const ValueKey('line-mrp')), '64');
      await tapKey(t, 'line-basis-store');
      expect(t.widget<TextField>(find.byKey(const ValueKey('line-mrp'))).controller!.text, '60'); // back to its own price
      await t.enterText(find.byKey(const ValueKey('line-qty')), '10');
      await tapKey(t, 'line-add');
      expect(find.text('Sell price'), findsOneWidget); // the line says what the price box is
      await tapKey(t, 'recv-supplier');
      await tapKey(t, 'supplier-s2');
      await confirm(t);
      expect(f.body('pur_receive_post')['lines'].single['price_basis'], 'store');
    });

    testWidgets('the search says when it cannot load, and tries again', (t) async {
      var fail = true;
      final api = PurchasingApi(baseUrl: 'http://t.test', accessToken: () => 't', client: MockClient((r) async {
        if (fnOf(r) == 'pur_item_find' && fail) return http.Response('{"error":"down"}', 503);
        return ok(fnOf(r) == 'pur_item_find' ? {'items': [{'id': 'i7', 'name': 'Amul Butter 500g'}]} : {'categories': []});
      }));
      await show(t, Scaffold(body: PurchaseItemSearch(api: api, onPick: (_) {})));
      await t.enterText(find.byKey(const ValueKey('recv-find')), 'amul');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('pick-error')), findsOneWidget);
      expect(find.byKey(const ValueKey('pick-create')), findsNothing); // no "new item" while we do not know what exists
      fail = false;
      await tapKey(t, 'pick-retry');
      expect(find.byKey(const ValueKey('pick-i7')), findsOneWidget);
    });

    testWidgets('a confirm the server had already saved: no second stock entry, and the summary says so', (t) async {
      final f = Fake()..replayed = true;
      await show(t, ReceiveGoodsScreen(api: f.api, po: _po, openBill: (_, _) {}));
      await t.enterText(find.byKey(const ValueKey('recv-mrp-1')), '28');
      await confirm(t);
      expect(find.text('Already saved'), findsOneWidget);
      expect(find.text('This purchase was saved before. The stock was not added again.'), findsOneWidget);
    });

    testWidgets('Add purchase (no order): asks who it came from, then sends the supplier', (t) async {
      final f = Fake();
      await show(t, ReceiveGoodsScreen(api: f.api, openBill: (_, _) {}));
      expect(find.text('Add purchase'), findsOneWidget);
      await addItem(t, 'amul', 'i7');
      await tapKey(t, 'recv-mark-received');
      expect(toast('Enter who the goods came from.'), findsOneWidget);
      // a new name typed in the supplier list
      await tapKey(t, 'recv-supplier');
      await t.enterText(find.byKey(const ValueKey('supplier-search')), 'Metro');
      await t.pumpAndSettle();
      await tapKey(t, 'supplier-use-typed');
      await confirm(t);
      expect(f.body('pur_receive_post'), containsPair('supplier_name', 'Metro'));
      expect(f.body('pur_receive_post').containsKey('po_id'), isFalse);
    });

    testWidgets('the GST invoice: invoice number, date and GSTIN; HSN, MRP, qty, rate, discount and GST per line; gross, taxable, GST and net payable', (t) async {
      final f = Fake();
      String? opened;
      await show(t, ReceiveGoodsScreen(api: f.api, openBill: (_, id) => opened = id));
      await tapKey(t, 'recv-supplier');
      await tapKey(t, 'supplier-s2');
      expect(t.widget<TextField>(find.byKey(const ValueKey('recv-supplier'))).controller!.text, 'Fresh Farms Dairy');
      await t.enterText(find.byKey(const ValueKey('recv-invoice')), 'INV-77');
      // 10 × ₹260 = ₹2,600 gross; 5% off = ₹2,470 taxable; 12% GST = ₹296.40; net ₹2,766
      await addItem(t, 'amul', 'i7', qty: '10', disc: '5');
      await t.enterText(find.byKey(const ValueKey('recv-hsn-0')), '0405');
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const ValueKey('recv-gst-0')));
      await t.tap(find.byKey(const ValueKey('recv-gst-0')));
      await t.pumpAndSettle();
      await t.tap(find.text('12%').last);
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const ValueKey('recv-gross'))).data, '₹2,600');
      expect(t.widget<Text>(find.byKey(const ValueKey('recv-discount'))).data, '− ₹130');
      expect(t.widget<Text>(find.byKey(const ValueKey('recv-taxable'))).data, '₹2,470');
      expect(t.widget<Text>(find.byKey(const ValueKey('recv-gst'))).data, '₹296.40');
      expect(t.widget<Text>(find.byKey(const ValueKey('recv-net'))).data, '₹2,766');
      expect(find.textContaining('CGST ₹148.20 + SGST ₹148.20'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('recv-total'))).data, '₹2,766');
      // a GSTIN that is not 15 letters and numbers is caught before anything is sent
      await t.enterText(find.byKey(const ValueKey('recv-gstin')), '27ABC');
      await tapKey(t, 'recv-mark-received');
      expect(f.calls('pur_receive_post'), isEmpty);
      await t.enterText(find.byKey(const ValueKey('recv-gstin')), '27aapfu0939f1zv');
      await tapKey(t, 'recv-mark-received');
      expect(t.widget<Text>(find.byKey(const ValueKey('review-net'))).data, '₹2,766'); // the review shows the same money
      expect(find.textContaining('Invoice INV-77'), findsOneWidget);
      await tapKey(t, 'recv-confirm');
      expect(f.body('pur_receive_post')['invoice_no'], 'INV-77');
      expect(f.body('pur_receive_post')['lines'], [
        {'inventory_item_id': 'i7', 'qty': 10, 'mrp': 290, 'cost': 260, 'ordered_qty': null, 'hsn': '0405', 'gst_pct': 12, 'discount_pct': 5, 'price_basis': 'mrp'},
      ]);
      // with an invoice number the bill is saved in the same go
      final b = f.body('pur_bill_save');
      expect(b['receipt_document_id'], 'rcv1');
      expect(b['invoice_no'], 'INV-77');
      expect(b['supplier_gstin'], '27AAPFU0939F1ZV');
      expect(b['invoice_date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      expect(b['lines'], [
        {'inventory_item_id': 'i7', 'name': 'Amul Butter 500g', 'hsn': '0405', 'qty': 10, 'mrp': 290, 'rate': 260, 'discount_pct': 5, 'gst_pct': 12},
      ]);
      expect(find.text('Supplier bill saved with this purchase.'), findsOneWidget);
      await tapKey(t, 'done-bill');
      expect(opened, 'rcv1');
    });
  });

  group('An old receipt note', () {
    testWidgets('finishes in the one Received step: its supplier and items fill in, and confirming sets the old note aside', (t) async {
      final f = Fake();
      String? opened;
      await show(t, ReceiveGoodsScreen(api: f.api, replaces: Facts({'id': 'r5', 'doc_no': 'RCV-010', 'supplier_name': 'Metro', 'po_ref': 'SPO-0007'}), openBill: (_, id) => opened = id));
      expect(f.body('pur_bill_get')['receipt_document_id'], 'r5');
      expect(find.text('Finish RCV-010'), findsOneWidget); // not "Add purchase"
      expect(find.text('Add purchase'), findsNothing);
      expect(find.byKey(const ValueKey('recv-old-note')), findsOneWidget);
      expect(t.widget<TextField>(find.byKey(const ValueKey('recv-supplier'))).controller!.text, 'Metro');
      expect(find.text('Aashirvaad Atta 5kg'), findsOneWidget);
      expect(t.widget<TextField>(find.byKey(const ValueKey('recv-qty-0'))).controller!.text, '18');
      await t.enterText(find.byKey(const ValueKey('recv-mrp-0')), '310');
      await confirm(t);
      expect(f.body('pur_receive_post')['replaces_receipt_id'], 'r5');
      expect(f.body('pur_receive_post')['supplier_name'], 'Metro');
      await tapKey(t, 'done-bill');
      expect(opened, 'rcv1');
    });
  });

  group('Choose supplier', () {
    testWidgets('the saved suppliers list, searchable; picking one fills the name and its GSTIN', (t) async {
      final f = Fake();
      await show(t, ReceiveGoodsScreen(api: f.api, openBill: (_, _) {}));
      await tapKey(t, 'recv-supplier');
      expect(f.calls('pur_supplier_list'), hasLength(1));
      expect(find.text('Metro Cash & Carry'), findsOneWidget);
      expect(find.text('Fresh Farms Dairy'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('supplier-search')), 'pune');
      await t.pumpAndSettle();
      expect(find.text('Fresh Farms Dairy'), findsNothing);
      await tapKey(t, 'supplier-s1');
      expect(t.widget<TextField>(find.byKey(const ValueKey('recv-supplier'))).controller!.text, 'Metro Cash & Carry');
      expect(t.widget<TextField>(find.byKey(const ValueKey('recv-gstin'))).controller!.text, '27AABCM1234F1Z5');
      expect(find.text('9822001100'), findsOneWidget);
    });

    testWidgets('pick from phone contacts: a known number is that supplier, a new one is saved as a supplier', (t) async {
      final f = Fake();
      var contact = (name: 'Metro Office', phone: '+91 98220 01100');
      pickPhoneContact = () async => contact;
      addTearDown(() => pickPhoneContact = () async => null);
      await show(t, ReceiveGoodsScreen(api: f.api, openBill: (_, _) {}));
      await tapKey(t, 'recv-supplier');
      await tapKey(t, 'supplier-from-phone');
      expect(t.widget<TextField>(find.byKey(const ValueKey('recv-supplier'))).controller!.text, 'Metro Cash & Carry');
      expect(f.calls('pur_supplier_save'), isEmpty);
      contact = (name: 'Ravi Traders', phone: '+91 99887 76655');
      await tapKey(t, 'recv-supplier');
      await tapKey(t, 'supplier-from-phone');
      expect(f.body('pur_supplier_save'), allOf(containsPair('name', 'Ravi Traders'), containsPair('phone', '9988776655')));
      expect(t.widget<TextField>(find.byKey(const ValueKey('recv-supplier'))).controller!.text, 'Ravi Traders');
    });
  });

  group('Purchase bill', () {
    testWidgets('the lines from the delivery; totals with discount and GST; paying now records the money out in Money; a credit note is saved', (t) async {
      final f = Fake();
      final money = <http.Request>[];
      final m = StoreMoneyApi(baseUrl: 'http://t.test', accessToken: () => 't', client: MockClient((r) async {
        money.add(r);
        return ok({'id': 'e1', 'no': 'TXN-0001', 'replayed': false});
      }));
      await show(t, PurchaseBillScreen(api: f.api, receiptId: 'rcv1', justReceived: true, money: m));
      expect(t.widget<Text>(find.byKey(const ValueKey('bill-paid-so-far'))).data, 'Nothing paid yet.');
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
      await tapKey(t, 'credit-add');
      await t.enterText(find.byKey(const ValueKey('credit-name-0')), 'Atta');
      await t.enterText(find.byKey(const ValueKey('credit-amount-0')), '531');
      await t.pumpAndSettle();
      await tapKey(t, 'bill-pay-now'); // what is left after the credit note
      await tapKey(t, 'bill-pay-method-upi');
      await tapKey(t, 'bill-save');
      final b = f.body('pur_bill_save');
      expect(b['invoice_no'], 'INV-77');
      expect(b['payment_status'], 'unpaid'); // the bill's paid amount comes from Money's payment, never typed here
      // the payment: money out of UPI in Money, against this bill, for what was left (₹4,918 less the ₹531 credit note)
      expect(money.single.url.path, endsWith('/smoney_record'));
      expect(jsonDecode(money.single.body), {'kind': 'supplier_payment', 'method': 'upi', 'amount_minor': 438700, 'bill_receipt_id': 'rcv1', 'party': 'Metro', 'reference': 'INV-77'});
      expect(money.single.headers['Idempotency-Key'], startsWith('sm-'));
      expect(toast('Purchase bill saved and the payment is in Money.'), findsOneWidget);
      expect(b['lines'], [{'inventory_item_id': 'i1', 'name': 'Aashirvaad Atta 5kg', 'hsn': '', 'mrp': null, 'qty': 18, 'rate': 265.5, 'discount_pct': 2, 'gst_pct': 5}]);
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
