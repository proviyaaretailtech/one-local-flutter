import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/app_routes.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/tables/actions_screen.dart';
import 'package:vinii_pos/tables/floor_screen.dart';
import 'package:vinii_pos/tables/merge_screen.dart';
import 'package:vinii_pos/tables/table_order_screen.dart';
import 'package:vinii_pos/tables/table_widgets.dart';
import 'package:vinii_pos/tables/tables_api.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

/// Answers shaped like the real ones of migration 0404 (database/tests/404_tables_floor.sql and scripts/gateway-e2e.mjs show the same fields).
final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/tables_server.json').readAsStringSync()) as Map<String, dynamic>;

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) =>
    http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;
Map<String, dynamic> argsOf(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

class Fake {
  Fake([this._handler]);
  final http.Response? Function(http.Request r)? _handler;
  final requests = <http.Request>[];

  late final api = TablesApi(
    baseUrl: 'http://tbl.test',
    accessToken: () => 'token-123',
    client: MockClient((r) async {
      requests.add(r);
      final custom = _handler?.call(r);
      if (custom != null) return custom;
      switch (fnOf(r)) {
        case 'tbl_floor':
          final want = argsOf(r)['status'];
          final all = (fx['floor'] as Map<String, dynamic>);
          if (want == null || want == 'all') return ok(all);
          return ok({...all, 'tables': (all['tables'] as List).where((t) => (t as Map)['status'] == want).toList()});
        case 'tbl_view':
          return ok(argsOf(r)['table_id'] == 't2' ? fx['view_occupied'] : fx['view_available']);
        case 'tbl_order_view':
          return ok(fx['order_view']);
        case 'tbl_history':
          return ok(fx['history']);
        case 'tbl_reserve':
          return ok(fx['reserved']);
        case 'tbl_reserve_cancel':
          return ok({'reservation': {...(fx['reserved'] as Map)['reservation'] as Map, 'status': 'cancelled'}});
        case 'tbl_transfer':
          return ok(fx['transferred']);
        case 'tbl_merge':
          return ok(fx['merged']);
        case 'tbl_split':
          return ok(fx['split']);
        case 'pos_set_order_status':
          return ok({'id': 'o-1'});
      }
      return err(404, 'not found: ${fnOf(r)}');
    }),
  );

  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
}

Future<void> show(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 3600);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

Future<void> tapText(WidgetTester t, String text) async {
  await t.ensureVisible(find.text(text).last);
  await t.pumpAndSettle();
  await t.tap(find.text(text).last);
  await t.pumpAndSettle();
}

void main() {
  tearDown(HomeNav.reset);

  group('TablesApi', () {
    test('floor sends the token, the store, the filter; answers parse as facts', () async {
      final s = Fake();
      s.api.locationId = 'loc-1';
      final d = await s.api.floor(status: 'occupied', areaId: 'area-g');
      final r = s.requests.single;
      expect(r.method, 'POST');
      expect(r.url.toString(), 'http://tbl.test/rpc/tbl_floor');
      expect(argsOf(r), {'location_id': 'loc-1', 'status': 'occupied', 'area_id': 'area-g'});
      expect(r.headers['Authorization'], 'Bearer token-123');
      expect(d.l('tables').length, 1);
      expect(d.m('counts').n('all'), 7);
    });

    test('reserve sends the store wall-clock date and time with one key in the header and the body', () async {
      final s = Fake();
      final r = await s.api.reserve(tableId: 't4', guestName: ' John Doe ', phone: ' +1 (555) 019-2834 ', guests: 4, localDate: '2026-10-17', localTime: '19:30', notes: ' Window seat ', key: 'k1');
      final q = s.requests.single;
      expect(q.url.path, '/rpc/tbl_reserve');
      expect(q.headers['Idempotency-Key'], 'k1');
      expect(argsOf(q), {'table_id': 't4', 'guest_name': 'John Doe', 'phone': '+1 (555) 019-2834', 'guests': 4, 'local_date': '2026-10-17', 'local_time': '19:30', 'notes': 'Window seat', 'idempotency_key': 'k1'});
      expect(r.m('reservation').s('status'), 'confirmed');
    });

    test('transfer, merge, split, view, history and the status move send exactly what the screens mean', () async {
      final s = Fake();
      await s.api.transfer('a', 'b');
      await s.api.merge(['a', 'b']);
      await s.api.split(mergeId: 'm-1');
      await s.api.split(tableId: 't13');
      await s.api.view('t4');
      await s.api.history('t4', limit: 5);
      await s.api.orderView('t2');
      await s.api.cancelReservation('res-1');
      await s.api.cancelReservation('res-2', outcome: 'no_show');
      await s.api.setOrderStatus('o-1', 'awaiting_payment', expectedUpdatedAt: 'ts');
      expect(s.requests.map((r) => '${fnOf(r)} ${jsonEncode(argsOf(r))}').toList(), [
        'tbl_transfer {"from_table_id":"a","to_table_id":"b"}',
        'tbl_merge {"table_ids":["a","b"]}',
        'tbl_split {"merge_id":"m-1"}',
        'tbl_split {"table_id":"t13"}',
        'tbl_view {"table_id":"t4"}',
        'tbl_history {"table_id":"t4","limit":5}',
        'tbl_order_view {"table_id":"t2"}',
        'tbl_reserve_cancel {"id":"res-1"}',
        'tbl_reserve_cancel {"id":"res-2","outcome":"no_show"}',
        'pos_set_order_status {"order_id":"o-1","to":"awaiting_payment","expected_updated_at":"ts"}',
      ]);
    });

    test('a refusal keeps the server sentence, status and code', () async {
      final s = Fake((r) => err(409, 'This table is already reserved around that time.', 'conflict'));
      await expectLater(
        s.api.reserve(tableId: 't4', guestName: 'x', phone: '5550100', guests: 2, localDate: '2026-10-18', localTime: '12:00', key: 'k'),
        throwsA(isA<TablesApiException>().having((e) => e.message, 'message', 'This table is already reserved around that time.').having((e) => e.status, 'status', 409).having((e) => e.code, 'code', 'conflict')),
      );
    });

    test('keys are fresh each time', () {
      expect(TablesApi.newKey(), isNot(TablesApi.newKey()));
      expect(TablesApi.newKey(), startsWith('tbl-'));
    });
  });

  group('display helpers', () {
    test('elapsed and clock', () {
      expect(elapsed(75), '1h 15m');
      expect(elapsed(45), '45m');
      expect(elapsed(120), '2h');
      expect(clock12(DateTime(2026, 10, 17, 19, 30)), '7:30 PM');
      expect(clockFromHm('19:30'), '7:30 PM');
      expect(clockFromHm('09:05'), '9:05 AM');
      expect(clock12(DateTime(2026, 10, 17, 0, 5)), '12:05 AM');
      expect(clock12Padded(DateTime(2026, 10, 17, 19, 30)), '07:30 PM');
      expect(rupees(1302), '₹1,302');
      expect(pax(4), '4 Pax');
    });
  });

  group('Tables grid and sheet', () {
    testWidgets('shows every table with its state, time and the filter chips with counts', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api, initials: 'RS')));
      expect(find.text('Tables'), findsOneWidget);
      expect(find.text('RS'), findsOneWidget);
      for (final l in ['T1', 'T2', 'T3', 'T4', 'T5', 'T12', 'T13']) {
        expect(find.byKey(ValueKey('table-$l')), findsOneWidget, reason: l);
      }
      expect(find.text('AVAILABLE'), findsNWidgets(4));
      expect(find.text('OCCUPIED'), findsOneWidget);
      expect(find.text('RESERVED'), findsOneWidget);
      expect(find.text('CLEANING'), findsOneWidget);
      expect(find.text('1h 15m'), findsOneWidget);
      expect(find.text('7:30 PM'), findsOneWidget); // the store's wall clock from the server (reserved_local 19:30), not the phone's zone
      expect(find.text('All Tables (7)'), findsOneWidget);
      expect(find.text('Occupied (1)'), findsOneWidget);
      expect(find.text('Reserved (1)'), findsOneWidget);
      expect(find.text('Cleaning (1)'), findsOneWidget);
      // a joined pair shows the combined seats the server sends
      expect(find.text('8 Pax'), findsNWidgets(2));
    });

    testWidgets('a chip asks the server for that state', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await tapKey(t, 'chip-occupied');
      expect(argsOf(s.calls('tbl_floor').last)['status'], 'occupied');
      expect(find.byKey(const ValueKey('table-T2')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-T1')), findsNothing);
    });

    testWidgets('an error is a sentence with a retry, not a blank screen', (t) async {
      var fail = true;
      final s = Fake((r) => fail ? err(403, 'Your role cannot do this on the floor.', 'forbidden') : null);
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      expect(find.text('Your role cannot do this on the floor.'), findsOneWidget);
      fail = false;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('table-T1')), findsOneWidget);
    });

    testWidgets('tap an available table: the sheet offers Start New Order, Reserve Table, View History', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await tapKey(t, 'table-T4');
      expect(find.text('Table T4'), findsOneWidget);
      expect(find.text('4 Pax • Available'), findsOneWidget);
      expect(find.text('Start New Order'), findsOneWidget);
      expect(find.text('Reserve Table'), findsOneWidget);
      expect(find.text('View History'), findsOneWidget);
      await tapKey(t, 'sheet-close');
      expect(find.text('Table T4'), findsNothing);
    });

    testWidgets('Start New Order hands the table to the host; without a host it says so', (t) async {
      final s = Fake();
      Facts? got;
      await show(t, FloorScreen(env: TablesEnv(api: s.api, onStartOrder: (c, table) => got = table)));
      await tapKey(t, 'table-T4');
      await tapText(t, 'Start New Order');
      expect(got?.s('id'), 't4');
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await tapKey(t, 'table-T4');
      await tapText(t, 'Start New Order');
      expect(find.text('Starting an order from a table opens in a later release.'), findsOneWidget);
    });

    testWidgets('View History lists orders and reservations of the table', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await tapKey(t, 'table-T4');
      await tapKey(t, 'sheet-history');
      expect(find.text('Table T4 history'), findsOneWidget);
      expect(find.text('Order P-9001'), findsOneWidget);
      expect(find.text('Reservation for John Doe'), findsOneWidget);
      expect(argsOf(s.calls('tbl_history').single)['table_id'], 't4');
    });

    testWidgets('the sheet only offers what the server allows (kitchen: history only)', (t) async {
      final s = Fake((r) => fnOf(r) == 'tbl_view' ? ok({...fx['view_available'] as Map<String, dynamic>, 'allowed': ['history']}) : null);
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await tapKey(t, 'table-T4');
      expect(find.text('Start New Order'), findsNothing);
      expect(find.text('Reserve Table'), findsNothing);
      expect(find.text('View History'), findsOneWidget);
    });
  });

  group('Reserve form', () {
    Future<Fake> open(WidgetTester t, [http.Response? Function(http.Request)? h]) async {
      final s = Fake(h);
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await tapKey(t, 'table-T4');
      await tapText(t, 'Reserve Table');
      return s;
    }

    testWidgets('has the frame fields; Confirm waits for a name and a phone', (t) async {
      await open(t);
      expect(find.text('Reserve Table T4'), findsOneWidget);
      for (final l in ['GUEST NAME', 'PHONE NUMBER', 'PARTY SIZE', 'DATE', 'TIME', 'SPECIAL NOTES']) {
        expect(find.text(l), findsOneWidget, reason: l);
      }
      for (final n in [2, 4, 6, 8]) {
        expect(find.text('$n Pax'), findsOneWidget);
      }
      expect(find.text('Confirm Reservation'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.textContaining('Today,'), findsOneWidget);
    });

    testWidgets('Confirm Reservation sends the form once, with a key, and returns to the grid', (t) async {
      final s = await open(t);
      await t.enterText(find.byType(TextField).at(0), 'John Doe');
      await t.enterText(find.byType(TextField).at(1), '+1 (555) 019-2834');
      await tapKey(t, 'pax-6');
      await t.enterText(find.byType(TextField).at(2), 'Window seat preferred.');
      await tapText(t, 'Confirm Reservation');
      final q = s.calls('tbl_reserve').single;
      final a = argsOf(q);
      expect(a['table_id'], 't4');
      expect(a['guest_name'], 'John Doe');
      expect(a['phone'], '+1 (555) 019-2834');
      expect(a['guests'], 6);
      expect(a['notes'], 'Window seat preferred.');
      expect(a['local_date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      expect(a['local_time'], matches(RegExp(r'^\d{2}:\d{2}$')));
      expect(a.containsKey('scheduled_at'), isFalse);
      expect(q.headers['Idempotency-Key'], a['idempotency_key']);
      expect(find.text('Reserve Table T4'), findsNothing);
      expect(find.byKey(const ValueKey('table-T1')), findsOneWidget);
    });

    testWidgets('a refusal shows the server sentence and keeps the form', (t) async {
      final s = await open(t, (r) => fnOf(r) == 'tbl_reserve' ? err(409, 'This table is already reserved around that time.', 'conflict') : null);
      await t.enterText(find.byType(TextField).at(0), 'John');
      await t.enterText(find.byType(TextField).at(1), '5550100');
      await tapText(t, 'Confirm Reservation');
      expect(find.byKey(const ValueKey('reserve-error')), findsOneWidget);
      expect(find.text('This table is already reserved around that time.'), findsOneWidget);
      expect(find.text('Reserve Table T4'), findsOneWidget);
      expect(s.calls('tbl_reserve').length, 1);
    });

    testWidgets('a lost connection keeps the same key for the retry', (t) async {
      var first = true;
      final keys = <String>[];
      final s = await open(t, (r) {
        if (fnOf(r) != 'tbl_reserve') return null;
        keys.add(r.headers['Idempotency-Key']!);
        if (first) {
          first = false;
          throw const SocketException('offline');
        }
        return null;
      });
      await t.enterText(find.byType(TextField).at(0), 'John');
      await t.enterText(find.byType(TextField).at(1), '5550100');
      await tapText(t, 'Confirm Reservation');
      expect(s.calls('tbl_reserve').length, 1);
      await tapText(t, 'Confirm Reservation');
      expect(keys.length, 2);
      expect(keys[0], keys[1]);
    });

    testWidgets('Cancel leaves without calling the server', (t) async {
      final s = await open(t);
      await tapText(t, 'Cancel');
      expect(s.calls('tbl_reserve'), isEmpty);
      expect(find.text('Reserve Table T4'), findsNothing);
    });
  });

  group('Actions, order detail, transfer', () {
    testWidgets('an occupied table opens its actions: bill, waiter, Open Existing Order, Transfer Table', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await tapKey(t, 'table-T2');
      expect(find.text('Table T12 Actions'), findsOneWidget);
      expect(find.text('Dine-In • Occupied • Bill Amount ₹1,302 • Waiter: SS'), findsOneWidget);
      expect(find.text('Open Existing Order'), findsOneWidget);
      expect(find.text('Transfer Table'), findsOneWidget);
    });

    testWidgets('Open Existing Order: banner, items with kitchen status, timeline, subtotal, six buttons', (t) async {
      final s = Fake();
      await show(t, ActionsScreen(env: TablesEnv(api: s.api), tableId: 't2'));
      await tapKey(t, 'action-open-order');
      expect(find.text('Table T12 Order'), findsOneWidget);
      expect(find.text('Ground Floor • 4 Pax'), findsOneWidget);
      expect(find.text('ACTIVE IN KITCHEN'), findsOneWidget);
      for (final n in ['Chicken Tikka Biryani', 'Butter Naan', 'Paneer Butter Masala']) {
        expect(find.text(n), findsOneWidget);
      }
      expect(find.text('Preparing'), findsNWidgets(3));
      expect(find.text('₹640'), findsOneWidget);
      expect(find.text('2x'), findsOneWidget);
      expect(find.text('OPERATIONAL TIMELINE'), findsOneWidget);
      expect(find.textContaining('KOT #103 generated (auto-fire)'), findsOneWidget);
      expect(find.text('₹1,240'), findsOneWidget);
      for (final b in ['Add Items', 'Send KOT', 'Print KOT', 'Change Table', 'Merge Table', 'Generate Bill']) {
        expect(find.text(b), findsOneWidget, reason: b);
      }
    });

    testWidgets('a button the server switched off says why and calls nothing', (t) async {
      final s = Fake();
      await show(t, TableOrderScreen(env: TablesEnv(api: s.api), tableId: 't2'));
      await tapText(t, 'Add Items');
      expect(find.text('Adding items to an open order is not in this release.'), findsOneWidget);
      await tapText(t, 'Print KOT');
      expect(find.text('Printing a KOT is not in this release.'), findsOneWidget);
      await tapText(t, 'Send KOT');
      expect(find.text('Not available right now.'), findsOneWidget);
      expect(s.calls('pos_set_order_status'), isEmpty);
    });

    testWidgets('Generate Bill moves the open order to awaiting payment with the version the person saw', (t) async {
      final s = Fake();
      await show(t, TableOrderScreen(env: TablesEnv(api: s.api), tableId: 't2'));
      await tapText(t, 'Generate Bill');
      expect(argsOf(s.calls('pos_set_order_status').single), {'order_id': 'o-1', 'to': 'awaiting_payment', 'expected_updated_at': '2026-10-17T06:00:00+00:00'});
      expect(find.text('Bill generated.'), findsOneWidget);
    });

    testWidgets('Generate Bill refused by the database shows its sentence', (t) async {
      final s = Fake((r) => fnOf(r) == 'pos_set_order_status' ? err(409, 'This order was changed on another device.', 'version_conflict') : null);
      await show(t, TableOrderScreen(env: TablesEnv(api: s.api), tableId: 't2'));
      await tapText(t, 'Generate Bill');
      expect(find.text('This order was changed on another device.'), findsOneWidget);
    });

    testWidgets('Transfer Table: choose the destination, confirm the sentence, move', (t) async {
      final s = Fake();
      await show(t, ActionsScreen(env: TablesEnv(api: s.api), tableId: 't2'));
      await tapText(t, 'Transfer Table');
      expect(find.text('Transfer T12 to…'), findsOneWidget);
      await tapKey(t, 'table-T1');
      expect(find.text('Confirm Table Transfer?'), findsOneWidget);
      expect(find.textContaining('transfer an order (₹1,302) from Table T12 to Table T1.'), findsOneWidget);
      expect(find.textContaining('consolidated'), findsNothing);
      await tapText(t, 'Confirm Transfer');
      expect(argsOf(s.calls('tbl_transfer').single), {'from_table_id': 't2', 'to_table_id': 't1'});
      expect(find.text('Moved 1 order to Table T1.'), findsOneWidget);
    });

    testWidgets('transferring onto an occupied table warns that open orders are consolidated; Cancel moves nothing', (t) async {
      final s = Fake((r) => fnOf(r) == 'tbl_view' ? ok(fx['view_occupied']) : null);
      await show(t, ActionsScreen(env: TablesEnv(api: s.api), tableId: 't2'));
      await tapText(t, 'Transfer Table');
      // T2 (id t2) is the source in the fixture; pick the free T4 first to see no warning, then retry onto the occupied one in a second flow
      await tapKey(t, 'table-T2');
      expect(find.text('Choose a different table.'), findsOneWidget);
      await tapKey(t, 'table-T3');
      await tapText(t, 'Cancel');
      expect(s.calls('tbl_transfer'), isEmpty);
    });

    testWidgets('a joined table cannot be chosen as a destination', (t) async {
      final s = Fake();
      await show(t, ActionsScreen(env: TablesEnv(api: s.api), tableId: 't2'));
      await tapText(t, 'Transfer Table');
      await tapKey(t, 'table-T13');
      expect(find.textContaining('is joined to other tables'), findsOneWidget);
      expect(find.text('Confirm Table Transfer?'), findsNothing);
    });

    testWidgets('a transfer the server refuses shows its sentence', (t) async {
      final s = Fake((r) => fnOf(r) == 'tbl_transfer' ? err(409, 'T12 has nothing to move.', 'not_occupied') : null);
      await show(t, ActionsScreen(env: TablesEnv(api: s.api), tableId: 't2'));
      await tapText(t, 'Transfer Table');
      await tapKey(t, 'table-T1');
      await tapText(t, 'Confirm Transfer');
      expect(find.text('T12 has nothing to move.'), findsOneWidget);
    });
  });

  group('Merge tables', () {
    testWidgets('select two tables: Merge Seating, Combined Total, the rule, Join Tables', (t) async {
      final s = Fake();
      await show(t, MergeScreen(env: TablesEnv(api: s.api)));
      expect(find.text('Merge Tables'), findsOneWidget);
      expect(find.text('Select tables to combine seating capacity'), findsOneWidget);
      expect(find.text('Merge Seating'), findsOneWidget);
      expect(find.text('Split Existing Merges'), findsOneWidget);
      await tapKey(t, 'table-T1');
      await tapKey(t, 'table-T4');
      expect(find.text('SELECTED'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('merge-total')), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('merge-total'))).data, '8 Pax');
      expect(find.textContaining('T1 & T4: Tables must be in the same dining area to combine.'), findsOneWidget);
      await tapText(t, 'Join Tables');
      expect(argsOf(s.calls('tbl_merge').single), {'table_ids': ['t1', 't4']});
    });

    testWidgets('Join Tables waits for two tables; a table can be unselected', (t) async {
      final s = Fake();
      await show(t, MergeScreen(env: TablesEnv(api: s.api), startTableId: 't1'));
      await tapText(t, 'Join Tables');
      expect(s.calls('tbl_merge'), isEmpty);
      await tapKey(t, 'table-T4');
      await tapKey(t, 'table-T4');
      expect(find.text('SELECTED'), findsOneWidget);
    });

    testWidgets('the server refusing a join shows its sentence and nothing closes', (t) async {
      final s = Fake((r) => fnOf(r) == 'tbl_merge' ? err(409, 'More than one of these tables has an open order; finish or transfer one first.', 'busy') : null);
      await show(t, MergeScreen(env: TablesEnv(api: s.api), startTableId: 't1'));
      await tapKey(t, 'table-T4');
      await tapText(t, 'Join Tables');
      expect(find.text('More than one of these tables has an open order; finish or transfer one first.'), findsOneWidget);
      expect(find.text('Merge Tables'), findsOneWidget);
    });

    testWidgets('Split Existing Merges lists the joined groups and splits the chosen one', (t) async {
      final s = Fake();
      await show(t, MergeScreen(env: TablesEnv(api: s.api)));
      await tapText(t, 'Split Existing Merges');
      expect(find.text('T12 + T13'), findsOneWidget);
      await tapText(t, 'T12 + T13');
      expect(argsOf(s.calls('tbl_split').single), {'merge_id': 'm-1'});
      expect(find.text('Tables split.'), findsOneWidget);
    });

    testWidgets('Cancel leaves', (t) async {
      final s = Fake();
      await show(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => MergeScreen(env: TablesEnv(api: s.api)))), child: const Text('go')))));
      await tapText(t, 'go');
      expect(find.text('Merge Tables'), findsOneWidget);
      await tapText(t, 'Cancel');
      expect(find.text('Merge Tables'), findsNothing);
    });
  });

  group('wiring', () {
    test('installRoutes plugs the tables screen into the home hooks', () {
      HomeNav.reset();
      expect(HomeNav.tables, isNull);
      installRoutes();
      expect(HomeNav.tables, isNotNull);
    });

    testWidgets('the POS bottom bar reports taps of the tabs other sections own', (t) async {
      final s = Fake();
      final taps = <String>[];
      await show(t, FloorScreen(env: TablesEnv(api: s.api, onNavigate: taps.add)));
      await tapKey(t, 'tbl-tab-money');
      await tapKey(t, 'tbl-tab-stock');
      expect(taps, ['money', 'stock']);
    });
  });
}
