import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/account/wallet_api.dart';
import 'package:vinii_pos/money/money_flow.dart';
import 'package:vinii_pos/money/money_transfer.dart';
import 'package:vinii_pos/ads/ads_screens.dart';
import 'package:vinii_pos/money/store_money.dart';
import 'package:vinii_pos/onboarding/document_picker.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart' show toast;

// Store Money, redesigned from the founder's sketches (28 Oct 2026): the wallet with Money in / Money out / Transfer, the OneLocal cards on
// the POS + OneLocal plan, Money in and out lists with the add form and receipts, Transfer to a contact, and the cash register and dues.

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

class Fake {
  final requests = <http.Request>[];
  Map<String, dynamic> body(String fn) => jsonDecode(requests.lastWhere((r) => fnOf(r) == fn).body) as Map<String, dynamic>;
  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
  bool closed = false;
  late final api = StoreMoneyApi(baseUrl: 'http://t.test', accessToken: () => 't', client: MockClient((r) async {
    requests.add(r);
    if (r.method == 'PUT') return http.Response('', 200); // the proof photo to its signed slot
    return switch (fnOf(r)) {
      'smoney_stock' => ok({
          'stock_value_minor': 4334500, 'items': 16, 'no_cost': 1, 'losses_minor': 52000,
          'top': [{'name': 'Amul Butter 500g', 'qty': 52, 'unit': 'pc', 'value_minor': 1352000}],
          'losses': [{'reason': 'Damaged in store', 'value_minor': 52000, 'lines': 2}],
        }),
      'smoney_home' => ok({
          'today': {'in_minor': 120000, 'out_minor': 50000, 'net_minor': 70000},
          'accounts': [
            {'key': 'cash', 'name': 'Cash drawer', 'balance_minor': 198000},
            {'key': 'upi', 'name': 'UPI', 'balance_minor': 120600},
            {'key': 'bank', 'name': 'Bank', 'balance_minor': 183000},
          ],
          'total_minor': 501600, 'customer_dues_minor': 52395, 'supplier_dues_minor': 491800,
          'can_record': true, 'can_void': true,
        }),
      'smoney_entries' => ok({
          'entries': [
            {'id': 'e1', 'no': 'TXN-0001', 'date': '2026-10-28', 'account': 'upi', 'method': 'gpay', 'family': 'upi', 'direction': 'in', 'kind': 'other_income',
              'amount_minor': 50000, 'party': '', 'party_phone': '9420071132', 'has_proof': true, 'status': 'posted'},
            {'id': 'e2', 'no': 'TXN-0002', 'date': '2026-10-28', 'account': 'cash', 'method': 'cash', 'family': 'cash', 'direction': 'in', 'kind': 'due_received',
              'amount_minor': 500, 'party': 'Ramesh', 'party_phone': '', 'status': 'void', 'void_reason': 'twice'},
            {'id': null, 'date': '2026-10-28', 'account': 'upi', 'method': 'upi', 'family': 'upi', 'direction': 'in', 'kind': 'sales', 'amount_minor': 120000, 'status': 'posted', 'auto': true},
          ],
        }),
      'smoney_record' => ok({'id': 'n1', 'no': 'TXN-0003', 'date': '2026-10-28', 'replayed': false}),
      'smoney_contacts' => ok({
          'contacts': [{'id': 'c1', 'name': 'Gupta Traders', 'phone': '9876543210', 'upi_id': 'gupta@okhdfc'}],
          'recent': [{'name': 'Ramesh', 'phone': ''}],
        }),
      'smoney_contact_save' => () {
          final b = jsonDecode(r.body) as Map<String, dynamic>;
          return ok({'id': b['id'] ?? 'c9', 'name': b['name'], 'phone': b['phone'] ?? '', 'upi_id': b['upi_id'] ?? ''});
        }(),
      'smoney_proof_slot' => ok({'path': 'org/proofs/p1.jpg', 'upload_url': 'http://storage.test/upload/p1', 'max_bytes': 5242880}),
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
  late final wallet = WalletApi(baseUrl: 'http://t.test', accessToken: () => 't', client: MockClient((r) async {
    requests.add(r);
    return ok({
      'unsettled': {'due': 8000, 'commission': 400, 'orders': 3},
      'on_the_way': {'amount': 2000},
      'paid': {'amount': 0, 'failed_transfers': 0},
      'owed_to_onelocal': {'amount': 0},
      'movements': {'rows': []},
    });
  }));
}

final opened = <Uri>[];

/// A real 1×1 photo, so the preview can draw it.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

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
  setUp(() {
    opened.clear();
    openMoneyLink = (u) async {
      opened.add(u);
      return true;
    };
    canScanProof = () => true;
    scanProof = () async => PickedDocument(name: 'proof.png', bytes: _png, contentType: 'image/png');
  });

  group('home', () {
    testWidgets('Stock in Money: what the stock is worth at cost and what was lost this month, with the detail', (t) async {
      final f = Fake();
      await show(t, StoreMoneyScreen(api: f.api, plan: 'pos_only'));
      expect(t.widget<Text>(find.byKey(const ValueKey('money-stock-value'))).data, '₹43,345');
      expect(t.widget<Text>(find.byKey(const ValueKey('money-stock-lost'))).data, 'Lost this month ₹520');
      await t.tap(find.byKey(const ValueKey('money-stock')));
      await t.pumpAndSettle();
      expect(find.text('Amul Butter 500g'), findsOneWidget);
      expect(find.byKey(const ValueKey('loss-Damaged in store')), findsOneWidget);
      expect(find.textContaining('1 without a cost price'), findsOneWidget);
    });

    testWidgets('the wallet balance with its accounts, and Money in / Money out / Transfer', (t) async {
      final f = Fake();
      await show(t, StoreMoneyScreen(api: f.api, plan: 'pos_only'));
      expect(find.text('Your wallet balance'), findsOneWidget);
      expect(find.text('₹5,016'), findsOneWidget);
      expect(find.text('Cash drawer ₹1,980'), findsOneWidget);
      for (final k in ['money-in', 'money-out', 'money-transfer']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget);
      }
    });

    testWidgets('Purchase POS: no OneLocal wallet and no ad credits', (t) async {
      final f = Fake();
      await show(t, StoreMoneyScreen(api: f.api, walletApi: f.wallet, plan: 'pos_only'));
      expect(find.byKey(const ValueKey('onelocal-wallet')), findsNothing);
      expect(find.byKey(const ValueKey('ad-credits')), findsNothing);
      expect(f.calls('wallet_overview'), isEmpty);
    });

    testWidgets('POS + OneLocal: the OneLocal wallet (due + on the way) and the ad and discount credits', (t) async {
      final f = Fake();
      await show(t, StoreMoneyScreen(api: f.api, walletApi: f.wallet, plan: 'pos_and_onelocal'));
      expect(find.text('OneLocal wallet'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('onelocal-wallet-amount'))).data, '₹10,000');
      expect(find.text('Ad credits'), findsOneWidget);
      expect(find.text('Discount against commission'), findsOneWidget);
      await tapKey(t, 'ad-credits');
      expect(find.byType(AdsHomeScreen), findsOneWidget); // ad credits are coins in the Ads section
    });

    testWidgets('cash register: what should be in the drawer, and Close day books the count', (t) async {
      final f = Fake();
      await show(t, StoreMoneyScreen(api: f.api, plan: 'pos_only'));
      expect(find.text('₹1,480'), findsOneWidget);
      await tapKey(t, 'close-day');
      await t.enterText(find.byKey(const ValueKey('close-counted')), '1460');
      await tapKey(t, 'close-confirm');
      expect(f.body('smoney_close_day'), containsPair('counted_minor', 146000));
      expect(find.byKey(const ValueKey('day-closed')), findsOneWidget);
    });

    testWidgets('dues: a supplier bill opens Pay money with its amount and records against the bill', (t) async {
      final f = Fake();
      await show(t, StoreMoneyScreen(api: f.api, plan: 'pos_only'));
      await tapKey(t, 'money-part-dues');
      expect(find.text('Metro'), findsOneWidget);
      await t.tap(find.descendant(of: find.byKey(const ValueKey('due-bill-r1')), matching: find.text('Pay')));
      await t.pumpAndSettle();
      expect(find.text('Pay supplier bill'), findsOneWidget);
      expect(t.widget<TextField>(find.byKey(const ValueKey('entry-amount'))).controller!.text, '4918');
      await tapKey(t, 'entry-save');
      expect(f.body('smoney_record'), allOf(containsPair('kind', 'supplier_payment'), containsPair('bill_receipt_id', 'r1'), containsPair('party', 'Metro')));
    });
  });

  group('Money in', () {
    testWidgets('the total leaves out cancelled entries; rows show the phone and how it came in; Today by default', (t) async {
      final f = Fake();
      await show(t, MoneyFlowScreen(api: f.api, direction: 'in', today: DateTime(2026, 10, 28)));
      expect(f.body('smoney_entries'), allOf(containsPair('from', '2026-10-28'), containsPair('to', '2026-10-28'), containsPair('direction', 'in')));
      expect(t.widget<Text>(find.byKey(const ValueKey('flow-total'))).data, '₹1,700'); // 500 + 1,200 sales; the cancelled 5 is not counted
      expect(find.text('9420071132'), findsOneWidget);
      expect(find.textContaining('GPay'), findsOneWidget);
      expect(find.text('Sales'), findsOneWidget);
    });

    testWidgets('Cash / UPI / Card filter and the date range ask the server again', (t) async {
      final f = Fake();
      await show(t, MoneyFlowScreen(api: f.api, direction: 'in', today: DateTime(2026, 10, 28)));
      await tapKey(t, 'flow-method-card');
      expect(f.body('smoney_entries'), containsPair('method', 'card'));
      await tapKey(t, 'flow-range');
      await tapKey(t, 'range-month');
      expect(f.body('smoney_entries'), containsPair('from', '2026-10-01'));
    });

    testWidgets('the date pill opens a small calendar: a day shows that day only, and the pill says which', (t) async {
      final f = Fake();
      await show(t, MoneyFlowScreen(api: f.api, direction: 'in', today: DateTime(2026, 10, 28)));
      await tapKey(t, 'flow-range');
      expect(find.byKey(const ValueKey('range-calendar')), findsOneWidget);
      await t.tap(find.text('25'));
      await t.pumpAndSettle();
      expect(f.body('smoney_entries'), allOf(containsPair('from', '2026-10-25'), containsPair('to', '2026-10-25')));
      expect(find.text('25 Oct'), findsOneWidget);
      await tapKey(t, 'flow-range');
      await t.tap(find.text('27'));
      await t.pumpAndSettle();
      expect(find.text('Yesterday'), findsOneWidget);
      await tapKey(t, 'flow-range');
      await tapKey(t, 'range-today');
      expect(f.body('smoney_entries'), containsPair('from', '2026-10-28'));
      expect(find.text('Today'), findsOneWidget);
    });

    test('the report: title, dates, the split by method, every entry and the grand total', () async {
      final pdf = await moneyReportPdf(direction: 'in', from: DateTime(2026, 10, 1), to: DateTime(2026, 10, 28), rows: [
        {'no': 'TXN-1', 'date': '2026-10-28', 'kind': 'goods_sale', 'method': 'gpay', 'family': 'upi', 'amount_minor': 50000, 'party': 'Vaishnavi'},
        {'no': 'TXN-2', 'date': '2026-10-27', 'kind': 'other_income', 'method': 'cash', 'family': 'cash', 'amount_minor': 10000},
      ], shop: const {'name': 'Sharma General Store'});
      expect(pdf.length, greaterThan(1000));
      expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
    });

    testWidgets('a row opens its receipt: WhatsApp to the number, and the proof photo link', (t) async {
      final f = Fake();
      await show(t, MoneyFlowScreen(api: f.api, direction: 'in', today: DateTime(2026, 10, 28)));
      await tapKey(t, 'flow-e1');
      expect(find.text('Transaction summary'), findsOneWidget);
      expect(find.byKey(const ValueKey('receipt-proof')), findsOneWidget);
      await tapKey(t, 'receipt-whatsapp');
      expect(opened.single.host, 'api.whatsapp.com'); // not wa.me: its redirect breaks emojis
      expect(opened.single.queryParameters['phone'], '919420071132');
    });

    test('the WhatsApp link keeps emojis and spaces exactly', () {
      final u = whatsAppLink('98230 93070', '🛍️ Hi ✅');
      expect(u.toString(), 'https://api.whatsapp.com/send?phone=919823093070&text=%F0%9F%9B%8D%EF%B8%8F%20Hi%20%E2%9C%85');
      expect(u.queryParameters['text'], '🛍️ Hi ✅');
      expect(whatsAppLink('', 'x').queryParameters.containsKey('phone'), isFalse);
    });

    testWidgets('Add money: amount required; GPay goes with the party, phone and proof photo', (t) async {
      final f = Fake();
      await show(t, MoneyFlowScreen(api: f.api, direction: 'in', today: DateTime(2026, 10, 28)));
      await tapKey(t, 'flow-add');
      await tapKey(t, 'entry-save');
      expect(toast('Enter the amount.'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('entry-amount')), '1000');
      await tapKey(t, 'entry-method-gpay');
      await tapKey(t, 'entry-contact');
      await tapKey(t, 'contact-c1');
      expect(t.widget<TextField>(find.byKey(const ValueKey('entry-phone'))).controller!.text, '9876543210');
      await tapKey(t, 'entry-proof');
      await tapKey(t, 'proof-camera');
      expect(find.byKey(const ValueKey('entry-proof-preview')), findsOneWidget);
      await tapKey(t, 'entry-save');
      final b = f.body('smoney_record');
      expect(b, allOf(containsPair('kind', 'goods_sale'), containsPair('method', 'gpay'), containsPair('amount_minor', 100000), containsPair('party', 'Gupta Traders'),
          containsPair('party_phone', '9876543210'), containsPair('proof_path', 'org/proofs/p1.jpg')));
      expect(f.requests.where((r) => r.method == 'PUT'), hasLength(1));
      expect(f.calls('smoney_record').single.headers['Idempotency-Key'], startsWith('sm-'));
      expect(find.byKey(const ValueKey('money-flow-in')), findsOneWidget); // back on the list
    });

    testWidgets('Generate receipt saves once, then shows the summary; SMS opens messages to the number', (t) async {
      final f = Fake();
      await show(t, MoneyEntryScreen(api: f.api, direction: 'in'));
      await t.enterText(find.byKey(const ValueKey('entry-amount')), '250');
      await t.enterText(find.byKey(const ValueKey('entry-phone')), '98230 93070');
      await tapKey(t, 'entry-receipt');
      expect(find.byKey(const ValueKey('money-receipt')), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('receipt-total'))).data, '₹250');
      expect(find.text('TXN-0003'), findsOneWidget);
      await tapKey(t, 'receipt-sms');
      expect(opened.single.scheme, 'sms');
      expect(opened.single.path, '+919823093070');
      expect(f.calls('smoney_record'), hasLength(1));
    });
  });

  group('types', () {
    testWidgets('Money in lists every type, income from sales of goods first, then Other and Account transfer', (t) async {
      final f = Fake();
      await show(t, MoneyEntryScreen(api: f.api, direction: 'in'));
      expect(find.text('Income (sales of goods)'), findsOneWidget); // the default
      await tapKey(t, 'entry-kind');
      for (final label in ['Sale / POS collection', 'Manual income', 'Customer paid due', 'Capital infusion', 'Partner top-up', 'Aggregator settlement', 'Other', 'Account transfer']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
    });

    testWidgets('Money out lists purchase, owner withdrawal and Other', (t) async {
      final f = Fake();
      await show(t, MoneyEntryScreen(api: f.api, direction: 'out'));
      await tapKey(t, 'entry-kind');
      for (final label in ['Expense', 'Purchase / raw material', 'Supplier payment', 'Salary / wages', 'Owner withdrawal', 'Refund to customer', 'Other', 'Account transfer']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
    });

    testWidgets('Other asks what it was for, and sends it as the category', (t) async {
      final f = Fake();
      await show(t, MoneyEntryScreen(api: f.api, direction: 'in'));
      await tapKey(t, 'entry-kind');
      // Other comes last, after Account transfer
      expect(t.getTopLeft(find.text('Other').last).dy, greaterThan(t.getTopLeft(find.text('Account transfer').last).dy));
      await t.tap(find.text('Other').last);
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('entry-amount')), '75');
      await tapKey(t, 'entry-save');
      expect(toast('Say what the money was for.'), findsOneWidget);
      expect(f.calls('smoney_record'), isEmpty);
      await t.enterText(find.byKey(const ValueKey('entry-other')), 'Scrap sold');
      await tapKey(t, 'entry-save');
      expect(f.body('smoney_record'), allOf(containsPair('kind', 'other_in'), containsPair('category', 'Scrap sold')));
    });

    testWidgets('an Other entry shows what was typed as its type, on the receipt', (t) async {
      await show(t, Builder(builder: (c) => TextButton(onPressed: () => showMoneyReceipt(c, {'no': 'TXN-9', 'date': '2026-10-28', 'direction': 'in', 'kind': 'other_in',
          'category': 'Scrap sold', 'method': 'cash', 'amount_minor': 7500}), child: const Text('open'))));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('Scrap sold'), findsOneWidget);
      expect(find.text('Other'), findsNothing);
    });

    testWidgets('Account transfer: from and to accounts instead of how it was paid', (t) async {
      final f = Fake();
      await show(t, MoneyEntryScreen(api: f.api, direction: 'out'));
      await tapKey(t, 'entry-kind');
      await t.tap(find.text('Account transfer').last);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('entry-method-cash')), findsNothing);
      expect(find.byKey(const ValueKey('entry-party')), findsNothing);
      await t.enterText(find.byKey(const ValueKey('entry-amount')), '2000');
      await tapKey(t, 'entry-from-upi');
      await tapKey(t, 'entry-save');
      expect(f.body('smoney_record'), allOf(containsPair('kind', 'transfer'), containsPair('account', 'upi'), containsPair('to_account', 'bank'), containsPair('amount_minor', 200000)));
    });
  });

  group('receipt message', () {
    const shop = {'name': 'Sharma General Store', 'address': 'Main Road, Latur', 'phone': '+917715956686', 'gstin': ''};
    final entry = {'no': 'TXN-0003', 'date': '2026-10-28', 'created_at': DateTime(2026, 10, 28, 16, 15).toIso8601String(), 'direction': 'in',
      'kind': 'other_income', 'method': 'cash', 'amount_minor': 50000, 'party': 'Vaishnavi', 'party_phone': '8668320699'};

    test('format C: thank-you, the shop, the receipt box, a number to call, OneLocal', () {
      expect(MoneyReceipt(entry, shop: shop).text, [
        '🛍️ *Thank you for shopping with us!*',
        '',
        '*Sharma General Store*',
        'Main Road, Latur',
        '',
        '┌ Receipt TXN-0003',
        '│ 28 Oct 2026, 4:15 PM',
        '│ From: Vaishnavi (86683 20699)',
        '│ For: Manual income',
        '│ Paid by: Cash',
        '└ *Total: ₹500* ✅',
        '',
        'Questions? Call 77159 56686',
        '',
        '_OneLocal · Your local shop, online_',
      ].join('\n'));
    });

    test('money out thanks for the business and says who was paid; missing details are left out', () {
      final t = MoneyReceipt({...entry, 'direction': 'out', 'kind': 'other_out', 'category': 'Shop repairs', 'party_phone': ''}).text;
      expect(t, startsWith('🤝 *Thank you for doing business with us!*'));
      expect(t, contains('│ To: Vaishnavi\n'));
      expect(t, contains('│ For: Shop repairs'));
      expect(t, isNot(contains('Questions? Call')));
    });

    testWidgets('WhatsApp from the Money in form sends the format with the shop', (t) async {
      final f = Fake();
      await show(t, MoneyEntryScreen(api: f.api, direction: 'in', shop: shop));
      await t.enterText(find.byKey(const ValueKey('entry-amount')), '500');
      await t.enterText(find.byKey(const ValueKey('entry-phone')), '8668320699');
      await tapKey(t, 'entry-whatsapp');
      final text = opened.single.queryParameters['text']!;
      expect(text, contains('*Sharma General Store*'));
      expect(text, contains('└ *Total: ₹500* ✅'));
      expect(text, contains('Questions? Call 77159 56686'));
    });
  });

  group('Money out', () {
    testWidgets('an expense with its head, paid by card', (t) async {
      final f = Fake();
      await show(t, MoneyEntryScreen(api: f.api, direction: 'out'));
      expect(find.text('Pay money'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('entry-amount')), '120');
      await tapKey(t, 'entry-method-card');
      await tapKey(t, 'entry-category');
      await t.tap(find.text('Rent').last);
      await t.pumpAndSettle();
      await tapKey(t, 'entry-save');
      expect(f.body('smoney_record'), allOf(containsPair('kind', 'expense'), containsPair('method', 'card'), containsPair('category', 'Rent')));
    });
  });

  group('Transfer', () {
    test('UPI links for GPay, PhonePe and any UPI app', () {
      final g = upiPayLink('gpay', upiId: 'gupta@okhdfc', name: 'Gupta Traders', amountMinor: 150050, note: 'Oct bill');
      expect(g.scheme, 'tez');
      expect(g.toString(), contains('pa=gupta%40okhdfc'));
      expect(g.toString(), contains('am=1500.50'));
      expect(g.toString(), contains('pn=Gupta%20Traders'));
      expect(upiPayLink('phonepe', upiId: 'a@b', name: 'A', amountMinor: 100).scheme, 'phonepe');
      expect(upiPayLink('any', upiId: 'a@b', name: 'A', amountMinor: 100).scheme, 'upi');
    });

    testWidgets('select a contact, pay through GPay, say it went through: recorded in Money out with the UTR', (t) async {
      final f = Fake();
      await show(t, MoneyTransferScreen(api: f.api));
      await tapKey(t, 'transfer-gpay');
      expect(toast('Select who you are paying.'), findsOneWidget);
      await tapKey(t, 'transfer-contact');
      await tapKey(t, 'contact-c1');
      expect(find.text('gupta@okhdfc'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('transfer-amount')), '1500');
      await tapKey(t, 'transfer-gpay');
      expect(opened.single.scheme, 'tez');
      await t.enterText(find.byKey(const ValueKey('transfer-utr')), '4321');
      await tapKey(t, 'transfer-paid');
      expect(f.body('smoney_record'), allOf(containsPair('kind', 'supplier_payment'), containsPair('method', 'gpay'), containsPair('amount_minor', 150000),
          containsPair('party', 'Gupta Traders'), containsPair('reference', '4321')));
      expect(find.byKey(const ValueKey('money-receipt')), findsOneWidget);
    });

    testWidgets('a contact without a UPI ID is asked for one first', (t) async {
      final f = Fake();
      await show(t, MoneyTransferScreen(api: f.api));
      await tapKey(t, 'transfer-contact');
      await tapKey(t, 'contact-recent-Ramesh');
      await t.enterText(find.byKey(const ValueKey('transfer-amount')), '200');
      await tapKey(t, 'transfer-phonepe');
      expect(find.byKey(const ValueKey('contact-form')), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('contact-upi')), 'ramesh@ybl');
      await tapKey(t, 'contact-save');
      expect(f.body('smoney_contact_save'), allOf(containsPair('name', 'Ramesh'), containsPair('upi_id', 'ramesh@ybl')));
      expect(find.text('ramesh@ybl'), findsOneWidget);
      expect(opened, isEmpty); // not paid yet
    });

    testWidgets('card is recorded only', (t) async {
      final f = Fake();
      await show(t, MoneyTransferScreen(api: f.api));
      await tapKey(t, 'transfer-contact');
      await tapKey(t, 'contact-c1');
      await t.enterText(find.byKey(const ValueKey('transfer-amount')), '300');
      await tapKey(t, 'transfer-how-card');
      await tapKey(t, 'transfer-card-record');
      expect(f.body('smoney_record'), allOf(containsPair('method', 'card'), containsPair('amount_minor', 30000)));
      expect(opened, isEmpty);
    });

    testWidgets('moving money between the store\'s own accounts', (t) async {
      final f = Fake();
      await show(t, MoneyTransferScreen(api: f.api));
      await tapKey(t, 'transfer-move');
      await t.enterText(find.byKey(const ValueKey('move-amount')), '1000');
      await tapKey(t, 'move-save');
      expect(f.body('smoney_record'), allOf(containsPair('kind', 'transfer'), containsPair('account', 'cash'), containsPair('to_account', 'bank')));
    });
  });
}
