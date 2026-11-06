// Restaurant All Orders (founder, 6 Nov 2026): every order, dine-in included, not only the store's online-order piles.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/orders/orders_api.dart';
import 'package:vinii_pos/restaurant/rst_all_orders_screen.dart';

import 'helpers.dart';

Map<String, dynamic> _card(String id, String channel, {String status = 'completed', String state = 'counter', String pay = 'Paid', String created = '2026-11-06T08:00:00+00:00'}) => {
      'id': id, 'display_no': 'P-$id', 'channel': channel, 'channel_label': channel == 'dine_in' ? 'Dine-in' : 'Store Checkout', 'created_at': created, 'customer': 'Guest',
      'placed_at': '06 Nov 2026 · 1:47 PM', 'status': status, 'status_label': status, 'total': 347, 'items': '2 lines · 2 units', 'payment_status': pay, 'state': state,
    };

http.Response _ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

({OrdersApi api, List<Uri> asked}) _server(http.Response Function(Uri u) answer) {
  final asked = <Uri>[];
  return (
    api: OrdersApi(baseUrl: 'http://pos.test', accessToken: () => 't', client: MockClient((r) async {
      asked.add(r.url);
      return answer(r.url);
    })),
    asked: asked,
  );
}

Future<void> _show(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 2400);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: screen));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('every order is listed, dine-in and counter bills too, each saying what kind it is', (t) async {
    final s = _server((_) => _ok({
          'orders': [
            _card('1', 'dine_in'),
            _card('2', 'pickup', status: 'pending', pay: 'Unpaid · ₹231 due'),
            _card('3', 'delivery', state: 'delivered'),
            _card('4', 'pickup', status: 'cancelled', state: 'cancelled', pay: 'Not captured'),
          ]
        }));
    await _show(t, RstAllOrdersScreen(api: s.api));
    for (final id in ['1', '2', '3', '4']) {
      expect(find.byKey(ValueKey('all-order-$id')), findsOneWidget, reason: id);
    }
    expect(find.text('Dine in · Guest'), findsOneWidget);
    expect(find.text('Takeaway · Guest'), findsNWidgets(2));
    expect(find.text('Delivery · Guest'), findsOneWidget);
    expect(find.text('Unpaid · ₹231 due'), findsOneWidget);
    expect(find.text('Cancelled'), findsNWidgets(2), reason: 'the filter and the cancelled order');
  });

  testWidgets('a filter asks the server for those orders; search sends what was typed', (t) async {
    final s = _server((_) => _ok({'orders': [_card('1', 'dine_in')]}));
    await _show(t, RstAllOrdersScreen(api: s.api));
    expect(s.asked.single.queryParameters['filter'], 'all');
    await t.tap(find.byKey(const ValueKey('all-orders-filter-pending')));
    await t.pumpAndSettle();
    expect(s.asked.last.queryParameters['filter'], 'pending');
    await t.enterText(find.byKey(const ValueKey('all-orders-search')), 'P-00005');
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(s.asked.last.queryParameters, containsPair('q', 'P-00005'));
    expect(s.asked.last.queryParameters['filter'], 'pending');
  });

  testWidgets('50 orders: Show more asks for the ones before the last, and adds them', (t) async {
    final s = _server((u) => _ok({
          'orders': u.queryParameters['before'] == null
              ? [for (var i = 0; i < 50; i++) _card('a$i', 'dine_in', created: '2026-11-06T08:00:${(59 - i).toString().padLeft(2, '0')}+00:00')]
              : [_card('old', 'pickup')]
        }));
    await _show(t, RstAllOrdersScreen(api: s.api));
    await t.scrollUntilVisible(find.byKey(const ValueKey('all-orders-more')), 400, scrollable: find.byType(Scrollable).first);
    await t.tap(find.byKey(const ValueKey('all-orders-more')));
    await t.pumpAndSettle();
    expect(s.asked.last.queryParameters['before'], '2026-11-06T08:00:10+00:00');
    expect(find.byKey(const ValueKey('all-orders-more')), findsNothing, reason: 'fewer than 50 came back: that is all of them');
    await t.scrollUntilVisible(find.byKey(const ValueKey('all-order-old')), 400, scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const ValueKey('all-order-old')), findsOneWidget);
  });

  testWidgets('fewer than 50: no Show more. None at all: says so. A failure can be tried again', (t) async {
    var fail = true;
    final s = _server((_) => fail ? http.Response(jsonEncode({'detail': 'The server is busy.'}), 500, headers: {'content-type': 'application/json'}) : _ok({'orders': []}));
    await _show(t, RstAllOrdersScreen(api: s.api));
    expect(find.byKey(const ValueKey('all-orders-error')), findsOneWidget);
    fail = false;
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(find.text('No orders yet.'), findsOneWidget);
    expect(find.byKey(const ValueKey('all-orders-more')), findsNothing);
  });
}
