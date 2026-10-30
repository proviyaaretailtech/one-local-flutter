// Restaurant Money in the store's design (0622): the wallet card, the OneLocal and credit cards, the cash register with Close day, dues,
// Money in / Money out with dates, methods and Add / Pay money, and Transfer (UPI app with the amount filled in, card, move between accounts).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/account/wallet_api.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/money/rst_money.dart';
import 'package:vinii_pos/money/rst_money_api.dart';
import 'package:vinii_pos/money/rst_money_flow.dart';
import 'package:vinii_pos/ui/theme.dart';

class Fake {
  Fake([this.answer]);
  final http.Response? Function(String fn, Map<String, dynamic> body)? answer;
  final calls = <(String, Map<String, dynamic>, String?)>[];
  Map<String, dynamic> register = {
    'day': '2026-10-29', 'opening_minor': 0, 'cash_sales_minor': 79000, 'other_in_minor': 0, 'refunds_minor': 0, 'paid_out_minor': 0,
    'expected_minor': 79000, 'closed': null, 'can_close': true,
  };
  late final client = MockClient((r) async {
    final fn = r.url.pathSegments.last;
    final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
    calls.add((fn, body, r.headers['Idempotency-Key']));
    final a = answer?.call(fn, body);
    if (a != null) return a;
    return ok(switch (fn) {
      'rmoney_home' => {
          'accounts': [
            {'key': 'cash', 'name': 'Cash drawer', 'balance_minor': 79000},
            {'key': 'upi', 'name': 'UPI', 'balance_minor': 0},
            {'key': 'bank', 'name': 'Bank', 'balance_minor': 0},
          ],
          'total_minor': 79000, 'can_record': true, 'can_void': true,
        },
      'wallet_overview' => {'unsettled': {'due': 0}, 'on_the_way': {'amount': 0}},
      'rmoney_register' => register,
      'rmoney_close_day' => register = {...register, 'closed': {'counted_minor': body['counted_minor'], 'expected_minor': 79000, 'difference_minor': (body['counted_minor'] as int) - 79000}},
      'rmoney_dues' => {
          'to_collect': [
            {'order_id': 'o1', 'reference': 'P-00060', 'name': 'Ravi (test)', 'amount_minor': 50000, 'paid_minor': 0, 'left_minor': 50000},
          ],
          'to_pay': [],
          'collect_minor': 50000, 'pay_minor': 0,
        },
      'rmoney_entries_list' => {
          'from': body['from'], 'to': body['to'], 'count': body['direction'] == 'in' ? 1 : 0, 'total_minor': body['direction'] == 'in' ? 79000 : 0,
          'rows': body['direction'] == 'in'
              ? [
                  {'id': 'p1', 'source': 'sale', 'kind': 'sales', 'title': 'Sales · P-00052', 'direction': 'in', 'method': 'cash', 'amount_minor': 79000, 'day': '2026-10-29', 'voidable': false},
                ]
              : [],
        },
      'rmoney_contacts_list' => {
          'saved': [{'id': 'c1', 'name': 'Fresh Farm (test)', 'phone': '+919800000123', 'upi_id': 'freshfarm@okaxis'}],
          'recent': [{'name': 'Nandini Dairy', 'phone': ''}],
        },
      'rmoney_record' => {'id': 'm1', 'entry_no': 'MN-00001'},
      _ => <String, dynamic>{},
    });
  });
  late final rpc = RpcClient(client: client, baseUrl: 'http://pos.test', accessToken: () => 't');
  late final api = RstMoneyApi(rpc: rpc);
  late final wallet = WalletApi(rpc: rpc);
  Iterable<Map<String, dynamic>> of(String fn) => calls.where((c) => c.$1 == fn).map((c) => c.$2);
}

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> show(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(800, 1720); // a 400 × 860 phone
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: w));
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pumpAndSettle();
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  final today = DateTime(2026, 10, 29, 14, 20);

  testWidgets('the wallet balance with the cash drawer, UPI and bank; Money in, Money out, Transfer; OneLocal wallet; credits; the cash register', (t) async {
    final f = Fake();
    await show(t, RstMoneyScreen(api: f.api, walletApi: f.wallet, today: today));
    expect(find.text('Your wallet balance'), findsOneWidget);
    expect(find.byKey(const ValueKey('rm-total')), findsOneWidget);
    expect(find.text('Cash drawer ₹790'), findsOneWidget);
    expect(find.text('UPI ₹0'), findsOneWidget);
    expect(find.text('Bank ₹0'), findsOneWidget);
    for (final l in ['Money in', 'Money out', 'Transfer', 'OneLocal wallet', 'Due to you', 'Ad credits', 'Discount credits', 'Cash register', 'Dues']) {
      expect(find.text(l), findsWidgets, reason: l);
    }
    expect(find.text('Cash drawer · 29 Oct'), findsOneWidget);
    expect(find.text('+ ₹790'), findsOneWidget, reason: 'cash sales');
    expect(t.widget<Text>(find.byKey(const ValueKey('rm-expected'))).data, '₹790');
  });

  testWidgets('Close day: the counted cash is sent; the drawer then says it is closed and how much was short', (t) async {
    final f = Fake();
    await show(t, RstMoneyScreen(api: f.api, walletApi: f.wallet, today: today));
    await tap(t, find.byKey(const ValueKey('rm-close-day')));
    await t.enterText(find.byKey(const ValueKey('rm-counted')), '780');
    await tap(t, find.byKey(const ValueKey('rm-close-save')));
    expect(f.of('rmoney_close_day').single['counted_minor'], 78000);
    expect(find.byKey(const ValueKey('rm-closed')), findsOneWidget);
    expect(find.textContaining('₹10 short'), findsWidgets);
    expect(find.byKey(const ValueKey('rm-close-day')), findsNothing);
  });

  testWidgets('Dues: a bill on credit with Collect, which records the due as money in from that customer for that bill', (t) async {
    final f = Fake();
    await show(t, RstMoneyScreen(api: f.api, walletApi: f.wallet, today: today));
    await tap(t, find.byKey(const ValueKey('rm-part-dues')));
    expect(find.text('Ravi (test)'), findsOneWidget);
    expect(find.text('No supplier bills to pay.'), findsOneWidget);
    await tap(t, find.byKey(const ValueKey('rm-collect-P-00060')));
    expect(find.text('500'), findsOneWidget, reason: 'what is left, filled in');
    await tap(t, find.byKey(const ValueKey('rm-entry-method-upi')));
    await tap(t, find.byKey(const ValueKey('rm-entry-save')));
    final b = f.of('rmoney_record').single;
    expect(b['direction'], 'in');
    expect(b['kind'], 'due_received');
    expect(b['party'], 'Ravi (test)');
    expect(b['reference'], 'P-00060');
    expect(b['method'], 'upi');
    expect(b['amount_minor'], 50000);
  });

  testWidgets('Dues: a purchase bill saved from Received is paid as money out against that bill; too much cash says what is in the drawer', (t) async {
    var refuse = true;
    final f = Fake((fn, body) => switch (fn) {
          'rmoney_dues' => ok({
              'to_collect': [],
              'to_pay': [
                {'kind': 'purchase_bill', 'bill_receipt_id': 'r1', 'reference': 'LD-77', 'name': 'Latur Dairy', 'amount_minor': 100000, 'paid_minor': 40000, 'left_minor': 60000},
              ],
              'collect_minor': 0, 'pay_minor': 60000,
            }),
          'rmoney_record' when refuse => http.Response(jsonEncode({'detail': 'Only ₹108 in the cash drawer.', 'code': 'not_enough_cash'}), 400,
              headers: {'content-type': 'application/json'}),
          _ => null,
        });
    await show(t, RstMoneyScreen(api: f.api, walletApi: f.wallet, today: today));
    await tap(t, find.byKey(const ValueKey('rm-part-dues')));
    await tap(t, find.byKey(const ValueKey('rm-pay-LD-77')));
    expect(find.text('Purchase bill LD-77 · ₹600 left'), findsOneWidget);
    await tap(t, find.byKey(const ValueKey('rm-invoice-method-cash')));
    await tap(t, find.byKey(const ValueKey('rm-invoice-save')));
    expect(find.text('Only ₹108 in the cash drawer.'), findsOneWidget);
    await t.pumpAndSettle(const Duration(seconds: 4));
    refuse = false;
    await tap(t, find.byKey(const ValueKey('rm-invoice-method-upi')));
    await tap(t, find.byKey(const ValueKey('rm-invoice-save')));
    final b = f.of('rmoney_record').last;
    expect(b, {'direction': 'out', 'bill_receipt_id': 'r1', 'amount_minor': 60000, 'method': 'upi'});
    expect(f.of('money_invoice_pay'), isEmpty);
    expect(find.byKey(const ValueKey('rm-invoice-save')), findsNothing, reason: 'saved: the sheet closes');
  });

  testWidgets('Money in: the total and entries for today, the list; a method pill and the dates ask again; Add money saves once with a key', (t) async {
    final f = Fake();
    await show(t, RstMoneyFlowScreen(api: f.api, direction: 'in', today: today));
    expect(t.widget<Text>(find.byKey(const ValueKey('rm-flow-total'))).data, '₹790');
    expect(find.text('1 entry'), findsOneWidget);
    expect(find.text('Money received'), findsOneWidget);
    expect(find.text('Sales · P-00052'), findsOneWidget);
    expect(find.text('Cash · 29 Oct'), findsOneWidget);
    expect(f.of('rmoney_entries_list').last, containsPair('from', '2026-10-29'));
    await tap(t, find.byKey(const ValueKey('rm-method-upi')));
    expect(f.of('rmoney_entries_list').last['method'], 'upi');
    await tap(t, find.byKey(const ValueKey('rm-range')));
    await tap(t, find.text('Last 7 days').last);
    expect(f.of('rmoney_entries_list').last['from'], '2026-10-23');
    await tap(t, find.byKey(const ValueKey('rm-add')));
    await t.enterText(find.byKey(const ValueKey('rm-entry-amount')), '250');
    await tap(t, find.byKey(const ValueKey('rm-entry-save')));
    final b = f.of('rmoney_record').single;
    expect(b, containsPair('direction', 'in'));
    expect(b, containsPair('amount_minor', 25000));
    expect(b, containsPair('method', 'cash'));
    expect(f.calls.where((c) => c.$1 == 'rmoney_record').single.$3, startsWith('rm-'), reason: 'an idempotency key');
  });

  testWidgets('Money out: nothing in these dates; Pay money with Other needs what it was for; PDF hands over a file', (t) async {
    final f = Fake();
    Uint8List? pdf;
    await show(t, RstMoneyFlowScreen(api: f.api, direction: 'out', today: today, sharePdf: (b, n) async => pdf = b));
    expect(find.text('Nothing in these dates.'), findsOneWidget);
    expect(find.text('0 entries'), findsOneWidget);
    await tap(t, find.byKey(const ValueKey('rm-pdf')));
    expect(pdf, isNotNull);
    await tap(t, find.byKey(const ValueKey('rm-pay')));
    await t.enterText(find.byKey(const ValueKey('rm-entry-amount')), '120');
    await tap(t, find.byKey(const ValueKey('rm-entry-kind')));
    await tap(t, find.text('Other').last);
    await tap(t, find.byKey(const ValueKey('rm-entry-save')));
    expect(f.of('rmoney_record'), isEmpty, reason: 'what it was for is needed');
    await t.enterText(find.byKey(const ValueKey('rm-entry-what')), 'Gas cylinder');
    await tap(t, find.byKey(const ValueKey('rm-entry-save')));
    expect(f.of('rmoney_record').single, containsPair('category', 'Gas cylinder'));
    expect(f.of('rmoney_record').single, containsPair('direction', 'out'));
  });

  testWidgets('Transfer by UPI: pick a contact, the amount; GPay opens with the UPI ID and amount; Yes records it as money out with the UTR', (t) async {
    final f = Fake();
    final opened = <Uri>[];
    await show(t, Builder(builder: (c) => TextButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => RstTransferScreen(api: f.api, openUrl: (u) async {
          opened.add(u);
          return true;
        }))), child: const Text('go'))));
    await tap(t, find.text('go'));
    await tap(t, find.byKey(const ValueKey('rm-pay-gpay')));
    expect(opened, isEmpty, reason: 'no contact yet');
    await tap(t, find.byKey(const ValueKey('rm-contact')));
    await tap(t, find.text('Fresh Farm (test)'));
    await t.enterText(find.byKey(const ValueKey('rm-transfer-amount')), '300');
    await tap(t, find.byKey(const ValueKey('rm-pay-gpay')));
    expect(opened.single.scheme, 'tez');
    expect(opened.single.queryParameters, containsPair('pa', 'freshfarm@okaxis'));
    expect(opened.single.queryParameters, containsPair('am', '300.00'));
    await t.enterText(find.byKey(const ValueKey('rm-utr')), 'UTR42');
    await tap(t, find.byKey(const ValueKey('rm-paid')));
    final b = f.of('rmoney_record').single;
    expect(b, containsPair('method', 'gpay'));
    expect(b, containsPair('party', 'Fresh Farm (test)'));
    expect(b, containsPair('reference', 'UTR42'));
    expect(b, containsPair('kind', 'supplier_payment'));
    expect(find.text('go'), findsOneWidget, reason: 'back on the Money page');
  });

  testWidgets('Transfer: a contact without a UPI ID asks for it; Card saves a card payment; Move money moves between accounts', (t) async {
    final f = Fake();
    await show(t, RstTransferScreen(api: f.api, openUrl: (_) async => true));
    await tap(t, find.byKey(const ValueKey('rm-contact')));
    await tap(t, find.text('Nandini Dairy'));
    expect(find.byKey(const ValueKey('rm-contact-upi')), findsOneWidget, reason: 'a supplier without a UPI ID opens the contact form');
    await t.enterText(find.byKey(const ValueKey('rm-contact-upi')), 'nandini@oksbi');
    f.calls.clear();
    await tap(t, find.byKey(const ValueKey('rm-contact-save')));
    expect(f.of('rmoney_contact_save').single, containsPair('upi_id', 'nandini@oksbi'));
  });

  testWidgets('Transfer by card and Move money', (t) async {
    final f = Fake((fn, b) => fn == 'rmoney_contact_save' ? ok({'id': 'c2', 'name': b['name'], 'phone': '', 'upi_id': ''}) : null);
    await show(t, RstTransferScreen(api: f.api, openUrl: (_) async => true));
    await tap(t, find.byKey(const ValueKey('rm-contact')));
    await tap(t, find.text('Fresh Farm (test)'));
    await t.enterText(find.byKey(const ValueKey('rm-transfer-amount')), '99.50');
    await tap(t, find.byKey(const ValueKey('rm-how-card')));
    await tap(t, find.byKey(const ValueKey('rm-pay-card')));
    expect(f.of('rmoney_record').single, containsPair('method', 'card'));
    expect(f.of('rmoney_record').single, containsPair('amount_minor', 9950));
  });

  testWidgets('Move money between your own accounts', (t) async {
    final f = Fake();
    await show(t, RstTransferScreen(api: f.api, openUrl: (_) async => true));
    await tap(t, find.byKey(const ValueKey('rm-move')));
    await t.enterText(find.byKey(const ValueKey('rm-move-amount')), '500');
    await tap(t, find.byKey(const ValueKey('rm-move-save')));
    expect(f.of('rmoney_record').single, allOf(containsPair('direction', 'move'), containsPair('from_account', 'cash'), containsPair('to_account', 'bank'), containsPair('amount_minor', 50000)));
  });
}
