import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/barcodes/barcodes_api.dart';
import 'package:vinii_pos/catalogue/catalogue_api.dart';
import 'package:vinii_pos/catalogue/quick_add_screen.dart';
import 'package:vinii_pos/catalogue/sku_api.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/purchasing/add_supplier_sheet.dart';
import 'package:vinii_pos/purchasing/purchasing_api.dart';
import 'package:vinii_pos/inventory/inventory_widgets.dart' show kRedText;
import 'package:vinii_pos/stock/labels_screens.dart' show printLabelPdf;
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
  var variants = <Map<String, dynamic>>[];
  var suppliers = <Map<String, dynamic>>[
    {'id': 'sup_1', 'name': 'Metro Cash & Carry', 'phone': '9822001100', 'city': 'Pune'},
  ];
  late final client = MockClient((r) async {
    requests.add(r);
    final b = r.body.isEmpty ? <String, dynamic>{} : body(r);
    return switch (fnOf(r)) {
      // the database makes the SKU from its parts
      'cat_item_save' => ok({...item('n1', b['name'] as String, 'OL-${b['sku_parts']?['sub']}-${b['sku_parts']?['slot3']}-${b['sku_parts']?['size']}-01', b['price_minor'] as int), 'inventory_item_id': 'inv-1'}),
      'sku_options' => ok({
          'subcategories': [
            {'code': 'OIL', 'name': 'Edible Oils & Ghee', 'category': 'Groceries', 'examples': 'Sunflower, ghee'},
            {'code': 'VEG', 'name': 'Vegetables', 'category': 'Groceries', 'examples': 'Tomato, onion'},
          ],
          'units': [for (final u in ['G', 'KG', 'ML', 'L', 'PC', 'PK']) {'code': u}],
          'brands': [
            {'code': 'FRT', 'name': 'Fortune', 'kind': 'brand', 'status': 'approved'},
            {'code': 'TOM', 'name': 'Tomato', 'kind': 'loose_item', 'status': 'approved'},
            {'code': 'LSE', 'name': 'Loose / Unbranded', 'kind': 'reserved', 'status': 'approved'},
          ],
          'store_initials': 'SGS', 'lot': '3110',
        }),
      'sku_variants' => ok({'variants': variants}),
      'sku_lookup' => ok(b['barcode'] == '8906007280012'
          ? {'found': true, 'sku': 'OL-OIL-FRT-1L-01', 'name': 'FORTUNE SUNFLOWER OIL 1L', 'sub': 'OIL', 'slot3': 'FRT', 'size': '1L', 'status': 'approved'}
          : {'found': false}),
      'sku_brand_propose' => ok({'code': 'KSN', 'name': b['name'], 'kind': b['kind'], 'status': 'pending'}),
      'inv_opening_stock' => stockRefusal != null ? err(403, stockRefusal!) : ok({'id': 'd1', 'doc_no': 'ADJ-9', 'status': 'posted', 'lines': []}),
      'pur_supplier_list' => ok({'suppliers': suppliers}),
      'pur_supplier_save' => () {
          final s = {'id': 'sup_2', 'name': b['name'], 'phone': b['phone'] ?? '', 'city': b['city'] ?? ''};
          suppliers = [...suppliers, s];
          return ok(s);
        }(),
      'bc_make' => ok({'menu_item_id': b['menu_item_id'], 'name': 'Homemade Papad', 'sku': 'PAPAD-1', 'price': 50, 'barcode': '2000000000190', 'barcode_source': 'generated'}),
      'cat_store_categories' => ok({'categories': ['Grocery', 'Fashion'], 'subcategories': ['Kirana / general store', "Men's wear"]}),
      'pur_item_supplier_set' => ok({'inventory_item_id': b['inventory_item_id'], 'supplier_id': b['supplier_id']}),
      _ => err(404, 'not found'),
    };
  });
  late final cat = CatalogueApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client);
  late final inv = InventoryApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client);
  late final pur = PurchasingApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client);
  late final bc = BarcodesApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client);
  late final sku = SkuApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client);
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
        body: TextButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => QuickAddScreen(api: f.cat, inventory: f.inv, purchasing: f.pur, barcodes: f.bc, skus: f.sku))), child: const Text('go')),
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

/// The unit (or size) from the list that fits the category.
Future<void> pickUnit(WidgetTester t, String label) async {
  await tap(t, 'quick-unit');
  await t.tap(find.text(label).last);
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

/// The SKU's parts: subcategory, brand / item code (LSE fits both price types), unit.
Future<void> pickSku(WidgetTester t, {String sub = 'OIL', String brand = 'LSE', String qty = '', String unit = 'KG'}) async {
  await tap(t, 'sku-sub');
  await tap(t, 'sku-sub-$sub');
  await tap(t, 'sku-brand');
  await tap(t, 'sku-brand-$brand');
  if (qty.isNotEmpty) {
    await t.ensureVisible(find.byKey(const ValueKey('sku-qty')));
    await t.enterText(find.byKey(const ValueKey('sku-qty')), qty);
    await t.pump();
  }
  await tap(t, 'sku-unit-$unit');
}

/// Pick the SKU, then save.
Future<void> pickAndSave(WidgetTester t) async {
  await pickSku(t);
  await tap(t, 'quick-save');
}

void main() {
  setUpAll(() async {
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });

  testWidgets('everything on one screen, and it fits a phone: photo, name, barcode, cost · MRP · price, margin, supplier, unit, stock', (t) async {
    final f = Fake();
    await open(t, f);
    for (final k in ['quick-photo-add', 'quick-name', 'quick-barcode', 'quick-scan', 'quick-cost', 'quick-mrp', 'quick-price', 'quick-margin', 'quick-supplier', 'quick-supplier-add', 'quick-category', 'quick-unit', 'quick-qty', 'quick-save']) {
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
    await type(t, 'quick-name', 'parle-g');
    await type(t, 'quick-barcode', '8901719110016');
    await type(t, 'quick-cost', '8');
    await type(t, 'quick-mrp', '10');
    await type(t, 'quick-price', '10');
    await pickUnit(t, 'Pack');
    await type(t, 'quick-qty', '24');
    await tap(t, 'quick-supplier');
    await t.tap(find.text('Metro Cash & Carry').last);
    await t.pumpAndSettle();
    await pickAndSave(t);
    final save = body(f.calls('cat_item_save').single);
    expect(save, allOf(
      containsPair('mode', 'quick'), containsPair('name', 'Parle-G'), containsPair('barcode', '8901719110016'),
      containsPair('cost_minor', 800), containsPair('mrp_minor', 1000), containsPair('price_minor', 1000), containsPair('selling_unit', 'pack'),
    ));
    expect(save['sku_parts'], {'sub': 'OIL', 'slot3': 'LSE', 'size': 'KG'}); // the SKU's parts, never the name
    expect(save.containsKey('sku'), isFalse);
    expect(body(f.calls('inv_opening_stock').single), {'inventory_item_id': 'inv-1', 'qty': 24});
    expect(body(f.calls('pur_item_supplier_set').single), {'inventory_item_id': 'inv-1', 'supplier_id': 'sup_1', 'price_minor': 800});
    expect(find.byType(QuickAddScreen), findsNothing);
  });

  testWidgets('no barcode on the product: Make a store barcode, made and printed when it is saved', (t) async {
    final f = Fake();
    final printed = <String>[];
    final real = printLabelPdf;
    printLabelPdf = (pdf, name) async => printed.add(name);
    addTearDown(() => printLabelPdf = real);
    await open(t, f);
    await type(t, 'quick-name', 'Homemade Papad');
    await type(t, 'quick-price', '50');
    await tap(t, 'quick-make-code');
    expect(find.byKey(const ValueKey('quick-store-code')), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-barcode')), findsNothing);
    await pickAndSave(t);
    expect(body(f.calls('cat_item_save').single).containsKey('barcode'), isFalse);
    expect(body(f.calls('bc_make').single), {'menu_item_id': 'n1'});
    expect(printed, ['Barcode labels']);
    expect(find.byType(QuickAddScreen), findsNothing);
  });

  testWidgets('a typed barcode hides Make a store barcode; undo brings the box back', (t) async {
    final f = Fake();
    await open(t, f);
    expect(find.byKey(const ValueKey('quick-make-code')), findsOneWidget);
    await type(t, 'quick-barcode', '8901719110016');
    expect(find.byKey(const ValueKey('quick-make-code')), findsNothing);
    await type(t, 'quick-barcode', '');
    await tap(t, 'quick-make-code');
    expect(t.widget<Text>(find.byKey(const ValueKey('quick-labels-value'))).data, '1'); // one label unless changed
    await tap(t, 'quick-labels-more');
    await tap(t, 'quick-labels-more');
    expect(t.widget<Text>(find.byKey(const ValueKey('quick-labels-value'))).data, '3');
    for (var i = 0; i < 3; i++) {
      await tap(t, 'quick-labels-less');
    }
    expect(t.widget<Text>(find.byKey(const ValueKey('quick-labels-value'))).data, '0'); // no label this time
    expect(find.text('No label: print it later from Barcodes.'), findsOneWidget);
    await tap(t, 'quick-make-code-undo');
    expect(find.byKey(const ValueKey('quick-barcode')), findsOneWidget);
  });

  testWidgets('MRP-based: the price starts at the MRP (and may be lowered); the type is saved', (t) async {
    final f = Fake();
    await open(t, f);
    expect(find.byKey(const ValueKey('quick-basis-mrp')), findsOneWidget);
    await type(t, 'quick-name', 'Tata Salt 1kg');
    await type(t, 'quick-mrp', '28');
    expect(t.widget<TextField>(find.byKey(const ValueKey('quick-price'))).controller!.text, '28');
    await type(t, 'quick-price', '26');
    await type(t, 'quick-mrp', '30'); // a typed price stays
    expect(t.widget<TextField>(find.byKey(const ValueKey('quick-price'))).controller!.text, '26');
    await pickAndSave(t);
    expect(body(f.calls('cat_item_save').single), allOf(containsPair('price_basis', 'mrp'), containsPair('mrp_minor', 3000), containsPair('price_minor', 2600)));
  });

  testWidgets('store-based: no MRP box; cost + markup % sets the price, a typed price shows its markup; kg suggests it', (t) async {
    final f = Fake();
    await open(t, f);
    await pickUnit(t, 'Kilogram (kg)');
    expect(find.byKey(const ValueKey('quick-mrp')), findsNothing); // kg: store-based
    expect(find.byKey(const ValueKey('quick-markup')), findsOneWidget);
    await type(t, 'quick-name', 'Loose Jaggery');
    await type(t, 'quick-cost', '40');
    await type(t, 'quick-markup', '25');
    expect(t.widget<TextField>(find.byKey(const ValueKey('quick-price'))).controller!.text, '50');
    await type(t, 'quick-price', '60');
    expect(t.widget<TextField>(find.byKey(const ValueKey('quick-markup'))).controller!.text, '50');
    expect(find.text('Margin ₹20 · 33.3%'), findsOneWidget);
    await pickAndSave(t);
    final b = body(f.calls('cat_item_save').single);
    expect(b, allOf(containsPair('price_basis', 'store'), containsPair('price_minor', 6000), containsPair('selling_unit', 'kg')));
    expect(b.containsKey('mrp_minor'), isFalse); // the database keeps the price as the MRP
  });

  testWidgets('the type can be picked by hand, and then the unit no longer changes it', (t) async {
    final f = Fake();
    await open(t, f);
    await tap(t, 'quick-basis-store');
    await pickUnit(t, 'Pack');
    expect(find.byKey(const ValueKey('quick-markup')), findsOneWidget);
  });

  testWidgets('category from a list (the store\'s own first); the units follow it: clothes in sizes, groceries in kg', (t) async {
    final f = Fake();
    await open(t, f);
    await tap(t, 'quick-category');
    expect(find.text('Your store'), findsNWidgets(2)); // Grocery and Fashion, the store's own, come first
    expect(find.text('Electronics'), findsOneWidget); // then the rest
    await t.tap(find.text('Fashion').last);
    await t.pumpAndSettle();
    expect(find.text('Size or unit'), findsOneWidget);
    await tap(t, 'quick-unit');
    for (final s in ['Size S', 'Size M', 'Size XL']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    expect(find.text('Kilogram (kg)'), findsNothing); // no grocery units for clothes
    await t.tap(find.text('Size M'));
    await t.pumpAndSettle();
    expect(find.textContaining('Size M · pc'), findsOneWidget);
    await type(t, 'quick-name', 'Cotton Shirt');
    await type(t, 'quick-mrp', '599');
    await pickAndSave(t);
    expect(body(f.calls('cat_item_save').single), allOf(
      containsPair('category', 'Fashion'), containsPair('selling_unit', 'pc'), containsPair('unit_description', 'Size M'),
    ));
  });

  testWidgets('groceries: the units fit (no sizes); a size picked for clothes goes when the category changes', (t) async {
    final f = Fake();
    await open(t, f);
    await tap(t, 'quick-category');
    await t.tap(find.text('Fashion').last);
    await t.pumpAndSettle();
    await pickUnit(t, 'Size XL');
    await tap(t, 'quick-category');
    await t.tap(find.text('Grocery').last);
    await t.pumpAndSettle();
    expect(find.textContaining('Size XL · pc'), findsNothing);
    expect(find.textContaining('Kilogram (kg)'), findsOneWidget); // Grocery is counted in kg first
    await tap(t, 'quick-unit');
    expect(find.text('Size M'), findsNothing);
    expect(find.text('Litre (l)'), findsOneWidget);
  });

  testWidgets('a custom unit: typed once, used for this product', (t) async {
    final f = Fake();
    await open(t, f);
    await tap(t, 'quick-unit');
    await t.tap(find.text('+ Add a custom unit'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, 'Roll');
    await t.tap(find.text('Use'));
    await t.pumpAndSettle();
    expect(find.textContaining('roll'), findsWidgets); // the unit box and the stock line
    await type(t, 'quick-name', 'Cling Film');
    await type(t, 'quick-price', '80');
    await pickAndSave(t);
    expect(body(f.calls('cat_item_save').single), containsPair('selling_unit', 'roll'));
  });

  testWidgets('a new category the store types', (t) async {
    final f = Fake();
    await open(t, f);
    await tap(t, 'quick-category');
    await t.tap(find.text('+ New category'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, 'Biscuits');
    await t.tap(find.text('Use'));
    await t.pumpAndSettle();
    expect(find.textContaining('Biscuits'), findsOneWidget);
    expect(find.text('Unit'), findsOneWidget); // not on the list: every common unit
  });

  testWidgets('the SKU: subcategory, brand and size make it, never the name; nothing to type; a new brand is proposed for review', (t) async {
    final f = Fake();
    await open(t, f);
    expect(find.byKey(const ValueKey('quick-sku-change')), findsNothing); // no System Code made from the name
    await type(t, 'quick-name', 'fortune oil');
    expect(t.widget<Text>(find.byKey(const ValueKey('sku-preview'))).data, 'OL-···-···-···-##');
    await tap(t, 'sku-sub');
    await tap(t, 'sku-sub-OIL');
    await tap(t, 'sku-brand');
    expect(find.byKey(const ValueKey('sku-brand-TOM')), findsNothing); // MRP-based: brands, not loose items
    await t.enterText(find.byKey(const ValueKey('sku-search')), 'Kissan');
    await t.pumpAndSettle();
    await tap(t, 'sku-brand-new');
    expect(body(f.calls('sku_brand_propose').single), {'name': 'Kissan', 'kind': 'brand'});
    await t.ensureVisible(find.byKey(const ValueKey('sku-qty')));
    await t.enterText(find.byKey(const ValueKey('sku-qty')), '500');
    await t.pump();
    await tap(t, 'sku-unit-G');
    expect(t.widget<Text>(find.byKey(const ValueKey('sku-preview'))).data, 'OL-OIL-KSN-500G-##');
    await type(t, 'quick-price', '50');
    await tap(t, 'quick-save');
    expect(body(f.calls('cat_item_save').single)['sku_parts'], {'sub': 'OIL', 'slot3': 'KSN', 'size': '500G'});
  });

  testWidgets('no SKU parts: the product is not saved', (t) async {
    final f = Fake();
    await open(t, f);
    await type(t, 'quick-name', 'tea');
    await type(t, 'quick-price', '5');
    await tap(t, 'quick-save');
    expect(find.text('Choose the subcategory, brand and size for the SKU.'), findsOneWidget);
    expect(f.calls('cat_item_save'), isEmpty);
  });

  testWidgets('store-based: the store SKU shows its initials and lot (day and month); loose items fit', (t) async {
    final f = Fake();
    await open(t, f);
    await tap(t, 'quick-basis-store');
    await tap(t, 'sku-sub');
    await tap(t, 'sku-sub-VEG');
    await tap(t, 'sku-brand');
    expect(find.byKey(const ValueKey('sku-brand-FRT')), findsNothing); // store-based: loose items and local brands
    await tap(t, 'sku-brand-TOM');
    await tap(t, 'sku-unit-KG');
    expect(t.widget<Text>(find.byKey(const ValueKey('sku-preview'))).data, 'OL-VEG-TOM-KG-SGS-3110-##');
  });

  testWidgets('MRP-based: OneLocal already has products with these parts: say if it is one of them (the same SKU) or a new variant', (t) async {
    final f = Fake()..variants = [{'sku': 'OL-OIL-FRT-1L-01', 'name': 'Fortune Sunflower Oil 1l', 'status': 'approved', 'barcode': '8906007280012'}];
    await open(t, f);
    await type(t, 'quick-name', 'fortune');
    await type(t, 'quick-price', '150');
    await pickSku(t, brand: 'FRT', qty: '1', unit: 'L');
    await tap(t, 'quick-save');
    expect(f.calls('cat_item_save'), isEmpty); // not until it is said
    await tap(t, 'sku-variant-OL-OIL-FRT-1L-01');
    expect(t.widget<Text>(find.byKey(const ValueKey('sku-preview'))).data, 'OL-OIL-FRT-1L-01');
    await tap(t, 'quick-save');
    expect(body(f.calls('cat_item_save').single)['sku_parts'], {'sub': 'OIL', 'slot3': 'FRT', 'size': '1L', 'master_sku': 'OL-OIL-FRT-1L-01'});
  });

  testWidgets('barcode first: a pack OneLocal knows brings its name, parts and SKU', (t) async {
    final f = Fake();
    await open(t, f);
    await type(t, 'quick-barcode', '8906007280012');
    await t.pumpAndSettle();
    expect(t.widget<TextField>(find.descendant(of: find.byKey(const ValueKey('quick-name')), matching: find.byType(TextField))).controller!.text, 'FORTUNE SUNFLOWER OIL 1L');
    expect(t.widget<Text>(find.byKey(const ValueKey('sku-preview'))).data, 'OL-OIL-FRT-1L-01');
    await type(t, 'quick-price', '150');
    await tap(t, 'quick-save');
    expect(body(f.calls('cat_item_save').single)['sku_parts'], {'sub': 'OIL', 'slot3': 'FRT', 'size': '1L', 'master_sku': 'OL-OIL-FRT-1L-01'});
  });

  testWidgets('no stock and no supplier: only the product is saved', (t) async {
    final f = Fake();
    await open(t, f);
    await type(t, 'quick-name', 'Tea');
    await type(t, 'quick-price', '5');
    await pickAndSave(t);
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
    await pickAndSave(t);
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
    await pickAndSave(t);
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
