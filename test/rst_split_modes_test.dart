// Split the bill Equally and By dish (founder, 3 Nov 2026), beside By payment method. The answers are what the database gave on the local
// test database (server/scripts/rst-payment-reference-e2e.mjs with FIXTURES=…): a ₹1,218 bill split equally between 3 guests (406 each), and
// an ₹840 bill split by dish (Thali ₹525 to Guest 1; Dosa and 2 coffees ₹315 to Guest 2).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/tables/bill_api.dart';
import 'package:vinii_pos/tables/bill_pay_screen.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/tables/bill_split_screen.dart';
import 'package:vinii_pos/tables/table_widgets.dart';
import 'package:vinii_pos/tables/tables_api.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/rst_split_modes_server.json').readAsStringSync()) as Map<String, dynamic>;
Map<String, dynamic> copy(String k) => jsonDecode(jsonEncode(fx[k])) as Map<String, dynamic>;
http.Response ok(Object? body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;
Map<String, dynamic> argsOf(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

/// [view] is `view_equal` or `view_dish`; after a split is saved the bill carries [split] (`split_equal` / `split_dish`).
class Fake {
  Fake(this.view, this.split);
  final String view, split;
  final requests = <http.Request>[];
  bool saved = false;
  Map<String, dynamic> get bill {
    final v = copy(view);
    if (saved) ((v['orders'] as List).first as Map)['split'] = copy(split);
    return v;
  }

  String get tableId => (copy(view)['table'] as Map)['id'] as String;
  String get orderId => ((copy(view)['orders'] as List).first as Map)['id'] as String;
  List<Map<String, dynamic>> get items => (((copy(view)['orders'] as List).first as Map)['items'] as List).cast<Map<String, dynamic>>();

  late final client = MockClient((r) async {
    requests.add(r);
    switch (fnOf(r)) {
      case 'rst_bill_view':
        return ok(bill);
      case 'rst_bill_split':
        saved = true;
        return ok(copy(split));
      case 'rst_bill_pay':
        return ok({'amount': 406, 'due': 812, 'method': 'card', 'part_label': 'Guest 1', 'order_paid': false, 'table_settled': false});
    }
    return http.Response(jsonEncode({'detail': 'not found'}), 404);
  });
  late final api = BillApi(baseUrl: 'http://bill.test', accessToken: () => 't', client: client);
  late final env = TablesEnv(api: TablesApi(baseUrl: 'http://bill.test', accessToken: () => 't', client: client));
  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
}

Future<void> open(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 4000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

Future<void> tapText(WidgetTester t, String text) async {
  await t.ensureVisible(find.text(text).last);
  await t.tap(find.text(text).last);
  await t.pumpAndSettle();
}

String textOf(WidgetTester t, String key) => (t.widget<Text>(find.byKey(ValueKey(key)))).data!;

void main() {
  testWidgets('Equally: 3 guests pay ₹406 each; sent as a split equally; each guest is then taken at Checkout', (t) async {
    final f = Fake('view_equal', 'split_equal');
    await open(t, BillSplitScreen(env: f.env, tableId: f.tableId, orderId: f.orderId, bill: f.api));
    expect(find.text('PAY BY'), findsOneWidget, reason: 'by payment method comes first');
    await tapKey(t, 'split-mode-equal');
    expect(find.text('SPLIT EQUALLY'), findsOneWidget);
    expect(textOf(t, 'guests-count'), '2');
    expect(textOf(t, 'equal-each'), '₹609');
    await tapKey(t, 'guests-plus');
    expect(textOf(t, 'equal-each'), '₹406');
    expect(find.text('Each guest pays at Checkout by cash, card or UPI. The table closes when every guest has paid.'), findsOneWidget);
    await tapKey(t, 'save-split');
    final a = argsOf(f.calls('rst_bill_split').single);
    expect([a['mode'], a['guests'], a['parts']], ['equal', 3, []]);
    for (var g = 1; g <= 3; g++) {
      expect(find.byKey(ValueKey('part-$g')), findsOneWidget);
    }
    expect(find.text('To be paid'), findsNWidgets(3));
    expect(find.byKey(const ValueKey('take-payment')), findsOneWidget);
    expect(find.text('Take payment · Guest 1 ₹406'), findsOneWidget);
  });

  testWidgets('Equally: the last guest takes the paise left over (₹1,218 between 9)', (t) async {
    final f = Fake('view_equal', 'split_equal');
    await open(t, BillSplitScreen(env: f.env, tableId: f.tableId, orderId: f.orderId, bill: f.api));
    await tapKey(t, 'split-mode-equal');
    for (var i = 0; i < 7; i++) {
      await tapKey(t, 'guests-plus');
    }
    expect(find.text('Guests 1–8 pay'), findsOneWidget);
    expect(textOf(t, 'equal-each'), '₹135.33');
    expect(textOf(t, 'equal-last'), '₹135.36', reason: '135.33 × 8 + 135.36 = 1,218');
    await tapKey(t, 'guests-minus');
    expect(textOf(t, 'equal-each'), '₹152.25');
    expect(find.byKey(const ValueKey('equal-last')), findsNothing, reason: '8 × 152.25 is the bill');
  });

  testWidgets('By dish: every dish to a guest, the share shown; sent with each guest\'s dishes; the guest\'s dishes on their part', (t) async {
    final f = Fake('view_dish', 'split_dish');
    await open(t, BillSplitScreen(env: f.env, tableId: f.tableId, orderId: f.orderId, bill: f.api));
    await tapKey(t, 'split-mode-item');
    expect(find.text('SPLIT BY DISH'), findsOneWidget);
    expect(find.text('2 × Coffee'), findsOneWidget);
    await tapKey(t, 'save-split');
    expect(find.text('Choose a guest for every dish.'), findsOneWidget);
    expect(f.calls('rst_bill_split'), isEmpty);
    for (final n in [0, 1, 2]) {
      await tapKey(t, 'dish-$n-guest-1');
    }
    await tapKey(t, 'save-split');
    expect(find.text('Guest 2 has no dish yet.'), findsOneWidget);
    await tapKey(t, 'dish-1-guest-2');
    await tapKey(t, 'dish-2-guest-2');
    expect(textOf(t, 'guest-share-1'), '₹525');
    expect(textOf(t, 'guest-share-2'), '₹315');
    await tapKey(t, 'save-split');
    final a = argsOf(f.calls('rst_bill_split').single);
    final id = {for (final i in f.items) i['name']: i['id']};
    expect(a['mode'], 'item');
    expect(a['parts'], [
      {'label': 'Guest 1', 'item_ids': [id['Thali']]},
      {'label': 'Guest 2', 'item_ids': [id['Dosa'], id['Coffee']]},
    ]);
    expect(find.text('Thali'), findsOneWidget);
    expect(find.text('Dosa, 2 × Coffee'), findsOneWidget);
  });

  testWidgets('Change split opens on the split there is (By dish, each dish with its guest)', (t) async {
    final f = Fake('view_dish', 'split_dish')..saved = true;
    await open(t, BillSplitScreen(env: f.env, tableId: f.tableId, orderId: f.orderId, bill: f.api));
    await tapText(t, 'Change split');
    expect(find.text('SPLIT BY DISH'), findsOneWidget);
    expect(textOf(t, 'guest-share-1'), '₹525');
    expect(textOf(t, 'guest-share-2'), '₹315');
  });

  testWidgets('a guest\'s part paid by UPI at Checkout carries the UTR', (t) async {
    final f = Fake('view_equal', 'split_equal')..saved = true;
    final part = (copy('split_equal')['parts'] as List).first as Map<String, dynamic>;
    await open(t, BillPayScreen(env: f.env, tableId: f.tableId, bill: f.api, part: Facts({...part, 'order_id': f.orderId})));
    await tapKey(t, 'method-UPI / QR');
    await tapText(t, 'Complete Payment · Guest 1');
    expect(find.text('Enter the UPI reference: the UTR or transaction id the guest\'s app shows.'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('bill-reference')), '431298765012');
    await tapText(t, 'Complete Payment · Guest 1');
    await tapKey(t, 'confirm-yes');
    final a = argsOf(f.calls('rst_bill_pay').single);
    expect([a['part_id'], a['method'], a['reference']], [part['id'], 'upi', '431298765012']);
  });
}
