import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/money/store_money.dart';
import 'package:vinii_pos/service/free_slots_screen.dart';
import 'package:vinii_pos/service/service_api.dart';
import 'package:vinii_pos/service/service_money.dart';

import 'helpers.dart';

// Service Money and Free slots (founder, 2 Nov 2026): the store's Money made service-specific (also in the side menu); the Free slots tile
// says which slots and who is free.

const _json = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic>? closedDay; // the day once closed

/// One fake server for both APIs: `svc_*` for the service, `smoney_*` for the wallet books (in paise).
class _Fake {
  _Fake([Map<String, Object Function(Map<String, dynamic>)>? extra])
      : answers = {
          'smoney_home': (_) => {
                'shop': {'name': 'Demo Services'},
                'total_minor': 1693800,
                'accounts': [
                  {'key': 'cash', 'name': 'Cash drawer', 'balance_minor': 258800},
                  {'key': 'upi', 'name': 'UPI', 'balance_minor': 1245000},
                  {'key': 'bank', 'name': 'Bank', 'balance_minor': 190000},
                ],
                'can_record': true,
                'can_void': true,
              },
          'smoney_register': (_) => {'day': '2026-11-02', 'opening_minor': 140000, 'sales_minor': 118800, 'cash_in_minor': 0, 'refunds_minor': 0, 'cash_out_minor': 0, 'expected_minor': 258800, 'closed': closedDay},
          'smoney_close_day': (b) => {'day': '2026-11-02', 'expected_minor': 258800, 'closed': closedDay = {'by': 'Owner', 'counted_minor': b['counted_minor'], 'difference_minor': 0}},
          'svc_money_split': (_) => {
                'today': {'total': 6138, 'bookings': 4338, 'jobs': 0, 'bills': 1800, 'packages': 0, 'offline': 4938, 'online': 1200, 'cash': 1188, 'upi': 4950, 'card': 0, 'refunds': 200},
                'month': {'total': 7538, 'bookings': 5738, 'jobs': 0, 'bills': 1800, 'packages': 0, 'offline': 6338, 'online': 1200, 'cash': 1788, 'upi': 5750, 'card': 0, 'refunds': 200},
                'due': 2040,
              },
          'svc_bill_list': (_) => {
                'counts': {'due': 1},
                'due_amount': 1440,
                'bills': [
                  {'id': 'b1', 'display_no': 'P-001', 'status': 'due', 'title': 'AC repair', 'customer': 'Test Cust', 'date_label': '2 Nov', 'total': 1440, 'paid': 0, 'due': 1440},
                ],
              },
          'svc_free_slots': (_) => {
                'date_label': 'Monday, 2 November',
                'slot_minutes': 20,
                'total': 3,
                'free_now': ['Arjun Kumar'],
                'people': [
                  {'staff_id': 'a', 'name': 'Arjun Kumar', 'title': 'Technician', 'state': 'free_now', 'count': 2, 'slots': [{'time': '16:50', 'label': '4:50 PM'}, {'time': '17:10', 'label': '5:10 PM'}]},
                  {'staff_id': 'm', 'name': 'Meera Iyer', 'title': 'Stylist', 'state': 'busy', 'busy_until': '5:30 PM', 'count': 1, 'slots': [{'time': '17:30', 'label': '5:30 PM'}]},
                  {'staff_id': 'r', 'name': 'Ravi Shinde', 'title': '', 'state': 'off', 'count': 0, 'slots': []},
                ],
              },
          ...?extra,
        };
  final Map<String, Object Function(Map<String, dynamic>)> answers;
  final calls = <(String, Map<String, dynamic>)>[];
  late final client = MockClient((r) async {
    final fn = r.url.pathSegments.last;
    final body = r.body.isEmpty ? <String, dynamic>{} : (jsonDecode(r.body) as Map).cast<String, dynamic>();
    calls.add((fn, body));
    return http.Response(jsonEncode(answers[fn]!(body)), 200, headers: _json);
  });
  late final api = ServiceApi(baseUrl: 'http://pos.test', accessToken: () => 'token', client: client);
  late final money = StoreMoneyApi(baseUrl: 'http://pos.test', accessToken: () => 'token', client: client);
  List<Map<String, dynamic>> of(String fn) => calls.where((c) => c.$1 == fn).map((c) => c.$2).toList();
}

Future<void> _tap(WidgetTester t, Key key) async {
  await t.ensureVisible(find.byKey(key));
  await t.tap(find.byKey(key));
  await t.pumpAndSettle();
}

void main() {
  setUp(() {
    HomeNav.storeName = 'Demo Services';
    closedDay = null;
  });
  tearDown(HomeNav.reset);

  testWidgets('Free slots: who is free now, busy till when or off, and each person\'s free times', (t) async {
    final f = _Fake();
    await show(t, FreeSlotsScreen(api: f.api));
    await t.pumpAndSettle();
    expect(f.of('svc_free_slots'), hasLength(1));
    expect((t.widget(find.byKey(const ValueKey('free-total'))) as Text).data, '3');
    expect((t.widget(find.byKey(const ValueKey('free-now'))) as Text).data, '1');
    for (final s in ['Free slots', 'Monday, 2 November · 20 min slots', 'Who is free', 'Arjun Kumar', 'Free now', '2 free slots', '4:50 PM', '5:10 PM',
      'Meera Iyer', 'Busy till 5:30 PM', '1 free slot', 'Ravi Shinde', 'Off today', 'Not working today.']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    expect(find.byKey(const ValueKey('free-slot-a-16:50')), findsOneWidget);
  });

  testWidgets('Money: the store\'s wallet (balance, accounts, Money in / out / Transfer) and money from services by kind and source', (t) async {
    final f = _Fake();
    await show(t, ServiceMoneyScreen(api: f.api, moneyApi: f.money));
    await t.pumpAndSettle();
    expect(f.of('smoney_home'), hasLength(1));
    expect(f.of('svc_money_split'), hasLength(1));
    expect(f.of('svc_bill_list').single, {'filter': 'due'});
    // the store's OneLocal wallet and credits (founder, 4 Nov 2026)
    for (final s in ['OneLocal wallet', 'From your online bookings', 'Due to you', 'Ad credits', 'To promote your business', 'Discount credits', 'Discount against commission']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    for (final s in ['Money', 'Your wallet balance', '₹16,938', 'Cash drawer ₹2,588', 'UPI ₹12,450', 'Bank ₹1,900', 'Money in', 'Money out', 'Transfer',
      'From your services', '₹6,138', 'taken today', 'Bookings', '₹4,338', 'Jobs', 'Bills made here', '₹1,800', 'Packages & memberships',
      'Offline (in the POS)', '₹4,938', 'Online (customer app)', '₹1,200']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    expect(find.text('Cash ₹1,188 · UPI ₹4,950 · Card/other ₹0 · refunds ₹200'), findsOneWidget);
    await _tap(t, const ValueKey('money-period-month'));
    expect(find.text('₹7,538'), findsOneWidget);
    expect(find.text('taken this month'), findsOneWidget);
  });

  testWidgets('Money: the cash drawer (cash from services, close the day) and the customers who still owe', (t) async {
    final f = _Fake();
    await show(t, ServiceMoneyScreen(api: f.api, moneyApi: f.money));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('Should be in the drawer'), 200,
        scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first);
    await t.pumpAndSettle();
    for (final s in ['Cash drawer · 02 Nov', 'Opening cash', 'Cash from services', '+ ₹1,188', 'Should be in the drawer', '₹2,588']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    await _tap(t, const ValueKey('close-day'));
    await t.enterText(find.byKey(const ValueKey('close-counted')), '2588');
    await _tap(t, const ValueKey('close-confirm'));
    expect(f.of('smoney_close_day').single['counted_minor'], 258800);
    expect(find.byKey(const ValueKey('day-closed')), findsOneWidget);

    await _tap(t, const ValueKey('money-part-dues'));
    expect(find.text('Customers owe ₹2,040'), findsOneWidget);
    for (final s in ['Test Cust', 'P-001 · AC repair · 2 Nov', '₹1,440', 'Collect']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
  });
}
