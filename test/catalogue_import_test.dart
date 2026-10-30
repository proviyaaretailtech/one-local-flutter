import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/catalogue/catalogue_api.dart';
import 'package:vinii_pos/catalogue/catalogue_import.dart';
import 'package:vinii_pos/catalogue/sku_api.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/ui/theme.dart';
import 'package:vinii_pos/ui/xlsx.dart';

// Catalogue import from Excel (founder, 31 Oct 2026): the sample template, reading .xlsx and .csv, every row checked (new / update / to
// fix) against the store's items and OneLocal's SKU lists, then saved one by one with its own key.

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

final skuOptions = SkuOptions({
  'subcategories': [
    {'code': 'BIS', 'name': 'Biscuits & Cookies'},
    {'code': 'RIC', 'name': 'Rice & Rice Products'},
  ],
  'units': [for (final u in ['G', 'KG', 'L', 'ML', 'PC', 'PK']) {'code': u}],
  'brands': [
    {'code': 'PRL', 'name': 'Parle-G', 'kind': 'brand', 'status': 'approved'},
    {'code': 'LSE', 'name': 'Loose / Unbranded', 'kind': 'reserved', 'status': 'approved'},
  ],
});

final catalogue = [
  CatItem({'id': 'm1', 'name': 'Amul Butter 500g', 'sku': 'OL-BUT-AML-500G-01', 'barcode': '8901262010016', 'version': 3, 'price_minor': 28500}),
];

Uint8List csv(String s) => Uint8List.fromList(utf8.encode(s));

const header = 'Name*,Category,Unit,Price type,MRP,Selling price*,Cost,Barcode,Subcategory*,Brand / item,Size*,SKU,GST %,HSN,Opening stock';

void main() {
  test('the sample template reads back: the column names and three example rows, numbers as plain numbers', () {
    final rows = readXlsx(catalogueTemplate());
    expect(rows.first, kImportColumns);
    expect(rows.length, 4);
    expect(rows[1].take(6), ['Parle-G 250g', 'Biscuits', 'pc', 'MRP', '30', '28']);
    final parsed = parseCatalogueFile('catalogue-template.xlsx', catalogueTemplate());
    checkImportRows(parsed, const [], skuOptions);
    expect(parsed[0].ok, isTrue, reason: parsed[0].problems.join('; '));
    expect(parsed[1].ok, isTrue, reason: parsed[1].problems.join('; '));
  });

  test('CSV: quotes, commas inside quotes, line breaks and a byte-order mark', () {
    expect(readCsv('﻿a,"b, c","say ""hi"""\r\n1,2,3\n'), [
      ['a', 'b, c', 'say "hi"'],
      ['1', '2', '3'],
    ]);
  });

  test('every row is checked: new, an update by SKU or barcode, and what is wrong', () {
    final rows = parseCatalogueFile('items.csv', csv([
      header,
      'Parle-G 250g,Biscuits,pc,MRP,30,28,24,8901719110016,BIS,PRL,250g,,18,1905,48',
      'Amul Butter 500g,Dairy,pc,MRP,290,280,,,,,,OL-BUT-AML-500G-01,,,',
      'Butter by barcode,Dairy,pc,MRP,290,275,,8901262010016,,,,,,,',
      'Basmati Loose,Grocery,kg,Store,,90,72,,Rice & Rice Products,,KG,,5,1006,25.5',
      'No price,Grocery,pc,MRP,30,,,,BIS,PRL,100G,,,,',
      'Too dear,Grocery,pc,MRP,30,35,,,BIS,PRL,100G,,,,',
      'Odd parts,Grocery,pc,MRP,30,25,,,XYZ,Nobody,big,,,,',
      'Twice,Grocery,pc,MRP,30,25,,8901719110016,BIS,PRL,250G,,,,',
      'Ghost SKU,Grocery,pc,MRP,30,25,,,BIS,PRL,250G,OL-NOPE-01,,,',
      'Old stock,Dairy,pc,MRP,290,280,,,,,,OL-BUT-AML-500G-01,,,5',
    ].join('\n')));
    checkImportRows(rows, catalogue, skuOptions);
    final byName = {for (final r in rows) r.name: r};
    final parle = byName['Parle-G 250g']!;
    expect(parle.ok, isTrue);
    expect(parle.update, isFalse);
    expect(parle.fields['sku_parts'], {'sub': 'BIS', 'slot3': 'PRL', 'size': '250G'});
    expect(parle.fields, allOf(containsPair('price_minor', 2800), containsPair('mrp_minor', 3000), containsPair('price_basis', 'mrp'), containsPair('gst_pct', 18)));
    expect(parle.openingStock, 48);
    final bySku = byName['Amul Butter 500g']!;
    expect([bySku.ok, bySku.update, bySku.fields['version']], [true, true, 3]);
    expect(bySku.fields.containsKey('sku_parts'), isFalse); // an update never makes a new SKU
    expect(byName['Butter by barcode']!.existing?.id, 'm1');
    final loose = byName['Basmati Loose']!;
    expect(loose.fields['sku_parts'], {'sub': 'RIC', 'slot3': 'LSE', 'size': 'KG'}); // a name works; no brand = loose
    expect([loose.fields['price_basis'], loose.fields.containsKey('mrp_minor')], ['store', false]);
    expect(byName['No price']!.problems, contains('Selling price is missing or not a number'));
    expect(byName['Too dear']!.problems, contains('Selling price is above the MRP'));
    expect(byName['Odd parts']!.problems.join(' '), allOf(contains('Subcategory "XYZ"'), contains('Brand "Nobody"'), contains('Size "big"')));
    expect(byName['Twice']!.problems, contains('Barcode 8901719110016 is also on row 2'));
    expect(byName['Ghost SKU']!.problems.first, startsWith('SKU OL-NOPE-01 is not one of your products'));
    expect(byName['Old stock']!.problems, contains('Opening stock is only for new items; count an existing item in Stock'));
  });

  test('a file without the column names says what is needed', () {
    expect(() => parseCatalogueFile('x.csv', csv('foo,bar\n1,2')), throwsA(isA<FormatException>()));
    expect(() => parseCatalogueFile('x.xlsx', csv('not a zip')), throwsA(isA<FormatException>()));
  });

  testWidgets('pick → every row checked → Import saves the good ones with keys, then the opening stock; the bad ones stay to fix', (t) async {
    final requests = <http.Request>[];
    final client = MockClient((r) async {
      requests.add(r);
      final b = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
      return switch (fnOf(r)) {
        'cat_item_list' => ok({'items': [for (final i in catalogue) i.raw], 'counts': {}, 'page': 1, 'page_size': 100, 'total_matching': 1}),
        'sku_options' => ok({'subcategories': [{'code': 'BIS', 'name': 'Biscuits & Cookies'}], 'units': [{'code': 'G'}, {'code': 'PC'}], 'brands': [{'code': 'PRL', 'name': 'Parle-G', 'status': 'approved'}, {'code': 'LSE', 'name': 'Loose', 'status': 'approved'}]}),
        'cat_item_save' => ok({'id': b['id'] ?? 'new-${requests.length}', 'name': b['name'], 'sku': 'OL-BIS-PRL-250G-01', 'inventory_item_id': 'inv-${requests.length}', 'version': 1}),
        'inv_opening_stock' => ok({'id': 'd1', 'doc_no': 'ADJ-1', 'status': 'posted', 'lines': []}),
        _ => ok({}),
      };
    });
    final real = pickCatalogueFile;
    pickCatalogueFile = () async => (name: 'stock.csv', bytes: csv([
          header,
          'Parle-G 250g,Biscuits,pc,MRP,30,28,24,8901719110016,BIS,PRL,250G,,18,1905,48',
          'Amul Butter 500g,Dairy,pc,MRP,290,280,,,,,,OL-BUT-AML-500G-01,,,',
          'No price,Grocery,pc,MRP,30,,,,BIS,PRL,100G,,,,',
        ].join('\n')));
    addTearDown(() => pickCatalogueFile = real);
    t.view.physicalSize = const Size(800, 2600);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: posTheme(),
      home: CatalogueImportScreen(
        api: CatalogueApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client),
        inventory: InventoryApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client),
        sku: SkuApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client),
      ),
    ));
    await t.tap(find.byKey(const ValueKey('import-pick')));
    await t.pumpAndSettle();
    expect(find.text('New · 1'), findsOneWidget);
    expect(find.text('Updates · 1'), findsOneWidget);
    expect(find.text('To fix · 1'), findsOneWidget);
    expect(find.text('Import 2 products'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('import-go')));
    await t.pumpAndSettle();
    final saves = requests.where((r) => fnOf(r) == 'cat_item_save').toList();
    expect(saves, hasLength(2));
    expect(saves.first.headers['Idempotency-Key'], endsWith('-2'), reason: 'a new product: its own key per row, so importing again adds nothing twice');
    expect(saves.last.headers['Idempotency-Key'], isNull, reason: 'an update is guarded by its version instead');
    expect(jsonDecode(saves.first.body)['sku_parts'], {'sub': 'BIS', 'slot3': 'PRL', 'size': '250G'});
    expect(jsonDecode(saves.last.body), allOf(containsPair('id', 'm1'), containsPair('version', 3)));
    expect(jsonDecode(requests.firstWhere((r) => fnOf(r) == 'inv_opening_stock').body)['qty'], 48);
    expect(find.byKey(const ValueKey('import-summary')), findsOneWidget);
    expect(find.text('1 added, 1 updated, 1 to fix.'), findsOneWidget);
  });
}
