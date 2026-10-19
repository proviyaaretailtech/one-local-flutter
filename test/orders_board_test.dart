// Orders tab (specs/orders-live-hold): Live orders, the Zomato / Swiggy views, Hold orders, Resume POS on the same order, Cancel with a reason.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:vinii_pos/orders/cart_screen.dart';
import 'package:vinii_pos/orders/orders_api.dart';
import 'package:vinii_pos/orders/orders_board_screen.dart';
import 'package:vinii_pos/orders/orders_outlet_header.dart';

import 'helpers.dart';
import 'order_fixtures.dart';
import 'orders_test.dart' show FakeServer, ok, err, showTall;

const heldId = '22222222-2222-4222-8222-222222222222';
const v1 = '2026-10-20T12:00:00.123456+00:00', v2 = '2026-10-20T12:05:00.654321+00:00';

Map<String, dynamic> board({String channel = 'all', String status = 'new', List<Map<String, dynamic>> orders = const [], bool zomatoOnline = false}) => {
      'header': {'business': 'Niks Browni And Burger', 'outlet': 'Main', 'accepting': true},
      'channel': channel,
      'status': status,
      'counts': {'new': 6, 'preparing': 8, 'ready': 4, 'dispatched': 0, 'completed': 24},
      'channels': [for (final k in ['all', 'dine_in', 'takeaway', 'delivery', 'zomato', 'swiggy']) {'key': k, 'live': k == 'all' ? 18 : 0}],
      'integrations': [
        {'channel': 'zomato', 'name': 'Zomato', 'listed': true, 'connected': zomatoOnline, 'state': zomatoOnline ? 'online' : 'offline', 'reason': zomatoOnline ? null : 'not_connected'},
        {'channel': 'swiggy', 'name': 'Swiggy', 'listed': false, 'connected': false, 'state': 'offline', 'reason': 'not_connected'},
      ],
      'orders': orders,
      'prep_minutes': 20,
    };

Map<String, dynamic> live(String id, String no, String status, int minutes, {bool delayed = false, String customer = 'Rahul Sharma', String? note, num total = 420}) => {
      'order_id': id, 'display_no': no, 'placed_at': '2026-10-20T12:53:00Z', 'customer': customer, 'items': '1× Margherita Pizza, 1× Garlic Bread',
      'note': note, 'channel': 'takeaway', 'channel_tag': null, 'external_id': null, 'table': null, 'status': status, 'minutes': minutes, 'delayed': delayed, 'total': total,
    };

Map<String, dynamic> holds({bool delayed = true, List<Map<String, dynamic>>? rows}) => {
      'delayed_after_minutes': 15,
      'oldest': {'order_id': heldId, 'display_no': 'P-00012', 'minutes': 45, 'delayed': delayed},
      'count': 1,
      'holds': rows ??
          [
            {
              'order_id': heldId, 'display_no': 'P-00012', 'channel': 'takeaway', 'source': 'Takeaway · Counter', 'customer': 'Guest',
              'reason': 'Customer waiting for group head before ordering mains', 'items': '1× Garlic Bread, 1× Coke', 'note': null, 'total': 189,
              'held_at': '2026-10-20T12:00:00Z', 'minutes': 45, 'delayed': delayed, 'resumed': 0, 'has_coupon': false, 'version': v1,
            },
          ],
    };

/// The held bill as `GET /pos-orders/:id` answers (stage checkout, two lines).
Map<String, dynamic> heldView() => {
      ...view('checkout'),
      'id': heldId,
      'display_no': 'P-00012',
      'version': v1,
      'items': [
        {'order_item_id': 'oi1', 'menu_item_id': 'm1', 'name': 'Garlic Bread', 'qty': 1, 'amount': 120, 'sub': ''},
        {'order_item_id': 'oi2', 'menu_item_id': 'm2', 'name': 'Coke', 'qty': 1, 'amount': 60, 'sub': ''},
      ],
    };

Map<String, dynamic> quote(int coke) => {
      'subtotal': 120 + 60 * coke, 'gst_pct': 5, 'gst_amount': 0, 'service_charge': 0, 'discount': 0, 'round_off': 0, 'total': 120 + 60 * coke,
      'lines': [{'menu_item_id': 'm1', 'amount': 120}, {'menu_item_id': 'm2', 'amount': 60 * coke}],
    };

Map<String, dynamic> body(http.Request r) => (jsonDecode(r.body) as Map).cast<String, dynamic>();

/// A fake server for the whole tab: the board, the hold list, one held order, quote, pay, cancel and pos_hold_update.
FakeServer tabServer({Map<String, dynamic> Function(Map<String, dynamic> args)? boardFor, Map<String, dynamic>? holdList}) => FakeServer((r) {
      final p = r.url.path;
      if (p.endsWith('/rpc/pos_orders_board')) return ok((boardFor ?? (a) => board(channel: a['channel'] ?? 'all', status: a['status'] ?? 'new'))(body(r)));
      if (p.endsWith('/rpc/pos_hold_list')) return ok(holdList ?? holds());
      if (p.endsWith('/rpc/pos_hold_update')) return ok({'order_id': heldId, 'updated_at': v2, 'changed': true, 'replayed': false});
      if (p.endsWith('/quote')) return ok(quote(((body(r)['lines'] as List).last as Map)['qty'] as int));
      if (p.endsWith('/$heldId/pay')) return ok({...view('pending'), 'id': heldId, 'display_no': 'P-00012'});
      if (p.endsWith('/$heldId/cancel')) return ok({...view('cancelled'), 'id': heldId});
      if (p.endsWith('/$heldId') && r.method == 'GET') return ok(heldView());
      return err(404, 'not in this fake: $p');
    });

Future<void> tapChip(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey(key)));
}

Future<void> openTab(WidgetTester t, FakeServer s, {String tab = 'live'}) =>
    showTall(t, OrdersBoardScreen(api: s.api, initialTab: tab, poll: Duration.zero));

void main() {
  group('OrdersApi (Orders tab)', () {
    test('board and hold list go through the gateway door with the token; resume sends lines, version and the key', () async {
      final s = tabServer();
      final b = await s.api.board(channel: 'zomato', status: 'preparing', q: ' Aarav ');
      expect(s.requests.last.url.toString(), 'http://pos.test/rpc/pos_orders_board');
      expect(s.requests.last.headers['Authorization'], 'Bearer token-123');
      expect(body(s.requests.last), {'channel': 'zomato', 'status': 'preparing', 'q': 'Aarav'});
      expect(b.business, 'Niks Browni And Burger');
      expect(b.count('completed'), 24);
      expect(b.integration('zomato')!.online, isFalse);
      final h = await s.api.holds();
      expect(h.holds.single.reason, startsWith('Customer waiting'));
      final v = await s.api.updateHold(heldId, lines: [CartLine(menuItemId: 'm2', name: 'Coke', qty: 2)], version: v1, key: 'pos-k1');
      final u = s.requests.last;
      expect(u.url.path, '/rpc/pos_hold_update');
      expect(u.headers['Idempotency-Key'], 'pos-k1');
      expect(body(u), {'order_id': heldId, 'expected_updated_at': v1, 'lines': [{'menu_item_id': 'm2', 'qty': 2}], 'idempotency_key': 'pos-k1'});
      expect(v, v2);
    });

    test('Save & Hold sends the reason only when there is one', () async {
      final s = FakeServer((_) => ok(view('checkout')));
      await s.api.hold(lines: [CartLine(menuItemId: 'm1', name: 'x')], key: 'pos-h', reason: '  UPI pending ');
      expect(body(s.requests.last), {'lines': [{'menu_item_id': 'm1', 'qty': 1}], 'reason': 'UPI pending'});
      await s.api.hold(lines: [CartLine(menuItemId: 'm1', name: 'x')], key: 'pos-h2', reason: ' ');
      expect(body(s.requests.last).containsKey('reason'), isFalse);
    });
  });

  test('outlet header initials', () {
    expect(OrdersOutletHeader.initials('Niks Browni And Burger'), 'NB');
    expect(OrdersOutletHeader.initials('Dosa'), 'DO');
    expect(OrdersOutletHeader.initials(''), '·');
  });

  group('Live orders', () {
    testWidgets('header, tabs, chips with live counts, cards with status minutes and Delayed', (t) async {
      final s = tabServer(boardFor: (a) => board(orders: [
            live('o1', 'P-01086', 'new', 5, note: 'Less spicy'),
            live('o2', 'P-01085', 'new', 28, delayed: true, customer: 'Walk-in Guest', total: 820),
          ]));
      await openTab(t, s);
      expect(find.text('Niks Browni And Burger'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('NB'), findsOneWidget);
      expect(find.text('Live orders'), findsOneWidget);
      expect(find.text('Hold orders'), findsOneWidget);
      for (final c in ['All', 'Dine In', 'Takeaway', 'Delivery', 'Zomato', 'Swiggy']) {
        expect(find.text(c), findsOneWidget);
      }
      expect(find.text('New (6)'), findsOneWidget);
      expect(find.text('Preparing (8)'), findsOneWidget);
      expect(find.text('Ready (4)'), findsOneWidget);
      expect(find.text('Completed (24)'), findsOneWidget);
      expect(find.textContaining('Dispatched'), findsNothing); // not on All while none are dispatched
      expect(find.text('#P-01086'), findsOneWidget);
      expect(find.text('Rahul Sharma'), findsOneWidget);
      expect(find.text('1× Margherita Pizza, 1× Garlic Bread'), findsNWidgets(2));
      expect(find.text('Order note · Less spicy'), findsOneWidget);
      expect(find.text('Order note · No custom note'), findsOneWidget);
      expect(find.text('New (5m)'), findsOneWidget);
      expect(find.text('Delayed (28m)'), findsOneWidget);
      expect(find.text('₹820'), findsOneWidget);
      expect(body(s.where('POST', '/rpc/pos_orders_board').first), {'channel': 'all', 'status': 'new'});
    });

    testWidgets('picking a status and a channel asks the database again; Delivery shows Dispatched', (t) async {
      final s = tabServer();
      await openTab(t, s);
      await t.tap(find.text('Preparing (8)'));
      await t.pumpAndSettle();
      expect(body(s.requests.last)['status'], 'preparing');
      await tapChip(t, 'channel-delivery');
      await t.pumpAndSettle();
      expect(body(s.requests.last), {'channel': 'delivery', 'status': 'preparing'});
      expect(find.text('Dispatched (0)'), findsOneWidget);
    });

    testWidgets('empty: All Caught Up! and New Order opens the Bill', (t) async {
      final s = FakeServer((r) => r.url.path.endsWith('/rpc/pos_orders_board') ? ok(board(status: 'preparing')) : ok(quote(1)));
      await openTab(t, s);
      await t.tap(find.text('Preparing (8)'));
      await t.pumpAndSettle();
      expect(find.text('All Caught Up!'), findsOneWidget);
      expect(find.text('No orders are currently being prepared.'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('new-order')));
      await t.pumpAndSettle();
      expect(find.byType(CartScreen), findsOneWidget);
      expect(find.text('Cart · new bill'), findsOneWidget);
    });

    testWidgets('Zomato: the banner reads OFFLINE / Not connected from the database, and no order is invented', (t) async {
      final s = tabServer();
      await openTab(t, s);
      await tapChip(t, 'channel-zomato');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('integration-banner')), findsOneWidget);
      expect(find.text('Zomato Integration'), findsOneWidget);
      expect(find.text('OFFLINE'), findsOneWidget);
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text('Zomato is not connected'), findsOneWidget);
      expect(find.text('Search Zomato orders...'), findsOneWidget);
      expect(find.text('Dispatched (0)'), findsOneWidget);
      expect(find.byKey(const ValueKey('live-o1')), findsNothing);
      await tapChip(t, 'channel-swiggy');
      await t.pumpAndSettle();
      expect(find.text('Swiggy Integration'), findsOneWidget);
      expect(find.text('OFFLINE'), findsOneWidget);
    });

    testWidgets('Zomato connected: ONLINE, cards carry the channel tag and the external id', (t) async {
      final s = tabServer(boardFor: (a) => board(channel: 'zomato', zomatoOnline: true, orders: [
            {...live('z1', 'P-00090', 'new', 5, customer: 'Aarav Mehta', total: 960), 'channel': 'zomato', 'channel_tag': 'Zomato', 'external_id': 'ZOM-9921'},
          ]));
      await openTab(t, s);
      await tapChip(t, 'channel-zomato');
      await t.pumpAndSettle();
      expect(find.text('ONLINE'), findsOneWidget);
      expect(find.text('Zomato'), findsNWidgets(2)); // the chip and the card tag
      expect(find.text('#ZOM-9921'), findsOneWidget);
      expect(find.text('Aarav Mehta'), findsOneWidget);
    });

    testWidgets('a failed load says so and retries', (t) async {
      var n = 0;
      final s = FakeServer((r) => ++n == 1 ? err(503, 'The database is not connected yet.') : ok(board()));
      await openTab(t, s);
      expect(find.text('The database is not connected yet.'), findsOneWidget);
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(find.text('All Caught Up!'), findsOneWidget);
    });
  });

  group('Hold orders', () {
    testWidgets('oldest-hold alert, search, card with reason, items, note, Delayed badge and both actions', (t) async {
      final s = tabServer();
      await openTab(t, s, tab: 'hold');
      expect(find.text('Oldest hold: 45 min ago (#P-00012) requires attention.'), findsOneWidget);
      expect(find.text('Search held orders...'), findsOneWidget);
      expect(find.textContaining('#P-00012'), findsWidgets);
      expect(find.text('Customer waiting for group head before ordering mains'), findsOneWidget);
      expect(find.text('1× Garlic Bread, 1× Coke'), findsOneWidget);
      expect(find.text('Delayed (45m)'), findsOneWidget);
      expect(find.text('Cancel Order'), findsOneWidget);
      expect(find.text('Resume POS'), findsOneWidget);
      expect(find.byKey(const ValueKey('new-order')), findsNothing);
    });

    testWidgets('a fresh hold reads New and no alert is shown', (t) async {
      final h = holds(delayed: false);
      (h['holds'] as List).first['minutes'] = 4;
      final s = tabServer(holdList: h);
      await openTab(t, s, tab: 'hold');
      expect(find.byKey(const ValueKey('oldest-hold')), findsNothing);
      expect(find.text('New'), findsOneWidget);
    });

    testWidgets('no holds: an honest empty state', (t) async {
      final s = tabServer(holdList: {'delayed_after_minutes': 15, 'oldest': null, 'count': 0, 'holds': []});
      await openTab(t, s, tab: 'hold');
      expect(find.text('No bills on hold'), findsOneWidget);
    });

    testWidgets('Cancel Order needs a reason, then cancels with the bill version', (t) async {
      final s = tabServer();
      await openTab(t, s, tab: 'hold');
      await t.tap(find.text('Cancel Order'));
      await t.pumpAndSettle();
      expect(find.text('Cancel #P-00012?'), findsOneWidget);
      await t.tap(find.text('Cancel bill'));
      await t.pumpAndSettle();
      expect(s.where('POST', '/cancel'), isEmpty); // disabled without a reason
      await t.enterText(find.byKey(const ValueKey('cancel-reason')), 'Customer left');
      await t.pump();
      await t.tap(find.text('Cancel bill'));
      await t.pumpAndSettle();
      final c = s.where('POST', '/$heldId/cancel').single;
      expect(body(c), {'reason': 'Customer left', 'version': v1});
      expect(toast('#P-00012 cancelled.'), findsOneWidget);
    });

    testWidgets('Resume POS opens the held bill in the cart; a change is written to the SAME order, then paid on it', (t) async {
      final s = tabServer();
      await openTab(t, s, tab: 'hold');
      await t.tap(find.text('Resume POS'));
      await t.pumpAndSettle();
      expect(find.byType(CartScreen), findsOneWidget);
      expect(find.text('Cart · held bill #P-00012'), findsOneWidget);
      expect(find.text('Garlic Bread'), findsOneWidget);
      expect(find.text('Coke'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('One more Coke'));
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Proceed to Checkout'));
      await t.pumpAndSettle();
      expect(find.text('Checkout · held bill #P-00012'), findsOneWidget);
      await t.tap(find.text('UPI / QR'));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Complete Payment'));
      await t.pumpAndSettle();
      final u = s.where('POST', '/rpc/pos_hold_update').single;
      expect(body(u)['order_id'], heldId);
      expect(body(u)['expected_updated_at'], v1);
      expect(body(u)['lines'], [{'menu_item_id': 'm1', 'qty': 1}, {'menu_item_id': 'm2', 'qty': 2}]);
      final p = s.where('POST', '/$heldId/pay').single;
      expect(body(p)['version'], v2); // the version pos_hold_update answered
      expect(body(p)['method'], 'upi');
      expect(u.headers['Idempotency-Key'], '${p.headers['Idempotency-Key']}:lines');
      expect(s.where('POST', '/checkout'), isEmpty); // never placed again as a new order
      expect(s.where('POST', '/hold'), isEmpty);
      expect(find.text('Order Confirmation'), findsOneWidget);
    });

    testWidgets('Resume POS without changes pays the held order directly', (t) async {
      final s = tabServer();
      await openTab(t, s, tab: 'hold');
      await t.tap(find.text('Resume POS'));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Proceed to Checkout'));
      await t.pumpAndSettle();
      await t.tap(find.text('Card'));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Complete Payment'));
      await t.pumpAndSettle();
      expect(s.where('POST', '/rpc/pos_hold_update'), isEmpty);
      expect(body(s.where('POST', '/$heldId/pay').single)['version'], v1);
    });

    testWidgets('Save & Hold from a resumed bill keeps the same order and updates the reason', (t) async {
      final s = tabServer();
      await openTab(t, s, tab: 'hold');
      await t.tap(find.text('Resume POS'));
      await t.pumpAndSettle();
      await t.tap(find.text('Save & Hold'));
      await t.pumpAndSettle();
      expect(find.text('Customer waiting for group head before ordering mains'), findsWidgets); // the sheet starts from the old reason
      await t.enterText(find.byKey(const ValueKey('hold-reason')), 'Mains after 8 PM');
      await t.tap(find.text('Hold bill'));
      await t.pumpAndSettle();
      final u = s.where('POST', '/rpc/pos_hold_update').single;
      expect(body(u)['reason'], 'Mains after 8 PM');
      expect(body(u).containsKey('lines'), isFalse);
      expect(s.where('POST', '/hold'), isEmpty);
      expect(find.byType(OrdersBoardScreen), findsOneWidget); // back on the hold list
    });
  });
}
