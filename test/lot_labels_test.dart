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
import 'package:vinii_pos/stock/labels_screens.dart' as labels;
import 'package:vinii_pos/stock/lot_labels_screen.dart';
import 'package:vinii_pos/stock/stock_env.dart';
import 'package:vinii_pos/ui/theme.dart';

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

Map<String, dynamic> line(String id, String sku, String name, num qty, num rejected) =>
    {'item': {'id': id, 'sku': sku, 'name': name, 'unit': 'unit'}, 'qty': qty, 'rejected_qty': rejected};

// a received lot: 12 Coca-Cola (2 damaged), 6 Pepsi, 3 all damaged, and one product the shop does not sell
final _receipt = {
  'id': 'r3', 'doc_no': 'RCV-003', 'doc_type': 'receipt', 'status': 'posted', 'version': 4, 'supplier_name': 'ABC Foods',
  'lines': [
    line('i1', 'COKE-500ML', 'Coca-Cola 500ml', 12, 2),
    line('i2', 'PEPSI-330', 'Pepsi 330ml', 6, 0),
    line('i3', 'EGGS-6', 'Eggs tray', 3, 3),
    line('i4', 'CARTON', 'Packing carton', 5, 0),
  ],
};

final _catalogue = {
  'COKE-500ML': {'id': 'm1', 'inventory_item_id': 'i1', 'name': 'Coca-Cola 500ml', 'sku': 'COKE-500ML', 'price_minor': 4000, 'mrp_minor': 4500, 'selling_unit': 'pc', 'barcode': '8901764012215'},
  'PEPSI-330': {'id': 'm2', 'inventory_item_id': 'i2', 'name': 'Pepsi 330ml', 'sku': 'PEPSI-330', 'price_minor': 3500, 'selling_unit': 'pc'},
};

class Fake {
  final requests = <http.Request>[];
  late final client = MockClient((r) async {
    requests.add(r);
    final b = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
    switch (fnOf(r)) {
      case 'inv_document_view':
        return ok(_receipt);
      case 'cat_item_lookup':
        final c = _catalogue[b['code']];
        return c == null ? http.Response('{"detail":"No product has that code.","code":"not_found"}', 404, headers: {'content-type': 'application/json'}) : ok(c);
    }
    return http.Response('{"detail":"not found"}', 404);
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
  t.view.physicalSize = const Size(780, 3000);
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

  final realPrint = labels.printLabelPdf;
  tearDown(() => labels.printLabelPdf = realPrint);

  testWidgets('every product of the lot is listed with one label per good unit; damaged ones get none', (t) async {
    final f = Fake();
    await phone(t, LotLabelsScreen(env: f.env, receiptId: 'r3'));
    expect(find.text('Lot labels'), findsOneWidget);
    expect(find.text('RCV-003 · ABC Foods'), findsOneWidget);
    expect(find.byKey(const ValueKey('lot-line-i1')), findsOneWidget);
    expect(find.byKey(const ValueKey('lot-line-i2')), findsOneWidget);
    expect(find.byKey(const ValueKey('lot-line-i3')), findsNothing); // all 3 damaged
    expect(find.textContaining('10 received'), findsOneWidget); // 12 − 2 damaged
    // a product the shop does not sell cannot get a price label: shown, off, and says why
    expect(find.text('Not sold in the shop, so it has no price for a label.'), findsOneWidget);
    expect(t.widget<Switch>(find.byKey(const ValueKey('lot-on-i4'))).value, isFalse);
    // Coca-Cola already carries its maker's barcode: skipped (off), can still be turned on
    expect(find.textContaining('Has its own barcode, so it needs no label.'), findsOneWidget);
    expect(t.widget<Switch>(find.byKey(const ValueKey('lot-on-i1'))).value, isFalse);
    expect(find.textContaining('PEPSI-330'), findsOneWidget); // the System Code is what the label carries
    expect(find.text('Print 6 labels'), findsOneWidget); // Pepsi only
  });

  testWidgets('a product turned off or a changed count changes the total; Print sends them all in one PDF', (t) async {
    final f = Fake();
    Uint8List? sent;
    labels.printLabelPdf = (pdf, name) async => sent = pdf;
    await phone(t, LotLabelsScreen(env: f.env, receiptId: 'r3'));
    await tap(t, find.byKey(const ValueKey('lot-on-i1'))); // turned on anyway
    expect(find.text('Print 16 labels'), findsOneWidget);
    await tap(t, find.byKey(const ValueKey('lot-on-i2')));
    expect(find.text('Print 10 labels'), findsOneWidget);
    expect(find.byKey(const ValueKey('lot-count-i2')), findsNothing);
    await tap(t, find.descendant(of: find.byKey(const ValueKey('lot-count-i1')), matching: find.text('–')).first);
    expect(find.text('Print 9 labels'), findsOneWidget);
    await tap(t, find.byKey(const ValueKey('lot-print')));
    expect(sent, isNotNull);
    expect(find.text('9 labels sent to the print screen.'), findsOneWidget);
  });
}
