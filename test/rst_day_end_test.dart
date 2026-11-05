// Day end on the restaurant's cash drawer (founder, 3 Nov 2026; 0650): the bills still open are listed; Day end with bills open needs a
// note and says they go to Revenue leakage; a count that is not a valid amount says so; an ended day can be reopened with a reason; the
// Leakage audit and the dashboard card show the unsettled bills and the reopen. The answers are what the database gave on the local test
// database (server/scripts/rst-day-end-e2e.mjs with FIXTURES=…): a table T7, a takeaway and a held takeaway open, ₹735 due.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/money/rst_money.dart';
import 'package:vinii_pos/money/rst_money_api.dart';
import 'package:vinii_pos/outlets/outlet_scope.dart';
import 'package:vinii_pos/reports/rst_reports_api.dart';
import 'package:vinii_pos/reports/rst_reports_screen.dart';
import 'package:vinii_pos/restaurant/home_insights.dart';
import 'package:vinii_pos/restaurant/restaurant_api.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/rst_day_end_server.json').readAsStringSync()) as Map<String, dynamic>;
Map<String, dynamic> copy(String k) => jsonDecode(jsonEncode(fx[k])) as Map<String, dynamic>;
http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

/// The register answers [register] until Day end or a reopen answers the next one.
class Fake {
  Fake(this.register, {this.onClose});
  Map<String, dynamic> register;
  final http.Response Function(Map<String, dynamic> body)? onClose;
  final calls = <(String, Map<String, dynamic>)>[];
  late final client = MockClient((r) async {
    final fn = r.url.pathSegments.last;
    final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
    calls.add((fn, body));
    switch (fn) {
      case 'rmoney_register':
        return ok(register);
      case 'rmoney_close_day':
        if (onClose != null) return onClose!(body);
        return ok(register = copy('register_closed'));
      case 'rmoney_reopen_day':
        return ok(register = copy('register_reopened'));
    }
    return ok({});
  });
  late final api = RstMoneyApi(rpc: RpcClient(client: client, baseUrl: 'http://pos.test', accessToken: () => 't'));
  Iterable<Map<String, dynamic>> of(String fn) => calls.where((c) => c.$1 == fn).map((c) => c.$2);
}

Future<void> open(WidgetTester t, Fake f, {bool canRecord = true}) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(800, 2400);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: Scaffold(body: SingleChildScrollView(child: RmRegisterPart(api: f.api, canRecord: canRecord, onChanged: () {})))));
  await t.pumpAndSettle();
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('the drawer lists the bills still open before Day end (3 bills, ₹735: Table T7 and two takeaways)', (t) async {
    final f = Fake(copy('register_open'));
    await open(t, f);
    expect(find.byKey(const ValueKey('rm-open-bills')), findsOneWidget);
    expect(find.text('3 bills still open · ₹735 due'), findsOneWidget);
    expect(find.textContaining('Table T7 · #'), findsOneWidget);
    expect(find.text('Day end · count the cash'), findsOneWidget);
    expect(find.textContaining('Close day'), findsNothing, reason: 'renamed Day end');
  });

  testWidgets('Day end with bills open: an invalid count and a missing note say so; then it is sent with confirm and the note', (t) async {
    final f = Fake(copy('register_open'));
    await open(t, f);
    await tapKey(t, 'rm-close-day');
    expect(find.byKey(const ValueKey('rm-open-bills-dialog')), findsOneWidget);
    expect(find.text('End day anyway'), findsOneWidget);
    await tapKey(t, 'rm-close-save');
    expect(find.text('Enter the cash you counted, like 2500 or 2500.50.'), findsOneWidget, reason: 'it used to do nothing');
    await t.enterText(find.byKey(const ValueKey('rm-counted')), '500');
    await tapKey(t, 'rm-close-save');
    expect(find.text('Write why: these bills go to Revenue leakage.'), findsOneWidget);
    expect(f.of('rmoney_close_day'), isEmpty);
    await t.enterText(find.byKey(const ValueKey('rm-dayend-note')), 'Table T7 still eating; takeaways not collected');
    await tapKey(t, 'rm-close-save');
    expect(f.of('rmoney_close_day').single, {'counted_minor': 50000, 'confirm_open_bills': true, 'note': 'Table T7 still eating; takeaways not collected'});
    expect(find.textContaining('Day ended · counted ₹500'), findsOneWidget);
    expect(find.byKey(const ValueKey('rm-closed-open')), findsOneWidget);
    expect(find.textContaining('3 bills left open (₹735) · in Revenue leakage'), findsOneWidget);
    expect(toast('Day ended. ₹500 extra in the drawer. 3 open bills went to Revenue leakage.'), findsOneWidget);
  });

  testWidgets('a day with nothing open ends with just the count', (t) async {
    final f = Fake({...copy('register_open'), 'open_bills': {'count': 0, 'tables': 0, 'due_minor': 0, 'list': []}});
    await open(t, f);
    expect(find.byKey(const ValueKey('rm-open-bills')), findsNothing);
    await tapKey(t, 'rm-close-day');
    expect(find.byKey(const ValueKey('rm-dayend-note')), findsNothing);
    expect(find.text('End day'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('rm-counted')), '500');
    await tapKey(t, 'rm-close-save');
    expect(f.of('rmoney_close_day').single, {'counted_minor': 50000});
  });

  testWidgets('a refusal from the database is shown', (t) async {
    final f = Fake(copy('register_open'),
        onClose: (_) => http.Response(jsonEncode({'detail': '4 bills are still open (₹940.00); settle them, or end the day with a note and they go to Revenue leakage.', 'code': 'open_bills'}), 409,
            headers: {'content-type': 'application/json; charset=utf-8'}));
    await open(t, f);
    await tapKey(t, 'rm-close-day');
    await t.enterText(find.byKey(const ValueKey('rm-counted')), '500');
    await t.enterText(find.byKey(const ValueKey('rm-dayend-note')), 'Late table');
    await tapKey(t, 'rm-close-save');
    expect(toast('4 bills are still open (₹940.00); settle them, or end the day with a note and they go to Revenue leakage.'), findsOneWidget);
  });

  testWidgets('the owner reopens an ended day with a reason; the reopen is listed', (t) async {
    final f = Fake({...copy('register_closed'), 'can_reopen': true});
    await open(t, f);
    expect(find.byKey(const ValueKey('rm-close-day')), findsNothing);
    await tapKey(t, 'rm-reopen-day');
    await tapKey(t, 'rm-reopen-save');
    expect(find.text('Write why the day is reopened.'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('rm-reopen-reason')), 'Counted the float twice');
    await tapKey(t, 'rm-reopen-save');
    expect(f.of('rmoney_reopen_day').single['reason'], 'Counted the float twice');
    expect(find.byKey(const ValueKey('rm-close-day')), findsOneWidget, reason: 'the day can end again');
    expect(find.text('Reopened by ZZ own · Counted the float twice'), findsOneWidget);
    expect(toast('Day reopened. Count the cash again at Day end.'), findsOneWidget);
  });

  testWidgets('a manager sees no Reopen day', (t) async {
    final f = Fake(copy('register_closed')); // can_reopen: false (a manager's answer)
    await open(t, f);
    expect(find.byKey(const ValueKey('rm-reopen-day')), findsNothing);
  });

  testWidgets('Leakage audit: the bills left unsettled at Day end (with the note and who ended the day), and the day reopened', (t) async {
    final client = MockClient((r) async => ok(copy('audit')));
    ignoreOverflow();
    t.view.physicalSize = const Size(800, 2400);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: RstReportScreen(kind: 'audit', api: RstReportsApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client), today: DateTime(2026, 11, 3))));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('rep-day-end')), findsOneWidget);
    expect(find.text('LEFT UNSETTLED AT DAY END · 3 · ₹735'), findsOneWidget);
    expect(find.textContaining('Table T7 · bill'), findsOneWidget);
    expect(find.textContaining('Day end by ZZ mgr · Table T7 still eating; takeaways not collected'), findsNWidgets(3));
  });

  testWidgets('the dashboard Revenue leakage card: bills left unsettled at Day end and the day reopened, in red', (t) async {
    final client = MockClient((r) async => ok({...copy('insights'), 'mix': {}, 'payments': [], 'top': [], 'menu': {}, 'ready': 0}));
    ignoreOverflow();
    t.view.physicalSize = const Size(800, 2400);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: Scaffold(body: SingleChildScrollView(child: RestaurantInsights(api: RestaurantApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client))))));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('rst-leakage')), findsOneWidget);
    expect(find.text('6 bills left unsettled at Day end · ₹1,470'), findsOneWidget);
    expect(find.text('Day reopened 1 time'), findsOneWidget);
    expect(find.text('No admin PIN changes'), findsOneWidget);
  });

  // 0655: an owner's own void needs no admin PIN; the card read "None today" after one. The leakage answer is the database's after the
  // owner voided a paid ₹208 bill.
  testWidgets('the dashboard Revenue leakage card: bills voided today, with their value and in the latest changes', (t) async {
    final client = MockClient((r) async => ok({...copy('insights'), 'mix': {}, 'payments': [], 'top': [], 'menu': {}, 'ready': 0,
          'leakage': {'latest': [{'at': '2026-11-04T11:18:04.328082+00:00', 'by': 'ZZ UI Owner', 'bill': 'P-00004', 'what': 'P-00004 voided, 208.00 refunded: test void', 'approved_by': 'Staff'}],
                      'voided': 1, 'reopened': 0, 'unsettled': 0, 'voided_minor': 20800, 'admin_changes': 0, 'unsettled_due_minor': 0}}));
    ignoreOverflow();
    t.view.physicalSize = const Size(800, 2400);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: Scaffold(body: SingleChildScrollView(child: RestaurantInsights(api: RestaurantApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client))))));
    await t.pumpAndSettle();
    expect(find.text('1 bill voided · ₹208'), findsOneWidget);
    expect(find.text('No admin PIN changes'), findsOneWidget, reason: 'not "None today" once a bill is voided');
    expect(find.text('#P-00004 · P-00004 voided, 208.00 refunded: test void · ZZ UI Owner'), findsOneWidget);
  });

  // 0653: Day end with several outlets booked everything into the first outlet. The answers are the database's for a business with two
  // outlets (server/scripts/rst-five-fixes-e2e.mjs with FIXTURES=…).
  group('several outlets', () {
    final Map<String, dynamic> ox = jsonDecode(File('test/fixtures/rst_outlets_register_server.json').readAsStringSync()) as Map<String, dynamic>;
    Map<String, dynamic> oc(String k) => jsonDecode(jsonEncode(ox[k])) as Map<String, dynamic>;
    tearDown(OutletScope.reset);

    testWidgets("none chosen: each outlet's day, no Day end button; a tap chooses the outlet and shows its drawer", (t) async {
      final f = Fake(oc('register_outlets'));
      await open(t, f);
      expect(find.byKey(const ValueKey('rm-register-outlets')), findsOneWidget);
      expect(find.byKey(const ValueKey('rm-close-day')), findsNothing, reason: 'Day end is per outlet');
      expect(find.text('Day open'), findsNWidgets(2));
      final second = (oc('register_outlets')['outlets'] as List)[1] as Map;
      f.register = oc('register_one');
      await tapKey(t, 'rm-outlet-${second['id']}');
      expect(OutletScope.selected.value, second['id']);
      expect(f.of('rmoney_register').last['location_id'], second['id'], reason: 'the drawer of the chosen outlet');
      expect(find.byKey(const ValueKey('rm-close-day')), findsOneWidget);
      expect(find.textContaining('Cash drawer · ${oc('register_one')['location_name']}'), findsOneWidget, reason: 'which outlet this drawer is');
      f.register = oc('register_outlets');
      await tapKey(t, 'rm-all-outlets');
      expect(OutletScope.selected.value, isNull);
      expect(find.byKey(const ValueKey('rm-register-outlets')), findsOneWidget, reason: 'back to the list');
    });

    testWidgets('an outlet chosen at the top: Day end is sent for it', (t) async {
      OutletScope.selected.value = 'loc-2';
      final f = Fake({...copy('register_open'), 'open_bills': {'count': 0, 'tables': 0, 'due_minor': 0, 'list': []}});
      await open(t, f);
      await tapKey(t, 'rm-close-day');
      await t.enterText(find.byKey(const ValueKey('rm-counted')), '300');
      await tapKey(t, 'rm-close-save');
      expect(f.of('rmoney_close_day').single, {'location_id': 'loc-2', 'counted_minor': 30000});
    });
  });
}
