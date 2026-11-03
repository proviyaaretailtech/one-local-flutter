// A restaurant's takeaway and delivery bills at the restaurant Checkout (0649). The answers are what the database gave on the local test
// database (server/scripts/rst-counter-bill-e2e.mjs with FIXTURES=…): takeaway P-00001, Thali + Lassi, ₹525; a takeaway still on hold.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/orders/order_screen.dart';
import 'package:vinii_pos/orders/orders_api.dart';
import 'package:vinii_pos/tables/bill_api.dart';
import 'package:vinii_pos/tables/bill_pay_screen.dart';
import 'package:vinii_pos/tables/table_widgets.dart';
import 'package:vinii_pos/tables/tables_api.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';
import 'order_fixtures.dart';

final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/rst_counter_bill_server.json').readAsStringSync()) as Map<String, dynamic>;
Map<String, dynamic> copy(String k) => jsonDecode(jsonEncode(fx[k])) as Map<String, dynamic>;
http.Response ok(Object? body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.pathSegments.last;
Map<String, dynamic> argsOf(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

/// The restaurant Checkout's server: [view] is `view_takeaway` or `view_held`.
class FakeBill {
  FakeBill([this.view = 'view_takeaway']);
  final String view;
  final requests = <http.Request>[];
  late final api = BillApi(baseUrl: 'http://bill.test', accessToken: () => 't', client: MockClient((r) async {
    requests.add(r);
    return switch (fnOf(r)) {
      'rst_bill_view' => ok(copy(view)),
      'rst_bill_pay' => ok(copy('pay_last')),
      _ => http.Response(jsonEncode({'detail': 'not found'}), 404),
    };
  }));
  late final env = TablesEnv(api: TablesApi(baseUrl: 'http://bill.test', accessToken: () => 't', client: MockClient((_) async => ok({}))));
  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
  String get orderId => ((copy(view)['orders'] as List).firstOrNull as Map?)?['id'] as String? ?? (copy(view)['counter'] as Map)['order_id'] as String;
}

class _Shell implements TabShell {
  _Shell(this.kind);
  @override
  String kind;
  @override
  void setKind(String k) => kind = k;
  @override
  bool show(String label) => false;
}

Future<void> open(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 5600);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

Future<void> tapText(WidgetTester t, String text) async {
  await t.ensureVisible(find.text(text).last);
  await t.tap(find.text(text).last);
  await t.pumpAndSettle();
}

/// The order page of the takeaway, as the server shows a bill with no fulfilment: Checkout, Complete Payment.
Map<String, dynamic> takeawayView({String channel = 'pickup', Object? tableId}) => {...view('checkout'), 'channel': channel, 'table_id': tableId};

void main() {
  testWidgets('a takeaway bill opens by its order: "Takeaway #P-00001", its dishes, coupon, manual discount and Split Pay', (t) async {
    final f = FakeBill();
    await open(t, BillPayScreen(env: f.env, tableId: '', orderId: f.orderId, bill: f.api));
    expect(argsOf(f.calls('rst_bill_view').single), {'order_id': f.orderId}, reason: 'by its order: it has no table');
    expect(find.text('Takeaway #P-00001'), findsOneWidget);
    expect(find.text('CURRENT ITEMS (TAKEAWAY #P-00001)'), findsOneWidget);
    expect(find.text('1 × Thali'), findsOneWidget);
    expect(find.byKey(const ValueKey('bill-code')), findsOneWidget, reason: 'the coupon box');
    expect(find.byKey(const ValueKey('bill-manual-discount')), findsOneWidget);
    expect(find.text('Split Pay'), findsOneWidget);
  });

  testWidgets('paid by UPI with its UTR: the success says the bill is paid (not a table)', (t) async {
    final f = FakeBill();
    await open(t, BillPayScreen(env: f.env, tableId: '', orderId: f.orderId, bill: f.api));
    await tapText(t, 'UPI / QR');
    await t.enterText(find.byKey(const ValueKey('bill-reference')), 'UTR5150');
    await tapText(t, 'Complete Payment');
    await tapText(t, 'Yes, it is paid');
    final a = argsOf(f.calls('rst_bill_pay').single);
    expect([a['order_id'], a['method'], a['reference']], [f.orderId, 'upi', 'UTR5150']);
    expect(find.text('The bill is paid.'), findsOneWidget);
    expect(find.textContaining('table'), findsNothing);
  });

  testWidgets('a takeaway on hold says to send it to the kitchen first; nothing can be paid', (t) async {
    final f = FakeBill('view_held');
    await open(t, BillPayScreen(env: f.env, tableId: '', orderId: (copy('view_held')['counter'] as Map)['order_id'] as String, bill: f.api));
    expect(find.text('Send the order to the kitchen first.'), findsOneWidget);
    await tapText(t, 'Complete Payment');
    expect(f.calls('rst_bill_pay'), isEmpty);
  });

  group('the order page', () {
    late List<http.Request> orderCalls;
    OrdersApi ordersApi(Map<String, dynamic> v) {
      orderCalls = [];
      return OrdersApi(baseUrl: 'http://pos.test', accessToken: () => 't', client: MockClient((r) async {
        orderCalls.add(r);
        return ok(v);
      }));
    }

    testWidgets('a restaurant\'s takeaway: Complete Payment opens the restaurant Checkout, not the store pay sheet', (t) async {
      HomeNav.shell = _Shell('restaurant');
      addTearDown(() => HomeNav.shell = null);
      final f = FakeBill();
      await open(t, OrderScreen(api: ordersApi(takeawayView()), orderId: orderId, bill: f.api));
      await tapText(t, 'Complete Payment');
      expect(f.calls('rst_bill_view'), isNotEmpty);
      expect(argsOf(f.calls('rst_bill_view').first), {'order_id': orderId});
      expect(find.text('Takeaway #P-00001'), findsOneWidget);
      expect(find.byKey(const ValueKey('pay-tender')), findsNothing, reason: 'not the store pay sheet');
    });

    testWidgets('a restaurant\'s phone delivery: the same', (t) async {
      HomeNav.shell = _Shell('restaurant');
      addTearDown(() => HomeNav.shell = null);
      final f = FakeBill();
      await open(t, OrderScreen(api: ordersApi(takeawayView(channel: 'delivery')), orderId: orderId, bill: f.api));
      await tapText(t, 'Complete Payment');
      expect(f.calls('rst_bill_view'), isNotEmpty);
    });

    testWidgets('a store\'s held bill keeps the store pay sheet', (t) async {
      final f = FakeBill();
      await open(t, OrderScreen(api: ordersApi(takeawayView()), orderId: orderId, bill: f.api));
      await tapText(t, 'Complete Payment');
      expect(f.calls('rst_bill_view'), isEmpty);
      expect(find.byKey(const ValueKey('pay-tender')), findsOneWidget);
    });
  });
}
