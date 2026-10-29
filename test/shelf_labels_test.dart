import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/catalogue/catalogue_api.dart';
import 'package:vinii_pos/inventory/inv_env.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/stock/label_pdf.dart';
import 'package:vinii_pos/stock/labels_screens.dart' as labels;
import 'package:vinii_pos/stock/shelf_labels_screen.dart';
import 'package:vinii_pos/stock/stock_env.dart';
import 'package:vinii_pos/ui/theme.dart';

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

final _items = [
  {'id': 'm1', 'inventory_item_id': 'i1', 'name': 'Coca-Cola Pet Bottle 500ml', 'sku': 'COKE-500ML', 'category': 'Beverages', 'status': 'active', 'price_minor': 4000, 'mrp_minor': 4500, 'selling_unit': 'pc'},
  {'id': 'm2', 'inventory_item_id': 'i2', 'name': 'Pepsi Cola Can 330ml', 'sku': 'PEPSI-330', 'category': 'Beverages', 'status': 'active', 'price_minor': 3500, 'selling_unit': 'pc'},
];

class Fake {
  final requests = <http.Request>[];
  late final client = MockClient((r) async {
    requests.add(r);
    return switch (fnOf(r)) {
      'cat_item_list' => ok({'items': _items, 'total': _items.length, 'page': 1, 'counts': {}, 'categories': ['Beverages']}),
      'cat_item_lookup' => ok({..._items.first, 'barcode': '8901764012215'}),
      _ => http.Response('{"detail":"not found"}', 404),
    };
  });
  late final env = StockEnv(
    inv: InvEnv(api: InventoryApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client)),
    catalogue: CatalogueApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client),
    rpc: RpcClient(baseUrl: 'http://t.test', accessToken: () => 't', client: client),
  );
}

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

Future<void> phone(WidgetTester t, Widget screen) async {
  t.view.physicalSize = const Size(780, 4000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
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

  testWidgets('Choose: products with their price, the two label styles and three sizes; Preview needs a product', (t) async {
    final f = Fake();
    await phone(t, ShelfLabelsScreen(env: f.env));
    expect(find.text('Shelf labels'), findsOneWidget);
    expect(find.text('Coca-Cola Pet Bottle 500ml'), findsOneWidget);
    expect(find.text('₹40'), findsOneWidget);
    expect(find.text('System Code COKE-500ML'), findsOneWidget);
    for (final s in ['Standard price tag', 'Offer label', 'Small (2"×1")', 'Medium (3"×2")', 'Large (4"×3")']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    expect(jsonDecode(f.requests.first.body)['status'], 'active');
    await tap(t, 'labels-preview'); // nothing picked yet: stays on Choose
    expect(find.byKey(const ValueKey('label-preview')), findsNothing);
  });

  testWidgets('an offer label shows the offer price, the MRP struck through and the saving; size changes the label', (t) async {
    final f = Fake();
    await phone(t, ShelfLabelsScreen(env: f.env));
    await tap(t, 'labels-product-m1');
    await tap(t, 'labels-style-offer');
    await tap(t, 'labels-size-large');
    await tap(t, 'labels-preview');
    final label = find.byKey(const ValueKey('label-preview'));
    expect(label, findsOneWidget);
    expect(find.descendant(of: label, matching: find.text('OFFER PRICE')), findsOneWidget);
    expect(find.descendant(of: label, matching: find.text('MRP ₹45')), findsOneWidget);
    expect(find.descendant(of: label, matching: find.text('SAVE ₹5')), findsOneWidget);
    final large = t.getSize(label);
    expect(large.width / large.height, closeTo(4 / 3, 0.01));
    await tap(t, 'labels-back');
    await tap(t, 'labels-size-small');
    await tap(t, 'labels-preview');
    final small = t.getSize(find.byKey(const ValueKey('label-preview')));
    expect(small.width / small.height, closeTo(2, 0.01));
    expect(small.width, lessThan(large.width));
  });

  testWidgets('Print labels makes one PDF page per label, with the product barcode, and hands it to the print screen', (t) async {
    final f = Fake();
    final sent = <(Uint8List, String)>[];
    final before = labels.printLabelPdf;
    labels.printLabelPdf = (pdf, name) async => sent.add((pdf, name));
    addTearDown(() => labels.printLabelPdf = before);
    await phone(t, ShelfLabelsScreen(env: f.env));
    await tap(t, 'labels-product-m1');
    await tap(t, 'labels-preview');
    await t.tap(find.text('+').last);
    await t.pump();
    await t.tap(find.text('+').last);
    await t.pumpAndSettle();
    await t.runAsync(() async {
      await t.tap(find.byKey(const ValueKey('labels-print')));
      for (var i = 0; i < 50 && sent.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await t.pumpAndSettle();
    expect(sent.single.$2, 'shelf-labels.pdf');
    expect(RegExp(r'/Type\s*/Page[^s]').allMatches(latin1.decode(sent.single.$1)).length, 3);
    expect(f.requests.where((r) => fnOf(r) == 'cat_item_lookup'), hasLength(1));
    expect(find.text('3 labels sent to the print screen.'), findsOneWidget);
  });

  test('label sizes are the common thermal rolls, in inches', () {
    expect([LabelSize.small.widthMm, LabelSize.small.heightMm], [50.8, 25.4]);
    expect([LabelSize.medium.widthMm, LabelSize.medium.heightMm], [76.2, 50.8]);
    expect([LabelSize.large.widthMm, LabelSize.large.heightMm], [101.6, 76.2]);
    const l = LabelData(name: 'x', priceMinor: 4000, mrpMinor: 4500, code: 'c', systemCode: 's');
    expect(l.savingMinor, 500);
  });
}
