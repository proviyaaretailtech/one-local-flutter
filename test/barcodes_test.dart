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

// Side menu → Barcodes (one page since 1 Nov 2026): a search bar that lists items as you type, All / No barcode / Loose, tick several to
// make their codes (the ring, then print) or print their labels, tap one for its details; a scan opens the item or links the code;
// weigh & print; custom code (print, or save on an item).

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

Future<void> type(WidgetTester t, String key, String text) async {
  await t.enterText(find.byKey(ValueKey(key)), text);
  await t.pump(const Duration(milliseconds: 300));
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

  testWidgets('one page: every item listed with its code, the filters with their counts', (t) async {
    await open(t, Till());
    expect(find.text('Barcodes'), findsWidgets);
    for (final id in ['m1', 'm2', 'm9']) {
      expect(find.byKey(ValueKey('bc-item-$id')), findsOneWidget);
    }
    expect(find.text('2000000000015'), findsOneWidget);
    expect(find.text('No barcode yet'), findsNWidgets(2));
    expect(find.text('All (3)'), findsOneWidget);
    expect(find.text('No barcode (2)'), findsOneWidget);
    expect(find.text('Loose (1)'), findsOneWidget);
  });

  testWidgets('the search bar lists the matching items as you type, items with a code too; clear brings all back', (t) async {
    final till = Till();
    await open(t, till);
    await type(t, 'bc-search', 'coca');
    expect(sent(till, 'bc_list').last, {'tab': 'all', 'q': 'coca'});
    expect(find.byKey(const ValueKey('bc-item-m1')), findsOneWidget); // it has a code: still found
    expect(find.byKey(const ValueKey('bc-item-m2')), findsNothing);
    expect(t.widget<Text>(find.byKey(const ValueKey('bc-shown'))).data, '1 match');
    await type(t, 'bc-search', 'zzz');
    expect(find.text('No results found'), findsOneWidget);
    await tapKey(t, 'bc-search-clear');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('bc-item-m2')), findsOneWidget);
  });

  testWidgets('a search under No barcode that finds nothing offers all items', (t) async {
    final till = Till();
    await open(t, till);
    await tapKey(t, 'bc-filter-missing');
    expect(find.byKey(const ValueKey('bc-item-m1')), findsNothing);
    await type(t, 'bc-search', 'coca');
    await tapKey(t, 'bc-search-all');
    expect(sent(till, 'bc_list').last, {'tab': 'all', 'q': 'coca'});
    expect(find.byKey(const ValueKey('bc-item-m1')), findsOneWidget);
  });

  testWidgets('tap one: its details; make its code, then print with label type and copies', (t) async {
    final till = Till();
    await open(t, till);
    await tapKey(t, 'bc-item-m2');
    expect(find.text('Barcode Details'), findsOneWidget);
    await tapKey(t, 'details-make');
    expect(sent(till, 'bc_make').single['menu_item_id'], 'm2');
    expect(find.text('2000000000022'), findsWidgets);
    await t.pump(const Duration(seconds: 6)); // the toast has gone
    await tapKey(t, 'details-print-label');
    expect(find.text('Print Label'), findsOneWidget);
    await tapKey(t, 'print-type-large');
    await tapKey(t, 'copies-more');
    expect(t.widget<Text>(find.byKey(const ValueKey('copies-value'))).data, '2');
    await tapKey(t, 'print-label-go');
    expect(printed, ['Barcode labels']);
  });

  testWidgets('tick several: make the missing codes (the ring), then print them; the coded one prints straight away', (t) async {
    final till = Till();
    await open(t, till);
    await tapKey(t, 'bc-select-all');
    expect(t.widget<Text>(find.byKey(const ValueKey('bc-count'))).data, '3 items selected');
    expect(find.text('Make 2 codes'), findsOneWidget);
    expect(find.text('Print 1'), findsOneWidget);
    await tapKey(t, 'bc-make');
    expect(sent(till, 'bc_make').map((b) => b['menu_item_id']), ['m2', 'm9']);
    expect(t.widget<Text>(find.byKey(const ValueKey('bulk-progress'))).data, '2/2');
    await tapKey(t, 'bulk-print');
    expect(find.text('Print Labels'), findsOneWidget);
    expect(find.text('2 items have new barcodes.'), findsOneWidget);
    await tapKey(t, 'copies-more');
    await tapKey(t, 'print-label-go');
    expect(printed, ['Barcode labels']);
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('bc-count')), findsNothing); // the ticks are cleared
    await t.pump(const Duration(seconds: 6)); // the toast has gone
    await tapKey(t, 'bc-tick-m1');
    expect(find.text('Make 1 code'), findsNothing);
    await tapKey(t, 'bc-print');
    expect(find.text('Print Label'), findsOneWidget);
  });

  testWidgets('scan: a known code opens its item; an unknown one links it to the product you pick', (t) async {
    final real = scanForBarcodes;
    addTearDown(() => scanForBarcodes = real);
    final till = Till();
    await open(t, till);
    scanForBarcodes = (_) async => '8901262150019';
    await tapKey(t, 'bc-search-scan');
    expect(find.text('Barcode Details'), findsOneWidget);
    await t.pageBack();
    await t.pumpAndSettle();
    scanForBarcodes = (_) async => '8901000000001';
    await tapKey(t, 'bc-search-scan');
    expect(find.text('Link Barcode'), findsOneWidget);
    expect(find.text('8901000000001'), findsOneWidget);
    await type(t, 'link-search', 'coca');
    await tapKey(t, 'link-item-m1');
    await tapKey(t, 'link-confirm');
    expect([sent(till, 'bc_link').single['menu_item_id'], sent(till, 'bc_link').single['code']], ['m1', '8901000000001']);
    expect(find.text('Barcodes'), findsWidgets); // back on the page
  });

  testWidgets('loose: filter, tap one to weigh & print; the chips set the amount and the real weigh-label code', (t) async {
    final till = Till();
    await open(t, till);
    await tapKey(t, 'bc-filter-loose');
    expect(find.textContaining('PLU 00003'), findsOneWidget);
    await tapKey(t, 'bc-item-m9');
    await tapKey(t, 'weigh-chip-0.500');
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(t.widget<Text>(find.byKey(const ValueKey('weigh-total'))).data, rupees(45));
    expect(sent(till, 'bc_weigh_label').last, {'menu_item_id': 'm9', 'weight_g': 500});
    // a custom weight in grams: 300 g
    await tapKey(t, 'weigh-custom-unit-g');
    expect(t.widget<TextField>(find.byKey(const ValueKey('weigh-custom'))).controller!.text, '500');
    await t.enterText(find.byKey(const ValueKey('weigh-custom')), '300');
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(t.widget<Text>(find.byKey(const ValueKey('weigh-total'))).data, rupees(27));
    expect(sent(till, 'bc_weigh_label').last, {'menu_item_id': 'm9', 'weight_g': 300});
    await tapKey(t, 'weigh-print-label');
    expect(printed, ['Barcode labels']);
  });

  testWidgets('details: turn on Sold loose', (t) async {
    final till = Till();
    await open(t, till);
    await tapKey(t, 'bc-item-m2');
    await tapKey(t, 'details-loose');
    expect(sent(till, 'bc_set_loose').single, {'menu_item_id': 'm2', 'loose': true});
  });

  testWidgets('custom code: make one for me and print it; save on item → pick the product → saved', (t) async {
    final till = Till();
    await open(t, till);
    await tapKey(t, 'bc-custom');
    await tapKey(t, 'custom-print');
    expect(find.text('Type a code first.'), findsOneWidget);
    await tapKey(t, 'custom-mode-make');
    expect(find.text('2000000000039'), findsWidgets);
    await tapKey(t, 'custom-more');
    await tapKey(t, 'custom-print');
    expect(printed, ['Barcode labels']);
    await t.pump(const Duration(seconds: 6)); // the toast has gone
    await tapKey(t, 'custom-save');
    await type(t, 'pick-search', 'butter');
    expect(find.byKey(const ValueKey('pick-m1')), findsNothing);
    await tapKey(t, 'pick-m2');
    await tapKey(t, 'pick-confirm');
    expect([sent(till, 'bc_custom').last['code'], sent(till, 'bc_custom').last['menu_item_id']], ['2000000000039', 'm2']);
    expect(toast('2000000000039 saved on Amul Butter 500g.'), findsOneWidget);
    expect(find.byKey(const ValueKey('bc-search')), findsOneWidget); // back on the page
  });
}
