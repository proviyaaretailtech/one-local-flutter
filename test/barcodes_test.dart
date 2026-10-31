import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/barcodes/barcodes_api.dart';
import 'package:vinii_pos/barcodes/barcodes_screen.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/orders/orders_api.dart' show rupees;
import 'package:vinii_pos/stock/labels_screens.dart' show printLabelPdf;
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';
import 'sell_fixtures.dart';

// Side menu → Barcodes (founder's mock-ups, 30 Oct 2026): home, create (single or bulk), bulk (tick → review → ring → results → print),
// all codes, details, print label options, weigh & print, custom (save on item / preview → print), link an unknown code, empty states.

Future<void> open(WidgetTester t, Till till) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 2400);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: BarcodesScreen(api: BarcodesApi(baseUrl: 'http://pos.test', accessToken: () => 'tok', client: till.client), store: 'Sharma General Store')));
  await t.pumpAndSettle();
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

List<Map<String, dynamic>> sent(Till till, String fn) => till.where('POST', '/rpc/$fn').map((r) => jsonDecode(r.body) as Map<String, dynamic>).toList();

void main() {
  tearDown(HomeNav.reset);
  late List<String> printed;
  setUp(() {
    printed = [];
    printLabelPdf = (pdf, name) async => printed.add(name);
  });

  testWidgets('home: Create Barcode, All Codes, Loose Items, Custom Barcode', (t) async {
    await open(t, Till());
    expect(find.text('Barcodes'), findsWidgets);
    for (final k in ['bc-home-create', 'bc-home-all', 'bc-home-loose', 'bc-home-custom']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget);
    }
  });

  testWidgets('single item: choose the product, its code is made, then its details and the print options', (t) async {
    final till = Till();
    await open(t, till);
    await tapKey(t, 'bc-home-create');
    expect(find.text('How would you like to create the barcode?'), findsOneWidget);
    await tapKey(t, 'create-single');
    await tapKey(t, 'select-m2');
    await tapKey(t, 'select-confirm');
    expect(sent(till, 'bc_make').single['menu_item_id'], 'm2');
    expect(find.text('Barcode Details'), findsOneWidget);
    expect(find.text('2000000000022'), findsWidgets);
    await tapKey(t, 'details-print-label');
    expect(find.text('Print Label'), findsOneWidget);
    await tapKey(t, 'print-type-large');
    await tapKey(t, 'copies-more');
    expect(t.widget<Text>(find.byKey(const ValueKey('copies-value'))).data, '2');
    await tapKey(t, 'print-label-go');
    expect(printed, ['Barcode labels']);
  });

  testWidgets('bulk: tick by category, review, the ring counts each one, results, print labels with copies per item', (t) async {
    final till = Till();
    await open(t, till);
    await tapKey(t, 'bc-home-create');
    await tapKey(t, 'create-bulk');
    expect(find.text('All (2)'), findsOneWidget);
    await tapKey(t, 'bulk-cat-Grocery');
    expect(find.byKey(const ValueKey('bulk-pick-m2')), findsNothing);
    await tapKey(t, 'bulk-select-all');
    expect(t.widget<Text>(find.byKey(const ValueKey('bulk-count'))).data, '1 item selected');
    await tapKey(t, 'bulk-cat-all');
    await tapKey(t, 'bulk-pick-m2');
    await tapKey(t, 'bulk-continue');
    expect(find.text('You are about to generate barcodes for 2 items.'), findsOneWidget);
    await tapKey(t, 'bulk-generate');
    expect(sent(till, 'bc_make').map((b) => b['menu_item_id']), ['m2', 'm9']);
    expect(t.widget<Text>(find.byKey(const ValueKey('bulk-progress'))).data, '2/2');
    await tapKey(t, 'bulk-view-results');
    expect(find.text('Barcode Results'), findsOneWidget);
    await tapKey(t, 'bulk-print');
    expect(find.text('2 items selected'), findsOneWidget);
    await tapKey(t, 'bulk-copies-more');
    await tapKey(t, 'bulk-print-go');
    expect(printed, ['Barcode labels']);
  });

  testWidgets('all codes: filters, and a search that finds nothing says so', (t) async {
    final till = Till();
    await open(t, till);
    await tapKey(t, 'bc-home-all');
    expect(find.text('2000000000015'), findsOneWidget);
    await tapKey(t, 'codes-filter-linked');
    expect(find.byKey(const ValueKey('bc-empty')), findsOneWidget);
    expect(find.text('No results found'), findsOneWidget);
    await tapKey(t, 'codes-filter-none');
    await tapKey(t, 'code-m2');
    expect(find.text('No barcode yet'), findsOneWidget);
    await tapKey(t, 'details-loose');
    expect(sent(till, 'bc_set_loose').single, {'menu_item_id': 'm2', 'loose': true});
  });

  testWidgets('loose items: weigh & print, the chips set the amount and the real weigh-label code', (t) async {
    final till = Till();
    await open(t, till);
    await tapKey(t, 'bc-home-loose');
    expect(find.textContaining('PLU 00003'), findsOneWidget);
    await tapKey(t, 'code-m9');
    await tapKey(t, 'weigh-chip-0.500');
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(t.widget<Text>(find.byKey(const ValueKey('weigh-total'))).data, rupees(45));
    expect(sent(till, 'bc_weigh_label').last, {'menu_item_id': 'm9', 'weight_g': 500});
    await tapKey(t, 'weigh-print-label');
    expect(printed, ['Barcode labels']);
  });

  testWidgets('custom: make one for me, preview then print; save on item → select product → code linked', (t) async {
    final till = Till();
    await open(t, till);
    await tapKey(t, 'bc-home-custom');
    await tapKey(t, 'custom-print');
    expect(find.text('Type a code first.'), findsOneWidget);
    await tapKey(t, 'custom-mode-make');
    expect(find.text('2000000000039'), findsWidgets);
    await tapKey(t, 'custom-more');
    await tapKey(t, 'custom-print');
    expect(t.widget<Text>(find.byKey(const ValueKey('preview-copies'))).data, '2');
    await tapKey(t, 'preview-print');
    expect(printed, ['Barcode labels']);
    await t.pump(const Duration(seconds: 6)); // the toast has gone
    await tapKey(t, 'preview-edit');
    await tapKey(t, 'custom-save');
    await tapKey(t, 'select-m2');
    await tapKey(t, 'select-confirm');
    expect([sent(till, 'bc_custom').last['code'], sent(till, 'bc_custom').last['menu_item_id']], ['2000000000039', 'm2']);
    expect(find.text('Code linked!'), findsOneWidget);
  });
}
