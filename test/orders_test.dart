import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/orders/cart_screen.dart';
import 'package:vinii_pos/orders/order_screen.dart';
import 'package:vinii_pos/orders/orders_api.dart';
import 'package:vinii_pos/orders/orders_home.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';
import 'order_fixtures.dart';

/// Fake server: records each request and answers from [handler].
class FakeServer {
  FakeServer(this.handler);
  final http.Response Function(http.Request r) handler;
  final requests = <http.Request>[];
  late final api = OrdersApi(
    baseUrl: 'http://pos.test',
    accessToken: () => 'token-123',
    client: MockClient((r) async {
      requests.add(r);
      return handler(r);
    }),
  );
  Iterable<http.Request> where(String method, String pathEnd) => requests.where((r) => r.method == method && r.url.path.endsWith(pathEnd));
}

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) =>
    http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> showTall(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 5600);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

void main() {
  group('OrdersApi', () {
    test('checkout sends the token, the idempotency key and only items and quantities', () async {
      final s = FakeServer((_) => ok(view('pending')));
      final v = await s.api.checkout(lines: [CartLine(menuItemId: 'm1', name: 'Amul Butter 500g', qty: 2)], method: 'cash', tendered: 2000, key: 'pos-abc12345');
      final r = s.requests.single;
      expect(r.url.toString(), 'http://pos.test/api/partner/pos-orders/checkout');
      expect(r.headers['Authorization'], 'Bearer token-123');
      expect(r.headers['Idempotency-Key'], 'pos-abc12345');
      expect(jsonDecode(r.body), {'lines': [{'menu_itemorderId': 'm1', 'qty': 2}], 'method': 'cash', 'tendered': 2000});
      expect(v.title, 'Order Confirmation');
    });

    test('server refusals keep their message and code', () async {
      final s = FakeServer((_) => err(409, 'This order was changed on another device.', 'version_conflict'));
      await expectLater(
        s.api.act(orderId, 'pack', version: 3),
        throwsA(isA<OrdersApiException>().having((e) => e.stale, 'stale', true).having((e) => e.message, 'message', 'This order was changed on another device.')),
      );
      expect(s.requests.single.headers['Idempotency-Key'], startsWith('pos-'));
    });

    test('history passes filter and search', () async {
      final s = FakeServer((_) => ok({'orders': []}));
      await s.api.history(filter: 'pending', q: ' rahul ');
      expect(s.requests.single.url.queryParameters, {'filter': 'pending', 'q': 'rahul'});
    });

    test('rupees uses Indian grouping', () {
      expect(rupees(1740), '₹1,740');
      expect(rupees(123456.5), '₹1,23,456.50');
      expect(rupees(980), '₹980');
      expect(rupees(-100), '-₹100');
    });

    test('new keys are unique and match the server shape', () {
      final a = OrdersApi.newKey(), b = OrdersApi.newKey();
      expect(a, isNot(b));
      expect(RegExp(r'^[\w:.-]{8,200}$').hasMatch(a), isTrue);
    });
  });

  group('OrdersHome (Orders History)', () {
    testWidgets('lists the server cards and refilters', (t) async {
      final s = FakeServer((r) => ok({
            'orders': r.url.queryParameters['filter'] == 'cancelled'
                ? [card('2', 'cancelled', 'Cancelled')]
                : [card('1', 'pending', 'Pending'), card('3', 'completed', 'Completed')]
          }));
      await showTall(t, OrdersHome(api: s.api));
      expect(find.text('Orders History'), findsOneWidget);
      expect(find.text('Order #P-1'), findsOneWidget);
      expect(find.text('Order #P-3'), findsOneWidget);
      expect(find.text('2 orders'), findsOneWidget);
      expect(find.text('Unpaid · ₹980 due'), findsNWidgets(2));
      expect(find.text('View details'), findsNWidgets(2));
      await t.tap(find.text('Cancelled').first);
      await t.pumpAndSettle();
      expect(s.requests.last.url.queryParameters['filter'], 'cancelled');
      expect(find.text('Order #P-2'), findsOneWidget);
      expect(find.text('Order #P-1'), findsNothing);
    });

    testWidgets('search waits for typing to stop', (t) async {
      final s = FakeServer((_) => ok({'orders': []}));
      await showTall(t, OrdersHome(api: s.api));
      await t.enterText(find.byType(TextField), 'P-1087');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(s.requests.last.url.queryParameters['q'], 'P-1087');
      expect(find.text('No orders match.'), findsOneWidget);
    });

    testWidgets('View details opens the order', (t) async {
      final s = FakeServer((r) => r.url.path.endsWith('/pos-orders') ? ok({'orders': [card(orderId, 'pending', 'Pending')]}) : ok(view('preparing')));
      await showTall(t, OrdersHome(api: s.api));
      await t.tap(find.text('View details'));
      await t.pumpAndSettle();
      expect(find.text('Order Preparing'), findsOneWidget);
    });
  });

  group('CartScreen', () {
    final lines = [
      CartLine(menuItemId: 'm1', name: 'Amul Butter 500g', qty: 2),
      CartLine(menuItemId: 'm2', name: 'Britannia Good Day 600g'),
    ];
    Map<String, dynamic> quote() => {
          'subtotal': 920, 'gst_pct': 5, 'gst_amount': 46, 'service_charge': 92, 'discount': 0, 'round_off': 0, 'total': 1058,
          'lines': [{'menu_itemorderId': 'm1', 'amount': 640}, {'menu_itemorderId': 'm2', 'amount': 280}],
        };

    testWidgets('shows server totals, then checks out with cash tendered and one key', (t) async {
      final s = FakeServer((r) => r.url.path.endsWith('/quote') ? ok(quote()) : ok(view('pending')));
      await showTall(t, CartScreen(api: s.api, initialLines: [for (final l in lines) CartLine(menuItemId: l.menuItemId, name: l.name, qty: l.qty)]));
      expect(find.text('Cart'), findsOneWidget);
      expect(find.text('Draft · not placed'), findsOneWidget);
      expect(find.text('₹1,058'), findsOneWidget);
      expect(find.text('₹640'), findsOneWidget);
      expect(jsonDecode(s.where('POST', '/quote').first.body), {'lines': [{'menu_itemorderId': 'm1', 'qty': 2}, {'menu_itemorderId': 'm2', 'qty': 1}]});

      await t.tap(find.text('Proceed to Checkout ₹1,058'));
      await t.pumpAndSettle();
      expect(find.text('Checkout'), findsOneWidget);
      expect(find.text('Not placed · payment check'), findsOneWidget);
      await t.tap(find.text('₹1,100'));
      await t.pumpAndSettle();
      expect(find.text('Confirm ₹1,100 received, settle ₹1,058 and return ₹42 change.'), findsOneWidget);

      await t.tap(find.text('Complete Payment ₹1,058'));
      await t.pumpAndSettle();
      final c = s.where('POST', '/checkout').single;
      expect(jsonDecode(c.body)['method'], 'cash');
      expect(jsonDecode(c.body)['tendered'], 1100);
      expect(c.headers['Idempotency-Key'], startsWith('pos-'));
      expect(find.text('Order Confirmation'), findsOneWidget);
    });

    testWidgets('a failed payment keeps the same key for the retry', (t) async {
      var attempts = 0;
      final s = FakeServer((r) {
        if (r.url.path.endsWith('/quote')) return ok(quote());
        attempts++;
        return attempts == 1 ? err(503, 'The database is not connected yet.') : ok(view('pending'));
      });
      await showTall(t, CartScreen(api: s.api, initialLines: [CartLine(menuItemId: 'm1', name: 'Amul Butter 500g')]));
      await t.tap(find.textContaining('Proceed to Checkout'));
      await t.pumpAndSettle();
      await t.tap(find.text('UPI / QR'));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Complete Payment'));
      await t.pumpAndSettle();
      expect(toast('The database is not connected yet.'), findsOneWidget);
      await t.tap(find.textContaining('Complete Payment'));
      await t.pumpAndSettle();
      final keys = s.where('POST', '/checkout').map((r) => r.headers['Idempotency-Key']).toList();
      expect(keys, hasLength(2));
      expect(keys[0], keys[1]);
      expect(jsonDecode(s.where('POST', '/checkout').last.body).containsKey('tendered'), isFalse);
    });

    testWidgets('quantity stepper requotes; coupon refusal is shown as the server says it', (t) async {
      final s = FakeServer((r) {
        final b = jsonDecode(r.body) as Map;
        if (b['coupon_code'] != null) return err(422, 'Coupons are not set up for this organization.', 'coupon_unknown');
        return ok(quote());
      });
      await showTall(t, CartScreen(api: s.api, initialLines: [CartLine(menuItemId: 'm1', name: 'Amul Butter 500g', qty: 2)]));
      await t.tap(find.bySemanticsLabel('One more Amul Butter 500g'));
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      expect(jsonDecode(s.requests.last.body)['lines'][0]['qty'], 3);
      await t.tap(find.text('Apply Coupon'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).last, 'WELCOME10');
      await t.tap(find.text('Apply'));
      await t.pumpAndSettle();
      expect(toast('Coupons are not set up for this organization.'), findsOneWidget);
      await t.tap(find.text('Add Tip'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      expect(toast('Tips are not set up for counter bills yet.'), findsOneWidget);
    });
  });

  group('OrderScreen', () {
    for (final (stage, title, primary, secondary) in const [
      ('checkout', 'Checkout', 'Complete Payment', 'Cancel bill'),
      ('pending', 'Order Confirmation', 'Print receipt', 'Send by WhatsApp'),
      ('preparing', 'Order Preparing', 'Open picking checklist', 'Report missing item'),
      ('picked', 'Order Picked', 'Start packing', 'Review picked quantities'),
      ('ready', 'Order Ready', 'Record handover', 'Arrange dispatch'),
      ('in_transit', 'Order In Transit', 'Check delivery status', 'Report delivery issue'),
      ('exception', 'Order Exception', 'Resolve missing information', 'Arrange store collection'),
      ('cancelled', 'Order Cancelled', 'Review cancellation', 'Create new cart from items'),
    ]) {
      testWidgets('$stage: shows what the server says', (t) async {
        final s = FakeServer((_) => ok(view(stage)));
        await showTall(t, OrderScreen(api: s.api, orderId: orderId));
        expect(find.text(title), findsOneWidget);
        expect(find.text(primary), findsOneWidget);
        expect(find.text(secondary), findsOneWidget);
        expect(find.text('Order #P-01087'), findsOneWidget);
        expect(find.text('5 lines · 9 units'), findsOneWidget);
        expect(find.text('₹1,840'), findsWidgets);
        if (stage == 'exception') {
          final style = t.widget<Text>(find.text('Order Exception')).style!;
          expect(style.color, const Color(0xFFB42318));
        }
        if (stage == 'pending') expect(find.text('Change returned'), findsOneWidget);
      });
    }

    testWidgets('Start packing sends the version and a key, then shows the new state', (t) async {
      final s = FakeServer((r) => r.method == 'GET' ? ok(view('picked', version: 4)) : ok(view('ready', version: 5)));
      await showTall(t, OrderScreen(api: s.api, orderId: orderId));
      await t.tap(find.text('Start packing'));
      await t.pumpAndSettle();
      final post = s.where('POST', '/act').single;
      expect(jsonDecode(post.body), {'action': 'pack', 'version': 4});
      expect(post.headers['Idempotency-Key'], startsWith('pos-'));
      expect(find.text('Order Ready'), findsOneWidget);
    });

    testWidgets('picking checklist sends every line with its picked quantity', (t) async {
      final s = FakeServer((r) => r.method == 'GET' ? ok(view('preparing')) : ok(view('picked', version: 3)));
      await showTall(t, OrderScreen(api: s.api, orderId: orderId));
      await t.tap(find.text('Open picking checklist'));
      await t.pumpAndSettle();
      await t.tap(find.byType(Checkbox).first);
      await t.pump();
      await t.tap(find.text('Save picked quantities'));
      await t.pumpAndSettle();
      final body = jsonDecode(s.where('POST', '/act').single.body) as Map;
      expect(body['action'], 'pick');
      expect((body['lines'] as List).first, {'order_itemorderId': '00000001-0000-0000-0000-000000000000', 'qty': 2});
      expect((body['lines'] as List), hasLength(5));
    });

    testWidgets('a version conflict reloads the order and says why', (t) async {
      var gets = 0;
      final s = FakeServer((r) {
        if (r.method == 'GET') return ok(view(gets++ == 0 ? 'ready' : 'in_transit'));
        return err(409, 'This order was changed on another device.', 'version_conflict');
      });
      await showTall(t, OrderScreen(api: s.api, orderId: orderId));
      await t.tap(find.text('Record handover'));
      await t.pumpAndSettle();
      expect(toast('This order was changed on another device.'), findsOneWidget);
      expect(find.text('Order In Transit'), findsOneWidget);
    });

    testWidgets('exception: delivery information goes to the server, which clears the block', (t) async {
      final s = FakeServer((r) => r.method == 'GET' ? ok(view('exception', version: 6)) : ok(view('ready', version: 7)));
      await showTall(t, OrderScreen(api: s.api, orderId: orderId));
      await t.tap(find.text('Resolve missing information'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('delivery-phone')), '9876543210');
      await t.enterText(find.byKey(const ValueKey('delivery-address')), '12 Main road, Latur');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      final body = jsonDecode(s.where('POST', '/act').single.body) as Map;
      expect(body['action'], 'set_delivery_info');
      expect(body['version'], 6);
      expect(body['delivery'], {'name': '', 'phone': '9876543210', 'address': '12 Main road, Latur'});
      expect(find.text('Order Ready'), findsOneWidget);
    });

    testWidgets('held bill: pay by cash sends the amount received', (t) async {
      final s = FakeServer((r) => r.method == 'GET' ? ok(view('checkout')) : ok(view('pending')));
      await showTall(t, OrderScreen(api: s.api, orderId: orderId));
      expect(find.text('Held · awaiting payment'), findsOneWidget);
      await t.tap(find.text('Complete Payment'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('pay-tender')), '2000');
      await t.tap(find.text('Complete Payment ₹1,840'));
      await t.pumpAndSettle();
      final post = s.where('POST', '/pay').single;
      expect(jsonDecode(post.body), {'method': 'cash', 'tendered': 2000, 'version': '2026-10-16T12:53:00.000Z'});
      expect(post.headers['Idempotency-Key'], startsWith('pos-'));
      expect(find.text('Order Confirmation'), findsOneWidget);
    });

    testWidgets('print says honestly that no printer is connected', (t) async {
      final s = FakeServer((_) => ok(view('pending')));
      await showTall(t, OrderScreen(api: s.api, orderId: orderId));
      await t.tap(find.text('Print receipt'));
      await t.pump();
      expect(toast('No receipt printer is connected to this device yet.'), findsOneWidget);
    });

    testWidgets('cancelled: create a new cart from the same items', (t) async {
      final s = FakeServer((r) => r.url.path.endsWith('/quote') ? ok({'subtotal': 1600, 'gst_pct': 5, 'gst_amount': 80, 'service_charge': 160, 'discount': 0, 'round_off': 0, 'total': 1840, 'lines': []}) : ok(view('cancelled')));
      await showTall(t, OrderScreen(api: s.api, orderId: orderId));
      expect(find.text('Not captured'), findsOneWidget);
      await t.tap(find.text('Create new cart from items'));
      await t.pumpAndSettle();
      expect(find.text('Draft · not placed'), findsOneWidget);
      expect((jsonDecode(s.where('POST', '/quote').single.body)['lines'] as List), hasLength(5));
    });
  });
}
