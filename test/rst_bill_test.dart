import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/tables/bill_api.dart';
import 'package:vinii_pos/tables/bill_paid_screen.dart';
import 'package:vinii_pos/tables/bill_pay_screen.dart';
import 'package:vinii_pos/tables/bill_receipt_screen.dart';
import 'package:vinii_pos/tables/bill_split_screen.dart';
import 'package:vinii_pos/tables/table_order_screen.dart';
import 'package:vinii_pos/tables/table_widgets.dart';
import 'package:vinii_pos/tables/tables_api.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

/// Answers captured from the real database functions of migration 0550 (database/tests/550_rst_bill_pay.sql fixtures, run on a test DB).
final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/rst_bill_server.json').readAsStringSync()) as Map<String, dynamic>;
const t1 = '55000000-0000-0000-0000-0000000000c1', t2 = '55000000-0000-0000-0000-0000000000c2', t3 = '55000000-0000-0000-0000-0000000000c3';
const o1 = '55000000-0000-0000-0000-0000000000d1';

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) =>
    http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;
Map<String, dynamic> argsOf(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;
Map<String, dynamic> copy(String k) => jsonDecode(jsonEncode(fx[k])) as Map<String, dynamic>;

/// A fake POS server: the bill functions answer from the captured fixtures; [on] overrides one function per test.
class Fake {
  Fake();
  final requests = <http.Request>[];
  final on = <String, http.Response Function(http.Request r)>{};
  Map<String, dynamic> view1 = copy('view1');
  final opened = <Uri>[];

  late final client = MockClient((r) async {
    requests.add(r);
    final f = on[fnOf(r)];
    if (f != null) return f(r);
    switch (fnOf(r)) {
      case 'rst_bill_view':
        final id = argsOf(r)['table_id'];
        return ok(id == t2 ? fx['view2'] : id == t3 ? fx['view3'] : view1);
      case 'rst_bill_split':
        return ok(fx['split']);
      case 'rst_bill_pay':
        return ok(fx['paylast']);
      case 'rst_bill_coupon':
        return ok(fx['coupon']);
      case 'rst_bill_note':
        return ok({...(view1['orders'] as List).first as Map, 'notes': argsOf(r)['note']});
      case 'rst_receipt_view':
        return ok(fx['receipt']);
      case 'rst_receipt_log':
        return ok({'logged': true, 'channel': argsOf(r)['channel'], 'to': '******3210'});
      case 'tbl_order_view':
        return ok(orderView);
      case 'pos_set_order_status':
        return ok({'id': o1});
    }
    return err(404, 'not found: ${fnOf(r)}');
  });

  Map<String, dynamic> orderView = {
    'table': {'id': t1, 'label': 'T1', 'seats': 4, 'area_name': 'Ground Floor', 'main_table_id': t1},
    'status': {'key': 'awaiting_payment', 'label': 'AWAITING PAYMENT'},
    'orders': [
      {'id': o1, 'display_no': 'R5501', 'status': 'awaiting_payment', 'updated_at': '2026-10-20T06:00:00+00:00', 'total': 1050, 'subtotal': 1000}
    ],
    'items': [],
    'timeline': [],
    'subtotal': 1000,
    'can': {'add_items': false, 'send_kot': false, 'print_kot': false, 'change_table': true, 'merge_table': true, 'generate_bill': false},
    'unavailable': {},
  };

  late final bill = BillApi(baseUrl: 'http://bill.test', accessToken: () => 'token-1', client: client);
  late final tables = TablesApi(baseUrl: 'http://bill.test', accessToken: () => 'token-1', client: client);
  late final env = TablesEnv(api: tables);

  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
  Future<bool> open(Uri u) async {
    opened.add(u);
    return true;
  }
}

Future<void> show(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 4000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

/// A floor page that opens the table's order screen, so "Back to tables" has somewhere to land.
class _Floor extends StatelessWidget {
  const _Floor(this.s);
  final Fake s;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: TextButton(
            key: const ValueKey('open-table'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TableOrderScreen(env: s.env, tableId: t1, bill: s.bill))),
            child: const Text('Floor'),
          ),
        ),
      );
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

void main() {
  group('Checkout (step 3)', () {
    testWidgets('draws the bill of the table from the server: items, GST, total due, note and code', (t) async {
      final s = Fake();
      await show(t, BillPayScreen(env: s.env, tableId: t1, bill: s.bill));
      expect(find.text('Checkout'), findsOneWidget);
      expect(find.text('CURRENT ITEMS (TABLE T1)'), findsOneWidget);
      expect(find.text('2 × Paneer Butter Masala'), findsOneWidget);
      expect(find.text('₹600'), findsOneWidget);
      expect(find.text('GST (5%)'), findsOneWidget);
      expect(tester(t, const ValueKey('total-due')), '₹1,050');
      expect(find.text('Add a note for the kitchen'), findsOneWidget);
      expect(find.text('DISCOUNT CODE'), findsOneWidget);
      expect(find.text('Complete Payment'), findsOneWidget);
      expect(find.text('Print Bill'), findsOneWidget);
    });

    testWidgets('cash below the amount due is stopped on the phone and nothing is sent', (t) async {
      final s = Fake();
      await show(t, BillPayScreen(env: s.env, tableId: t1, bill: s.bill));
      await t.enterText(find.byKey(const ValueKey('bill-received')), '500');
      await tapText(t, 'Complete Payment');
      expect(find.text('Enter at least ₹1,050 received.'), findsOneWidget);
      expect(s.calls('rst_bill_pay'), isEmpty);
    });

    testWidgets('cash: the change is shown, the payment carries a key, the success card follows', (t) async {
      final s = Fake();
      s.on['rst_bill_pay'] = (r) => ok({...copy('paylast'), 'amount': 1050, 'tendered': 1100, 'change': 50, 'payment_method': 'cash', 'part_id': null});
      await show(t, BillPayScreen(env: s.env, tableId: t1, bill: s.bill));
      await t.enterText(find.byKey(const ValueKey('bill-received')), '1100');
      await t.pump();
      expect(tester(t, const ValueKey('bill-change')), '₹50');
      await tapText(t, 'Complete Payment');
      final r = s.calls('rst_bill_pay').single;
      expect(argsOf(r)['method'], 'cash');
      expect(argsOf(r)['tendered'], 1100);
      expect(argsOf(r).containsKey('part_id'), isFalse);
      expect(r.headers['Idempotency-Key'], startsWith('rst-'));
      expect(find.text('Transaction Successful'), findsOneWidget);
      expect(find.text('R5501'), findsOneWidget);
      expect(find.text('Change Returned'), findsOneWidget);
      expect(find.text('Dosa House 550 - Main'), findsOneWidget);
      expect(find.byType(TablesNav), findsOneWidget); // the restaurant bar, not the store's
    });

    testWidgets('card: nothing is recorded until the cashier confirms the card machine', (t) async {
      final s = Fake();
      await show(t, BillPayScreen(env: s.env, tableId: t1, bill: s.bill));
      await tapKey(t, 'method-Card');
      await tapText(t, 'Complete Payment');
      expect(find.text('Has the card payment gone through?'), findsOneWidget);
      await tapKey(t, 'confirm-no');
      expect(s.calls('rst_bill_pay'), isEmpty);
      await tapText(t, 'Complete Payment');
      await tapKey(t, 'confirm-yes');
      expect(argsOf(s.calls('rst_bill_pay').single)['method'], 'card');
    });

    testWidgets('no answer from the server: the retry sends the same key; a refusal starts a new one', (t) async {
      final s = Fake();
      var n = 0;
      s.on['rst_bill_pay'] = (r) {
        n++;
        if (n == 1) throw const SocketException('offline');
        return err(409, 'Guest 1 has already paid', 'wrong_state');
      };
      await show(t, BillPayScreen(env: s.env, tableId: t1, bill: s.bill));
      await tapText(t, 'Complete Payment');
      expect(find.textContaining('never taken twice'), findsOneWidget);
      await tapText(t, 'Complete Payment');
      expect(find.text('Guest 1 has already paid'), findsOneWidget);
      await tapText(t, 'Complete Payment');
      final keys = s.calls('rst_bill_pay').map((r) => r.headers['Idempotency-Key']).toList();
      expect(keys.length, 3);
      expect(keys[0], keys[1]);
      expect(keys[2], isNot(keys[1]));
    });

    testWidgets('a discount code is applied by the server and the bill is read again', (t) async {
      final s = Fake();
      await show(t, BillPayScreen(env: s.env, tableId: t1, bill: s.bill));
      await t.enterText(find.byKey(const ValueKey('bill-code')), 'dine10');
      s.view1 = {...copy('view1'), 'orders': [copy('coupon')], 'can': {'pay': true, 'note': true, 'split': true, 'coupon': false}, 'unavailable': {'coupon': 'A discount code is already on this bill.'}};
      await tapKey(t, 'apply-code');
      expect(argsOf(s.calls('rst_bill_coupon').single), {'order_id': o1, 'code': 'dine10'});
      expect(find.text('Discount (DINE10)'), findsOneWidget);
      expect(find.text('A discount code is already on this bill.'), findsOneWidget);
    });

    testWidgets('the kitchen note is saved through the server', (t) async {
      final s = Fake();
      await show(t, BillPayScreen(env: s.env, tableId: t1, bill: s.bill));
      await t.enterText(find.byKey(const ValueKey('bill-note')), 'Less spicy');
      await tapKey(t, 'save-note');
      expect(argsOf(s.calls('rst_bill_note').single)['note'], 'Less spicy');
      expect(find.text('Note saved for the kitchen.'), findsOneWidget);
    });

    testWidgets('a bill not generated yet cannot be paid and says why', (t) async {
      final s = Fake();
      await show(t, BillPayScreen(env: s.env, tableId: t3, bill: s.bill));
      expect(find.byKey(const ValueKey('pay-unavailable')), findsOneWidget);
      expect(find.text('Generate the bill first.'), findsOneWidget);
      await tapText(t, 'Complete Payment');
      expect(s.calls('rst_bill_pay'), isEmpty);
    });

    testWidgets('two bills on a table: the oldest first, "Bill 1 of 2"', (t) async {
      final s = Fake();
      await show(t, BillPayScreen(env: s.env, tableId: t2, bill: s.bill));
      expect(find.text('Table T2 · Bill 1 of 2'), findsOneWidget);
      expect(tester(t, const ValueKey('total-due')), '₹300');
    });

    testWidgets('Print Bill copies the bill text', (t) async {
      final s = Fake();
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
        if (c.method == 'Clipboard.setData') copied = (c.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await show(t, BillPayScreen(env: s.env, tableId: t1, bill: s.bill));
      await tapText(t, 'Print Bill');
      expect(copied, contains('Bill R5501 · Table T1'));
      expect(copied, contains('Total ₹1,050'));
    });

    testWidgets('a split bill sends the cashier to the split instead of taking it in one go', (t) async {
      final s = Fake()..view1 = copy('view1s');
      await show(t, BillPayScreen(env: s.env, tableId: t1, bill: s.bill));
      expect(find.byKey(const ValueKey('split-banner')), findsOneWidget);
      await tapText(t, 'Complete Payment');
      expect(find.text('Split the bill'), findsOneWidget);
      expect(s.calls('rst_bill_pay'), isEmpty);
    });
  });

  group('Split the bill (step 2)', () {
    testWidgets('equal: the guests are counted on the phone, the amounts come from the server', (t) async {
      final s = Fake();
      s.on['rst_bill_split'] = (r) => ok(fx['split']);
      await show(t, BillSplitScreen(env: s.env, tableId: t1, orderId: o1, bill: s.bill));
      expect(find.text('Table T1 · ₹1,050'), findsOneWidget);
      await tapKey(t, 'guests-plus');
      expect(find.text('3'), findsOneWidget);
      await tapKey(t, 'guest-0-method-upi');
      s.view1 = copy('view1s');
      await tapKey(t, 'save-split');
      final a = argsOf(s.calls('rst_bill_split').single);
      expect(a['mode'], 'equal');
      expect(a['guests'], 3);
      expect((a['parts'] as List).first, {'label': 'Guest 1', 'method': 'upi'});
      expect(s.calls('rst_bill_split').single.headers['Idempotency-Key'], startsWith('rst-'));
      expect(find.text('Paid by UPI'), findsOneWidget);
      expect(find.text('Pays by Cash'), findsOneWidget);
      expect(find.text('Take payment · Guest 2'), findsOneWidget);
      expect(find.text('Change split'), findsNothing); // a guest has paid: the plan is fixed
    });

    testWidgets('by item: each item goes to the guest chosen', (t) async {
      final s = Fake();
      await show(t, BillSplitScreen(env: s.env, tableId: t1, orderId: o1, bill: s.bill));
      await tapKey(t, 'mode-item');
      await tapKey(t, 'item-55000000-0000-0000-0000-0000000000e2-1');
      await tapKey(t, 'save-split');
      final parts = argsOf(s.calls('rst_bill_split').single)['parts'] as List;
      expect(parts[0]['item_ids'], ['55000000-0000-0000-0000-0000000000e1']);
      expect(parts[1]['item_ids'], ['55000000-0000-0000-0000-0000000000e2']);
    });

    testWidgets('by item: a guest with no item is stopped before sending', (t) async {
      final s = Fake();
      await show(t, BillSplitScreen(env: s.env, tableId: t1, orderId: o1, bill: s.bill));
      await tapKey(t, 'mode-item');
      await tapKey(t, 'save-split');
      expect(find.text('Give Guest 2 at least one item.'), findsOneWidget);
      expect(s.calls('rst_bill_split'), isEmpty);
    });

    testWidgets('by amount: what is left to share is shown; the server refusal is shown as it says', (t) async {
      final s = Fake();
      s.on['rst_bill_split'] = (r) => err(400, 'the parts add up to 1000 but 1050 is due', 'bad_request');
      await show(t, BillSplitScreen(env: s.env, tableId: t1, orderId: o1, bill: s.bill));
      await tapKey(t, 'mode-amount');
      await t.enterText(find.byKey(const ValueKey('amount-0')), '600');
      await t.pump();
      expect(tester(t, const ValueKey('left-to-share')), '₹450');
      await t.enterText(find.byKey(const ValueKey('amount-1')), '400');
      await tapKey(t, 'save-split');
      expect(find.text('the parts add up to 1000 but 1050 is due'), findsOneWidget);
    });

    testWidgets('a part is paid on the Checkout with the part id; back on the split the next guest is offered', (t) async {
      final s = Fake()..view1 = copy('view1s');
      s.on['rst_bill_pay'] = (r) => ok({...copy('paypart'), 'part_label': 'Guest 2'});
      await show(t, BillSplitScreen(env: s.env, tableId: t1, orderId: o1, bill: s.bill));
      await tapKey(t, 'take-payment');
      expect(find.text('Table T1 · Guest 2'), findsOneWidget);
      expect(tester(t, const ValueKey('total-due')), '₹420');
      expect(find.text('DISCOUNT CODE'), findsNothing);
      await tapText(t, 'Complete Payment · Guest 2');
      final a = argsOf(s.calls('rst_bill_pay').single);
      expect(a['part_id'], '53841450-cfc8-4b07-bed7-f56483c022dc');
      expect(a['method'], 'cash');
      expect(find.text('Split the bill'), findsOneWidget);
    });

    testWidgets('the last part paid opens the success card with the whole bill and Split', (t) async {
      final s = Fake()..view1 = copy('view1s');
      await show(t, BillSplitScreen(env: s.env, tableId: t1, orderId: o1, bill: s.bill));
      await tapKey(t, 'take-payment');
      await t.enterText(find.byKey(const ValueKey('bill-received')), '500');
      await tapText(t, 'Complete Payment · Guest 2');
      expect(find.text('Transaction Successful'), findsOneWidget);
      expect(find.text('₹1,050'), findsOneWidget);
      expect(find.text('Split'), findsOneWidget);
      expect(find.textContaining('The table is free'), findsOneWidget);
    });
  });

  group('Success and Send receipt (steps 4 and 5)', () {
    testWidgets('a table with another open bill offers it next', (t) async {
      final s = Fake();
      await show(t, BillPaidScreen(env: s.env, tableId: t2, bill: s.bill, result: Facts({...copy('paynext'), 'next_order_id': '55000000-0000-0000-0000-0000000000d3', 'table_settled': false})));
      expect(find.text('Next bill on this table'), findsOneWidget);
      expect(find.text('This table still has an open bill.'), findsOneWidget);
      await tapKey(t, 'next-bill');
      expect(find.text('Checkout'), findsOneWidget);
    });

    testWidgets('Send receipt lists the printer and the customer number; WhatsApp is logged and opened', (t) async {
      final s = Fake();
      await show(t, BillReceiptScreen(env: s.env, orderId: o1, bill: s.bill, openUrl: s.open));
      expect(find.text('Send receipt'), findsOneWidget);
      expect(find.text('#R5501 · ₹1,050 paid'), findsOneWidget);
      expect(find.text('Counter printer 1'), findsOneWidget);
      expect(find.text('9876543210'), findsOneWidget);
      await tapKey(t, 'receipt-whatsapp');
      await tapKey(t, 'receipt-send');
      expect(argsOf(s.calls('rst_receipt_log').single), {'order_id': o1, 'channel': 'whatsapp', 'to': '9876543210'});
      expect(s.opened.single.host, 'api.whatsapp.com');
      expect(s.opened.single.queryParameters['phone'], '919876543210');
      expect(s.opened.single.queryParameters['text'], contains('Receipt R5501'));
    });

    testWidgets('Email asks for the address and opens the mail app; Print is logged with the printer', (t) async {
      final s = Fake();
      await show(t, BillReceiptScreen(env: s.env, orderId: o1, bill: s.bill, openUrl: s.open));
      await tapKey(t, 'receipt-email');
      await t.enterText(find.byKey(const ValueKey('receipt-to')), 'asha@example.com');
      await tapKey(t, 'receipt-send');
      expect(s.opened.single.scheme, 'mailto');
      expect(s.opened.single.path, 'asha@example.com');
      await tapKey(t, 'receipt-print');
      final logs = s.calls('rst_receipt_log').map(argsOf).toList();
      expect(logs.map((a) => a['channel']), ['email', 'print']);
      expect(logs.last['to'], 'Counter printer 1');
    });

    testWidgets('a refused send says why and opens nothing', (t) async {
      final s = Fake();
      s.on['rst_receipt_log'] = (r) => err(400, 'enter a mobile number', 'bad_request');
      await show(t, BillReceiptScreen(env: s.env, orderId: o1, bill: s.bill, openUrl: s.open));
      await tapKey(t, 'receipt-sms');
      await t.enterText(find.byKey(const ValueKey('receipt-to')), '12');
      await tapKey(t, 'receipt-send');
      expect(find.text('enter a mobile number'), findsOneWidget);
      expect(s.opened, isEmpty);
    });
  });

  group('The whole journey from the table', () {
    testWidgets('Take Payment → pay → Print Receipt → Back to tables lands on the floor', (t) async {
      final s = Fake();
      s.on['rst_bill_pay'] = (r) => ok({...copy('paylast'), 'amount': 1050, 'payment_method': 'card', 'method': 'card', 'tendered': null, 'change': 0});
      await show(t, _Floor(s));
      await tapKey(t, 'open-table');
      expect(find.text('Table T1 Order'), findsOneWidget);
      await tapKey(t, 'take-payment');
      await tapKey(t, 'method-UPI / QR');
      await tapText(t, 'Complete Payment');
      await tapKey(t, 'confirm-yes');
      expect(find.text('Transaction Successful'), findsOneWidget);
      await tapText(t, 'Print Receipt');
      expect(find.text('Send receipt'), findsOneWidget);
      await tapKey(t, 'back-to-tables');
      expect(find.text('Floor'), findsOneWidget);
      expect(find.text('Table T1 Order'), findsNothing);
    });

    testWidgets('Generate Bill moves the orders to awaiting payment, then opens the Checkout', (t) async {
      final s = Fake();
      s.orderView = {
        ...s.orderView,
        'orders': [
          {'id': o1, 'display_no': 'R5501', 'status': 'delivered', 'updated_at': '2026-10-20T06:00:00+00:00', 'total': 1050, 'subtotal': 1000}
        ],
        'can': {...s.orderView['can'] as Map, 'generate_bill': true},
      };
      await show(t, TableOrderScreen(env: s.env, tableId: t1, bill: s.bill));
      await tapText(t, 'Generate Bill');
      expect(argsOf(s.calls('pos_set_order_status').single), containsPair('to', 'awaiting_payment'));
      expect(find.text('Checkout'), findsOneWidget);
    });

    testWidgets('New Order on the success card also goes back to the floor', (t) async {
      final s = Fake();
      await show(t, _Floor(s));
      await tapKey(t, 'open-table');
      await tapKey(t, 'take-payment');
      await tapText(t, 'Complete Payment');
      await tapText(t, 'New Order');
      expect(find.text('Floor'), findsOneWidget);
    });
  });
}

/// The text of the widget with [key].
String tester(WidgetTester t, Key key) => (t.widget(find.byKey(key)) as Text).data ?? '';
