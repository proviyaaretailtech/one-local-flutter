import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/catalogue/catalogue_api.dart';
import 'package:vinii_pos/catalogue/quick_add_screen.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/purchasing/add_supplier_sheet.dart';
import 'package:vinii_pos/purchasing/purchasing_api.dart';
import 'package:vinii_pos/inventory/inventory_widgets.dart' show kRedText;
import 'package:vinii_pos/ui/theme.dart';

import 'catalogue_fixtures.dart';
import 'helpers.dart' show toast;

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail) => http.Response(jsonEncode({'detail': detail}), status, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;
Map<String, dynamic> body(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

class Fake {
  Fake({this.stockRefusal});
  final String? stockRefusal;
  final requests = <http.Request>[];
  var suppliers = <Map<String, dynamic>>[
    {'id': 'sup_1', 'name': 'Metro Cash & Carry', 'phone': '9822001100', 'city': 'Pune'},
  ];
  late final client = MockClient((r) async {
    requests.add(r);
    final b = r.body.isEmpty ? <String, dynamic>{} : body(r);
    return switch (fnOf(r)) {
      'cat_item_save' => ok({...item('n1', b['name'] as String, b['sku'] as String, b['price_minor'] as int), 'inventory_item_id': 'inv-1'}),
      'inv_opening_stock' => stockRefusal != null ? err(403, stockRefusal!) : ok({'id': 'd1', 'doc_no': 'ADJ-9', 'status': 'posted', 'lines': []}),
      'pur_supplier_list' => ok({'suppliers': suppliers}),
      'pur_supplier_save' => () {
          final s = {'id': 'sup_2', 'name': b['name'], 'phone': b['phone'] ?? '', 'city': b['city'] ?? ''};
          suppliers = [...suppliers, s];
          return ok(s);
        }(),
      'pur_item_supplier_set' => ok({'inventory_item_id': b['inventory_item_id'], 'supplier_id': b['supplier_id']}),
      _ => err(404, 'not found'),
    };
  });
  late final cat = CatalogueApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client);
  late final inv = InventoryApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client);
  late final pur = PurchasingApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client);
  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
}

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

/// A 390-point phone with the real fonts, so an overflow here is a real one.
Future<void> open(WidgetTester t, Fake f) async {
  t.view.physicalSize = const Size(780, 3600);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: posTheme(),
    home: Builder(
      builder: (c) => Scaffold(
        body: TextButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => QuickAddScreen(api: f.cat, inventory: f.inv, purchasing: f.pur))), child: const Text('go')),
      ),
    ),
  ));
  await t.tap(find.text('go'));
  await t.pumpAndSettle();
}

Future<void> type(WidgetTester t, String key, String text) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.enterText(find.byKey(ValueKey(key)), text);
  await t.pump();
}

Future<void> tap(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });

  test('the System Code is made from the name: its first letters and numbers, then three digits', () {
    expect(systemCodeFor('Aashirvaad Atta 5kg', Random(1)), matches(RegExp(r'^AASHIR-\d{3}$')));
    expect(systemCodeFor('Tea', Random(1)), matches(RegExp(r'^TEA-\d{3}$')));
    expect(systemCodeFor('₹ ! ?', Random(1)), matches(RegExp(r'^ITEM-\d{3}$')));
  });

  testWidgets('everything on one screen, and it fits a phone: photo, name, barcode, cost · MRP · price, margin, supplier, unit, stock', (t) async {
    final f = Fake();
    await open(t, f);
    for (final k in ['quick-photo-add', 'quick-name', 'quick-barcode', 'quick-scan', 'quick-cost', 'quick-mrp', 'quick-price', 'quick-margin', 'quick-supplier', 'quick-supplier-add', 'quick-unit-kg', 'quick-qty', 'quick-save']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(t.takeException(), isNull);
  });

  testWidgets('the price is coloured like Item → Stock, and a margin under 5% is red', (t) async {
    final f = Fake();
    await open(t, f);
    await type(t, 'quick-mrp', '50');
    await type(t, 'quick-price', '50');
    expect(find.text('Same as MRP'), findsOneWidget);
    await type(t, 'quick-price', '45');
    expect(find.text('Below MRP'), findsOneWidget);
    await type(t, 'quick-price', '55');
    expect(find.text('Above MRP — not allowed'), findsOneWidget);
    await type(t, 'quick-price', '40');
    await type(t, 'quick-cost', '39');
    expect(find.text('Margin ₹1 · 2.5%'), findsOneWidget);
    final chip = t.widget<Text>(find.descendant(of: find.byKey(const ValueKey('quick-margin')), matching: find.byType(Text)));
    expect(chip.style?.color, kRedText);
    await type(t, 'quick-cost', '30');
    expect(find.text('Margin ₹10 · 25.0%'), findsOneWidget);
  });

  testWidgets('a price above the MRP is stopped on the phone', (t) async {
    final f = Fake();
    await open(t, f);
    await type(t, 'quick-name', 'Biscuit');
    await type(t, 'quick-mrp', '10');
    await type(t, 'quick-price', '12');
    await tap(t, 'quick-save');
    expect(find.text('The price cannot be above the MRP.'), findsOneWidget);
    expect(f.calls('cat_item_save'), isEmpty);
  });

  testWidgets('one save adds the product with its prices, unit and barcode, then its opening stock and its usual supplier', (t) async {
    final f = Fake();
    await open(t, f);
    await type(t, 'quick-name', 'Parle-G 100g');
    await type(t, 'quick-barcode', '8901719110016');
    await type(t, 'quick-cost', '8');
    await type(t, 'quick-mrp', '10');
    await type(t, 'quick-price', '10');
    await tap(t, 'quick-unit-pack');
    await type(t, 'quick-qty', '24');
    await tap(t, 'quick-supplier');
    await t.tap(find.text('Metro Cash & Carry').last);
    await t.pumpAndSettle();
    await tap(t, 'quick-save');
    final save = body(f.calls('cat_item_save').single);
    expect(save, allOf(
      containsPair('mode', 'quick'), containsPair('name', 'Parle-G 100g'), containsPair('barcode', '8901719110016'),
      containsPair('cost_minor', 800), containsPair('mrp_minor', 1000), containsPair('price_minor', 1000), containsPair('selling_unit', 'pack'),
    ));
    expect(save['sku'], startsWith('PARLEG-'));
    expect(body(f.calls('inv_opening_stock').single), {'inventory_item_id': 'inv-1', 'qty': 24});
    expect(body(f.calls('pur_item_supplier_set').single), {'inventory_item_id': 'inv-1', 'supplier_id': 'sup_1', 'price_minor': 800});
    expect(find.byType(QuickAddScreen), findsNothing);
  });

  testWidgets('no stock and no supplier: only the product is saved', (t) async {
    final f = Fake();
    await open(t, f);
    await type(t, 'quick-name', 'Tea');
    await type(t, 'quick-price', '5');
    await tap(t, 'quick-save');
    expect(f.calls('cat_item_save'), hasLength(1));
    expect(f.calls('inv_opening_stock'), isEmpty);
    expect(f.calls('pur_item_supplier_set'), isEmpty);
  });

  testWidgets('when the stock cannot be set (a cashier), the product is still added and the message says why', (t) async {
    final f = Fake(stockRefusal: 'Only the owner or a manager can set opening stock; ask them, or change it in Item → Stock.');
    await open(t, f);
    await type(t, 'quick-name', 'Tea');
    await type(t, 'quick-price', '5');
    await type(t, 'quick-qty', '10');
    await tap(t, 'quick-save');
    expect(toast('Tea added, but Only the owner or a manager can set opening stock; ask them, or change it in Item → Stock..'), findsOneWidget);
    expect(find.byType(QuickAddScreen), findsNothing);
  });

  testWidgets('+ supplier: the phone contacts open at once; the contact picked is added and chosen, nothing typed', (t) async {
    final before = pickPhoneContact;
    pickPhoneContact = () async => (name: 'Ramesh Wholesale', phone: '+91 98765 43210');
    addTearDown(() => pickPhoneContact = before);
    final f = Fake();
    await open(t, f);
    await tap(t, 'quick-supplier-add');
    expect(find.byKey(const ValueKey('supplier-name')), findsNothing); // no form
    expect(body(f.calls('pur_supplier_save').single), allOf(containsPair('name', 'Ramesh Wholesale'), containsPair('phone', '9876543210'))); // last 10 digits
    expect(toast('Ramesh Wholesale added as a supplier.'), findsOneWidget);
    await t.pump(const Duration(seconds: 5)); // the message goes away
    await t.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('quick-supplier')), matching: find.textContaining('Ramesh Wholesale')), findsOneWidget); // now the chosen supplier
    await type(t, 'quick-name', 'Sugar');
    await type(t, 'quick-price', '45');
    await tap(t, 'quick-save');
    expect(body(f.calls('pur_item_supplier_set').single)['supplier_id'], 'sup_2');
  });

  testWidgets('closing the contact list adds nothing', (t) async {
    final before = pickPhoneContact;
    pickPhoneContact = () async => null;
    addTearDown(() => pickPhoneContact = before);
    final f = Fake();
    await open(t, f);
    await tap(t, 'quick-supplier-add');
    expect(f.calls('pur_supplier_save'), isEmpty);
    expect(find.byKey(const ValueKey('supplier-name')), findsNothing);
  });

  testWidgets('where contacts cannot open, the short typed form shows instead', (t) async {
    final before = pickPhoneContact;
    pickPhoneContact = () async => throw MissingPluginException('no contacts here');
    addTearDown(() => pickPhoneContact = before);
    final f = Fake();
    await open(t, f);
    await tap(t, 'quick-supplier-add');
    expect(find.byKey(const ValueKey('supplier-name')), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('supplier-name')), 'Typed Traders');
    await tap(t, 'supplier-save');
    expect(body(f.calls('pur_supplier_save').single)['name'], 'Typed Traders');
  });
}
