import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/team/staff_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart' show toast;

// Store staff (founder, 28 Oct 2026): Staff | Attendance | Salary | Advances.

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

final _sunil = {'id': 's1', 'code': 'ST-001', 'name': 'Sunil Kumar', 'mobile': '9876543210', 'role': 'Cashier', 'salary_type': 'monthly', 'pay_minor': 1500000, 'working_hours': 8,
  'status': 'active', 'joining_date': '2026-10-01', 'today': 'present'};

class Fake {
  final requests = <http.Request>[];
  Map<String, dynamic> body(String fn) => jsonDecode(requests.lastWhere((r) => fnOf(r) == fn).body) as Map<String, dynamic>;
  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
  var att = <String, String?>{'s1': null};
  late final api = StaffApi(baseUrl: 'http://t.test', accessToken: () => 't', client: MockClient((r) async {
    requests.add(r);
    final b = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
    Map<String, dynamic> sal(String status) => {
          'year': 2026, 'month': 10,
          'rows': [{'id': 'x1', 'staff_id': 's1', 'name': 'Sunil Kumar', 'basic_minor': 1451613, 'ot_minor': 0, 'bonus_minor': 0, 'advance_minor': 200000, 'penalty_minor': 0,
            'net_minor': 1251613, 'paid_minor': status == 'paid' ? 1251613 : 0, 'pending_minor': status == 'paid' ? 0 : 1251613, 'status': status}],
        };
    return switch (fnOf(r)) {
      'staff_home' => ok({'total': 1, 'active': 1, 'present_today': 1, 'absent_today': 0, 'month': {'year': 2026, 'month': 10, 'payable_minor': 1251613, 'paid_minor': 0}, 'staff': [_sunil]}),
      'staff_save' => ok({..._sunil, 'name': b['name']}),
      'staff_attendance' => ok({'date': b['date'], 'rows': [{'staff_id': 's1', 'name': 'Sunil Kumar', 'status': att['s1'], 'ot_hours': 0}]}),
      'staff_attendance_save' => () {
          for (final row in (b['rows'] as List).cast<Map>()) {
            att['${row['staff_id']}'] = row['status'] as String?;
          }
          return ok({'date': b['date'], 'rows': [{'staff_id': 's1', 'name': 'Sunil Kumar', 'status': att['s1'], 'ot_hours': 0}]});
        }(),
      'staff_salary' => ok({'year': 2026, 'month': 10, 'rows': []}),
      'staff_salary_generate' => ok(sal('pending')),
      'staff_salary_pay' => ok(sal('paid')),
      'staff_advances' => ok({'advances': []}),
      'staff_advance_give' => ok({'advances': [{'id': 'a1', 'staff_id': 's1', 'name': 'Sunil Kumar', 'date': '2026-10-28', 'amount_minor': 200000, 'deduct_month': 10, 'deduct_year': 2026, 'mode': 'cash', 'status': 'open', 'reason': ''}]}),
      _ => ok({}),
    };
  }));
}

Future<void> show(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(780, 3600);
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
  testWidgets('the tiles and the staff list; Add staff needs only a name and the pay', (t) async {
    final f = Fake();
    await show(t, StaffScreen(api: f.api, today: DateTime(2026, 10, 28)));
    expect(find.text('Sunil Kumar'), findsOneWidget);
    expect(find.text('₹15,000/month'), findsOneWidget);
    expect(find.text('₹12,516.13'), findsNWidgets(2)); // payable and pending
    await tapKey(t, 'staff-add');
    expect(find.text('Photo URL'), findsNothing); // the web form's URL boxes are gone
    await tapKey(t, 'staff-save');
    expect(toast('Enter the name.'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('staff-f-name')), 'Ravi');
    await t.tap(find.text('Daily'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('staff-pay')), '500');
    await tapKey(t, 'staff-save');
    final b = f.body('staff_save');
    expect([b['name'], b['salary_type'], b['pay'], b['working_hours']], ['Ravi', 'daily', 500, 8]);
  });

  testWidgets('attendance: one tap marks a person; Mark all present marks everyone not marked', (t) async {
    final f = Fake();
    await show(t, StaffScreen(api: f.api, today: DateTime(2026, 10, 28)));
    await tapKey(t, 'staff-part-attendance');
    expect(find.text('Today'), findsOneWidget);
    await tapKey(t, 'att-all-present');
    expect(f.body('staff_attendance_save')['rows'], [{'staff_id': 's1', 'status': 'present'}]);
    await tapKey(t, 'att-s1-absent');
    expect((f.body('staff_attendance_save')['rows'] as List).single, containsPair('status', 'absent'));
  });

  testWidgets('salary: Generate, then Pay from an account', (t) async {
    final f = Fake();
    await show(t, StaffScreen(api: f.api, today: DateTime(2026, 10, 28)));
    await tapKey(t, 'staff-part-salary');
    expect(find.text('October 2026'), findsOneWidget);
    await tapKey(t, 'sal-generate');
    expect(f.body('staff_salary_generate'), {'year': 2026, 'month': 10});
    expect(find.textContaining('Advance −₹2,000'), findsOneWidget);
    await tapKey(t, 'sal-pay-s1');
    await tapKey(t, 'pay-from-upi');
    await tapKey(t, 'pay-confirm');
    expect(f.body('staff_salary_pay'), allOf(containsPair('id', 'x1'), containsPair('account', 'upi'), containsPair('amount', 12516.13)));
    expect(f.calls('staff_salary_pay').single.headers['Idempotency-Key'], startsWith('st-'));
    expect(find.text('Paid'), findsWidgets);
  });

  testWidgets('advances: give one from the cash drawer, taken back from this month', (t) async {
    final f = Fake();
    await show(t, StaffScreen(api: f.api, today: DateTime(2026, 10, 28)));
    await tapKey(t, 'staff-part-advances');
    await tapKey(t, 'adv-give');
    await t.enterText(find.byKey(const ValueKey('adv-amount')), '2000');
    await tapKey(t, 'adv-confirm');
    expect(f.body('staff_advance_give'), allOf(containsPair('staff_id', 's1'), containsPair('amount', 2000), containsPair('mode', 'cash'), containsPair('deduct_month', 10)));
    expect(find.text('To take back'), findsOneWidget);
  });
}
