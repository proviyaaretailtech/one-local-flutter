import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/orders/orders_api.dart';
import 'package:vinii_pos/sell/history_screen.dart';
import 'package:vinii_pos/sell/pay_screen.dart';
import 'package:vinii_pos/sell/payment_pending_screen.dart';
import 'package:vinii_pos/sell/result_screens.dart';
import 'package:vinii_pos/sell/sell_screen.dart';
import 'package:vinii_pos/shift/refund_blocked_screen.dart';
import 'package:vinii_pos/shift/shift_api.dart';
import 'package:vinii_pos/shift/shift_screens.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';
import 'order_fixtures.dart';
import 'sell_fixtures.dart';

// Store POS: cash shift (S5.1 open, S6.6 close), payment pending (S5.14), refund not allowed (S6.5). The fake server answers with
// rows shaped like the database functions of migrations 0500-0502; every rule is the database's, so these tests check what is sent and shown.

Future<void> tall(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 4800);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

ShiftApi api(Till till) => ShiftApi(baseUrl: 'http://pos.test', accessToken: () => 'tok', client: till.client);

void main() {
  group('ShiftApi', () {
    test('open sends the float with the idempotency key; close sends the count, reason and version', () async {
      final till = Till();
      await api(till).open(openingFloat: 1000, key: 'k-open');
      final o = till.where('POST', '/rpc/pos_shift_open').single;
      expect(jsonDecode(o.body), {'opening_float': 1000});
      expect(o.headers['Idempotency-Key'], 'k-open');
      till.override = (r) => r.url.path.endsWith('/pos_shift_close') ? ok(shiftRow(status: 'pending_approval', counted: 700, variance: -610, reason: 'Short')) : null;
      final c = await api(till).close('s1', counted: 700, reason: ' Short ', key: 'k-close', version: 1);
      expect(jsonDecode(till.where('POST', '/rpc/pos_shift_close').single.body), {'shift_id': 's1', 'counted_cash': 700, 'variance_reason': 'Short', 'expected_version': 1});
      expect(c.pendingApproval, isTrue);
      expect(c.expectedCash, 1310); // a closed shift reads its frozen figure
    });

    test('a refusal keeps the database code (no_shift, payment_pending)', () async {
      final till = Till()..override = (_) => err(409, 'Open the cash shift before taking the first payment.', 'no_shift');
      await expectLater(api(till).startPayment('o1', method: 'upi', key: 'k'), throwsA(isA<OrdersApiException>().having((e) => e.code, 'code', 'no_shift')));
    });

    test('refund check reads every reason', () async {
      final till = Till()..override = (r) => ok({'allowed': false, 'purpose': 'return', 'reasons': [{'code': 'outside_return_days', 'message': 'This bill was paid 10 days ago. Returns are accepted for 7 days.'}], 'return_days': 7, 'days_since_paid': 10});
      final c = await api(till).refundCheck('o1', purpose: 'return');
      expect(jsonDecode(till.calls.single.body), {'order_id': 'o1', 'purpose': 'return'});
      expect(c.allowed, isFalse);
      expect(c.reasons.single.$1, 'outside_return_days');
    });
  });

  group('S5.1 Open shift', () {
    testWidgets('the float is counted and sent once; the screen closes with true', (t) async {
      final till = Till();
      bool? result;
      await tall(t, Builder(builder: (c) => Center(child: TextButton(
            onPressed: () async => result = await Navigator.of(c).push<bool>(MaterialPageRoute(builder: (_) => OpenShiftScreen(api: api(till), required: true))),
            child: const Text('go')))));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.text('Open the shift before the first bill'), findsOneWidget);
      await t.tap(find.text('Open shift').last);
      await t.pumpAndSettle();
      expect(find.text('Enter the cash in the drawer (0 if it is empty).'), findsOneWidget);
      expect(till.where('POST', '/pos_shift_open'), isEmpty);
      await t.enterText(find.byKey(const ValueKey('float-field')), '1000');
      await t.tap(find.text('Open shift').last);
      await t.pumpAndSettle();
      expect(jsonDecode(till.where('POST', '/pos_shift_open').single.body), {'opening_float': 1000});
      expect(result, isTrue);
    });

    testWidgets('the till shows a banner when no shift is open, and opens it', (t) async {
      final till = Till()..shift = shiftCurrent(require: true);
      await tall(t, SellScreen(env: till.env()));
      expect(find.text('Open the cash shift before the first bill'), findsOneWidget);
      await t.tap(find.text('Open the cash shift before the first bill'));
      await t.pumpAndSettle();
      expect(find.byType(OpenShiftScreen), findsOneWidget);
    });

    testWidgets('no banner while a shift is open', (t) async {
      final till = Till();
      await tall(t, SellScreen(env: till.env()));
      expect(find.text('No cash shift open'), findsNothing);
      expect(find.text('Open the cash shift before the first bill'), findsNothing);
    });

    testWidgets('a cash payment refused for no shift leads to Open shift', (t) async {
      final till = Till()..override = (r) => r.url.path.endsWith('/checkout') ? err(409, 'Open the cash shift before taking the first payment.', 'no_shift') : null;
      final env = till.env();
      await tall(t, PayScreen(env: env, cart: cartWith(env.carts)));
      await t.enterText(find.byKey(const ValueKey('tender-field')), '700');
      await t.pumpAndSettle();
      await t.tap(find.text('Pay ₹630'));
      await t.pumpAndSettle();
      expect(find.byType(OpenShiftScreen), findsOneWidget);
      expect(find.text('Open the shift before the first bill'), findsOneWidget);
    });
  });

  group('S6.6 Close shift', () {
    testWidgets('shows the drawer the database worked out, cash moves and the other methods', (t) async {
      final till = Till();
      await tall(t, ShiftScreen(api: api(till)));
      expect(find.text('SH-0003'), findsOneWidget);
      expect(find.byKey(const ValueKey('expected-cash')), findsOneWidget);
      expect(find.text('₹1,310'), findsOneWidget);
      expect(find.text('In · Change from bank'), findsOneWidget);
      expect(find.text('Out · Milk for tea'), findsOneWidget);
      expect(find.text('UPI ₹420'), findsOneWidget);
    });

    testWidgets('a difference asks for a reason; above the limit it waits for a manager', (t) async {
      final till = Till();
      till.override = (r) => r.url.path.endsWith('/pos_shift_close') ? ok(shiftRow(status: 'pending_approval', counted: 700, variance: -610, reason: 'Short at night')) : null;
      await tall(t, ShiftScreen(api: api(till)));
      await t.enterText(find.byKey(const ValueKey('counted-field')), '700');
      await t.pumpAndSettle();
      expect(find.text('−₹610'), findsOneWidget);
      expect(find.text('Above ₹500: another manager approves it before the shift is closed.'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('variance-reason')), 'Short at night');
      await t.tap(find.text('Close shift'));
      await t.pumpAndSettle();
      final r = till.where('POST', '/pos_shift_close').single;
      expect(jsonDecode(r.body), {'shift_id': 's1', 'counted_cash': 700, 'variance_reason': 'Short at night', 'expected_version': 1});
      expect(r.headers['Idempotency-Key'], isNotEmpty);
      expect(find.text('SH-0003 is waiting for a manager'), findsOneWidget);
    });

    testWidgets('the database refusal is shown (reason required)', (t) async {
      final till = Till()..override = (r) => r.url.path.endsWith('/pos_shift_close') ? err(422, 'The count is -10 from what is expected; give a reason (3 to 200 characters).', 'reason_required') : null;
      await tall(t, ShiftScreen(api: api(till)));
      await t.enterText(find.byKey(const ValueKey('counted-field')), '1300');
      await t.pumpAndSettle();
      await t.tap(find.text('Close shift'));
      await t.pumpAndSettle();
      expect(find.text('The count is -10 from what is expected; give a reason (3 to 200 characters).'), findsOneWidget);
    });

    testWidgets('cash out asks for an amount and a reason and sends a key', (t) async {
      final till = Till();
      await tall(t, ShiftScreen(api: api(till)));
      await t.tap(find.text('Cash out').last);
      await t.pumpAndSettle();
      till.override = (r) => r.url.path.endsWith('/pos_shift_cash_move') ? ok(shiftRow()) : null;
      await t.enterText(find.byKey(const ValueKey('move-amount')), '60');
      await t.enterText(find.byKey(const ValueKey('move-reason')), 'Courier');
      await t.tap(find.text('Take cash out'));
      await t.pumpAndSettle();
      final r = till.where('POST', '/pos_shift_cash_move').single;
      expect(jsonDecode(r.body), {'shift_id': 's1', 'kind': 'out', 'amount': 60, 'reason': 'Courier'});
      expect(r.headers['Idempotency-Key'], isNotEmpty);
    });

    testWidgets('no shift: offers to open one', (t) async {
      final till = Till()..shift = shiftCurrent();
      await tall(t, ShiftScreen(api: api(till)));
      expect(find.text('No shift open'), findsOneWidget);
      await t.tap(find.text('Open shift'));
      await t.pumpAndSettle();
      expect(find.byType(OpenShiftScreen), findsOneWidget);
    });

    testWidgets('a manager approves a waiting difference with a note', (t) async {
      final till = Till()..shift = shiftCurrent(shift: shiftRow(), canApprove: true, pending: [shiftRow(status: 'pending_approval', counted: 700, variance: -610, reason: 'Short')]);
      till.override = (r) => r.url.path.endsWith('/pos_shift_approve') ? ok(shiftRow(status: 'closed')) : null;
      await tall(t, ShiftScreen(api: api(till)));
      expect(find.text('WAITING FOR YOUR APPROVAL'), findsOneWidget);
      await t.tap(find.text('Approve SH-0003'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('approve-note')), 'Counted twice');
      await t.tap(find.text('Approve difference'));
      await t.pumpAndSettle();
      expect(jsonDecode(till.where('POST', '/pos_shift_approve').single.body), {'shift_id': 's1', 'note': 'Counted twice'});
    });
  });

  group('S5.14 Payment pending', () {
    testWidgets('waits unpaid; a short reference is refused on the phone; confirm pays once and shows success', (t) async {
      final till = Till();
      await tall(t, PaymentPendingScreen(env: till.env(), order: OrderView(view('checkout')), method: 'upi'));
      expect(find.text('Payment pending'), findsOneWidget);
      expect(find.text('Not paid yet · P-01087'), findsOneWidget);
      expect(find.text('₹630'), findsOneWidget);
      await t.tap(find.text('Payment received'));
      await t.pumpAndSettle();
      expect(till.where('POST', '/pos_payment_confirm'), isEmpty);
      await t.enterText(find.byKey(const ValueKey('payment-ref')), 'UPI98765');
      await t.tap(find.text('Payment received'));
      await t.pumpAndSettle();
      expect(jsonDecode(till.where('POST', '/pos_payment_confirm').single.body), {'intent_id': 'pi1', 'reference': 'UPI98765'});
      expect(find.byType(SuccessScreen), findsOneWidget);
    });

    testWidgets('failed: logged, nothing charged, the failure screen offers a retry', (t) async {
      final till = Till();
      await tall(t, PaymentPendingScreen(env: till.env(), order: OrderView(view('checkout')), method: 'card'));
      await t.tap(find.text('Payment failed'));
      await t.pumpAndSettle();
      expect(jsonDecode(till.where('POST', '/pos_payment_fail').single.body)['status'], 'declined');
      expect(find.byType(FailedScreen), findsOneWidget);
      expect(find.text('Retry Payment'), findsOneWidget);
    });

    testWidgets('a payment already waiting on the bill is picked up, not started twice', (t) async {
      final till = Till()..override = (r) => r.url.path.endsWith('/pos_payment_start') ? err(409, 'A payment on this bill is still waiting.', 'payment_pending') : null;
      await tall(t, PaymentPendingScreen(env: till.env(), order: OrderView(view('checkout')), method: 'upi'));
      expect(jsonDecode(till.where('POST', '/pos_payment_status').single.body), {'order_id': orderId});
      expect(find.text('Payment pending'), findsOneWidget);
    });

    testWidgets('still waiting after 15 minutes says so', (t) async {
      final till = Till()..override = (r) => r.url.path.endsWith('/pos_payment_start') ? ok(intentRow(stale: true)) : null;
      await tall(t, PaymentPendingScreen(env: till.env(), order: OrderView(view('checkout')), method: 'upi'));
      expect(find.text('Still waiting after 15 minutes'), findsOneWidget);
    });
  });

  group('S6.5 Refund not allowed', () {
    final blocked = RefundCheck({
      'allowed': false, 'purpose': 'refund', 'display_no': 'P-00087', 'total': 630, 'taken': 630, 'refunded': 50, 'refundable_left': 580, 'return_days': 7, 'days_since_paid': 0,
      'reasons': [
        {'code': 'over_paid', 'message': '900 is more than was paid. At most 580 can still be refunded on this bill.'},
        {'code': 'needs_manager', 'message': 'Only a manager can give a refund. Ask a manager to do it.'},
      ],
    });

    testWidgets('says every reason in the database\'s words, with the figures', (t) async {
      await tall(t, RefundBlockedScreen(check: blocked));
      expect(find.text('Refund not allowed'), findsOneWidget);
      expect(find.text('900 is more than was paid. At most 580 can still be refunded on this bill.'), findsOneWidget);
      expect(find.text('Only a manager can give a refund. Ask a manager to do it.'), findsOneWidget);
      expect(find.text('₹580'), findsOneWidget);
    });

    testWidgets('a return outside the window shows the return days', (t) async {
      await tall(t, RefundBlockedScreen(check: RefundCheck({'allowed': false, 'purpose': 'return', 'display_no': 'P-00087', 'total': 630, 'taken': 630, 'refundable_left': 630, 'return_days': 7, 'days_since_paid': 10,
        'reasons': [{'code': 'outside_return_days', 'message': 'This bill was paid 10 days ago. Returns are accepted for 7 days.'}]})));
      expect(find.text('Return not allowed'), findsOneWidget);
      expect(find.text('7 days · paid 10 days ago'), findsOneWidget);
    });

    testWidgets('history: a refund the database would refuse opens the explanation and is not sent', (t) async {
      final till = Till()..override = (r) => r.url.path.endsWith('/pos_refund_check') ? ok(blocked.raw) : null;
      await tall(t, HistoryScreen(env: till.env()));
      await t.tap(find.text('View card').first);
      await t.pumpAndSettle();
      await t.tap(find.text('Refund this bill').first);
      await t.pumpAndSettle();
      await t.enterText(find.widgetWithText(TextField, 'Amount to refund'), '900');
      await t.tap(find.text('Give refund'));
      await t.pumpAndSettle();
      expect(jsonDecode(till.where('POST', '/pos_refund_check').single.body), {'order_id': 'r1', 'purpose': 'refund', 'amount': 900});
      expect(find.byType(RefundBlockedScreen), findsOneWidget);
      expect(till.where('POST', '/pos_refund'), isEmpty);
    });
  });
}
