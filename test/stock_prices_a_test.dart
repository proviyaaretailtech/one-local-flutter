import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/catalogue/catalogue_api.dart';
import 'package:vinii_pos/inventory/inv_env.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/stock/low_stock_view_screen.dart';
import 'package:vinii_pos/stock/reorder_screen.dart';
import 'package:vinii_pos/stock/stock_env.dart';
import 'package:vinii_pos/stock/update_stock_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) =>
    http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

// ---------------------------------------------------------------- fixtures (shapes captured from the local server)
Map<String, dynamic> stockRow(String id, String name, String status,
        {num available = 10, num reserved = 0, num damaged = 0, num inTransit = 0, num? days = 5, num? expiry = 60, String sku = 'SC1'}) =>
    {
      'id': id, 'sku': sku, 'name': name, 'unit': 'pc', 'status': status, 'damaged': damaged, 'category': 'Snacks', 'reserved': reserved,
      'available': available, 'item_type': 'sku', 'in_transit': inTransit, 'stock_days': days, 'expiry_date': null, 'expiry_days': expiry,
    };

final stockRows = [
  stockRow('i-milk', 'Milk 1 ltr', 'out', available: 0, inTransit: 24, days: null, expiry: null, sku: 'M001'),
  stockRow('i-parle', 'Parle-G 250g', 'low', available: 12, days: 4.4, expiry: 117, sku: 'PG250'),
  stockRow('i-tea', 'Tata Tea Gold 500g', 'low', available: 4, days: 28, reserved: 3, sku: 'TTG500'),
  stockRow('i-oil', 'Fortune Sunflower Oil 1L', 'near_expiry', available: 11, days: 38.5, expiry: 2, sku: 'FSO1L'),
  stockRow('i-butter', 'Amul Butter 500g', 'healthy', available: 34, days: 79, damaged: 2, reserved: 5, sku: 'AMB500'),
];

Map<String, dynamic> stockList() => {
      'page': 1, 'items': stockRows, 'total': stockRows.length, 'page_size': 50, 'categories': ['Snacks'],
      'counts': {'all': 5, 'low': 2, 'healthy': 1, 'critical': 1, 'near_expiry': 1},
    };

Map<String, dynamic> dashboard() => {
      'counts': {'low': 2, 'out': 1, 'total': 5, 'healthy': 1, 'critical': 1, 'near_expiry': 1},
      'positioning': {'free': 61, 'total': 85, 'inbound': 24},
      'replenishment': [
        {'id': 'i-milk', 'name': 'Milk 1 ltr', 'unit': 'pc', 'urgent': true, 'suggest': 5},
        {'id': 'i-parle', 'name': 'Parle-G 250g', 'unit': 'pc', 'urgent': false, 'suggest': 8},
      ],
      'damaged': {'top': [], 'count': 1, 'units': 2},
    };

Map<String, dynamic> forecast(String id) => {
      'item': {'id': id}, 'suggest_qty': id == 'i-milk' ? 5 : 8, 'demand_per_day': id == 'i-milk' ? 3 : 2.5, 'end_stock': id == 'i-milk' ? -21 : -5,
      'inbound_total': id == 'i-milk' ? 24 : 0,
    };

Map<String, dynamic> catRow(String id, String inv, String name, {int price = 4000, int? mrp = 4500, int? cost = 3000, num? stock = 10, bool on = true, int version = 3}) => {
      'id': id, 'sku': 'SC-$id', 'name': name, 'status': on ? 'active' : 'inactive', 'available': on, 'version': version, 'category': 'Snacks',
      'price_minor': price, 'mrp_minor': mrp, 'cost_minor': cost, 'stock_qty': stock, 'selling_unit': 'pc', 'inventory_item_id': inv,
    };

Map<String, dynamic> catList() => {
      'page': 1, 'page_size': 10, 'total_matching': 2,
      'counts': {'total': 2, 'active': 2, 'inactive': 0, 'drafts': 0}, 'categories': ['Beverages', 'Staples'],
      'items': [catRow('m-cola', 'i-cola', 'Coca-Cola 500ml'), catRow('m-salt', 'i-salt', 'Tata Salt 1kg', price: 2800, mrp: 2800, cost: 2000, stock: 58)],
    };

/// Fake server for all three APIs; records requests.
class Fake {
  Fake([this.handler]);
  final http.Response? Function(http.Request r)? handler;
  final requests = <http.Request>[];
  final opened = <String>[];
  var purchases = 0;

  late final client = MockClient((r) async {
    requests.add(r);
    final custom = handler?.call(r);
    if (custom != null) return custom;
    final body = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
    return switch (fnOf(r)) {
      'inv_stock_list' => ok(stockList()),
      'inv_dashboard' => ok(dashboard()),
      'inv_forecast' => ok(forecast(body['item_id'] as String)),
      'inv_stock_detail' => ok({'bins': [{'id': 'bin-a', 'code': 'A-01', 'name': 'Shelf A-01', 'zone': 'shelf', 'on_hand': 40}, {'id': 'bin-q', 'zone': 'quarantine', 'on_hand': 9}]}),
      'cat_item_list' => ok(catList()),
      'sf_products' => ok({'items': [{'id': 'm-cola', 'visible': true}, {'id': 'm-salt', 'visible': false}]}),
      'cat_item_save' => ok(catRow('m-cola', 'i-cola', 'Coca-Cola 500ml', version: 4)),
      'rst_menu_stock_set' => ok({'changed': 1}),
      'sf_product_save' => ok({'id': body['id']}),
      'inv_document_save' => ok({'id': 'doc-1', 'doc_no': 'ADJ-007', 'status': 'draft', 'version': 1}),
      'inv_document_act' => ok({'id': 'doc-1', 'doc_no': 'ADJ-007', 'status': 'awaiting_approval', 'version': 2}),
      _ => err(404, 'not found: ${fnOf(r)}'),
    };
  });

  late final env = StockEnv(
    inv: InvEnv(api: InventoryApi(baseUrl: 'http://pos.test', accessToken: () => 't', client: client)),
    catalogue: CatalogueApi(baseUrl: 'http://pos.test', accessToken: () => 't', client: client),
    rpc: RpcClient(baseUrl: 'http://pos.test', accessToken: () => 't', client: client),
    open: (context, page, {itemId}) async => opened.add(itemId == null ? page : '$page:$itemId'),
    onOpenPurchase: (_) => purchases++,
  );

  List<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn).toList();
  Map<String, dynamic> body(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;
}

Future<void> show(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 7000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f.first);
  await t.tap(f.first);
  await t.pumpAndSettle();
}

void main() {
  group('Stock Management', () {
    /// Opens a product's edit sheet (⋮), types [value] into [field] (stock / price / mrp / cost) and closes it.
    Future<void> edit(WidgetTester t, String id, String field, String value) async {
      await tap(t, find.byKey(ValueKey('stock-more-$id')));
      await t.enterText(find.byKey(ValueKey('sheet-$field')), value);
      await t.pump();
      await tap(t, find.byKey(const ValueKey('sheet-done')));
    }

    testWidgets('two sections; Stock & price lists each product with price, stock and cost; nothing to save until something changes', (t) async {
      final f = Fake();
      await show(t, UpdateStockScreen(env: f.env));
      expect(find.text('Stock Management'), findsOneWidget);
      expect(find.byKey(const ValueKey('section-stock')), findsOneWidget);
      expect(find.byKey(const ValueKey('section-availability')), findsOneWidget);
      expect(find.text('Coca-Cola 500ml'), findsOneWidget);
      expect(find.text('₹28'), findsOneWidget); // salt price
      expect(find.text('58 pc'), findsOneWidget); // salt stock
      expect(find.text('Cost ₹20'), findsOneWidget);
      expect(find.byType(Switch), findsNothing); // the switches are in the other section
      expect(find.text('No changes yet'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('stock-save')));
      expect(f.calls('cat_item_save'), isEmpty);
      expect(find.textContaining('SKU'), findsNothing);
    });

    testWidgets('the search bar scans a barcode: the product is found and the list is searched by its System Code', (t) async {
      final f = Fake((r) => fnOf(r) == 'cat_item_lookup' ? ok(catRow('m-cola', 'i-cola', 'Coca-Cola 500ml')) : null);
      await show(t, UpdateStockScreen(env: f.env, scan: (_) async => '8901764011506'));
      await tap(t, find.byKey(const ValueKey('search-scan')));
      expect(f.body(f.calls('cat_item_lookup').single)['code'], '8901764011506');
      expect(f.body(f.calls('cat_item_list').last)['q'], 'SC-m-cola');
      expect(find.widgetWithText(TextField, 'SC-m-cola'), findsOneWidget);
      // the same bar, same button, in the Store & app section
      await tap(t, find.byKey(const ValueKey('section-availability')));
      expect(find.byKey(const ValueKey('search-scan')), findsOneWidget);
    });

    testWidgets('a scanned code no product has says so', (t) async {
      final f = Fake((r) => fnOf(r) == 'cat_item_lookup' ? err(404, 'No item has that code.', 'not_found') : null);
      await show(t, UpdateStockScreen(env: f.env, scan: (_) async => '123'));
      await t.tap(find.byKey(const ValueKey('search-scan')));
      await t.pump();
      await t.pump();
      expect(find.text('No product has the code 123.'), findsOneWidget);
    });

    test('price box colour: same as MRP green, below MRP yellow, above MRP red; margin is (price − cost) ÷ price', () {
      expect(UpdateStockScreenTones.tone(4500, 4500)!.$3, 'Same as MRP');
      expect(UpdateStockScreenTones.tone(4000, 4500)!.$3, 'Below MRP');
      expect(UpdateStockScreenTones.tone(5000, 4500)!.$3, 'Above MRP — not allowed');
      expect(UpdateStockScreenTones.tone(null, 4500), isNull);
      final m = UpdateStockScreenTones.margin(4000, 3000)!;
      expect(m.amount, 1000);
      expect(m.pct, 25);
    });

    testWidgets('the edit box: Stock | Cost, MRP | Price, and the margin under them; colours follow the price as it is typed', (t) async {
      final f = Fake();
      await show(t, UpdateStockScreen(env: f.env));
      await tap(t, find.byKey(const ValueKey('stock-more-m-cola'))); // price ₹40, MRP ₹45, cost ₹30
      // the sketch's order: Stock beside Cost, then MRP beside Price
      final stock = t.getTopLeft(find.byKey(const ValueKey('sheet-stock'))), cost = t.getTopLeft(find.byKey(const ValueKey('sheet-cost')));
      final mrp = t.getTopLeft(find.byKey(const ValueKey('sheet-mrp'))), price = t.getTopLeft(find.byKey(const ValueKey('sheet-price')));
      expect(stock.dy, cost.dy);
      expect(cost.dx, greaterThan(stock.dx));
      expect(mrp.dy, greaterThan(stock.dy));
      expect(price.dx, greaterThan(mrp.dx));
      expect(t.getTopLeft(find.byKey(const ValueKey('sheet-margin'))).dy, greaterThan(price.dy));
      expect(find.text('Below MRP'), findsOneWidget);
      expect(find.text('₹10 · 25.0%'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('sheet-price')), '45');
      await t.pump();
      expect(find.text('Same as MRP'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('sheet-price')), '50');
      await t.pump();
      expect(find.text('Above MRP — not allowed'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('sheet-price')), '31');
      await t.pump();
      expect(find.text('₹1 · 3.2%'), findsOneWidget);
      expect(find.text('Below 5% — check the price or cost'), findsOneWidget);
    });

    testWidgets('Save refuses a price above MRP and says why', (t) async {
      final f = Fake();
      await show(t, UpdateStockScreen(env: f.env));
      await tap(t, find.byKey(const ValueKey('stock-more-m-cola')));
      await t.enterText(find.byKey(const ValueKey('sheet-price')), '50');
      await t.pump();
      await tap(t, find.byKey(const ValueKey('sheet-done')));
      await t.tap(find.byKey(const ValueKey('stock-save')));
      await t.pump();
      expect(find.text('The price of Coca-Cola 500ml is above its MRP. Lower the price or raise the MRP.'), findsOneWidget);
      expect(f.calls('cat_item_save'), isEmpty);
    });

    testWidgets('Store & app: an on/off switch for the store and one for the app on every product', (t) async {
      final f = Fake();
      await show(t, UpdateStockScreen(env: f.env));
      await tap(t, find.byKey(const ValueKey('section-availability')));
      expect(t.widget<Switch>(find.byKey(const ValueKey('shop-m-cola'))).value, isTrue);
      expect(t.widget<Switch>(find.byKey(const ValueKey('app-m-salt'))).value, isFalse);
      expect(find.byKey(const ValueKey('stock-more-m-cola')), findsNothing);
    });

    testWidgets('Save changes: prices in quick mode, the two switches, and one adjustment sent for approval', (t) async {
      final f = Fake();
      await show(t, UpdateStockScreen(env: f.env));
      await edit(t, 'm-cola', 'price', '42');
      await edit(t, 'm-salt', 'stock', '60');
      expect(find.text('₹42'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('section-availability')));
      await tap(t, find.byKey(const ValueKey('shop-m-cola')));
      await tap(t, find.byKey(const ValueKey('app-m-salt')));
      expect(find.text('2 products changed · review before saving'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('stock-save')));

      expect(f.body(f.calls('cat_item_save').single), {'mode': 'quick', 'version': 3, 'price_minor': 4200, 'id': 'm-cola'});
      expect(f.body(f.calls('rst_menu_stock_set').single), {'id': 'm-cola', 'in_stock': false});
      expect(f.body(f.calls('sf_product_save').single), {'id': 'm-salt', 'visible': true});
      final draft = f.body(f.calls('inv_document_save').single);
      expect(draft['doc_type'], 'adjustment');
      expect(draft['reason'], 'Data entry correction');
      expect(draft['lines'], [{'inventory_item_id': 'i-salt', 'adjust_type': 'increase', 'qty': 2}]);
      expect(f.calls('inv_document_save').single.headers['Idempotency-Key'], isNotNull);
      expect(f.body(f.calls('inv_document_act').single), containsPair('action', 'submit'));
      expect(find.textContaining('Sent for approval as ADJ-007'), findsOneWidget);
      expect(find.textContaining('Saved: prices, off sale in the shop'), findsOneWidget);
    });

    testWidgets('a lower stock takes the units off the shelves, never from quarantine', (t) async {
      final f = Fake();
      await show(t, UpdateStockScreen(env: f.env));
      await edit(t, 'm-cola', 'stock', '4');
      await tap(t, find.byKey(const ValueKey('stock-save')));
      expect(f.body(f.calls('inv_stock_detail').single)['item_id'], 'i-cola');
      expect(f.body(f.calls('inv_document_save').single)['lines'], [
        {'inventory_item_id': 'i-cola', 'from_bin_id': 'bin-a', 'adjust_type': 'decrease', 'qty': 6},
      ]);
    });

    testWidgets('a refused save is listed per product; Reset puts the saved values back; the category chips filter the list', (t) async {
      final f = Fake((r) => fnOf(r) == 'cat_item_save' ? err(403, 'Your role cannot change catalogue items.', 'forbidden') : null);
      await show(t, UpdateStockScreen(env: f.env));
      await edit(t, 'm-salt', 'cost', '21');
      await tap(t, find.byKey(const ValueKey('stock-save')));
      expect(find.textContaining('Not saved — prices: Your role cannot change catalogue items.'), findsOneWidget);
      await edit(t, 'm-cola', 'price', '50');
      expect(find.text('1 product changed · review before saving'), findsOneWidget);
      expect(find.text('₹50'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('stock-reset')));
      expect(find.text('No changes yet'), findsOneWidget);
      expect(find.text('₹50'), findsNothing);
      // the chips are the categories: picking one lists its products, and every category chip stays
      expect(find.text('On sale'), findsNothing);
      await tap(t, find.byKey(const ValueKey('chip-Staples')));
      expect(f.body(f.calls('cat_item_list').last)['category'], 'Staples');
      expect(find.byKey(const ValueKey('chip-Beverages')), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('chip-')));
      expect(f.body(f.calls('cat_item_list').last).containsKey('category'), isFalse);
    });
  });

  group('Low stock', () {
    testWidgets('most urgent first, with what is on the way; the buttons open incoming, reorder and purchase', (t) async {
      final f = Fake();
      await show(t, LowStockViewScreen(env: f.env));
      expect(find.text('Low stock'), findsWidgets);
      final milk = t.getRect(find.byKey(const ValueKey('low-i-milk'))).top;
      final parle = t.getRect(find.byKey(const ValueKey('low-i-parle'))).top;
      expect(milk, lessThan(parle)); // out of stock before low
      expect(find.byKey(const ValueKey('low-i-butter')), findsNothing); // healthy
      expect(find.text('System Code: M001'), findsOneWidget);
      await tap(t, find.descendant(of: find.byKey(const ValueKey('low-i-milk')), matching: find.text('See incoming')));
      await tap(t, find.descendant(of: find.byKey(const ValueKey('low-i-parle')), matching: find.text('Reorder')));
      await tap(t, find.text('Create purchase order'));
      expect(f.opened, ['movements:i-milk', 'reorder:i-parle']);
      expect(f.purchases, 1);
      await tap(t, find.byKey(const ValueKey('chip-critical')));
      expect(find.byKey(const ValueKey('low-i-parle')), findsNothing);
      await tap(t, find.byKey(const ValueKey('low-i-milk')));
      expect(f.opened.last, 'item:i-milk');
    });
  });

  group('Reorder', () {
    testWidgets('suggested quantities with sales per day; the summary adds them up; Create purchase order opens Purchase', (t) async {
      final f = Fake();
      await show(t, ReorderScreen(env: f.env));
      expect(find.text('Milk 1 ltr'), findsWidgets);
      expect(find.text('3.0 pc'), findsOneWidget); // sells per day
      expect(find.widgetWithText(TextField, '5'), findsOneWidget);
      expect(find.text('13'), findsOneWidget); // 5 + 8
      await t.enterText(find.byKey(const ValueKey('reorder-qty-i-parle')), '10');
      await t.pump();
      expect(find.text('15'), findsOneWidget);
      await tap(t, find.text('Create purchase order · 15 units'));
      expect(f.purchases, 1);
    });
  });

}
