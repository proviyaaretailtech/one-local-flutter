import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/shift/daily_ops_screens.dart';
import 'package:vinii_pos/shift/day_api.dart';
import 'package:vinii_pos/shift/shift_api.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart' show toast;

// Daily operations (founder, 31 Oct 2026): the business day starts by itself, opening cash carried and editable with a reason, closing cash
// counted with its difference, a manager closes the day, previous days are listed. The database decides; these check what the screens send.

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String code = 'bad_request']) =>
    http.Response(jsonEncode({'detail': detail, 'code': code}), status, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

Map<String, dynamic> dayJson({
  String id = 'd1', String date = '2026-10-31', String status = 'started', String? attention, num? opening = 1240, num? carried = 1240, String? source = 'carried',
  num expected = 1500, num? counted, num? variance, String? reason, List<Map<String, dynamic>> changes = const [], Map<String, dynamic>? prev, int version = 1,
}) =>
    {
      'id': id, 'business_date': date, 'status': status, 'attention_reason': attention, 'start_trigger': 'opening_time', 'started_at': '2026-10-31T03:30:00Z',
      'location_name': 'Main', 'carried_cash': carried, 'opening_cash': opening, 'opening_cash_source': source, 'counted_cash': counted, 'variance': variance,
      'variance_reason': reason, 'version': version, 'closed_at': status == 'closed' ? '2026-10-31T16:00:00Z' : null,
      'cash': {'opening_cash': opening, 'cash_sales': 400, 'bills': 3, 'other_cash_in': 0, 'cash_refunds': 40, 'cash_expenses': 100, 'deposits_withdrawals': 0,
        'other_cash_out': 0, 'other_methods': {'upi': 900, 'card': 300}, 'expected_cash': expected},
      'stock': {'opening_items': 12, 'opening_units': 340, 'closing_items': 0, 'moved_since_last_close': 2},
      'adjustments': changes, 'prev': prev,
    };

class Fake {
  Fake({this.manager = true});
  bool manager;
  Map<String, dynamic> day = dayJson();
  final requests = <http.Request>[];
  http.Response? Function(http.Request r)? override;
  Map<String, dynamic> body(String fn) => jsonDecode(requests.lastWhere((r) => fnOf(r) == fn).body) as Map<String, dynamic>;
  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);

  late final api = ShiftApi(baseUrl: 'http://t.test', accessToken: () => 't', client: MockClient((r) async {
    requests.add(r);
    final o = override?.call(r);
    if (o != null) return o;
    final b = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
    return switch (fnOf(r)) {
      'pos_day_today' => ok({'business_date': '2026-10-31', 'day': day, 'can_manage': manager, 'can_count': true, 'opens_at': '09:00:00'}),
      'pos_day_get' => ok(day),
      'pos_day_stock' => ok({'items': [
          {'name': 'Basmati Rice', 'sku': 'BAS', 'unit': 'kg', 'on_hand': 25.5, 'previous_closing': 27, 'moved': -1.5},
          {'name': 'Amul Butter', 'sku': 'AMB', 'unit': 'pc', 'on_hand': 40, 'previous_closing': 40, 'moved': 0},
        ]}),
      'pos_day_opening_set' => () {
          day = {...day, if (manager) 'opening_cash': b['amount'], 'adjustments': [...(day['adjustments'] as List), {'id': 'a9', 'kind': 'opening_correction', 'original_amount': day['opening_cash'],
            'revised_amount': b['amount'], 'reason': b['reason'], 'approval_status': manager ? 'approved' : 'pending', 'by': 'Raj', 'created_at': '2026-10-31T05:00:00Z'}]};
          return ok({...day, 'pending': !manager});
        }(),
      'pos_day_adjustment_decide' => ok(day = {...day, 'adjustments': [for (final a in day['adjustments'] as List) {...a as Map, 'approval_status': b['decision'] == 'approve' ? 'approved' : 'rejected'}]}),
      'pos_day_cash_count' => ok(day = {...day, 'counted_cash': b['counted_cash'], 'variance': (b['counted_cash'] as num) - (day['cash'] as Map)['expected_cash'], 'variance_reason': b['reason']}),
      'pos_day_close' => ok(day = {...day, 'status': 'closed', 'closed_at': '2026-10-31T16:00:00Z'}),
      'pos_day_list' => ok([dayJson(), dayJson(id: 'd0', date: '2026-10-30', status: 'closed', counted: 1240, variance: -10, reason: 'Change given')]),
      _ => err(404, 'not found'),
    };
  }));
}

Future<void> show(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(800, 3200);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(const SizedBox()); // a fresh screen each time
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: w));
  await t.pumpAndSettle();
}

Future<void> tapKey(WidgetTester t, String key) async {
  t.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)).removeCurrentSnackBar();
  await t.pump();
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('Daily operations: today with its status, the cash so far and the seven parts of the day; opening it starts the day', (t) async {
    final f = Fake();
    await show(t, DailyOpsScreen(api: f.api));
    expect(f.body('pos_day_today')['start'], isTrue); // the first activity starts the day
    expect(find.text('Sat, 31 Oct 2026'), findsOneWidget);
    expect(find.text('Started'), findsWidgets);
    for (final k in ['start', 'opening-stock', 'opening-cash', 'summary', 'closing-cash', 'closing', 'reports']) {
      expect(find.byKey(ValueKey('day-tile-$k')), findsOneWidget, reason: k);
    }
  });

  testWidgets('the day before was not closed: Requires attention, close it or open provisionally', (t) async {
    final f = Fake()..day = dayJson(status: 'attention', attention: 'previous_not_closed', opening: null, carried: null, source: null,
        prev: {'id': 'd0', 'business_date': '2026-10-30', 'status': 'attention', 'counted_cash': null});
    await show(t, DailyOpsScreen(api: f.api));
    expect(find.text('Requires attention'), findsWidgets);
    expect(find.byKey(const ValueKey('day-attention')), findsOneWidget);
    await tapKey(t, 'day-tile-start');
    expect(find.text('Not closed'), findsOneWidget);
    expect(find.byKey(const ValueKey('day-close-previous')), findsOneWidget);
    await tapKey(t, 'day-open-provisional');
    expect(find.text('Open provisionally'), findsOneWidget);
  });

  testWidgets('opening cash: a change needs a reason; it is sent with a key and the old amount stays in the list', (t) async {
    final f = Fake();
    await show(t, OpeningCashScreen(api: f.api, dayId: 'd1', canManage: true));
    expect(find.text('₹1,240'), findsWidgets);
    await t.enterText(find.byKey(const ValueKey('opening-amount')), '1300');
    await tapKey(t, 'opening-save');
    expect(toast('Give a reason (3 to 200 characters).'), findsOneWidget);
    expect(f.calls('pos_day_opening_set'), isEmpty);
    await t.enterText(find.byKey(const ValueKey('opening-reason')), 'Found 60 in the safe');
    await tapKey(t, 'opening-save');
    final last = f.calls('pos_day_opening_set').single;
    expect(last.headers['Idempotency-Key'], isNotEmpty);
    expect(jsonDecode(last.body), {'day_id': 'd1', 'amount': 1300, 'reason': 'Found 60 in the safe', 'expected_version': 1});
    expect(find.text('Opening cash corrected'), findsOneWidget);
    expect(find.textContaining('₹1,240 → ₹1,300'), findsOneWidget);
  });

  testWidgets('a biller\'s change waits for a manager; a manager approves it', (t) async {
    final f = Fake(manager: false);
    await show(t, OpeningCashScreen(api: f.api, dayId: 'd1', canManage: false));
    expect(find.text('Send for approval'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('opening-amount')), '1250');
    await t.enterText(find.byKey(const ValueKey('opening-reason')), 'Recounted');
    await tapKey(t, 'opening-save');
    expect(find.text('Waiting'), findsOneWidget);
    f.manager = true;
    await show(t, OpeningCashScreen(api: f.api, dayId: 'd1', canManage: true));
    await tapKey(t, 'change-approve-a9');
    expect(f.body('pos_day_adjustment_decide'), {'adjustment_id': 'a9', 'decision': 'approve'});
    expect(find.text('Approved'), findsOneWidget);
  });

  testWidgets('closing cash: the expected cash, the live difference, a reason when it differs', (t) async {
    final f = Fake();
    await show(t, ClosingCashScreen(api: f.api, dayId: 'd1'));
    expect(find.text('₹1,500'), findsWidgets); // expected
    await t.enterText(find.byKey(const ValueKey('count-amount')), '1490');
    await t.pump();
    expect(find.text('Short ₹10'), findsOneWidget);
    await tapKey(t, 'count-save');
    expect(toast('The count is not what is expected: give a reason.'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('count-reason')), 'Gave change twice');
    await tapKey(t, 'count-save');
    expect(f.body('pos_day_cash_count'), {'day_id': 'd1', 'counted_cash': 1490, 'reason': 'Gave change twice'});
  });

  testWidgets('day closing: count first; a manager closes; a dropped connection retries with the same key', (t) async {
    final f = Fake()..day = dayJson(counted: 1490, variance: -10, reason: 'Gave change twice');
    var drop = true;
    f.override = (r) {
      if (fnOf(r) == 'pos_day_close' && drop) {
        drop = false;
        throw http.ClientException('offline');
      }
      return null;
    };
    await show(t, DayClosingScreen(api: f.api, dayId: 'd1', canManage: true));
    await tapKey(t, 'close-go');
    await tapKey(t, 'close-confirm');
    await t.pump(const Duration(seconds: 6));
    await tapKey(t, 'close-go');
    await tapKey(t, 'close-confirm');
    final keys = f.calls('pos_day_close').map((r) => r.headers['Idempotency-Key']).toList();
    expect(keys.length, 2);
    expect(keys[0], keys[1]); // the same intent: the database replays, never closes twice
    expect(find.text('Closed'), findsWidgets);
  });

  testWidgets('a biller cannot close the day; without a count it asks for one', (t) async {
    final f = Fake()..day = dayJson(counted: 1500, variance: 0);
    await show(t, DayClosingScreen(api: f.api, dayId: 'd1', canManage: false));
    expect(find.text('A manager closes the day'), findsOneWidget);
    expect(find.byKey(const ValueKey('close-go')), findsNothing);
    f.day = dayJson();
    await show(t, DayClosingScreen(api: f.api, dayId: 'd1', canManage: true));
    expect(find.text('Count the cash first'), findsOneWidget);
  });

  testWidgets('opening stock: item by item, with what moved since the last close; summary keeps UPI and card out of the drawer', (t) async {
    final f = Fake();
    await show(t, DayStockScreen(api: f.api, day: BusinessDayFixture.day()));
    expect(find.text('25.5 kg'), findsOneWidget);
    expect(find.textContaining('-1.5 since the last close'), findsOneWidget);
    await show(t, DaySummaryScreen(api: f.api, dayId: 'd1'));
    expect(find.text('Not in the drawer'), findsOneWidget);
    expect(find.text('UPI'), findsOneWidget);
    expect(find.text('₹900'), findsOneWidget);
  });

  testWidgets('previous day reports: newest first, the difference shown; a closed day opens its summary', (t) async {
    final f = Fake();
    await show(t, PreviousDaysScreen(api: f.api, canManage: true));
    expect(find.text('Fri, 30 Oct 2026'), findsOneWidget);
    expect(find.text('-₹10'), findsOneWidget);
    await tapKey(t, 'report-2026-10-30');
    expect(find.text('Day summary'), findsWidgets);
  });
}

/// A day for screens that take one directly.
class BusinessDayFixture {
  static BusinessDay day() => BusinessDay(dayJson());
}
