import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/money/store_money.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart' show toast;

// The store's minimal Money tab (founder, 28 Oct 2026).

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

class Fake {
  final requests = <http.Request>[];
  Map<String, dynamic> body(String fn) => jsonDecode(requests.lastWhere((r) => fnOf(r) == fn).body) as Map<String, dynamic>;
  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
  bool closed = false;
  late final api = StoreMoneyApi(baseUrl: 'http://t.test', accessToken: () => 't', client: MockClient((r) async {
    requests.add(r);
    return switch (fnOf(r)) {
      'smoney_home' => ok({
          'today': {'in_minor': 120000, 'out_minor': 50000, 'net_minor': 70000},
          'accounts': [
            {'key': 'cash', 'name': 'Cash drawer', 'balance_minor': 198000},
            {'key': 'upi', 'name': 'UPI', 'balance_minor': 120600},
            {'key': 'bank', 'name': 'Bank', 'balance_minor': 183000},
          ],
          'total_minor': 501600, 'customer_dues_minor': 52395, 'supplier_dues_minor': 491800,
          'week': [for (var i = 22; i <= 28; i++) {'day': '2026-10-$i', 'in_minor': i * 1000, 'out_minor': i * 500}],
          'can_record': true, 'can_void': true,
        }),
      'smoney_entries' => ok({
          'entries': [
            {'id': 'e1', 'no': 'TXN-0001', 'date': '2026-10-28', 'account': 'cash', 'direction': 'out', 'kind': 'expense', 'amount_minor': 50000, 'category': 'Electricity', 'status': 'posted'},
            {'id': null, 'date': '2026-10-28', 'account': 'upi', 'direction': 'in', 'kind': 'sales', 'amount_minor': 120000, 'status': 'posted', 'auto': true},
          ],
        }),
      'smoney_record' => ok({'no': 'TXN-0002', 'replayed': false}),
      'smoney_register' => ok({'day': '2026-10-28', 'opening_minor': 198000, 'sales_minor': 0, 'cash_in_minor': 0, 'refunds_minor': 0, 'cash_out_minor': 50000, 'expected_minor': 148000,
          'closed': closed ? {'counted_minor': 146000, 'expected_minor': 148000, 'difference_minor': -2000, 'by': 'Raj'} : null}),
      'smoney_close_day' => () {
          closed = true;
          return ok({'day': '2026-10-28', 'opening_minor': 198000, 'sales_minor': 0, 'cash_in_minor': 0, 'refunds_minor': 0, 'cash_out_minor': 52000, 'expected_minor': 146000,
            'closed': {'counted_minor': 146000, 'expected_minor': 148000, 'difference_minor': -2000, 'by': 'Raj'}});
        }(),
      'smoney_dues' => ok({
          'customers': [{'party': 'Ramesh', 'due_minor': 52395}],
          'suppliers': [{'receipt_document_id': 'r1', 'supplier': 'Metro', 'invoice_no': 'INV-77', 'invoice_date': '2026-10-27', 'total_minor': 491800, 'paid_minor': 0, 'credit_minor': 0, 'due_minor': 491800}],
        }),
      _ => ok({}),
    };
  }));
}

Future<void> show(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(780, 4000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: w));
  await t.pumpAndSettle();
}

Future<void> tapKey(WidgetTester t, String key) async {
  t.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)).removeCurrentSnackBar();
  await t.pump();
  final f = find.byKey(ValueKey(key));
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('today, the three accounts and their total, the week, and Transactions first', (t) async {
    final f = Fake();
    await show(t, StoreMoneyScreen(api: f.api, today: DateTime(2026, 10, 28)));
    expect(find.text('₹5,016'), findsOneWidget); // total balance
    expect(find.text('₹1,980'), findsOneWidget); // cash drawer
    expect(find.text('₹1,206'), findsWidgets); // UPI
    expect(find.text('₹4,918'), findsOneWidget); // you owe suppliers
    expect(find.text('Money in vs out'), findsOneWidget);
    expect(find.text('Electricity', findRichText: true), findsNothing);
    expect(find.text('Expense'), findsOneWidget);
    expect(find.text('Sales'), findsOneWidget); // the day's sales, by itself
    expect(f.body('smoney_entries'), containsPair('from', '2026-10-01'));
  });

  testWidgets('Record transaction: money out as an expense from the cash drawer', (t) async {
    final f = Fake();
    await show(t, StoreMoneyScreen(api: f.api, today: DateTime(2026, 10, 28)));
    await tapKey(t, 'record-transaction');
    expect(find.text('Record transaction'), findsWidgets);
    await tapKey(t, 'record-save');
    expect(toast('Enter the amount.'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('record-amount')), '500');
    await tapKey(t, 'record-save');
    final b = f.body('smoney_record');
    expect(b['kind'], 'expense');
    expect(b['account'], 'cash');
    expect(b['amount_minor'], 50000);
    expect(f.calls('smoney_record').single.headers['Idempotency-Key'], startsWith('sm-'));
  });

  testWidgets('a transfer from cash to bank', (t) async {
    final f = Fake();
    await show(t, StoreMoneyScreen(api: f.api, today: DateTime(2026, 10, 28)));
    await tapKey(t, 'record-transaction');
    await t.tap(find.text('Transfer'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('record-amount')), '1000');
    await tapKey(t, 'record-save');
    expect(f.body('smoney_record'), allOf(containsPair('kind', 'transfer'), containsPair('account', 'cash'), containsPair('to_account', 'bank')));
  });

  testWidgets('cash register: what should be in the drawer, and Close day books the count', (t) async {
    final f = Fake();
    await show(t, StoreMoneyScreen(api: f.api, today: DateTime(2026, 10, 28)));
    await tapKey(t, 'money-part-register');
    expect(find.text('₹1,480'), findsOneWidget);
    await tapKey(t, 'close-day');
    await t.enterText(find.byKey(const ValueKey('close-counted')), '1460');
    await tapKey(t, 'close-confirm');
    expect(f.body('smoney_close_day'), containsPair('counted_minor', 146000));
    expect(find.byKey(const ValueKey('day-closed')), findsOneWidget);
  });

  testWidgets('dues: a supplier bill to pay opens the form with its amount and records against the bill', (t) async {
    final f = Fake();
    await show(t, StoreMoneyScreen(api: f.api, today: DateTime(2026, 10, 28)));
    await tapKey(t, 'money-part-dues');
    expect(find.text('Ramesh'), findsOneWidget);
    expect(find.text('Metro'), findsOneWidget);
    await t.tap(find.descendant(of: find.byKey(const ValueKey('due-bill-r1')), matching: find.text('Pay')));
    await t.pumpAndSettle();
    expect(find.text('Pay supplier bill'), findsOneWidget);
    expect(t.widget<TextField>(find.byKey(const ValueKey('record-amount'))).controller!.text, '4918');
    await tapKey(t, 'record-save');
    expect(f.body('smoney_record'), allOf(containsPair('kind', 'supplier_payment'), containsPair('bill_receipt_id', 'r1'), containsPair('party', 'Metro')));
  });
}
