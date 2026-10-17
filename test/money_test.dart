import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/app_routes.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/money/money_api.dart';
import 'package:vinii_pos/money/money_env.dart';
import 'package:vinii_pos/money/money_home.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

/// Answers captured from the real local database (database/tests/430_money_section_k.sql story): the app is built against what the server sends.
final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/money_server.json').readAsStringSync()) as Map<String, dynamic>;

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) =>
    http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;
Map<String, dynamic> argsOf(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

const _answers = {
  'money_options': 'options_owner', 'money_overview': 'overview', 'money_payments_list': 'payments', 'money_transactions_list': 'transactions', 'money_invoices_list': 'invoices',
  'money_cashbook': 'cashbook', 'money_expenses_list': 'expenses', 'money_refunds_list': 'refunds', 'money_settlements_list': 'settlements',
  'money_settlement_detail': 'settlement_detail', 'money_payouts_list': 'payouts', 'money_reports': 'reports', 'money_report_rows': 'report_rows',
};

class Fake {
  Fake([this.handler]);
  final http.Response? Function(http.Request r)? handler;
  final requests = <http.Request>[];
  late final env = MoneyEnv(
    api: MoneyApi(
      baseUrl: 'http://money.test',
      accessToken: () => 'token-123',
      client: MockClient((r) async {
        requests.add(r);
        final custom = handler?.call(r);
        if (custom != null) return custom;
        final k = _answers[fnOf(r)];
        if (k != null) return ok(fx[k]);
        return err(404, 'not found: ${fnOf(r)}');
      }),
    ),
    onNavigate: (_) {},
  );
  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
}

Future<void> show(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 5200);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

Widget screen(Fake f, String key) {
  f.env.screenFor = moneyScreenFor;
  return moneyScreenFor(f.env, key);
}

void main() {
  group('display formats', () {
    test('money groups like India and keeps paise', () {
      expect(money(1234567), '₹12,345.67');
      expect(money(50000, whole: true), '₹500');
      expect(money(50050, whole: true), '₹500.50');
      expect(money(-30000, whole: true), '−₹300');
      expect(money(8000, sign: true), '+₹80.00');
      expect(money(12345678900), '₹12,34,56,789.00');
      expect(money(null), '–');
    });
    test('rupees typed by a person become paise, anything else is refused', () {
      expect(parseRupees('250'), 25000);
      expect(parseRupees('1,250.5'), 125050);
      expect(parseRupees('0.07'), 7);
      expect(parseRupees('abc'), isNull);
      expect(parseRupees('1.234'), isNull);
      expect(parseRupees(''), isNull);
    });
    test('the CSV writes money columns as rupees and quotes commas', () {
      final csv = csvOf(Facts({
        'columns': [{'label': 'Ref', 'type': 'text'}, {'label': 'Amount (INR)', 'type': 'money'}],
        'rows': [['A,B', 12345], ['C', null]],
      }));
      expect(csv, 'Ref,Amount (INR)\n"A,B",123.45\nC,\n');
    });
    test('the real server payments report turns into a CSV', () {
      final csv = csvOf(Facts((fx['report_rows'] as Map).cast<String, dynamic>()));
      expect(csv.split('\n').first, 'Payment,Order,Method,Paid at,Amount (INR)');
      expect(csv, contains('ORD-2'));
      expect(csv, contains('1250.00'));
    });
    test('idempotency keys are unique and long enough', () {
      expect(MoneyApi.newKey(), isNot(MoneyApi.newKey()));
      expect(MoneyApi.newKey().length, greaterThan(20));
    });
  });

  group('overview', () {
    testWidgets('shows the server figures: balance, pending payouts, payments, awaiting, commission rate printed from data', (t) async {
      final f = Fake();
      await show(t, screen(f, 'overview'));
      expect(find.text('Overview'), findsWidgets);
      expect(find.text('Money / Overview'), findsOneWidget);
      expect(find.text('₹1,850.00'), findsOneWidget); // cashbook closing
      expect(find.text('Cashbook • on hand'), findsOneWidget);
      expect(find.text('₹2,884.33'), findsOneWidget); // pending payouts
      expect(find.text('₹2,590.00'), findsWidgets); // payments received
      expect(find.text('Payments trend'), findsOneWidget);
      expect(find.textContaining('Next settlement estimate'), findsOneWidget);
      expect(f.calls('money_overview').single.headers['authorization'], 'Bearer token-123');
      expect(argsOf(f.calls('money_overview').single)['period'], 'week');
    });

    testWidgets('a manager gets no payout tile and no commission row (the server sends them as null)', (t) async {
      final o = Map<String, dynamic>.from(fx['overview'] as Map)..['payouts'] = null..['commission'] = null..['next_settlement'] = null;
      final f = Fake((r) => fnOf(r) == 'money_overview' ? ok(o) : null);
      await show(t, screen(f, 'overview'));
      expect(find.text('Pending payouts'), findsNothing);
      expect(find.text('Awaiting capture'), findsOneWidget);
      expect(find.text('Commission earned'), findsNothing);
      expect(find.textContaining('Next settlement'), findsNothing);
    });

    testWidgets('changing the period asks the server again', (t) async {
      final f = Fake();
      await show(t, screen(f, 'overview'));
      await t.tap(find.text('This week').last);
      await t.pumpAndSettle();
      await t.tap(find.text('This month'));
      await t.pumpAndSettle();
      expect(argsOf(f.calls('money_overview').last)['period'], 'month');
    });

    testWidgets('the Download summary button copies a CSV and says so', (t) async {
      final f = Fake();
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await show(t, screen(f, 'overview'));
      await t.ensureVisible(find.text('Download summary'));
      await t.tap(find.text('Download summary'));
      await t.pumpAndSettle();
      expect(argsOf(f.calls('money_report_rows').single)['report'], 'payments');
      expect(copied, startsWith('Payment,Order,Method'));
      expect(find.textContaining('CSV copied'), findsOneWidget);
    });
  });

  group('payments', () {
    testWidgets('lists payments and the pending attempt with their labels, and the totals exclude pending', (t) async {
      final f = Fake();
      await show(t, screen(f, 'payments'));
      expect(find.text('Recent payments'), findsOneWidget);
      expect(find.textContaining('ORD-2'), findsOneWidget);
      expect(find.text('Paid'), findsWidgets);
      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('Received total excludes pending payments.\nShowing the latest records for this period.'), findsOneWidget);
      expect(find.text('Awaiting capture'), findsOneWidget);
    });

    testWidgets('the method chip sends the filter to the server', (t) async {
      final f = Fake();
      await show(t, screen(f, 'payments'));
      await t.tap(find.text('All methods'));
      await t.pumpAndSettle();
      await t.tap(find.text('Cash'));
      await t.pumpAndSettle();
      expect(argsOf(f.calls('money_payments_list').last)['method'], 'cash');
    });

    testWidgets('a server refusal shows its sentence with a way to retry', (t) async {
      var fail = true;
      final f = Fake((r) {
        if (fnOf(r) == 'money_payments_list' && fail) return err(403, 'Your role cannot see or do this.', 'forbidden');
        return null;
      });
      await show(t, screen(f, 'payments'));
      expect(find.text('Could not load this'), findsOneWidget);
      expect(find.text('Your role cannot see or do this.'), findsOneWidget);
      fail = false;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(find.text('Recent payments'), findsOneWidget);
    });
  });

  group('cashbook and expenses', () {
    testWidgets('cashbook shows opening, received, paid, closing and the entries, with the cash expense once', (t) async {
      final f = Fake();
      await show(t, screen(f, 'cashbook'));
      expect(find.text('Closing balance'), findsOneWidget);
      expect(find.text('₹1,850'), findsWidgets);
      expect(find.textContaining('CASH-002'), findsOneWidget);
      expect(find.text('Counter sales received'), findsOneWidget);
    });

    testWidgets('Cash In sends direction, paise and ONE idempotency key; a failure keeps the sheet and a retry reuses the key', (t) async {
      var fail = true;
      final f = Fake((r) {
        if (fnOf(r) == 'money_cash_record') return fail ? err(400, 'Enter an amount greater than zero.', 'bad_request') : ok({'id': 'x', 'no': 'CASH-009', 'replayed': false});
        return null;
      });
      await show(t, screen(f, 'cashbook'));
      await t.tap(find.text('Cash In'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).at(0), 'Opening float');
      await t.enterText(find.byType(TextField).at(1), '1,000');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(find.text('Enter an amount greater than zero.'), findsOneWidget);
      fail = false;
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      final posts = f.calls('money_cash_record').toList();
      expect(posts.length, 2);
      expect(posts[0].headers['idempotency-key'], posts[1].headers['idempotency-key']);
      expect(argsOf(posts[1])['amount_minor'], 100000);
      expect(argsOf(posts[1])['direction'], 'in');
      expect(find.text('Save'), findsNothing); // sheet closed
    });

    testWidgets('a bad amount is stopped on the phone with a sentence and nothing is sent', (t) async {
      final f = Fake();
      await show(t, screen(f, 'cashbook'));
      await t.tap(find.text('Cash Out'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).at(0), 'Tea');
      await t.enterText(find.byType(TextField).at(1), '1.234');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(find.textContaining('as rupees'), findsOneWidget);
      expect(f.calls('money_cash_record'), isEmpty);
    });

    testWidgets('expenses: total, rows and the Add Expense button; saving posts the day and the method', (t) async {
      final f = Fake((r) => fnOf(r) == 'money_expense_record' ? ok({'id': 'e', 'no': 'EXP-009', 'status': 'posted', 'replayed': false}) : null);
      await show(t, screen(f, 'expenses'));
      expect(find.text('Add Expense'), findsOneWidget);
      expect(find.textContaining('EXP-001'), findsOneWidget);
      await t.tap(find.text('Add Expense'));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Choose'));
      await t.pumpAndSettle();
      await t.tap(find.text('Packaging').last);
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).at(0), 'Carry bags');
      await t.enterText(find.byType(TextField).at(1), '300');
      await t.tap(find.text('Save expense'));
      await t.pumpAndSettle();
      final p = f.calls('money_expense_record').single;
      expect(argsOf(p)['category'], 'Packaging');
      expect(argsOf(p)['amount_minor'], 30000);
      expect(argsOf(p)['method'], 'cash');
      expect(argsOf(p)['expense_date'], fx['expenses']['day']);
      expect(p.headers['idempotency-key'], isNotEmpty);
    });

    testWidgets('a person who may not record sees no Add Expense button (the server said can_record false)', (t) async {
      final e = Map<String, dynamic>.from(fx['expenses'] as Map)..['can_record'] = false..['can_void'] = false;
      final f = Fake((r) => fnOf(r) == 'money_expenses_list' ? ok(e) : null);
      await show(t, screen(f, 'expenses'));
      expect(find.text('Add Expense'), findsNothing);
      expect(find.text('Void'), findsNothing);
    });

    testWidgets('voiding asks for a reason and sends it', (t) async {
      final f = Fake((r) => fnOf(r) == 'money_expense_void' ? ok({'id': 'e', 'status': 'voided', 'replayed': false}) : null);
      await show(t, screen(f, 'expenses'));
      await t.tap(find.text('Void').first);
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).first, 'entered twice');
      await t.tap(find.text('Void expense'));
      await t.pumpAndSettle();
      expect(argsOf(f.calls('money_expense_void').single)['note'], 'entered twice');
    });
  });

  group('refunds and adjustments', () {
    testWidgets('lists the refund and adjustments with signed amounts and statuses', (t) async {
      final f = Fake();
      await show(t, screen(f, 'refunds'));
      expect(find.text('Refund & adjustment list'), findsOneWidget);
      expect(find.textContaining('ADJ-001'), findsOneWidget);
      expect(find.text('−₹250.00'), findsOneWidget);
      expect(find.text('Approved'), findsOneWidget);
      expect(find.text('Review'), findsOneWidget);
      expect(find.text('Refunded'), findsWidgets);
      expect(find.text('Approve'), findsNothing); // the requester cannot decide
    });

    testWidgets('Approve and Reject show only where the server says can_decide, and Reject needs a reason', (t) async {
      final r = Map<String, dynamic>.from(fx['refunds'] as Map);
      r['rows'] = [for (final x in (r['rows'] as List)) {...(x as Map<String, dynamic>), if (x['status'] == 'review') 'can_decide': true}];
      final f = Fake((q) => fnOf(q) == 'money_refunds_list' ? ok(r) : (fnOf(q) == 'money_adjustment_decide' ? ok({'status': 'approved', 'replayed': false}) : null));
      await show(t, screen(f, 'refunds'));
      expect(find.text('Approve'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);
      await t.tap(find.text('Approve'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).first, 'ok to apply');
      await t.tap(find.text('Approve').last);
      await t.pumpAndSettle();
      final p = argsOf(f.calls('money_adjustment_decide').single);
      expect(p['decision'], 'approve');
      expect(p['note'], 'ok to apply');
    });

    testWidgets('requesting an adjustment sends a signed amount in paise', (t) async {
      final f = Fake((q) => fnOf(q) == 'money_adjustment_request' ? ok({'no': 'ADJ-009', 'status': 'review', 'replayed': false}) : null);
      await show(t, screen(f, 'refunds'));
      await t.ensureVisible(find.text('Request adjustment'));
      await t.tap(find.text('Request adjustment'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).at(0), 'Price correction');
      await t.enterText(find.byType(TextField).at(1), '-250');
      await t.tap(find.text('Send for review'));
      await t.pumpAndSettle();
      expect(argsOf(f.calls('money_adjustment_request').single)['amount_minor'], -25000);
    });
  });

  group('settlements, payouts, reports', () {
    testWidgets('settlements: history, tap into the detail with net payable, breakdown, payout details and orders', (t) async {
      final f = Fake();
      await show(t, screen(f, 'settlements'));
      expect(find.text('Settlement history'), findsOneWidget);
      expect(find.text('SET-20260928'), findsOneWidget);
      expect(find.text('Settled'), findsOneWidget);
      await t.tap(find.text('SET-20260928'));
      await t.pumpAndSettle();
      expect(find.text('Settlement Detail'), findsOneWidget);
      expect(find.text('Net payable amount'), findsOneWidget);
      expect(find.text('SETTLEMENT BREAKDOWN'), findsOneWidget);
      expect(find.text('Commission'), findsOneWidget);
      expect(find.text('N278260104821'), findsOneWidget);
      expect(argsOf(f.calls('money_settlement_detail').single)['id'], fx['settlements']['rows'][0]['id']);
      await t.ensureVisible(find.text('Download Statement'));
      await t.tap(find.text('Download Statement'));
      await t.pump();
      expect(find.text('PDF statement opens in a later release.'), findsOneWidget);
    });

    testWidgets('payouts: pending and last paid tiles, rows with status labels', (t) async {
      final f = Fake();
      await show(t, screen(f, 'payouts'));
      expect(find.text('Payout list'), findsOneWidget);
      expect(find.text('Pending payouts'), findsOneWidget);
      expect(find.text('Pending'), findsWidgets);
      expect(find.text('Paid'), findsWidgets);
      expect(find.text('Download payout report'), findsOneWidget);
    });

    testWidgets('reports: three categories, each downloads its own CSV; one the role cannot export says so', (t) async {
      final rep = Map<String, dynamic>.from(fx['reports'] as Map);
      rep['reports'] = [for (final r in (rep['reports'] as List)) {...(r as Map<String, dynamic>), if (r['key'] == 'wallet_ledger') 'ready': false}];
      final f = Fake((q) => fnOf(q) == 'money_reports' ? ok(rep) : null);
      await show(t, screen(f, 'reports'));
      expect(find.text('Downloadable reports'), findsOneWidget);
      expect(find.text('Payments & commission'), findsOneWidget);
      await t.tap(find.text('Settlements & payouts'));
      await t.pumpAndSettle();
      expect(argsOf(f.calls('money_report_rows').single)['report'], 'settlements_payouts');
      await t.tap(find.text('Wallet & ledger'));
      await t.pump();
      expect(find.text('Your role cannot export this report.'), findsOneWidget);
    });

    testWidgets('a manager is refused the settlements screen by the server and sees the sentence', (t) async {
      final f = Fake((r) => fnOf(r) == 'money_settlements_list' ? err(403, 'Only whole-business roles can see this.', 'forbidden') : null);
      await show(t, screen(f, 'settlements'));
      expect(find.text('Only whole-business roles can see this.'), findsOneWidget);
    });
  });

  group('transactions and invoices', () {
    testWidgets('transactions: the mixed ledger with signed amounts; a party shows its balance box', (t) async {
      final party = fx['transactions_party'] as Map<String, dynamic>;
      final f = Fake((r) => fnOf(r) == 'money_transactions_list' && argsOf(r)['party'] != null ? ok(party) : null);
      await show(t, screen(f, 'transactions'));
      expect(find.text('Ledger'), findsOneWidget);
      expect(find.textContaining('EXP-001'), findsWidgets);
      expect(find.text('Add party entry'), findsOneWidget);
      await t.tap(find.text('All parties'));
      await t.pumpAndSettle();
      await t.tap(find.text('Krishna'));
      await t.pumpAndSettle();
      expect(find.text('Balance with Krishna'), findsOneWidget);
      expect(find.textContaining('To receive'), findsOneWidget);
      expect(argsOf(f.calls('money_transactions_list').last)['party'], 'Krishna');
    });

    testWidgets('invoices: sales and purchase with their statuses; the purchase can be paid and sends paise', (t) async {
      final f = Fake((r) => fnOf(r) == 'money_invoice_pay' ? ok({'status': 'paid', 'replayed': false}) : null);
      await show(t, screen(f, 'invoices'));
      expect(find.text('INV-S-0001'), findsOneWidget);
      expect(find.text('INV-P-0208'), findsOneWidget);
      expect(find.text('Overdue'), findsOneWidget);
      expect(find.text('Download'), findsWidgets);
      await t.tap(find.text('Record payment'));
      await t.pumpAndSettle();
      await t.tap(find.text('Record payment').last);
      await t.pumpAndSettle();
      final a = argsOf(f.calls('money_invoice_pay').single);
      expect(a['amount_minor'], 300000);
      expect(a['method'], 'bank');
      expect(a['invoice_id'], isNotEmpty);
    });
  });

  group('entry, switcher and wiring', () {
    testWidgets('the Money tab asks what the person may open and lands on the first screen', (t) async {
      final f = Fake();
      await show(t, MoneyHome(env: f.env));
      expect(find.text('Money / Overview'), findsOneWidget);
      expect(f.env.allowed, contains('settlements'));
    });

    testWidgets('a person with no money permission gets a plain sentence', (t) async {
      final f = Fake((r) => fnOf(r) == 'money_options' ? ok({...(fx['options_owner'] as Map<String, dynamic>), 'screens': <String>[]}) : null);
      await show(t, MoneyHome(env: f.env));
      expect(find.textContaining('Your role does not include the money screens'), findsOneWidget);
    });

    testWidgets('a manager is offered only the screens the server listed', (t) async {
      final f = Fake((r) => fnOf(r) == 'money_options' ? ok(fx['options_manager']) : null);
      await show(t, MoneyHome(env: f.env));
      await t.tap(find.byKey(const ValueKey('money-switcher')));
      await t.pumpAndSettle();
      expect(find.text('Payments'), findsOneWidget);
      expect(find.text('Cashbook'), findsOneWidget);
      expect(find.text('Settlements'), findsNothing);
      expect(find.text('Payouts'), findsNothing);
      expect(find.text('Reports'), findsNothing);
      await t.tap(find.text('Cashbook'));
      await t.pumpAndSettle();
      expect(find.text('Closing balance'), findsOneWidget);
    });

    testWidgets('the switcher counts the screens the person really has', (t) async {
      final f = Fake((r) => fnOf(r) == 'money_options' ? ok(fx['options_manager']) : null);
      await show(t, MoneyHome(env: f.env));
      expect(find.text('1/7'), findsOneWidget);
    });

    testWidgets('the other bottom-bar tabs leave the section through onNavigate', (t) async {
      final ids = <String>[];
      final f = Fake();
      final env = MoneyEnv(api: f.env.api, onNavigate: ids.add);
      await show(t, moneyScreenFor(env..screenFor = moneyScreenFor, 'payments'));
      await t.tap(find.bySemanticsLabel('Stock'));
      expect(ids, ['stock']);
    });

    test('HomeNav.money is plugged in by installRoutes', () {
      HomeNav.reset();
      installRoutes();
      expect(HomeNav.money, isNotNull);
      HomeNav.reset();
    });
  });
}
