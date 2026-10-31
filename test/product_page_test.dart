import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/catalogue/catalogue_api.dart';
import 'package:vinii_pos/inventory/inv_env.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/stock/product_page.dart';
import 'package:vinii_pos/stock/stock_env.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart' show toast;

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) =>
    http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

// Shapes as the local server answers them (cat_item_lookup, sf_products, inv_stock_detail, inv_movement_list).
Map<String, dynamic> catRow({String? inv = 'i1', int version = 3, bool available = true, String status = 'active'}) => {
      'id': 'm1', 'sku': 'PG250', 'name': 'Parle-G 250g', 'brand': 'Parle', 'status': status, 'barcode': '8901063010031', 'category': 'Biscuits',
      'available': available, 'image_url': null, 'mrp_minor': 2500, 'stock_qty': 12, 'cost_minor': 1800, 'price_minor': 2400, 'stock_known': true,
      'selling_unit': 'pc', 'version': version, 'inventory_item_id': ?inv,
    };

final detail = {
  'item': {'id': 'i1', 'sku': 'PG250', 'name': 'Parle-G 250g', 'unit': 'pc', 'barcode': null, 'category': 'Biscuits', 'item_type': 'sku', 'reorder_level': 5},
  'bins': [
    {'id': 'b1', 'code': 'A-01', 'name': 'Shelf A-01', 'zone': 'shelf', 'on_hand': 12},
  ],
  'lots': [], 'status': 'low', 'damaged': 1, 'reserved': 2, 'sellable': 12, 'available': 12, 'in_transit': 24, 'stock_days': 3,
  'expiry_date': null, 'daily_demand': 4, 'latest_movement': null, 'location': {'id': 'loc', 'code': 'MAIN', 'name': 'Main'},
};

final moves = {
  'movements': [
    {'id': 8, 'ref': {'type': 'order', 'label': 'P-00013'}, 'item': {'id': 'i1', 'sku': 'PG250', 'name': 'Parle-G 250g', 'unit': 'pc'}, 'kind': 'sale', 'delta': -18, 'quantity': -18, 'created_at': '2026-10-21T18:06:14Z'},
    {'id': 2, 'ref': {'type': 'receipt', 'label': 'RCV-002'}, 'item': {'id': 'i1', 'sku': 'PG250', 'name': 'Parle-G 250g', 'unit': 'pc'}, 'kind': 'receipt', 'delta': 30, 'quantity': 30, 'created_at': '2026-10-20T10:00:00Z'},
  ],
};

class Fake {
  Fake({this.lookup, this.save, this.cat});
  final http.Response? Function()? lookup, save;
  final Map<String, dynamic>? cat;
  final requests = <http.Request>[];
  final opened = <String>[];
  late final client = MockClient((r) async {
    requests.add(r);
    return switch (fnOf(r)) {
      'inv_stock_detail' => ok(detail),
      'inv_movement_list' => ok(moves),
      'cat_item_lookup' => lookup?.call() ?? ok(cat ?? catRow()),
      'sf_products' => ok({'items': [{'id': 'm1', 'visible': false}]}),
      'cat_item_save' => save?.call() ?? ok({...catRow(version: 4), 'price_minor': 2500}),
      'rst_menu_stock_set' => ok({'changed': 1}),
      'sf_product_save' => ok({'id': 'm1'}),
      _ => err(404, 'not found: ${fnOf(r)}'),
    };
  });
  late final env = StockEnv(
    inv: InvEnv(api: InventoryApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client)),
    catalogue: CatalogueApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client),
    rpc: RpcClient(baseUrl: 'http://t.test', accessToken: () => 't', client: client),
    open: (context, page, {itemId}) async => opened.add('$page:$itemId'),
  );
  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
  Map<String, dynamic> body(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;
}

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

/// A 390-point phone with the real fonts, so an overflow here is a real one.
Future<void> phone(WidgetTester t, Widget screen) async {
  t.view.physicalSize = const Size(780, 4400);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });

  testWidgets('opened with a stock item: finds its catalogue record and shows codes, switches, prices, stock and movements', (t) async {
    final f = Fake();
    await phone(t, ProductPage(env: f.env, inventoryId: 'i1'));
    expect(f.body(f.calls('cat_item_lookup').single)['code'], 'PG250');
    expect(find.text('Parle-G 250g'), findsOneWidget);
    expect(find.text('System Code: PG250 · pc'), findsOneWidget);
    expect(find.text('8901063010031'), findsOneWidget);
    expect(find.byKey(const ValueKey('product-photo')), findsOneWidget);
    expect(t.widget<Switch>(find.byKey(const ValueKey('product-store'))).value, isTrue);
    expect(t.widget<Switch>(find.byKey(const ValueKey('product-app'))).value, isFalse);
    // prices with the edit-box rules: ₹24 below MRP ₹25 is yellow; margin ₹6 on ₹24 = 25%
    expect(find.widgetWithText(TextField, '24'), findsOneWidget);
    expect(find.text('Below MRP'), findsOneWidget);
    expect(find.text('₹6 · 25.0%'), findsOneWidget);
    // stock
    for (final s in ['In stock', 'On hold', 'Incoming', 'Damaged', 'Sells per day', 'Lasts about', 'Kept at']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    expect(find.text('Shelf A-01 (12)'), findsOneWidget);
    // last movements, plain words
    expect(f.body(f.calls('inv_movement_list').single), containsPair('limit', 5));
    expect(find.text('Sold'), findsOneWidget);
    expect(find.text('−18'), findsOneWidget);
    expect(find.textContaining('SKU'), findsNothing);
  });

  testWidgets('the Store and App switches save at once', (t) async {
    final f = Fake();
    await phone(t, ProductPage(env: f.env, item: CatItem(catRow())));
    await tap(t, find.byKey(const ValueKey('product-store')));
    expect(f.body(f.calls('rst_menu_stock_set').single), {'id': 'm1', 'in_stock': false});
    expect(t.widget<Switch>(find.byKey(const ValueKey('product-store'))).value, isFalse);
    await t.pump(const Duration(seconds: 4));
    await tap(t, find.byKey(const ValueKey('product-app')));
    expect(f.body(f.calls('sf_product_save').single), {'id': 'm1', 'visible': true});
    expect(t.widget<Switch>(find.byKey(const ValueKey('product-app'))).value, isTrue);
  });

  testWidgets('prices: colours follow the price as typed; above MRP is refused; Save prices sends only what changed', (t) async {
    final f = Fake();
    await phone(t, ProductPage(env: f.env, item: CatItem(catRow())));
    await t.enterText(find.byKey(const ValueKey('product-price')), '30');
    await t.pump();
    expect(find.text('Above MRP — not allowed'), findsOneWidget);
    await tap(t, find.byKey(const ValueKey('product-save-prices')));
    expect(toast('The price is above the MRP. Lower the price or raise the MRP.'), findsOneWidget);
    expect(f.calls('cat_item_save'), isEmpty);
    await t.pump(const Duration(seconds: 4));
    await t.enterText(find.byKey(const ValueKey('product-price')), '25');
    await t.pump();
    expect(find.text('Same as MRP'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('product-cost')), '24');
    await t.pump();
    expect(find.text('₹1 · 4.0%'), findsOneWidget);
    expect(find.text('Below 5%'), findsOneWidget);
    await tap(t, find.byKey(const ValueKey('product-save-prices')));
    final b = f.body(f.calls('cat_item_save').single);
    expect(b, {'mode': 'quick', 'version': 3, 'price_basis': 'mrp', 'price_minor': 2500, 'cost_minor': 2400, 'id': 'm1'}); // the price type is recorded on its first save
    expect(toast('Prices saved.'), findsOneWidget);
  });

  testWidgets('the small buttons open each job for this stock item; See all opens its movements', (t) async {
    final f = Fake();
    await phone(t, ProductPage(env: f.env, item: CatItem(catRow())));
    for (final k in ['product-adjust', 'product-transfer', 'product-reorder', 'product-label', 'product-moves-all']) {
      await tap(t, find.byKey(ValueKey(k)));
    }
    expect(f.opened, ['adjust:i1', 'transfer:i1', 'reorder:i1', 'product_labels:i1', 'movements:i1']);
    expect(find.byKey(const ValueKey('product-edit')), findsOneWidget);
  });

  testWidgets('a stock item the shop does not sell shows its stock and says it has no price', (t) async {
    final f = Fake(lookup: () => err(404, 'No item has that code.', 'not_found'));
    await phone(t, ProductPage(env: f.env, inventoryId: 'i1'));
    expect(find.text('Not sold in the shop, so it has no price here.'), findsOneWidget);
    expect(find.byKey(const ValueKey('product-store')), findsNothing);
    expect(find.text('In stock'), findsOneWidget);
    await tap(t, find.byKey(const ValueKey('product-edit')));
    expect(find.byKey(const ValueKey('product-edit')), findsOneWidget); // disabled: nothing opened
  });

  testWidgets('a catalogue item with no stock record says so and keeps its prices and switches', (t) async {
    final f = Fake();
    await phone(t, ProductPage(env: f.env, item: CatItem(catRow(inv: null))));
    expect(find.text('No stock record yet: stock, movements and the stock buttons appear once it has one.'), findsOneWidget);
    expect(f.calls('inv_stock_detail'), isEmpty);
    expect(find.byKey(const ValueKey('product-save-prices')), findsOneWidget);
    await tap(t, find.byKey(const ValueKey('product-adjust')));
    expect(f.opened, isEmpty);
  });
}
