// Orders tab (specs/orders-live-hold): Live orders, the Zomato / Swiggy views, Hold orders, Resume POS on the same order, Cancel with a reason.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/orders/cart_screen.dart';
import 'package:vinii_pos/orders/order_alerts.dart';
import 'package:vinii_pos/orders/orders_api.dart';
import 'package:vinii_pos/orders/order_screen.dart';
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
    testWidgets('every channel and status chip is fully on screen at phone width (none cut off at the edge)', (t) async {
      final s = tabServer(boardFor: (a) => board(orders: const []));
      await openTab(t, s);
      final width = t.view.physicalSize.width / t.view.devicePixelRatio;
      final chips = find.byWidgetPredicate((w) => w.key is ValueKey<String> &&
          RegExp(r'^(channel|status)-').hasMatch((w.key as ValueKey<String>).value));
      expect(chips, findsAtLeastNWidgets(10), reason: '6 channels and at least 4 statuses');
      for (final e in chips.evaluate()) {
        final r = t.getRect(find.byWidget(e.widget));
        expect(r.left, greaterThanOrEqualTo(0), reason: '${e.widget.key}');
        expect(r.right, lessThanOrEqualTo(width), reason: '${e.widget.key}');
      }
    });

    testWidgets('header, tabs, chips with live counts, cards with status minutes and Delayed', (t) async {
      final s = tabServer(boardFor: (a) => board(orders: [
            live('o1', 'P-01086', 'new', 5, note: 'Less spicy'),
            live('o2', 'P-01085', 'new', 28, delayed: true, customer: 'Walk-in Guest', total: 820),
          ]));
      await openTab(t, s);
      // The banner every main tab shows (OutletHeader): ONELOCAL PARTNER over the business; the outlet's status comes from the
      // outlets read (outlets_test.dart), not from the board.
      expect(find.text('ONELOCAL PARTNER'), findsOneWidget);
      expect(find.text('Niks Browni And Burger'), findsOneWidget);
      expect(find.text('Live orders'), findsNothing, reason: 'no Live / Hold switch any more');
      expect(find.text('Hold orders'), findsNothing);
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
      // the board's first load fails (the channel cards are a separate read, not counted)
      final s = FakeServer((r) => !r.url.path.endsWith('/rpc/pos_orders_board') ? err(404, 'no') : ++n == 1 ? err(503, 'The database is not connected yet.') : ok(board()));
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
      expect(find.text('Resume order'), findsOneWidget);
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

    testWidgets('Resume order opens the held bill in the cart; a change is written to the SAME order, then paid on it', (t) async {
      final s = tabServer();
      await openTab(t, s, tab: 'hold');
      await t.tap(find.text('Resume order'));
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

    testWidgets('Resume order without changes pays the held order directly', (t) async {
      final s = tabServer();
      await openTab(t, s, tab: 'hold');
      await t.tap(find.text('Resume order'));
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
      await t.tap(find.text('Resume order'));
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

  group('Channel cards (OneLocal, Swiggy, Zomato, On call)', () {
    Map<String, dynamic> sources() => {
          'channels': [
            {'key': 'onelocal', 'label': 'OneLocal', 'count': 2, 'open': 2, 'new': 1, 'total': 450, 'names': ['Priya (test)', 'Arjun (test)']},
            {'key': 'swiggy', 'label': 'Swiggy', 'count': 1, 'open': 1, 'new': 0, 'total': 320, 'names': ['Kiran (test)']},
            {'key': 'zomato', 'label': 'Zomato', 'count': 1, 'open': 0, 'new': 0, 'total': 210, 'names': ['Neha (test)']},
            {'key': 'on_call', 'label': 'On call delivery', 'count': 0, 'open': 0, 'new': 0, 'total': 0, 'names': []},
          ],
          'cancelled': 1,
          'orders': [
            {'id': 'o1', 'display_no': 'P-00031', 'placed_at': '2026-10-27T17:40:00Z', 'customer': 'Priya (test)', 'phone': '9800000101', 'total': 250, 'source': 'onelocal', 'stage': 'new', 'items': '2 × Cappuccino'},
            {'id': 'o2', 'display_no': 'P-00032', 'placed_at': '2026-10-27T17:30:00Z', 'customer': 'Arjun (test)', 'total': 200, 'source': 'onelocal', 'stage': 'on_way', 'items': '1 × Ice Blue'},
            {'id': 'o3', 'display_no': 'P-00033', 'placed_at': '2026-10-27T17:20:00Z', 'customer': 'Kiran (test)', 'total': 320, 'source': 'swiggy', 'stage': 'ready', 'items': '1 × Salted Fries', 'ref': 'SW-48213'},
            {'id': 'o4', 'display_no': 'P-00034', 'placed_at': '2026-10-27T16:20:00Z', 'customer': 'Neha (test)', 'total': 210, 'source': 'zomato', 'stage': 'delivered', 'items': '1 × Cappuccino', 'ref': 'ZO-77095'},
          ],
        };
    FakeServer withSources() => FakeServer((r) {
          final p = r.url.path;
          if (p.endsWith('/rpc/rst_channel_orders')) return ok(sources());
          if (p.endsWith('/rpc/pos_orders_board')) return ok(board());
          return err(404, 'not in this fake: $p');
        });

    testWidgets('delivery updates: Out for delivery asks the rider and minutes, sends them, and the order shows the rider; Delivered next', (t) async {
      final src = sources();
      final orders = (src['orders'] as List).cast<Map<String, dynamic>>();
      orders[0]
        ..['stage'] = 'ready'
        ..['customer'] = 'Priya (test)';
      final s = FakeServer((r) {
        final p = r.url.path;
        if (p.endsWith('/rpc/rst_channel_delivery')) {
          final b = jsonDecode(r.body) as Map<String, dynamic>;
          if (b['step'] == 'out') {
            orders[0]
              ..['stage'] = 'on_way'
              ..['delivery'] = {'stage': 'out', 'rider_name': b['rider_name'], 'rider_phone': b['rider_phone'], 'eta_minutes': b['eta_minutes']};
          }
          return ok({'message': 'P-00031 out for delivery with Ravi, about 15 min'});
        }
        if (p.endsWith('/rpc/rst_channel_orders')) return ok(src);
        if (p.endsWith('/rpc/pos_orders_board')) return ok(board());
        return err(404, 'not in this fake: $p');
      });
      final opened = <Uri>[];
      await showTall(t, OrdersBoardScreen(api: s.api, initialTab: 'live', poll: Duration.zero, openUrl: (u) async {
        opened.add(u);
        return true;
      }));
      await tapChip(t, 'channel-card-onelocal');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('deliver-track-P-00031')), findsOneWidget);
      expect(find.byKey(const ValueKey('deliver-filter-pending')), findsOneWidget);
      await tapChip(t, 'deliver-out-P-00031');
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('rider-name')), 'Ravi');
      await t.enterText(find.byKey(const ValueKey('rider-phone')), '98765 43210');
      await t.tap(find.byKey(const ValueKey('rider-eta-15')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('rider-go')));
      await t.pumpAndSettle();
      final sent = jsonDecode(s.where('POST', '/rpc/rst_channel_delivery').single.body) as Map<String, dynamic>;
      expect(sent, containsPair('step', 'out'));
      expect(sent, containsPair('rider_name', 'Ravi'));
      expect(sent, containsPair('rider_phone', '9876543210'));
      expect(sent, containsPair('eta_minutes', 15));
      expect(find.text('Ravi · +91 9876543210 · about 15 min'), findsOneWidget);
      expect(find.byKey(const ValueKey('deliver-delivered-P-00031')), findsOneWidget, reason: 'next: Delivered');
      // the customer hears where it is on WhatsApp
      await tapChip(t, 'deliver-notify-P-00031');
      await t.pumpAndSettle();
      expect(opened.single.path, '/919800000101');
      expect(opened.single.queryParameters['text'], contains('on its way with Ravi (+91 9876543210), reaching in about 15 min'));
      // the filter: only what is out for delivery
      await tapChip(t, 'deliver-filter-on_way');
      await t.pumpAndSettle();
      expect(find.text('Priya (test)'), findsOneWidget);
      expect(find.text('Arjun (test)'), findsOneWidget, reason: 'also on its way');
    });

    testWidgets('Delivered completes the order: money due at the door asks Cash / UPI / Card and sends it; a paid one does not ask', (t) async {
      final src = sources();
      final orders = (src['orders'] as List).cast<Map<String, dynamic>>();
      orders[1]
        ..['due'] = 200
        ..['prepaid'] = false; // Arjun, out for delivery, cash on delivery
      final s = FakeServer((r) {
        final p = r.url.path;
        if (p.endsWith('/rpc/rst_channel_delivery')) return ok({'message': 'P-00032 delivered, ₹200.00 collected by cash'});
        if (p.endsWith('/rpc/rst_channel_orders')) return ok(src);
        if (p.endsWith('/rpc/pos_orders_board')) return ok(board());
        return err(404, 'not in this fake: $p');
      });
      await openTab(t, s);
      await tapChip(t, 'channel-card-onelocal');
      await t.pumpAndSettle();
      await tapChip(t, 'deliver-delivered-P-00032');
      await t.pumpAndSettle();
      expect(find.text('Collect ₹200'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('paid-cash')));
      await t.pumpAndSettle();
      final sent = jsonDecode(s.where('POST', '/rpc/rst_channel_delivery').single.body) as Map<String, dynamic>;
      expect(sent, containsPair('step', 'delivered'));
      expect(sent, containsPair('payment_method', 'cash'));
    });

    testWidgets('Delivered on an order paid in the app does not ask how it was paid', (t) async {
      final src = sources();
      final orders = (src['orders'] as List).cast<Map<String, dynamic>>();
      orders[1]
        ..['due'] = 200
        ..['prepaid'] = true;
      final s = FakeServer((r) {
        final p = r.url.path;
        if (p.endsWith('/rpc/rst_channel_delivery')) return ok({'message': 'P-00032 delivered'});
        if (p.endsWith('/rpc/rst_channel_orders')) return ok(src);
        if (p.endsWith('/rpc/pos_orders_board')) return ok(board());
        return err(404, 'not in this fake: $p');
      });
      await openTab(t, s);
      await tapChip(t, 'channel-card-onelocal');
      await t.pumpAndSettle();
      await tapChip(t, 'deliver-delivered-P-00032');
      await t.pumpAndSettle();
      expect(find.textContaining('Collect'), findsNothing);
      expect(jsonDecode(s.where('POST', '/rpc/rst_channel_delivery').single.body) as Map, isNot(contains('payment_method')));
    });

    testWidgets('Delivery status asked for (from an order\'s page): the board opens that order\'s delivery list with the order opened and ringed', (t) async {
      final s = withSources();
      await openTab(t, s);
      expect(find.byKey(const ValueKey('channel-card-onelocal')), findsOneWidget, reason: 'the cards first');
      OrdersBoardScreen.requestedDelivery.value = (source: null, orderId: 'o2');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('channel-title')), findsOneWidget, reason: 'OneLocal\'s delivery list');
      expect(find.text('1 × Ice Blue'), findsOneWidget, reason: 'the order is opened');
      expect(find.byKey(const ValueKey('deliver-delivered-P-00032')), findsOneWidget, reason: 'its next step is right there');
      expect(OrdersBoardScreen.requestedDelivery.value, isNull, reason: 'shown once');
    });

    testWidgets('a source asked for (Home\'s delivery tile) opens its list', (t) async {
      final s = withSources();
      await openTab(t, s);
      OrdersBoardScreen.requestedDelivery.value = (source: 'swiggy', orderId: null);
      await t.pumpAndSettle();
      expect(find.text('Kiran (test)'), findsOneWidget);
      expect(find.text('Priya (test)'), findsNothing);
    });

    testWidgets('an order page\'s Check delivery status goes to the delivery list, not the courier sheet', (t) async {
      final s = FakeServer((r) => r.method == 'GET' ? ok(view('in_transit')) : err(404, 'not in this fake'));
      var asked = 0;
      await showTall(t, OrderScreen(api: s.api, orderId: 'o2', onDeliveryStatus: (_) => asked++));
      await t.tap(find.text('Mark delivered')); // a restaurant moves delivery orders on from the delivery list
      await t.pumpAndSettle();
      expect(asked, 1);
      expect(find.text('No courier tracking is connected. Confirm with the customer before closing the order.'), findsNothing);
    });

    testWidgets('an online order\'s Check delivery status (online_delivery) goes there too', (t) async {
      final online = view('in_transit')..['actions'] = [{'id': 'online_delivery', 'label': 'Check delivery status', 'style': 'primary'}];
      final s = FakeServer((r) => r.method == 'GET' ? ok(online) : err(404, 'not in this fake'));
      var asked = 0;
      await showTall(t, OrderScreen(api: s.api, orderId: 'o2', onDeliveryStatus: (_) => asked++));
      await t.tap(find.text('Check delivery status'));
      await t.pumpAndSettle();
      expect(asked, 1);
    });

    testWidgets('Swiggy: the rider is theirs, so after Ready the step is Picked up by rider; no Out for delivery, no customer message', (t) async {
      final s = withSources();
      await openTab(t, s);
      await tapChip(t, 'channel-card-swiggy');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('deliver-delivered-P-00033')), findsOneWidget);
      expect(find.text('Picked up by rider'), findsOneWidget);
      expect(find.byKey(const ValueKey('deliver-out-P-00033')), findsNothing);
      expect(find.byKey(const ValueKey('deliver-notify-P-00033')), findsNothing);
      expect(find.byKey(const ValueKey('deliver-filter-on_way')), findsNothing, reason: 'no Out for delivery filter for Swiggy');
    });

    testWidgets('four stacked cards above the counter orders: count, total, who, and the cancelled count', (t) async {
      final s = withSources();
      await openTab(t, s);
      for (final k in ['onelocal', 'swiggy', 'zomato', 'on_call']) {
        expect(find.byKey(ValueKey('channel-card-$k')), findsOneWidget, reason: k);
      }
      expect(find.text('OneLocal · 2'), findsOneWidget);
      expect(find.text('1 new · Priya (test), Arjun (test)'), findsOneWidget);
      expect(find.text('Swiggy · 1'), findsOneWidget);
      expect(find.text('All done · Neha (test)'), findsOneWidget);
      expect(find.text('On call delivery · 0'), findsOneWidget);
      expect(find.text('Cancelled · 1'), findsOneWidget);
      for (final k in ['onelocal', 'swiggy', 'zomato', 'on_call']) {
        expect(find.descendant(of: find.byKey(ValueKey('channel-card-$k')), matching: find.byKey(ValueKey('channel-logo-$k'))), findsOneWidget, reason: '$k logo on its card');
      }
      final cards = ['onelocal', 'swiggy', 'zomato', 'on_call'].map((k) => t.getRect(find.byKey(ValueKey('channel-card-$k'))).top).toList();
      expect(cards, [...cards]..sort(), reason: 'OneLocal, Swiggy, Zomato, On call, top to bottom');
      // only the cards: no list of orders and no channel or status pills under them
      expect(find.byKey(const ValueKey('channel-all')), findsNothing);
      expect(find.byKey(const ValueKey('status-new')), findsNothing);
      expect(find.text('Search order or customer...'), findsNothing);
    });

    testWidgets('a card opens its orders with the status and source; pills switch source; back returns to the cards', (t) async {
      final s = withSources();
      await openTab(t, s);
      await tapChip(t, 'channel-card-onelocal');
      await t.pumpAndSettle();
      expect(find.text('OneLocal · 2'), findsWidgets);
      expect(find.text('Priya (test)'), findsOneWidget);
      expect(find.text('New · waiting to accept'), findsOneWidget);
      expect(find.byKey(const ValueKey('channel-stage-P-00032')), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('channel-stage-P-00032'))).data, 'Out for delivery');
      expect(find.text('Kiran (test)'), findsNothing, reason: 'only OneLocal orders');
      await tapChip(t, 'channel-expand-P-00031');
      await t.pumpAndSettle();
      expect(find.text('2 × Cappuccino'), findsOneWidget);
      // the switcher is the four logos only, side by side
      for (final k in ['onelocal', 'swiggy', 'zomato', 'on_call']) {
        expect(find.descendant(of: find.byKey(ValueKey('channel-pill-$k')), matching: find.byType(Text)), findsNothing, reason: '$k: logo only');
        expect(find.descendant(of: find.byKey(ValueKey('channel-pill-$k')), matching: find.byKey(ValueKey('channel-logo-$k'))), findsOneWidget);
      }
      expect(t.getRect(find.byKey(const ValueKey('channel-pill-on_call'))).right, lessThanOrEqualTo(t.view.physicalSize.width / t.view.devicePixelRatio), reason: 'all four in view');
      await tapChip(t, 'channel-pill-swiggy');
      await t.pumpAndSettle();
      expect(find.text('Kiran (test)'), findsOneWidget);
      expect(find.text('Swiggy #SW-48213'), findsOneWidget);
      expect(find.text('Ready · waiting for rider'), findsOneWidget);
      await tapChip(t, 'channel-back');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('channel-card-zomato')), findsOneWidget);
    });

    testWidgets('KDS view and KOT view sit above the cards and open the kitchen display and the kitchen tickets', (t) async {
      final opened = <String>[];
      HomeNav.kitchenDisplay = (_) => opened.add('kds');
      HomeNav.kotView = (_) => opened.add('kot');
      addTearDown(HomeNav.reset);
      final s = withSources();
      await openTab(t, s);
      expect(find.text('KDS view'), findsOneWidget);
      expect(find.text('KOT view'), findsOneWidget);
      expect(t.getRect(find.byKey(const ValueKey('open-kds'))).bottom, lessThan(t.getRect(find.byKey(const ValueKey('channel-card-onelocal'))).top));
      await tapChip(t, 'open-kds');
      await t.pumpAndSettle();
      await tapChip(t, 'open-kot');
      await t.pumpAndSettle();
      expect(opened, ['kds', 'kot']);
    });

    group('accept within a minute', () {
      // P-00031 (OneLocal, new) was placed at 17:40:00; 20 seconds later it has 40 seconds left
      final placed = DateTime.utc(2026, 10, 27, 17, 40);
      FakeServer server({bool auto = false}) => FakeServer((r) {
            final p = r.url.path;
            if (p.endsWith('/rpc/rst_channel_orders')) return ok({...sources(), 'accept_window': 60, 'auto_accept': auto});
            if (p.endsWith('/rpc/rst_channel_accept')) return ok({'accepted': true});
            if (p.endsWith('/rpc/rst_auto_accept_set')) return ok({'auto_accept': body(r)['on']});
            if (p.endsWith('/rpc/pos_orders_board')) return ok(board());
            return err(404, 'not in this fake: $p');
          });

      testWidgets('a new order: the card shows the timer and the chime sounds once', (t) async {
        final sounds = _Sounds();
        final s = server();
        await showTall(t, OrdersBoardScreen(api: s.api, poll: Duration.zero, sounds: sounds, now: () => placed.add(const Duration(seconds: 20))));
        expect(find.descendant(of: find.byKey(const ValueKey('channel-timer-onelocal')), matching: find.text('Accept in 0:40')), findsOneWidget);
        expect(find.byKey(const ValueKey('channel-timer-swiggy')), findsNothing, reason: 'Swiggy has nothing new');
        expect(sounds.calls, ['arrive']);
        await tapChip(t, 'channel-card-onelocal');
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('channel-accept-in-P-00031')), findsOneWidget);
        expect(sounds.calls, ['arrive'], reason: 'the same order does not chime again');
      });

      testWidgets('the timer counts every second; the last 10 seconds sound the warning once; then it says late', (t) async {
        final sounds = _Sounds();
        var now = placed.add(const Duration(seconds: 48));
        final s = server();
        // the timers tick every second, so the screen never settles: frames are pumped by hand
        ignoreOverflow();
        t.view.physicalSize = const Size(780, 5600);
        t.view.devicePixelRatio = 2;
        addTearDown(t.view.reset);
        await t.pumpWidget(MaterialApp(home: OrdersBoardScreen(api: s.api, poll: const Duration(hours: 1), sounds: sounds, now: () => now)));
        for (var i = 0; i < 5; i++) {
          await t.pump(const Duration(milliseconds: 20));
        }
        expect(find.text('Accept in 0:12'), findsOneWidget);
        now = now.add(const Duration(seconds: 3));
        await t.pump(const Duration(seconds: 1));
        expect(find.text('Accept in 0:09'), findsOneWidget);
        expect(sounds.calls, ['arrive', 'warning']);
        now = now.add(const Duration(seconds: 1));
        await t.pump(const Duration(seconds: 1));
        expect(sounds.calls, ['arrive', 'warning'], reason: 'one warning per order');
        now = now.add(const Duration(seconds: 20));
        await t.pump(const Duration(seconds: 1));
        expect(find.text('Accept now · late'), findsOneWidget);
        await t.pumpWidget(const SizedBox()); // the screen goes, and its timers with it
      });

      testWidgets('Accept sends the order to the database; the auto-accept switch is saved there', (t) async {
        final s = server();
        await showTall(t, OrdersBoardScreen(api: s.api, poll: Duration.zero, sounds: _Sounds(), now: () => placed));
        expect(find.text('Auto-accept orders'), findsOneWidget);
        await tapChip(t, 'auto-accept');
        await t.pumpAndSettle();
        expect(body(s.where('POST', '/rpc/rst_auto_accept_set').single), {'on': true});
        await tapChip(t, 'channel-card-onelocal');
        await t.pumpAndSettle();
        await tapChip(t, 'channel-accept-P-00031');
        await t.pumpAndSettle();
        expect(body(s.where('POST', '/rpc/rst_channel_accept').single), {'order_id': 'o1'});
      });

      testWidgets('with auto-accept on, a new order is accepted by itself; with it off, it waits', (t) async {
        final on = server(auto: true);
        await showTall(t, OrdersBoardScreen(api: on.api, poll: Duration.zero, sounds: _Sounds(), now: () => placed));
        expect(body(on.where('POST', '/rpc/rst_channel_accept').first), {'order_id': 'o1', 'auto': true});
        await t.pumpWidget(const SizedBox());
        final off = server();
        await showTall(t, OrdersBoardScreen(api: off.api, poll: Duration.zero, sounds: _Sounds(), now: () => placed));
        expect(off.where('POST', '/rpc/rst_channel_accept'), isEmpty);
      });
    });

    testWidgets('without the channel read (an older server) the board shows as before', (t) async {
      final s = tabServer();
      await openTab(t, s);
      expect(find.byKey(const ValueKey('channel-card-swiggy')), findsNothing);
      expect(find.byKey(const ValueKey('channel-all')), findsOneWidget, reason: 'the old board as before');
      expect(find.byKey(const ValueKey('new-order')), findsOneWidget);
    });
  });
}

class _Sounds extends OrderAlertSounds {
  _Sounds();
  final calls = <String>[];
  @override
  Future<void> arrive() async => calls.add('arrive');
  @override
  Future<void> warning() async => calls.add('warning');
}
