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
import 'package:vinii_pos/ui/wallet.dart';

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
      expect(jsonDecode(r.body), {'lines': [{'menu_item_id': 'm1', 'qty': 2}], 'method': 'cash', 'tendered': 2000});
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
    testWidgets('online orders sit in piles by where they are; counter bills are not here; cancelled is a small link', (t) async {
      final s = FakeServer((r) => ok({
            'orders': [
              card('1', 'pending', 'Pending', state: 'new', delivery: 'Awaiting acceptance · not dispatched'),
              card('2', 'pending', 'Pending', state: 'new', delivery: 'Awaiting acceptance · not dispatched'),
              card('3', 'pending', 'Pending', state: 'ongoing', delivery: 'Picking · 2 of 5 units'),
              card('4', 'pending', 'Pending', state: 'ready', delivery: 'Ready · not handed over'),
              card('5', 'completed', 'Completed', state: 'delivered', delivery: 'Delivered · 5 of 5 units'),
              card('6', 'completed', 'Completed', state: 'return', delivery: 'Delivered · 5 of 5 units'),
              card('7', 'cancelled', 'Cancelled', state: 'cancelled'),
              card('8', 'pending', 'Pending', state: 'counter'), // a held counter bill
            ]
          }));
      await showTall(t, OrdersHome(api: s.api));
      expect(find.text('7 orders'), findsOneWidget); // the counter bill is not an online order
      for (final p in ['New orders · 2', 'In progress · 1', 'Packed · waiting for rider · 1', 'Return requested · 1', 'Delivered · 1']) {
        expect(find.text(p), findsOneWidget, reason: p);
      }
      expect(find.text('Cancelled · 1'), findsOneWidget);
      // the New orders pile comes first and fans out
      expect(t.getTopLeft(find.byKey(const ValueKey('orders-pile-new'))).dy, lessThan(t.getTopLeft(find.byKey(const ValueKey('orders-pile-delivered'))).dy));
      await t.tap(find.byKey(const ValueKey('orders-pile-new')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('order-card-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('order-card-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('order-card-3')), findsNothing);
      expect(find.text('Awaiting acceptance · not dispatched'), findsNWidgets(2));
      // cards one after another, none covering the next; a back arrow with the pile's name
      expect(t.getRect(find.byKey(const ValueKey('order-card-2'))).top, greaterThanOrEqualTo(t.getRect(find.byKey(const ValueKey('order-card-1'))).bottom));
      expect(find.text('New orders · 2'), findsOneWidget);
      // the customer leads, in the pile's colour; the order number is small
      final name = t.widget<Text>(find.descendant(of: find.byKey(const ValueKey('order-card-1')), matching: find.text('Rahul Mehta')));
      expect(name.style?.color, WalletColors.orange.first);
      expect(find.descendant(of: find.byKey(const ValueKey('order-card-1')), matching: find.textContaining('#P-1 ·')), findsOneWidget);
      expect(find.text('Waiting for you to accept'), findsOneWidget);
      // the phone's back button closes the pile first
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('orders-piles')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('orders-pile-new')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('order-card-1')));
      await t.pumpAndSettle();
      expect(find.text('View details'), findsOneWidget);
      // another pile from the tabs on top
      await t.ensureVisible(find.byKey(const ValueKey('orders-tab-return')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('orders-tab-return')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('order-card-6')), findsOneWidget);
      expect(find.textContaining('Return requested ·'), findsWidgets);
      // back, then the cancelled link
      await t.tap(find.byKey(const ValueKey('orders-all-piles')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('orders-cancelled')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('order-card-7')), findsOneWidget);
      expect(find.byKey(const ValueKey('order-card-8')), findsNothing);
    });

    testWidgets('an older server without states: orders are still placed (completed → Delivered, otherwise In progress)', (t) async {
      final s = FakeServer((r) => ok({'orders': [card('1', 'pending', 'Pending'), card('3', 'completed', 'Completed')]}));
      await showTall(t, OrdersHome(api: s.api));
      expect(find.text('In progress · 1'), findsOneWidget);
      expect(find.text('Delivered · 1'), findsOneWidget);
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
      await t.tap(find.byKey(const ValueKey('orders-pile-ongoing')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(ValueKey('order-card-$orderId')));
      await t.pumpAndSettle();
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
          'lines': [{'menu_item_id': 'm1', 'amount': 640}, {'menu_item_id': 'm2', 'amount': 280}],
        };

    testWidgets('shows server totals, then checks out with cash tendered and one key', (t) async {
      final s = FakeServer((r) => r.url.path.endsWith('/quote') ? ok(quote()) : ok(view('pending')));
      await showTall(t, CartScreen(api: s.api, initialLines: [for (final l in lines) CartLine(menuItemId: l.menuItemId, name: l.name, qty: l.qty)]));
      expect(find.text('Cart'), findsOneWidget);
      expect(find.text('Draft · not placed'), findsOneWidget);
      expect(find.text('₹1,058'), findsOneWidget);
      expect(find.text('₹640'), findsOneWidget);
      expect(jsonDecode(s.where('POST', '/quote').first.body), {'lines': [{'menu_item_id': 'm1', 'qty': 2}, {'menu_item_id': 'm2', 'qty': 1}]});

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
      ('pending', 'Order Confirmation', 'Accept order', 'Send receipt on WhatsApp'),
      ('preparing', 'Order Preparing', 'Pack order', 'Something missing?'),
      ('picked', 'Order Picked', 'Pack order', 'Something missing?'),
      ('ready', 'Order Ready', 'Customer collected it', 'Send for delivery'),
      ('in_transit', 'Order In Transit', 'Mark delivered', 'Report a delivery problem'),
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

    testWidgets('a new order: Accept order accepts it straight away, with the steps on top', (t) async {
      final s = FakeServer((r) => r.method == 'GET' ? ok(view('pending', version: 1)) : ok(view('preparing', version: 2)));
      await showTall(t, OrderScreen(api: s.api, orderId: orderId));
      expect(find.byKey(const ValueKey('order-step-0')), findsOneWidget);
      expect(find.text('Hand over'), findsOneWidget);
      await t.tap(find.text('Accept order'));
      await t.pumpAndSettle();
      final post = s.where('POST', '/act').single;
      expect(jsonDecode(post.body), {'action': 'accept', 'version': 1});
      expect(post.headers['Idempotency-Key'], startsWith('pos-'));
      expect(find.text('Pack order'), findsOneWidget);
    });

    testWidgets('a version conflict reloads the order and says why', (t) async {
      var gets = 0;
      final s = FakeServer((r) {
        if (r.method == 'GET') return ok(view(gets++ == 0 ? 'ready' : 'in_transit'));
        return err(409, 'This order was changed on another device.', 'version_conflict');
      });
      await showTall(t, OrderScreen(api: s.api, orderId: orderId));
      await t.tap(find.text('Customer collected it'));
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
      final s = FakeServer((_) => ok(view('completed')));
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
