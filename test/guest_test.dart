import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/guest/guest_api.dart';
import 'package:vinii_pos/guest/guest_app.dart';
import 'package:vinii_pos/guest_web_main.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/tables/guest_orders.dart';
import 'package:vinii_pos/tables/table_order_screen.dart';
import 'package:vinii_pos/tables/table_qr_api.dart';
import 'package:vinii_pos/tables/table_qr_screen.dart';
import 'package:vinii_pos/tables/table_widgets.dart';
import 'package:vinii_pos/tables/tables_api.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

/// Shaped like guest_qr_open / guest_staff_menu (database/tests/560_table_qr_guest_menu.sql, server/scripts/guest-e2e.mjs).
Map<String, dynamic> visitJson() => {
      'session': 'ab' * 32,
      'business': {'name': 'Dosa House 560'},
      'outlet': {'name': 'Main'},
      'table': {'label': 'T1', 'area_name': 'Garden', 'seats': 4},
      'payment': 'at_table',
      'menu': {
        'brand': {'name': 'Dosa House', 'accent': '#FF6600', 'table_word': 'Table'},
        'categories': [
          {'id': 'c1', 'name': 'Dosas'},
          {'id': 'c2', 'name': 'Drinks'},
        ],
        'items': [
          {'id': 'i1', 'name': 'Masala Dosa', 'description': 'Crisp, potato filling', 'price': 120, 'food_type': 'veg', 'is_recommended': true, 'prep_minutes': 12, 'category_id': 'c1', 'tags': ['Spicy']},
          {'id': 'i2', 'name': 'Chicken Dosa', 'price': 180, 'food_type': 'non_veg', 'prep_minutes': 15, 'category_id': 'c1', 'tags': []},
          {'id': 'i3', 'name': 'Filter Coffee', 'price': 40.5, 'food_type': 'veg', 'prep_minutes': 3, 'category_id': 'c2', 'tags': []},
        ],
      },
    };

class FakeGateway implements GuestGateway {
  FakeGateway({this.waits = true, this.failOpen});
  final bool waits;
  final GuestApiException? failOpen;
  final sent = <({List<Map<String, dynamic>> lines, String? name, String? note, String key})>[];
  List<Facts> requests = [];
  GuestApiException? failSend;

  @override
  bool get waitsForStaff => waits;
  @override
  Future<GuestVisit> open() async {
    if (failOpen != null) throw failOpen!;
    return GuestVisit(Facts(visitJson()));
  }

  @override
  Future<GuestMenu> menu() async => GuestMenu(Facts(visitJson()['menu'] as Map<String, dynamic>));
  @override
  Future<Facts> send(List<GuestLine> lines, {String? guestName, String? note, required String key}) async {
    if (failSend != null) throw failSend!;
    sent.add((lines: [for (final l in lines) l.toJson()], name: guestName, note: note, key: key));
    final r = Facts({
      'id': 'r${sent.length}',
      'status': waits ? 'waiting' : 'accepted',
      'lines': [for (final l in lines) {'name': l.item.name, 'qty': l.qty}],
      'order': waits ? null : {'display_no': 'P-00042', 'status': 'sent_to_kitchen'},
    });
    requests = [r, ...requests];
    return r;
  }

  @override
  Future<List<Facts>> status() async => requests;

  GuestBill? billToShow;
  final feedbacks = <(int, String?)>[];
  @override
  Future<GuestBill?> bill() async => billToShow;
  @override
  Future<void> feedback(int rating, {String? comment}) async => feedbacks.add((rating, comment));
}

/// Welcome -> Start exploring -> budget (skipped, or [budget] set) -> "What are you in the mood for?" (All dishes) -> the deck.
Future<void> startOrdering(WidgetTester t, {bool budget = false}) async {
  await t.tap(find.byKey(const ValueKey('guest-start')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey(budget ? 'budget-save' : 'budget-skip')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const ValueKey('mood-all')));
  await t.pumpAndSettle();
}

Future<void> showGuest(WidgetTester t, GuestGateway g, {VoidCallback? onExit}) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(800, 1700);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: GuestApp(key: UniqueKey(), gateway: g, onExit: onExit, pollEvery: const Duration(hours: 1))));
  await t.pumpAndSettle();
}

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) => http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  group('guest screens', () {
    testWidgets('welcome names the restaurant and the table; Start opens the swipe deck', (t) async {
      await showGuest(t, FakeGateway());
      expect(find.text('Dosa House'), findsOneWidget);
      expect(find.text('Table T1 · Garden'), findsOneWidget);
      await startOrdering(t);
      expect(find.byKey(const ValueKey('deck-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('deck-name')), findsOneWidget);
      expect(find.text('Masala Dosa'), findsWidgets);
    });

    testWidgets('swipe right adds, left skips, up opens the details; the buttons do the same', (t) async {
      await showGuest(t, FakeGateway());
      await startOrdering(t);
      await t.drag(find.byKey(const ValueKey('deck-card')), const Offset(300, 0));   // right: Masala Dosa added
      await t.pumpAndSettle();
      expect(find.text('1 dish · ₹120'), findsOneWidget);
      await t.drag(find.byKey(const ValueKey('deck-card')), const Offset(-300, 0));  // left: Chicken Dosa skipped
      await t.pumpAndSettle();
      expect(find.text('1 dish · ₹120'), findsOneWidget);
      await t.drag(find.byKey(const ValueKey('deck-card')), const Offset(0, -300));  // up: Filter Coffee details
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('item-detail')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('detail-plus')));
      await t.tap(find.byKey(const ValueKey('detail-add')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('added-title')), findsOneWidget);   // board 7: "Added to your order!"
      await t.tap(find.byKey(const ValueKey('added-keep')));
      await t.pumpAndSettle();
      expect(find.text('3 dishes · ₹201'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('deck-add')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('deck-done')), findsOneWidget);
      expect(find.text('4 dishes · ₹241.50'), findsOneWidget);
    });

    testWidgets('budget: the split per person, the ring on the deck, within and over budget on the order', (t) async {
      await showGuest(t, FakeGateway());
      await t.tap(find.byKey(const ValueKey('guest-start')));
      await t.pumpAndSettle();
      expect(find.text('₹3,000'), findsOneWidget);
      expect(find.text('₹1,500 per person'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('budget-people-plus')));
      await t.pump();
      expect(find.text('₹1,000 per person'), findsOneWidget);
      await t.drag(find.byKey(const ValueKey('budget-slider')), const Offset(-2000, 0));   // all the way down: ₹500
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('budget-amount')), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('budget-amount'))).data, '₹500');
      await t.tap(find.byKey(const ValueKey('budget-save')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('mood-all')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('budget-ring')), findsOneWidget);
      expect(find.text('₹0 / ₹500'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('deck-add')));   // Masala Dosa, 120
      await t.pumpAndSettle();
      expect(find.text('₹120 / ₹500'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('cart-bar')));
      await t.pumpAndSettle();
      expect(find.textContaining("You're well within your budget! ₹380 remaining"), findsOneWidget);
      for (var n = 0; n < 4; n++) {
        await t.tap(find.byKey(const ValueKey('plus-i1')));
      }
      await t.pump();
      expect(find.text('Over your budget by ₹100'), findsOneWidget);   // 5 x 120 = 600
    });

    testWidgets('mood: picking a category starts the deck on it; a new pick starts a fresh deck', (t) async {
      await showGuest(t, FakeGateway());
      await t.tap(find.byKey(const ValueKey('guest-start')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('budget-skip')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('mood-c1')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('mood-c2')));
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const ValueKey('deck-name'))).data, 'Filter Coffee');
      expect(find.byKey(const ValueKey('budget-ring')), findsNothing, reason: 'no budget set');
      await t.tap(find.byKey(const ValueKey('menu-back')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('mood-all')));
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const ValueKey('deck-name'))).data, 'Masala Dosa');
    });

    testWidgets('order screen: Keep exploring keeps the deck where it was; Clear all empties the order', (t) async {
      await showGuest(t, FakeGateway());
      await startOrdering(t);
      await t.tap(find.byKey(const ValueKey('deck-add')));   // Masala Dosa
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cart-bar')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('order-screen')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('back')));
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const ValueKey('deck-name'))).data, 'Chicken Dosa');
      await t.tap(find.byKey(const ValueKey('cart-bar')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('order-clear')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('cart-bar')), findsNothing);
    });

    Facts accepted(String stage, {int? left}) => Facts({
          'id': 'r1',
          'status': 'accepted',
          'lines': [
            {'name': 'Masala Dosa', 'qty': 1},
          ],
          'order': {
            'display_no': 'P-00007',
            'status': 'sent_to_kitchen',
            'status_label': 'Being prepared',
            'track': {
              'stage': stage,
              'minutes_left': left,
              'estimate_minutes': 20,
              'steps': [
                {'key': 'confirmed', 'done': true, 'at': '2026-10-22T12:14:00Z'},
                {'key': 'in_kitchen', 'done': stage != 'confirmed', 'at': '2026-10-22T12:16:00Z'},
                {'key': 'ready', 'done': stage == 'ready' || stage == 'served', 'at': null},
                {'key': 'served', 'done': stage == 'served', 'at': null},
              ],
            },
          },
        });

    Future<FakeGateway> sendOne(WidgetTester t, {bool budget = false}) async {
      final g = FakeGateway();
      await showGuest(t, g);
      await startOrdering(t, budget: budget);
      await t.tap(find.byKey(const ValueKey('deck-add')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cart-bar')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('order-continue')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('send-order')));
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 800));
      return g;
    }

    testWidgets('tracking: the kitchen steps and the minutes left; the orders page refreshes when reopened from the menu', (t) async {
      final g = await sendOne(t);
      expect(find.byKey(const ValueKey('track')), findsNothing, reason: 'still waiting for the staff');
      await t.tap(find.byKey(const ValueKey('order-more')));
      await t.pumpAndSettle();
      g.requests = [accepted('in_kitchen', left: 12)];
      await t.tap(find.byKey(const ValueKey('menu-orders')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('track')), findsOneWidget);
      expect(find.text('Estimated serving time: about 12 min'), findsOneWidget);
      expect(find.text('In the kitchen'), findsOneWidget);
      expect(find.text('Served'), findsOneWidget);
      expect(find.byKey(const ValueKey('view-bill')), findsOneWidget);
    });

    testWidgets('served: the bill with the budget, pay at the table, one feedback with a comment', (t) async {
      final g = await sendOne(t, budget: true);
      await t.tap(find.byKey(const ValueKey('order-more')));
      await t.pumpAndSettle();
      g.requests = [accepted('served')];
      g.billToShow = GuestBill(Facts({
        'orders': [
          {
            'items': [
              {'name': 'Masala Dosa', 'qty': 1, 'line_total': 120},
            ],
          },
        ],
        'subtotal': 120,
        'gst_amount': 6,
        'total': 126,
        'paid': 0,
        'due': 126,
        'bill_ready': false,
        'feedback': null,
      }));
      await t.tap(find.byKey(const ValueKey('menu-orders')));
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 800));
      expect(find.text('Your order is served!'), findsOneWidget);
      expect(find.byKey(const ValueKey('track-eta')), findsNothing);
      await t.tap(find.byKey(const ValueKey('view-bill')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('bill-screen')), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('bill-total'))).data, '₹126');
      expect(find.textContaining('You stayed within your budget'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('bill-pay')));
      await t.pump();
      expect(find.text('The staff will bring your bill'), findsOneWidget);
      await t.ensureVisible(find.byKey(const ValueKey('rate-5')));
      await t.tap(find.byKey(const ValueKey('rate-5')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('feedback-comment')), 'Crisp dosa');
      await t.ensureVisible(find.byKey(const ValueKey('feedback-send')));
      await t.tap(find.byKey(const ValueKey('feedback-send')));
      await t.pumpAndSettle();
      expect(g.feedbacks, [(5, 'Crisp dosa')]);
      expect(find.byKey(const ValueKey('feedback-thanks')), findsOneWidget);
    });

    testWidgets('list: categories, search and veg only; add and remove with the stepper', (t) async {
      await showGuest(t, FakeGateway());
      await startOrdering(t);
      await t.tap(find.byKey(const ValueKey('mode-list')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('row-i2')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('veg-only')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('row-i2')), findsNothing);
      await t.ensureVisible(find.byKey(const ValueKey('cat-c2')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cat-c2')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('row-i1')), findsNothing);
      expect(find.byKey(const ValueKey('row-i3')), findsOneWidget);
      await t.ensureVisible(find.byKey(const ValueKey('cat-all')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cat-all')));
      await t.enterText(find.byKey(const ValueKey('menu-search')), 'masala');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('row-i3')), findsNothing);
      await t.tap(find.byKey(const ValueKey('add-i1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('plus-i1')));
      await t.pumpAndSettle();
      expect(find.text('2 dishes · ₹240'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('minus-i1')));
      await t.tap(find.byKey(const ValueKey('minus-i1')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('cart-bar')), findsNothing);
    });

    testWidgets('web: Send to the restaurant sends the lines, the name and the note once; then "Waiting for the staff"', (t) async {
      final g = FakeGateway();
      await showGuest(t, g);
      await startOrdering(t);
      await t.tap(find.byKey(const ValueKey('deck-add')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cart-bar')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('order-continue')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('order-name')), findsOneWidget);
      expect(find.text('Send to the restaurant'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('order-name')), 'Asha');
      await t.enterText(find.byKey(const ValueKey('order-note')), 'less spicy');
      await t.tap(find.byKey(const ValueKey('send-order')));
      await t.pumpAndSettle();
      expect(g.sent, hasLength(1));
      expect(g.sent.single.lines, [
        {'menu_item_id': 'i1', 'qty': 1},
      ]);
      expect(g.sent.single.name, 'Asha');
      expect(g.sent.single.note, 'less spicy');
      expect(find.text('Sent to the restaurant'), findsOneWidget);
      expect(find.text('Waiting for the staff to confirm'), findsOneWidget);
      expect(find.byKey(const ValueKey('cart-bar')), findsNothing);
      await t.pump(const Duration(milliseconds: 800));   // "Order more" wakes a moment after the send
      await t.tap(find.byKey(const ValueKey('order-more')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('deck-card')), findsOneWidget);
    });

    testWidgets('a failed send keeps the order and retries with the same key', (t) async {
      final g = FakeGateway()..failSend = const GuestApiException(429, 'Your table already has orders waiting for the staff.', 'rate_limited');
      await showGuest(t, g);
      await startOrdering(t);
      await t.tap(find.byKey(const ValueKey('deck-add')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cart-bar')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('order-continue')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('send-order')));
      await t.pumpAndSettle();
      expect(find.text('Your table already has orders waiting for the staff.'), findsOneWidget);
      g.failSend = null;
      await t.tap(find.byKey(const ValueKey('send-order')));
      await t.pumpAndSettle();
      expect(g.sent, hasLength(1));
      expect(find.text('Sent to the restaurant'), findsOneWidget);
    });

    testWidgets('an ended visit asks to scan again; a closed menu shows the server sentence', (t) async {
      await showGuest(t, FakeGateway(failOpen: const GuestApiException(409, 'Please scan the table code again.', 'session_expired')));
      expect(find.byKey(const ValueKey('guest-ended')), findsOneWidget);
      await showGuest(t, FakeGateway(failOpen: const GuestApiException(409, 'This restaurant has not published its menu yet. Please order with the staff.', 'not_published')));
      expect(find.text('This restaurant has not published its menu yet. Please order with the staff.'), findsOneWidget);
    });

    testWidgets('Hand to guest: no name field, "Send to the kitchen", the order number, Back to staff', (t) async {
      var exited = 0;
      final g = FakeGateway(waits: false);
      await showGuest(t, g, onExit: () => exited++);
      await startOrdering(t);
      await t.tap(find.byKey(const ValueKey('deck-add')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cart-bar')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('order-continue')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('order-name')), findsNothing);
      await t.tap(find.text('Send to the kitchen'));
      await t.pumpAndSettle();
      expect(find.text('Sent to the kitchen'), findsOneWidget);
      expect(find.text('Order P-00042 is with the kitchen.'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('guest-exit')));
      expect(exited, 1);
    });
  });

  group('guest doors', () {
    test('web: open keeps the session, send names only dishes and quantities, errors keep their code', () async {
      final calls = <http.Request>[];
      final g = WebGuestGateway(
        code: 'cd' * 32,
        baseUrl: 'https://pos.test/',
        client: MockClient((r) async {
          calls.add(r);
          return switch (r.url.path) {
            '/guest/open' => ok(visitJson()),
            '/guest/send' => ok({'id': 'r1', 'status': 'waiting'}),
            '/guest/status' => err(409, 'Please scan the table code again.', 'session_expired'),
            _ => err(404, 'Not found'),
          };
        }),
      );
      final v = await g.open();
      expect(v.tableLabel, 'T1');
      expect(v.menu.accent, const Color(0xFFFF6600));
      expect(jsonDecode(calls.first.body), {'code': 'cd' * 32});
      expect(calls.first.headers['authorization'], isNull, reason: 'the guest page sends no key and no token');
      await g.send([GuestLine(v.menu.byId('i1')!, 2, ' crispy ')], guestName: ' Asha ', note: '', key: 'g-1234567890');
      expect(jsonDecode(calls[1].body), {
        'session': 'ab' * 32,
        'idempotency_key': 'g-1234567890',
        'lines': [
          {'menu_item_id': 'i1', 'qty': 2, 'notes': 'crispy'},
        ],
        'guest_name': 'Asha',
      });
      await expectLater(g.status(), throwsA(isA<GuestApiException>().having((e) => e.sessionEnded, 'sessionEnded', true)));
    });

    test('web: bill and feedback go through the guest door with the session', () async {
      final calls = <http.Request>[];
      final g = WebGuestGateway(
        code: 'cd' * 32,
        baseUrl: 'https://pos.test',
        client: MockClient((r) async {
          calls.add(r);
          return switch (r.url.path) {
            '/guest/open' => ok(visitJson()),
            '/guest/bill' => ok({'orders': [], 'subtotal': 0, 'gst_amount': 0, 'total': 0, 'paid': 0, 'due': 0, 'bill_ready': false, 'feedback': {'rating': 4, 'comment': ''}}),
            '/guest/feedback' => ok({'rating': 5, 'thanks': true}),
            _ => err(404, 'Not found'),
          };
        }),
      );
      await g.open();
      final b = await g.bill();
      expect(b!.rating, 4);
      expect(jsonDecode(calls[1].body), {'session': 'ab' * 32});
      await g.feedback(5, comment: '  great ');
      expect(jsonDecode(calls[2].body), {'session': 'ab' * 32, 'rating': 5, 'comment': 'great'});
    });

    test('staff: Hand to guest uses the staff session, the table and the store, with an Idempotency-Key', () async {
      final calls = <http.Request>[];
      final rpc = RpcClient(
        baseUrl: 'https://pos.test',
        accessToken: () => 'tok',
        client: MockClient((r) async {
          calls.add(r);
          return r.url.path.endsWith('guest_staff_menu') ? ok(visitJson()) : ok({'order': {'display_no': 'P-00042'}, 'replayed': false});
        }),
      );
      final g = StaffGuestGateway(tableId: 't1', locationId: 'loc1', rpc: rpc);
      final v = await g.open();
      await g.send([GuestLine(v.menu.byId('i3')!, 1)], key: 'g-abcdef123456');
      expect(calls.map((c) => c.url.path), ['/rpc/guest_staff_menu', '/rpc/guest_staff_place']);
      expect(jsonDecode(calls[0].body), {'location_id': 'loc1', 'table_id': 't1'});
      expect(calls[1].headers['Idempotency-Key'], 'g-abcdef123456');
      expect(calls[1].headers['Authorization'], 'Bearer tok');
      expect((jsonDecode(calls[1].body) as Map)['lines'], [
        {'menu_item_id': 'i3', 'qty': 1},
      ]);
      expect(g.waitsForStaff, isFalse);
    });

    test('the page finds the table code in its address', () {
      final code = 'ab' * 32;
      expect(tableCodeFrom(Uri.parse('https://pos.test/t/$code')), code);
      expect(tableCodeFrom(Uri.parse('https://pos.test/t/#/t/$code')), code);
      expect(tableCodeFrom(Uri.parse('https://pos.test/t/?t=$code')), code);
      expect(tableCodeFrom(Uri.parse('https://pos.test/t/not-a-code')), isNull);
      expect(tableCodeFrom(Uri.parse('https://pos.test/')), isNull);
      expect(TableQrApi.linkFor(code, base: 'https://order.test/'), 'https://order.test/t/$code');
    });

    group('public menu link (no sign-in, no table)', () {
      MenuCardGateway card(List<http.Request> calls, {http.Response? reply}) => MenuCardGateway(
            slug: 'dosa-house',
            baseUrl: 'https://pos.test',
            client: MockClient((r) async {
              calls.add(r);
              return reply ?? ok({...visitJson(), 'table': null}..remove('session'));
            }),
          );

      test('the page finds the business name in /m/<slug>', () {
        expect(menuSlugFrom(Uri.parse('https://pos.test/m/demo-spice')), 'demo-spice');
        expect(menuSlugFrom(Uri.parse('https://pos.test/m/Demo-Spice')), 'demo-spice');
        expect(menuSlugFrom(Uri.parse('https://pos.test/t/#/m/demo-spice')), 'demo-spice');
        expect(menuSlugFrom(Uri.parse('https://pos.test/m/..')), isNull);
        expect(menuSlugFrom(Uri.parse('https://pos.test/t/${'ab' * 32}')), isNull);
      });

      testWidgets('opens straight on the menu: no welcome, no cart; swipes only move on; details have no Add', (t) async {
        final calls = <http.Request>[];
        await showGuest(t, card(calls));
        expect(calls.single.url.toString(), 'https://pos.test/guest/card');
        expect(jsonDecode(calls.single.body), {'slug': 'dosa-house'});
        expect(find.byKey(const ValueKey('guest-start')), findsNothing);
        expect(find.byKey(const ValueKey('menu-back')), findsNothing);
        expect(find.byKey(const ValueKey('deck-card')), findsOneWidget);
        expect(find.text('Main'), findsOneWidget);   // the outlet, not a table
        expect(find.byKey(const ValueKey('deck-skip')), findsNothing);
        await t.drag(find.byKey(const ValueKey('deck-card')), const Offset(300, 0));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('deck-add')));
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('cart-bar')), findsNothing);
        await t.drag(find.byKey(const ValueKey('deck-card')), const Offset(0, -300));
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('item-detail')), findsOneWidget);
        expect(find.byKey(const ValueKey('detail-add')), findsNothing);
      });

      testWidgets('the list shows prices with no ADD buttons', (t) async {
        await showGuest(t, card([]));
        await t.tap(find.byKey(const ValueKey('mode-list')));
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('row-i1')), findsOneWidget);
        expect(find.byKey(const ValueKey('add-i1')), findsNothing);
      });

      testWidgets('a menu that is not live shows the server sentence', (t) async {
        await showGuest(t, card([], reply: err(404, 'This menu is not available right now.', 'not_found')));
        expect(find.text('This menu is not available right now.'), findsOneWidget);
      });

      test('sending from the menu link is refused on the phone', () async {
        final g = card([]);
        final v = await g.open();
        expect(() => g.send([GuestLine(v.menu.byId('i1')!, 1)], key: 'g-abcdef123456'), throwsA(isA<GuestApiException>()));
        expect(await g.status(), isEmpty);
      });
    });

    testWidgets('the page without a code asks to scan', (t) async {
      await t.pumpWidget(const GuestWebPage(code: null));
      expect(find.byKey(const ValueKey('guest-no-code')), findsOneWidget);
    });
  });

  group('staff: table QR codes and guest orders', () {
    Map<String, dynamic> listJson({bool manager = true, bool t1On = true}) => {
          'location_id': 'loc1',
          'can': {'issue': manager, 'see_codes': manager},
          'counts': {'all': 2, 'with_code': 1, 'on': t1On ? 1 : 0},
          'tables': [
            {'id': 't1', 'label': 'T1', 'seats': 4, 'area_name': 'Garden', 'has_code': true, 'enabled': t1On, 'code': manager ? 'ef' * 32 : null},
            {'id': 't2', 'label': 'T2', 'seats': 2, 'area_name': null, 'has_code': false, 'enabled': true, 'code': null},
          ],
        };

    ({TablesEnv env, List<http.Request> calls}) env({bool manager = true, http.Response? Function(http.Request r)? extra}) {
      final calls = <http.Request>[];
      final client = MockClient((r) async {
        calls.add(r);
        final fn = r.url.path.split('/').last;
        final custom = extra?.call(r);
        if (custom != null) return custom;
        final a = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
        return switch (fn) {
          'tbl_qr_list' => ok(listJson(manager: manager)),
          'tbl_qr_issue' => ok({'id': a['table_id'], 'label': a['table_id'] == 't1' ? 'T1' : 'T2', 'seats': 2, 'has_code': true, 'enabled': true, 'code': '12' * 32, 'issued': true, 'replaced': a['replace'] == true}),
          'tbl_qr_set_enabled' => ok({'id': a['table_id'], 'label': 'T1', 'seats': 4, 'has_code': true, 'enabled': a['enabled'], 'code': 'ef' * 32}),
          'guest_requests_list' => ok({
              'can_decide': true,
              'waiting': 1,
              'requests': [
                {'id': 'r1', 'status': 'waiting', 'table': {'id': 't1', 'label': 'T1'}, 'guest_name': 'Ravi', 'minutes_waiting': 2, 'estimated_total': 240, 'note': 'no onion',
                 'lines': [{'name': 'Masala Dosa', 'qty': 2, 'notes': null}]},
              ],
            }),
          'guest_request_decide' => ok({'id': 'r1', 'status': a['action'] == 'accept' ? 'accepted' : 'declined', 'order': {'display_no': 'P-00007'}}),
          'tbl_order_view' => ok({'table': {'id': 't1', 'label': 'T1', 'seats': 4}, 'status': null, 'orders': [], 'items': [], 'timeline': [], 'subtotal': 0, 'can': {}, 'unavailable': {}}),
          _ => err(404, 'not found: $fn'),
        };
      });
      final rpc = RpcClient(baseUrl: 'https://pos.test', accessToken: () => 'tok', client: client);
      return (env: TablesEnv(api: TablesApi(rpc: rpc, locationId: 'loc1'), qrApi: TableQrApi(rpc: rpc)), calls: calls);
    }

    Future<void> showStaff(WidgetTester t, Widget w) async {
      ignoreOverflow();
      t.view.physicalSize = const Size(800, 2400);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(theme: posTheme(), home: w));
      await t.pumpAndSettle();
    }

    Map<String, dynamic> body(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;
    Iterable<http.Request> of(List<http.Request> calls, String fn) => calls.where((c) => c.url.path.endsWith('/$fn'));

    testWidgets('a manager sees the codes by area, issues one, switches one off, prints it', (t) async {
      final e = env();
      Uint8List? printed;
      await showStaff(t, TableQrScreen(env: e.env, linkBase: 'https://order.test', onPrint: (pdf, name) async => printed = pdf));
      expect(find.text('GARDEN'), findsOneWidget);
      expect(find.text('OTHER TABLES'), findsOneWidget);
      expect(find.text('Working'), findsOneWidget);
      expect(find.text('No code'), findsOneWidget);
      expect(body(of(e.calls, 'tbl_qr_list').first)['location_id'], 'loc1');
      await t.tap(find.byKey(const ValueKey('qr-issue-t2')));
      await t.pumpAndSettle();
      expect(body(of(e.calls, 'tbl_qr_issue').single), {'location_id': 'loc1', 'table_id': 't2'});
      expect(find.text('No code'), findsNothing);
      await t.tap(find.byKey(const ValueKey('qr-switch-t1')));
      await t.pumpAndSettle();
      expect(body(of(e.calls, 'tbl_qr_set_enabled').single), {'location_id': 'loc1', 'table_id': 't1', 'enabled': false});
      expect(find.text('Switched off'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('qr-show-t2')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('qr-image')), findsOneWidget);
      expect(find.text('https://order.test/t/${'12' * 32}'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('qr-print')));
      await t.pumpAndSettle();
      await t.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.pumpAndSettle();
      expect(printed, isNotNull);
      expect(String.fromCharCodes(printed!.take(5)), '%PDF-');
    });

    testWidgets('replacing a code needs the table name typed, then sends it', (t) async {
      final e = env();
      await showStaff(t, TableQrScreen(env: e.env));
      await t.tap(find.byKey(const ValueKey('qr-more-t1')));
      await t.pumpAndSettle();
      await t.tap(find.text('Replace code…'));
      await t.pumpAndSettle();
      final confirm = find.byKey(const ValueKey('replace-confirm'));
      expect(t.widget<TextButton>(confirm).onPressed, isNull);
      await t.enterText(find.byKey(const ValueKey('replace-name')), 'T2');
      await t.pumpAndSettle();
      expect(t.widget<TextButton>(confirm).onPressed, isNull);
      await t.enterText(find.byKey(const ValueKey('replace-name')), 't1');
      await t.pumpAndSettle();
      await t.tap(confirm);
      await t.pumpAndSettle();
      expect(body(of(e.calls, 'tbl_qr_issue').single), {'location_id': 'loc1', 'table_id': 't1', 'replace': true, 'confirm_label': 't1'});
    });

    testWidgets('floor staff see which tables have a code, not the codes, and cannot issue', (t) async {
      final e = env(manager: false);
      await showStaff(t, TableQrScreen(env: e.env));
      expect(find.byKey(const ValueKey('qr-staff-note')), findsOneWidget);
      expect(find.byKey(const ValueKey('qr-issue-t2')), findsNothing);
      expect(find.byKey(const ValueKey('qr-show-t1')), findsNothing);
      expect(find.byKey(const ValueKey('qr-switch-t1')), findsNothing);
    });

    testWidgets('the table order screen shows the waiting guest order; Accept sends it to the kitchen; Decline asks why', (t) async {
      final e = env();
      await showStaff(t, TableOrderScreen(env: e.env, tableId: 't1'));
      expect(find.text('1 guest order waiting'), findsOneWidget);
      expect(find.text('Table T1 · Ravi · 2 min ago'), findsOneWidget);
      expect(find.text('Note: no onion'), findsOneWidget);
      expect(body(of(e.calls, 'guest_requests_list').first), {'location_id': 'loc1', 'table_id': 't1'});
      await t.tap(find.byKey(const ValueKey('guest-accept-r1')));
      await t.pumpAndSettle();
      expect(body(of(e.calls, 'guest_request_decide').single), {'location_id': 'loc1', 'id': 'r1', 'action': 'accept'});
      await t.tap(find.byKey(const ValueKey('guest-decline-r1')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('decline-dialog')), findsOneWidget);
      expect(t.widget<TextButton>(find.byKey(const ValueKey('decline-confirm'))).onPressed, isNull);
      await t.enterText(find.byKey(const ValueKey('decline-reason')), 'Kitchen closing');
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('decline-confirm')));
      await t.pumpAndSettle();
      expect(body(of(e.calls, 'guest_request_decide').last), {'location_id': 'loc1', 'id': 'r1', 'action': 'decline', 'reason': 'Kitchen closing'});
      expect(find.byKey(const ValueKey('hand-to-guest')), findsOneWidget);
    });

    testWidgets('Hand to guest opens the guest screens and Back to staff returns', (t) async {
      final e = env();
      await showStaff(t, Builder(
        builder: (c) => Scaffold(
          body: Center(
            child: TextButton(key: const ValueKey('go'), onPressed: () => Navigator.of(c).push(GuestHostScreen.route(e.env, 't1', gateway: FakeGateway(waits: false))), child: const Text('go')),
          ),
        ),
      ));
      await t.tap(find.byKey(const ValueKey('go')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('guest-app')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('guest-exit')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('guest-app')), findsNothing);
    });

    testWidgets('a role that may not see guest orders: the panel stays hidden', (t) async {
      final e = env(extra: (r) => r.url.path.endsWith('guest_requests_list') ? err(403, 'Your role cannot do this on the floor.', 'forbidden') : null);
      await showStaff(t, TableOrderScreen(env: e.env, tableId: 't1'));
      expect(find.byKey(const ValueKey('guest-orders')), findsNothing);
    });
  });
}
