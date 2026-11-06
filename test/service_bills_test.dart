import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/devices/bill_receipt.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/service/bills_screen.dart';
import 'package:vinii_pos/service/service_api.dart';
import 'package:vinii_pos/ui/wallet.dart';

import 'helpers.dart';

// The Bill tab (2 Nov 2026): bills with due and paid, one bill to collect, send or print, and New bill.

const _json = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic> _bill(String id, {String status = 'due', bool booking = false, num total = 1440, num paid = 0, String phone = '9000000399'}) => {
      'id': id, 'display_no': 'P-00$id', 'status': status, 'status_label': {'due': 'Due', 'paid': 'Paid', 'part_paid': 'Part paid'}[status], 'tone': status == 'paid' ? 'good' : 'warn',
      'title': booking ? 'Haircut (women)' : 'AC repair', 'customer': 'Test Cust', 'customer_phone': phone, 'address': booking ? null : 'Flat 1, Pune',
      'source': booking ? 'booking' : 'bill', 'booking': booking ? {'id': 'ap1', 'display_no': 'APT-0021', 'status': 'confirmed'} : null,
      'date_label': '2 Nov 2026, 3:37 PM',
      'lines': [{'name': 'AC service', 'qty': 2, 'price': 800, 'amount': 1600}],
      'subtotal': 1600, 'discount': 160, 'gst_pct': 0, 'gst_amount': 0, 'round_off': 0, 'total': total, 'paid': paid, 'due': total - paid,
      'payments': [if (paid > 0) {'method': 'upi', 'amount': paid, 'at_label': '2 Nov, 3:40 PM'}],
      'can_collect': !booking && status != 'paid', 'can_open_booking': booking,
    };

class _Fake {
  _Fake([Map<String, Object Function(Map<String, dynamic>)>? extra]) : answers = {
          'svc_bill_list': (b) => {
                'counts': {'all': 3, 'due': 2, 'paid': 1}, 'due_amount': 2040, 'paid_this_month': 5938,
                'bills': b['filter'] == 'paid' ? [_bill('3', status: 'paid', paid: 1440)] : [_bill('1'), _bill('2', booking: true, total: 800, paid: 200)],
              },
          'svc_bill_view': (b) => b['order_id'] == '2' ? _bill('2', booking: true, total: 800, paid: 200) : _bill('${b['order_id']}'),
          'svc_invoice_pay': (b) => {..._bill('1', status: 'paid', paid: 1440), 'change': 560},
          'svc_invoice_create': (b) => _bill('9'),
          'pos_bill_link': (b) => {'code': 'AbC123xyz000'},
          'svc_catalogue': (b) => {
                'services': [
                  {'id': 'ac', 'name': 'AC service', 'price': 800, 'duration_min': 60},
                  {'id': 'pl', 'name': 'Plumber visit', 'price': 300, 'duration_min': 45},
                ],
                'providers': [],
              },
          ...?extra,
        };
  final Map<String, Object Function(Map<String, dynamic>)> answers;
  final calls = <(String, Map<String, dynamic>, String?)>[];
  late final api = ServiceApi(
    baseUrl: 'http://pos.test',
    accessToken: () => 'token',
    client: MockClient((r) async {
      final fn = r.url.pathSegments.last;
      final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      calls.add((fn, body, r.headers['Idempotency-Key']));
      return http.Response(jsonEncode(answers[fn]!(body)), 200, headers: _json);
    }),
  );
  List<Map<String, dynamic>> of(String fn) => calls.where((c) => c.$1 == fn).map((c) => c.$2).toList();
}

Future<void> _tap(WidgetTester t, Key key) async {
  await t.ensureVisible(find.byKey(key));
  await t.tap(find.byKey(key));
  await t.pumpAndSettle();
}

void main() {
  setUp(() => HomeNav.storeName = 'Demo Services');
  tearDown(HomeNav.reset);

  testWidgets('the Bill tab opens on its piles, one below the other: Due (red), Taken today (green), Paid (blue), no All pile (founder, 2 Nov 2026)', (t) async {
    final f = _Fake();
    await show(t, BillsScreen(api: f.api));
    await t.pumpAndSettle(); // the sections build in (the store's motion)
    expect(f.of('svc_bill_list').single, {'filter': 'due'});
    for (final s in ['Bills', '+ New bill', 'Due', '2 bills · ₹2,040 due', 'Taken today', 'Paid', '1 bill · ₹5,938 this month']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    final piles = t.widgetList<WalletPile>(find.byType(WalletPile)).toList();
    expect(piles.map((p) => p.key), [const ValueKey('pile-due'), const ValueKey('pile-today'), const ValueKey('pile-paid'), const ValueKey('pile-walkins')]);
    expect(piles.map((p) => p.colors), [WalletColors.red, WalletColors.green, WalletColors.blue, WalletColors.slate]);
    expect(find.byKey(const ValueKey('bill-1')), findsNothing, reason: 'no bills until a pile is opened');
    expect(find.byKey(const ValueKey('pile-all')), findsNothing, reason: 'every bill is in a pile already; no All pile');
    expect(find.text('All bills'), findsNothing);
    expect(find.byKey(const ValueKey('filter-due')), findsNothing, reason: 'no filter chips any more');
  });

  testWidgets('a pile opens its bills in the pile\'s colour; tapping the pile again goes back to every pile', (t) async {
    final f = _Fake();
    await show(t, BillsScreen(api: f.api));
    await t.pumpAndSettle();
    await _tap(t, const ValueKey('pile-paid'));
    expect(f.of('svc_bill_list').last, {'filter': 'paid'});
    final cards = t.widgetList<BillAccentCard>(find.byType(BillAccentCard)).toList();
    expect(cards.single.key, const ValueKey('bill-3'));
    expect(cards.single.accent, WalletColors.blue.first, reason: 'the Paid pile\'s colour, as an accent');
    expect(find.text('P-003 · AC repair'), findsOneWidget);
    await _tap(t, const ValueKey('pile-paid'));
    expect(find.byKey(const ValueKey('pile-due')), findsOneWidget);
    expect(find.byKey(const ValueKey('bill-3')), findsNothing);
    await _tap(t, const ValueKey('pile-due'));
    expect(f.of('svc_bill_list').last, {'filter': 'due'});
    for (final s in ['P-001 · AC repair', 'Bill', 'Booking APT-0021', '₹1,440', 'Due ']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    expect(t.widget<BillAccentCard>(find.byKey(const ValueKey('bill-1'))).accent, WalletColors.red.first);
  });

  testWidgets('opened on a pile (the dashboard\'s Money tile opens Taken today); a search lists results across every bill', (t) async {
    final f = _Fake();
    await show(t, BillsScreen(api: f.api, filter: 'today'));
    await t.pumpAndSettle();
    expect(f.of('svc_bill_list').first, {'filter': 'today'});
    expect(find.byKey(const ValueKey('pile-today')), findsOneWidget);
    expect(find.byKey(const ValueKey('pile-due')), findsNothing);
    await _tap(t, const ValueKey('pile-today'));
    await t.enterText(find.byKey(const ValueKey('bill-search')), 'Test');
    await t.pumpAndSettle();
    expect(f.of('svc_bill_list').last, {'filter': 'all', 'q': 'Test'});
    expect(find.text('Search results'), findsOneWidget);
  });

  testWidgets('bills are white cards with their pile\'s colour as an accent; the bill page opens as a pass', (t) async {
    final f = _Fake();
    await show(t, BillsScreen(api: f.api, filter: 'due'));
    await t.pumpAndSettle();
    expect(billWalletColors('due'), WalletColors.red);
    expect(billWalletColors('paid'), WalletColors.green);
    expect(t.widget<BillAccentCard>(find.byKey(const ValueKey('bill-1'))).accent, WalletColors.red.first, reason: 'white card, red accent (founder, 2 Nov 2026)');
    expect(find.descendant(of: find.byKey(const ValueKey('bill-1')), matching: find.byType(WalletCard)), findsNothing, reason: 'not a full-colour card');
    await show(t, BillDetailScreen(api: f.api, id: '1'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('bill-pass')), findsOneWidget);
    expect(find.text('Due ₹1,440'), findsOneWidget);
  });

  testWidgets('a bill made here: lines, discount, totals; Collect takes cash with one key and shows the change', (t) async {
    final f = _Fake();
    await show(t, BillDetailScreen(api: f.api, id: '1'));
    await t.pumpAndSettle(); // the sections build in and the figures count up (the store's motion)
    for (final s in ['Bill P-001', 'AC repair', 'Test Cust · +91 90000 00399', 'Flat 1, Pune', 'AC service', '2×', '₹1,600', 'Discount', '−₹160', 'Total', 'Collect ₹1,440']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    expect(find.byKey(const ValueKey('open-booking')), findsNothing);
    await t.tap(find.text('Collect ₹1,440'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('pay-cash')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('cash-received')), '2000');
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    final pay = f.calls.singleWhere((c) => c.$1 == 'svc_invoice_pay');
    expect(pay.$2, {'order_id': '1', 'method': 'cash', 'tendered': 2000});
    expect(pay.$3, startsWith('svc-'));
    expect(find.text('₹1,440 collected · give back ₹560'), findsOneWidget);
    expect(find.text('Paid'), findsWidgets);
    expect(find.text('Collect ₹1,440'), findsNothing);
  });

  testWidgets('a booking\'s bill is paid through the booking: no Collect here, Open booking instead', (t) async {
    final f = _Fake();
    await show(t, BillDetailScreen(api: f.api, id: '2'));
    await t.pumpAndSettle(); // the sections build in and the figures count up (the store's motion)
    expect(find.textContaining('Collect'), findsNothing);
    expect(find.text('Open booking APT-0021'), findsOneWidget);
    expect(find.text('This bill is from booking APT-0021. Take payment from the booking, so the visit is closed too.'), findsOneWidget);
    expect(f.of('svc_invoice_pay'), isEmpty);
  });

  testWidgets('Send by WhatsApp: the public bill link in a short, neutral note; Print sends the bill\'s lines', (t) async {
    final f = _Fake();
    Uri? opened;
    BillReceipt? printed;
    await show(t, BillDetailScreen(api: f.api, id: '1', openUrl: (u) async => (opened = u) != null, printer: (_, b) async => printed = b));
    await t.pumpAndSettle(); // the sections build in and the figures count up (the store's motion)
    await _tap(t, const ValueKey('bill-whatsapp'));
    expect(f.of('pos_bill_link').single, {'order_id': '1'});
    expect(opened!.queryParameters['phone'], '919000000399');
    final text = opened!.queryParameters['text']!;
    expect(text, contains('Thank you for choosing Demo Services.'));
    expect(text, contains('https://one-local-flutter.vercel.app/b/AbC123xyz000'));
    expect(text, isNot(contains('visiting')));
    await _tap(t, const ValueKey('bill-print'));
    expect(printed!.billNo, 'P-001');
    expect(printed!.lines.single.name, 'AC service');
    expect([printed!.total, printed!.discount], [1440, 160]);
  });

  testWidgets('new bill: customer, services with quantities, 10% off; one call with a key; nothing without a service', (t) async {
    final f = _Fake();
    BillView? made;
    await show(t, Builder(builder: (c) => TextButton(onPressed: () async => made = await Navigator.of(c).push<BillView>(MaterialPageRoute(builder: (_) => NewBillScreen(api: f.api))), child: const Text('open'))));
    await t.pumpAndSettle(); // the sections build in and the figures count up (the store's motion)
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('bill-name')), 'Test Cust');
    await t.enterText(find.byKey(const ValueKey('bill-phone')), '90000 00399');
    await _tap(t, const ValueKey('bill-seg-2')); // a segment skips ahead: Discount
    await _tap(t, const ValueKey('disc-percent'));
    await _tap(t, const ValueKey('bill-seg-3'));
    expect(find.text('Save bill'), findsOneWidget); // only on the last step
    await t.tap(find.text('Save bill'));
    await t.pumpAndSettle();
    expect(find.text('Add at least one service.'), findsOneWidget);
    expect(find.text('Step 2 of 4'), findsOneWidget); // sent back to Services
    expect(f.of('svc_invoice_create'), isEmpty);
    await _tap(t, const ValueKey('more-ac'));
    await _tap(t, const ValueKey('more-ac'));
    await _tap(t, const ValueKey('bill-seg-2'));
    await t.enterText(find.byKey(const ValueKey('bill-discount')), '10');
    await t.pumpAndSettle();
    expect(find.text('−₹160'), findsOneWidget);
    expect(find.text('₹1,440'), findsOneWidget);
    await _tap(t, const ValueKey('bill-seg-3'));
    await t.tap(find.text('Save bill'));
    await t.pumpAndSettle();
    final call = f.calls.singleWhere((c) => c.$1 == 'svc_invoice_create');
    expect(call.$2, {'customer_name': 'Test Cust', 'customer_phone': '9000000399', 'lines': [{'menu_item_id': 'ac', 'qty': 2}], 'discount_pct': 10});
    expect(call.$3, startsWith('svc-'));
    expect(made!.id, '9');
  });

  Future<void> openNew(WidgetTester t, _Fake f) async {
    await show(t, Builder(builder: (c) => TextButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => NewBillScreen(api: f.api))), child: const Text('open'))));
    await t.pumpAndSettle();
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  testWidgets('new bill in steps (4 Nov 2026): Step 1 of 4, Next checks the step and moves on, Back goes back', (t) async {
    await openNew(t, _Fake());
    expect(find.text('Step 1 of 4'), findsOneWidget);
    expect(find.text('Save bill'), findsNothing);
    await _tap(t, const ValueKey('bill-next'));
    expect(find.text('Enter the customer\'s name.'), findsOneWidget);
    expect(find.text('Step 1 of 4'), findsOneWidget);
    await t.pump(const Duration(seconds: 4)); // the toast sits over Next until it goes
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('bill-name')), 'Test Cust');
    await _tap(t, const ValueKey('bill-next'));
    expect(find.text('Step 2 of 4'), findsOneWidget);
    expect(find.byKey(const ValueKey('more-ac')), findsOneWidget);
    await _tap(t, const ValueKey('bill-back'));
    expect(find.text('Step 1 of 4'), findsOneWidget);
    expect(find.byKey(const ValueKey('bill-name')), findsOneWidget);
  });

  testWidgets('new bill fits a 375x812 phone on every step', (t) async {
    t.view.physicalSize = const Size(375, 812);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await openNew(t, _Fake());
    expect(t.takeException(), isNull);
    await t.enterText(find.byKey(const ValueKey('bill-name')), 'Test Cust');
    await _tap(t, const ValueKey('bill-next'));
    await _tap(t, const ValueKey('more-ac'));
    for (var i = 1; i < 4; i++) {
      expect(t.takeException(), isNull);
      if (i < 3) await _tap(t, const ValueKey('bill-next'));
    }
    expect(find.text('Step 4 of 4'), findsOneWidget);
    expect(find.text('Save bill'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
