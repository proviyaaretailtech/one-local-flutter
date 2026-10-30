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

// Side menu → Barcodes (founder's mock-ups, 30 Oct 2026): home, bulk generate (choose → review → generating → done), all codes, details,
// weigh & print, custom barcode, link an unknown code.

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

void main() {
  tearDown(HomeNav.reset);
  late List<String> printed;
  setUp(() {
    printed = [];
    printLabelPdf = (pdf, name) async => printed.add(name);
  });

  testWidgets('home: four ways in', (t) async {
    await open(t, Till());
    expect(find.text('Manage product barcodes'), findsOneWidget);
    for (final k in ['bc-home-create', 'bc-home-bulk', 'bc-home-all', 'bc-home-loose']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget);
    }
  });

  testWidgets('bulk generate: all items without a barcode → review → each one made in turn → done, labels print', (t) async {
    final till = Till();
    await open(t, till);
    await tapKey(t, 'bc-home-bulk');
    expect(find.textContaining('2 items'), findsOneWidget); // the two without a barcode
    await tapKey(t, 'bulk-continue');
    expect(find.text('Review & Generate'), findsOneWidget);
    expect(find.text('You are about to generate barcodes for 2 products.'), findsOneWidget);
    await tapKey(t, 'bulk-generate');
    expect(till.where('POST', '/rpc/bc_make').map((r) => jsonDecode(r.body)['menu_item_id']), ['m2', 'm9']);
    expect(find.byKey(const ValueKey('bulk-done')), findsOneWidget);
    expect(find.text('2 products have been updated with new barcodes.'), findsOneWidget);
    await tapKey(t, 'bulk-print');
    expect(printed, ['Barcode labels']);
  });

  testWidgets('bulk generate: only the items you tick', (t) async {
    final till = Till();
    await open(t, till);
    await tapKey(t, 'bc-home-bulk');
    await tapKey(t, 'bulk-some');
    await tapKey(t, 'bulk-pick-m9');
    await tapKey(t, 'bulk-continue');
    expect(find.text('You are about to generate barcodes for 1 product.'), findsOneWidget);
    await tapKey(t, 'bulk-generate');
    expect(till.where('POST', '/rpc/bc_make').map((r) => jsonDecode(r.body)['menu_item_id']), ['m9']);
  });

  testWidgets('all codes: filter by source; details show the code, make one, print, turn sold loose on', (t) async {
    final till = Till();
    await open(t, till);
    await tapKey(t, 'bc-home-all');
    expect(find.text('2000000000015'), findsOneWidget);
    await tapKey(t, 'codes-filter-generated');
    expect(find.byKey(const ValueKey('code-m2')), findsNothing);
    await tapKey(t, 'codes-filter-none');
    await tapKey(t, 'code-m2');
    expect(find.text('Barcode Details'), findsOneWidget);
    expect(find.text('No barcode yet'), findsOneWidget);
    await tapKey(t, 'details-make');
    expect(find.text('2000000000022'), findsWidgets);
    await tapKey(t, 'details-print');
    expect(printed, ['Barcode labels']);
    await tapKey(t, 'details-loose');
    expect(jsonDecode(till.where('POST', '/rpc/bc_set_loose').single.body), {'menu_item_id': 'm2', 'loose': true});
  });

  testWidgets('loose items: weigh & print, the weight chips set the amount and the real weigh-label code', (t) async {
    final till = Till();
    await open(t, till);
    await tapKey(t, 'bc-home-loose');
    expect(find.textContaining('PLU 00003'), findsOneWidget);
    await tapKey(t, 'code-m9');
    expect(find.text('Weigh & Print Label'), findsOneWidget);
    await tapKey(t, 'weigh-chip-0.500');
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(t.widget<Text>(find.byKey(const ValueKey('weigh-total'))).data, rupees(45));
    expect(jsonDecode(till.where('POST', '/rpc/bc_weigh_label').last.body), {'menu_item_id': 'm9', 'weight_g': 500});
    await tapKey(t, 'weigh-print-label');
    expect(printed, ['Barcode labels']);
  });

  testWidgets('custom barcode: make one for me, set copies, print; save puts it on a product', (t) async {
    final till = Till();
    await open(t, till);
    await tapKey(t, 'bc-home-create');
    await tapKey(t, 'custom-print');
    expect(find.text('Type a code first.'), findsOneWidget);
    await tapKey(t, 'custom-mode-make');
    expect(find.text('2000000000039'), findsWidgets);
    await tapKey(t, 'custom-more');
    expect(t.widget<Text>(find.byKey(const ValueKey('custom-copies'))).data, '2');
    await tapKey(t, 'custom-print');
    expect(printed, ['Barcode labels']);
    await tapKey(t, 'custom-save');
    expect(find.text('Which product gets this code?'), findsOneWidget);
    await tapKey(t, 'link-item-m2');
    await tapKey(t, 'link-confirm');
    final sent = till.where('POST', '/rpc/bc_custom').map((r) => jsonDecode(r.body) as Map<String, dynamic>).last;
    expect([sent['code'], sent['menu_item_id']], ['2000000000039', 'm2']);
  });
}
