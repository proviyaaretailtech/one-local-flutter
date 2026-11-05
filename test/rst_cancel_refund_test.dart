// Cancel a dish, cancel KOT items, refund and void a restaurant bill (0640). The answers are what the database gave on the local test
// database (server/scripts/rst-cancel-refund-e2e.mjs with FIXTURES=…): bill Z9101 with Paneer 2, Naan 4 (2 cancelled), Tikka (cooking,
// then cancelled on a manager's approval) and Lassi (cancelled before the KOT); bill Z9104 paid ₹1,050 with a ₹50 refund.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/kitchen/kitchen_api.dart';
import 'package:vinii_pos/kitchen/kitchen_widgets.dart';
import 'package:vinii_pos/kitchen/kot_screen.dart';
import 'package:vinii_pos/reports/rst_reports_api.dart';
import 'package:vinii_pos/reports/rst_reports_screen.dart';
import 'package:vinii_pos/tables/bill_adjust.dart';
import 'package:vinii_pos/tables/bill_api.dart';

import 'helpers.dart';

final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/rst_cancel_refund_server.json').readAsStringSync()) as Map<String, dynamic>;
Map<String, dynamic> copy(Object? o) => jsonDecode(jsonEncode(o)) as Map<String, dynamic>;
http.Response ok(Object? body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String code = 'conflict']) =>
    http.Response(jsonEncode({'detail': detail, 'code': code}), status, headers: {'content-type': 'application/json; charset=utf-8'});

/// The open bill before the tikka came off: the captain's view, with the cooking tikka still on it.
Map<String, dynamic> openBill() => copy((fx['requested'] as Map)['order'])..['requests'] = [];

class Fake {
  Fake(this.view, {this.on = const {}});
  Map<String, dynamic> view;
  final Map<String, http.Response Function(Map<String, dynamic> body)> on;
  final calls = <(String, Map<String, dynamic>)>[];
  List<Map<String, dynamic>> of(String fn) => [for (final c in calls) if (c.$1 == fn) c.$2];

  late final client = MockClient((r) async {
    final fn = r.url.pathSegments.last;
    final b = r.body.isEmpty ? <String, dynamic>{} : (jsonDecode(r.body) as Map).cast<String, dynamic>();
    calls.add((fn, b));
    final h = on[fn];
    if (h != null) return h(b);
    return switch (fn) {
      'rst_order_adjust' => ok(view),
      'rst_items_cancel' => ok(fx['cancelled']),
      'rst_bill_refund' => ok(fx['refunded']),
      'rst_requests_list' => ok(fx['requests']),
      _ => err(404, 'Not found', 'not_found'),
    };
  });
  late final api = BillApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client);
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

/// A screen with one button that opens the Cancel item sheet for [orderId].
Widget opener(Fake f, {bool kitchenOnly = false, ValueChanged<bool>? done}) => Builder(
      builder: (c) => Scaffold(
        body: Center(
          child: TextButton(
            key: const ValueKey('open'),
            onPressed: () async {
              final r = await showCancelItemsSheet(c, api: f.api, orderId: f.view['id'] as String, kitchenOnly: kitchenOnly);
              done?.call(r);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

void main() {
  group('Cancel item', () {
    testWidgets('lists the dishes left with where they are; choose how many, a reason, Are you sure (No keeps it), then cancels', (t) async {
      final f = Fake(openBill());
      bool? changed;
      await show(t, opener(f, done: (v) => changed = v));
      await tapKey(t, 'open');
      // Lassi was cancelled before: not offered; Paneer, Naan, Tikka are
      expect(find.text('2× Paneer'), findsOneWidget);
      expect(find.text('2× Naan'), findsOneWidget);
      expect(find.text('1× Tikka'), findsOneWidget);
      expect(find.textContaining('Lassi'), findsNothing);
      expect(find.textContaining('2 cancelled before'), findsOneWidget, reason: 'the naan already lost 2');
      expect(find.textContaining('Cooking'), findsOneWidget);
      expect(find.text('Choose a dish'), findsOneWidget);

      await tapKey(t, 'cancel-plus-1'); // Naan
      expect(find.text('Cancel 1 dish'), findsOneWidget);
      await tapKey(t, 'cancel-plus-1');
      await tapKey(t, 'cancel-plus-1');
      expect(find.byKey(const ValueKey('cancel-qty-1')), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('cancel-qty-1'))).data, '2', reason: 'never more than are on the order');
      await tapKey(t, 'cancel-minus-1');

      await tapKey(t, 'cancel-go');
      expect(find.text('Say why (3 characters or more).'), findsOneWidget);
      expect(f.of('rst_items_cancel'), isEmpty);

      await tapKey(t, 'cancel-reason-Guest changed mind');
      await tapKey(t, 'cancel-go');
      expect(find.text('Are you sure you want to cancel?'), findsOneWidget);
      expect(find.textContaining('1× Naan. The kitchen is told to stop.'), findsOneWidget);
      await tapKey(t, 'adj-sure-no');
      expect(f.of('rst_items_cancel'), isEmpty, reason: 'No cancels nothing');

      await tapKey(t, 'cancel-go');
      await tapKey(t, 'adj-sure-yes');
      final b = f.of('rst_items_cancel').single;
      final naan = (f.view['items'] as List).firstWhere((i) => i['name'] == 'Naan')['id'];
      expect(b['order_id'], f.view['id']);
      expect(b['items'], [{'item_id': naan, 'qty': 1}]);
      expect(b['reason'], 'Guest changed mind');
      expect(b['idempotency_key'], startsWith('rst-'));
      expect(changed, isTrue);
      expect(toast('Cancelled. The bill is now ₹1,407.'), findsOneWidget);
    });

    testWidgets('a dish being cooked: the captain is told a manager approves, and the reply says it was sent', (t) async {
      final f = Fake(openBill(), on: {'rst_items_cancel': (_) => ok(fx['requested'])});
      await show(t, opener(f));
      await tapKey(t, 'open');
      await tapKey(t, 'cancel-plus-2'); // Tikka, cooking
      expect(find.byKey(const ValueKey('cancel-needs-manager')), findsOneWidget);
      expect(find.text('Ask to cancel 1 dish'), findsOneWidget);
      await tapKey(t, 'cancel-reason-Taking too long');
      await tapKey(t, 'cancel-go');
      expect(find.text('Ask a manager to cancel?'), findsOneWidget);
      await tapKey(t, 'adj-sure-yes');
      expect(toast('Sent to a manager to approve.'), findsOneWidget);
    });

    testWidgets('the server refusing shows its sentence and the sheet stays', (t) async {
      final f = Fake(openBill(), on: {'rst_items_cancel': (_) => err(409, 'Tikka is already cancelled')});
      await show(t, opener(f));
      await tapKey(t, 'open');
      await tapKey(t, 'cancel-plus-0');
      await tapKey(t, 'cancel-reason-Wrong dish');
      await tapKey(t, 'cancel-go');
      await tapKey(t, 'adj-sure-yes');
      expect(find.text('Tikka is already cancelled'), findsOneWidget);
      expect(find.byKey(const ValueKey('cancel-go')), findsOneWidget);
    });

    testWidgets('a paid bill: no sheet, the reason why', (t) async {
      final f = Fake(copy(fx['paid_cash']));
      bool? changed;
      await show(t, opener(f, done: (v) => changed = v));
      await tapKey(t, 'open');
      expect(find.byKey(const ValueKey('cancel-go')), findsNothing);
      expect(toast('Money was taken on this bill; give a refund instead.'), findsOneWidget);
      expect(changed, isFalse);
    });
  });

  group('Payment details', () {
    testWidgets('paid, refunded, still refundable and the status; payments, refund history with who asked', (t) async {
      final f = Fake(copy(fx['paid_mgr']));
      await show(t, BillMoneyScreen(api: f.api, orderId: f.view['id'] as String));
      await t.pumpAndSettle();
      expect(find.text('Payment details'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('adj-paid'))).data, '₹1,050');
      expect(t.widget<Text>(find.byKey(const ValueKey('adj-refunded'))).data, '₹50');
      expect(t.widget<Text>(find.byKey(const ValueKey('adj-refundable'))).data, '₹1,000');
      expect(find.text('Partly refunded'), findsOneWidget);
      expect(find.byKey(const ValueKey('adj-pay-0')), findsOneWidget);
      expect(find.textContaining('Cash · Cold soup'), findsOneWidget);
      expect(find.textContaining('By ZZ mgr · asked by ZZ cash'), findsOneWidget);
      expect(find.text('No dishes cancelled.'), findsOneWidget);
    });

    testWidgets('Refund: the amount (no more than is left), how it goes back, a reason, Are you sure, then the shared refund', (t) async {
      final f = Fake(copy(fx['paid_mgr']));
      await show(t, BillMoneyScreen(api: f.api, orderId: f.view['id'] as String));
      await t.pumpAndSettle();
      await tapKey(t, 'adj-refund');
      expect(find.textContaining('up to ₹1,000 can be refunded'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('money-amount')), '2000');
      await tapKey(t, 'money-method-cash');
      await tapKey(t, 'money-reason-Food quality');
      await tapKey(t, 'money-go');
      expect(find.text('At most ₹1,000 can be refunded on this bill.'), findsOneWidget);
      expect(f.of('rst_bill_refund'), isEmpty);

      await t.enterText(find.byKey(const ValueKey('money-amount')), '50');
      await t.pumpAndSettle();
      await tapKey(t, 'money-go');
      expect(find.text('Are you sure you want to refund ₹50?'), findsOneWidget);
      expect(find.textContaining('₹950 can still be refunded after this'), findsOneWidget);
      await tapKey(t, 'adj-sure-yes');
      final b = f.of('rst_bill_refund').single;
      expect(b, containsPair('amount', 50));
      expect(b, containsPair('method', 'cash'));
      expect(b, containsPair('reason', 'Food quality'));
      expect(b['idempotency_key'], startsWith('rst-'));
      expect(toast('₹50 refunded.'), findsOneWidget);
      expect(f.of('rst_order_adjust').length, 2, reason: 'the details read again');
    });

    testWidgets('a cashier asks for the refund (the sheet says a manager gives it)', (t) async {
      final f = Fake(copy(fx['paid_cash']), on: {'rst_bill_refund': (_) => ok({'status': 'requested', 'request_id': 'r1', 'replayed': false})});
      await show(t, BillMoneyScreen(api: f.api, orderId: f.view['id'] as String));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('adj-cancel_items')), findsOneWidget);
      await tapKey(t, 'adj-cancel_items');
      expect(toast('Money was taken on this bill; give a refund instead.'), findsOneWidget, reason: 'switched off: says why');
      await tapKey(t, 'adj-refund');
      expect(find.byKey(const ValueKey('money-asks')), findsOneWidget);
      expect(find.text('Ask for refund'), findsOneWidget);
      await tapKey(t, 'money-method-upi');
      await tapKey(t, 'money-reason-Goodwill');
      await tapKey(t, 'money-go');
      expect(find.text('Ask a manager to refund ₹1,000?'), findsOneWidget);
      await tapKey(t, 'adj-sure-yes');
      expect(toast('Sent to a manager to approve.'), findsOneWidget);
    });

    testWidgets('Void bill: money taken needs a way back; a manager asks the owner', (t) async {
      final f = Fake(copy(fx['paid_cash'])..['can'] = {...(fx['paid_cash'] as Map)['can'] as Map, 'is_manager': true},
          on: {'rst_bill_void': (_) => ok({'status': 'requested', 'request_id': 'r2', 'replayed': false})});
      await show(t, BillMoneyScreen(api: f.api, orderId: f.view['id'] as String));
      await t.pumpAndSettle();
      await tapKey(t, 'adj-void');
      expect(find.textContaining('₹1,000 goes back to the guest, then the bill is cancelled'), findsOneWidget);
      expect(find.text('Ask to void'), findsOneWidget);
      await tapKey(t, 'money-reason-Wrong bill');
      await tapKey(t, 'money-go');
      expect(find.text('Choose how the money goes back.'), findsOneWidget);
      await tapKey(t, 'money-method-card');
      await tapKey(t, 'money-go');
      expect(find.text('Ask the owner to void this bill?'), findsOneWidget);
      await tapKey(t, 'adj-sure-yes');
      final b = f.of('rst_bill_void').single;
      expect(b, containsPair('method', 'card'));
      expect(b, containsPair('reason', 'Wrong bill'));
      expect(toast('Sent to a manager to approve.'), findsOneWidget);
    });

    testWidgets('a request waiting: a manager approves it (Are you sure first); the asker only sees it waiting', (t) async {
      final waiting = copy((fx['requested'] as Map)['order']);
      final f = Fake(copy(waiting)..['requests'][0]['may_decide'] = true, on: {'rst_request_decide': (_) => ok({'status': 'cancelled', 'new_total': 777})});
      await show(t, BillMoneyScreen(api: f.api, orderId: f.view['id'] as String));
      await t.pumpAndSettle();
      expect(find.text('Waiting for approval'), findsOneWidget);
      expect(find.textContaining('Asked to cancel 1× Tikka'), findsOneWidget);
      await tapKey(t, 'adj-approve-0');
      expect(find.text('Approve this request?'), findsOneWidget);
      await tapKey(t, 'adj-sure-yes');
      final b = f.of('rst_request_decide').single;
      expect(b['decision'], 'approve');
      expect(b['request_id'], waiting['requests'][0]['request_id']);
      expect(toast('Cancelled. The bill is now ₹777.'), findsOneWidget);

      await t.pumpWidget(const SizedBox());
      final g = Fake(copy(waiting));
      await show(t, BillMoneyScreen(api: g.api, orderId: g.view['id'] as String));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('adj-approve-0')), findsNothing);
      expect(find.text('Waiting for a manager.'), findsOneWidget);
    });

    testWidgets('order history: the cancelled dishes with why, who and who approved', (t) async {
      final f = Fake(copy(fx['open_cap']));
      await show(t, BillMoneyScreen(api: f.api, orderId: f.view['id'] as String));
      await t.pumpAndSettle();
      expect(find.text('Cancelled items'), findsOneWidget);
      expect(find.textContaining('1× Lassi'), findsOneWidget);
      expect(find.textContaining('2× Naan · KOT 9101'), findsOneWidget);
      expect(find.textContaining('approved by ZZ mgr'), findsOneWidget);
    });

    testWidgets('Approvals lists every request waiting and opens its bill', (t) async {
      final f = Fake(openBill());
      await show(t, AdjustRequestsScreen(api: f.api));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('req-0')), findsOneWidget);
      await tapKey(t, 'req-0');
      expect(find.text('Payment details'), findsOneWidget);
    });
  });

  group('KOT screen', () {
    Map<String, dynamic> kot() => {
          'counts': {'all': 1, 'preparing': 1, 'ready': 0, 'completed': 0, 'cancelled': 1},
          'orders': [
            {
              'id': openBill()['id'], 'display_no': 'Z9101', 'total': 1407, 'stage': 'preparing', 'channel': 'dine_in', 'table_id': 't1', 'table_label': 'R1',
              'captain': null, 'paid': false, 'created_at': '2026-11-02T13:00:00Z', 'minutes': 5, 'items': 5, 'ready': 0,
              'kots': [{'id': 'k1', 'kot_no': 9101, 'status': 'preparing', 'items': 5, 'ready': 0}], 'stations': [], 'ready_item_ids': [], 'latest_ticket': 'k1',
              'item_cancels': [{'name': 'Naan', 'qty': 2, 'kot_no': '9101', 'reason': 'Guest wants only two', 'by': 'ZZ cap', 'sent': true, 'recent': true, 'at': '2026-11-02T13:05:00Z'},
                {'name': 'Lassi', 'qty': 1, 'kot_no': null, 'reason': 'Wrong order', 'by': 'ZZ cap', 'sent': false, 'recent': false, 'at': '2026-11-02T13:04:00Z'}],
            },
          ],
        };

    testWidgets('a KOT card shows the dishes cancelled after the KOT and opens Cancel KOT item with only the kitchen\'s dishes', (t) async {
      final f = Fake(openBill());
      final kitchen = KitchenApi(baseUrl: 'http://k.test', accessToken: () => 't', client: MockClient((r) async => ok(kot())));
      await show(t, KotScreen(env: KitchenEnv(api: kitchen, refreshEvery: null), openOrder: (_, _) {}, bill: f.api));
      await t.pumpAndSettle();
      expect(find.textContaining('STOP · 2× Naan cancelled (KOT 9101) · “Guest wants only two”'), findsOneWidget);
      // 0654: a dish cancelled before its KOT is listed too, without STOP; the order counts under Cancelled
      expect(find.textContaining('1× Lassi cancelled before the kitchen · “Wrong order”'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('kot-status-cancelled')), matching: find.text('1')), findsOneWidget);
      await tapKey(t, 'kot-cancelitem-Z9101');
      expect(find.textContaining('Cancel KOT item'), findsOneWidget);
      expect(find.text('2× Paneer'), findsOneWidget);
    });
  });

  testWidgets('Reports: Cancellations & refunds from the database', (t) async {
    final client = MockClient((r) async => ok(fx['report']));
    await show(t, RstReportScreen(kind: 'cancellations', api: RstReportsApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client), today: DateTime(2026, 11, 2)));
    await t.pumpAndSettle();
    expect(find.text('Cancellations & refunds'), findsOneWidget);
    expect(find.text('DISHES CANCELLED'), findsOneWidget);
    expect(find.text('BILLS VOIDED'), findsOneWidget);
    expect(find.text('REFUNDS'), findsOneWidget);
    expect(find.textContaining('approved by ZZ mgr'), findsWidgets);
  });
}
