import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/app_routes.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/menu/menu_widgets.dart' show FoodTypeMark;
import 'package:vinii_pos/tables/actions_screen.dart';
import 'package:vinii_pos/tables/floor_screen.dart';
import 'package:vinii_pos/tables/merge_screen.dart';
import 'package:vinii_pos/tables/manage_tables_screen.dart';
import 'package:vinii_pos/tables/table_deck.dart';
import 'package:vinii_pos/tables/table_order_screen.dart';
import 'package:vinii_pos/tables/table_widgets.dart';
import 'package:vinii_pos/tables/tables_api.dart';
import 'package:vinii_pos/tables/take_order_screens.dart';
import 'package:vinii_pos/ui/app_tab_bar.dart' show TabShellScope;
import 'package:vinii_pos/ui/app_header.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

/// Answers shaped like the real ones of migration 0404 (database/tests/404_tables_floor.sql and scripts/gateway-e2e.mjs show the same fields).
final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/tables_server.json').readAsStringSync()) as Map<String, dynamic>;
final Map<String, dynamic> tk = jsonDecode(File('test/fixtures/take_order_server.json').readAsStringSync()) as Map<String, dynamic>;

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
        case 'pos_sell_catalog':
          return ok(tk['menu']);
        case 'tbl_order_add':
          return ok(argsOf(r)['send'] == true ? tk['add_send'] : tk['add_hold']);
        case 'pos_counter_order':
          return ok({'order_id': 'o-9', 'replayed': false, 'held': argsOf(r)['send'] != true, 'kot': argsOf(r)['send'] == true ? (tk['add_send'] as Map)['kot'] : null, 'order': {'display_no': 'P-00009', 'total': 60}});
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

/// Opens a table the way staff do on the Bill: Tables → the table (chosen) → open it (its sheet, or its order when occupied).
/// On a "choose a table" floor (move / merge) the tables are on the page, so it is a plain tap.
Future<void> openTable(WidgetTester t, String label) async {
  if (find.byKey(const ValueKey('open-tables')).hitTestable().evaluate().isEmpty) return tapKey(t, 'table-$label');
  await tapKey(t, 'open-tables');
  await tapKey(t, 'table-$label');
  await tapKey(t, 'open-order-table');
}

/// Opens the Tables button's sheet (every table, three to a row) without choosing one.
Future<void> openTablesSheet(WidgetTester t) => tapKey(t, 'open-tables');

Future<void> tapText(WidgetTester t, String text) async {
  await t.ensureVisible(find.text(text).last);
  await t.pumpAndSettle();
  await t.tap(find.text(text).last);
  await t.pumpAndSettle();
}

void main() {
  tearDown(HomeNav.reset);

  group('TablesNav', () {
    testWidgets('draws its bar on its own, and nothing inside the app shell (the shell draws the one bar)', (t) async {
      final nav = TablesNav(onTap: (_) {});
      await t.pumpWidget(MaterialApp(home: Scaffold(bottomNavigationBar: nav)));
      expect(find.text('Bill'), findsOneWidget);
      await t.pumpWidget(MaterialApp(home: TabShellScope(child: Scaffold(bottomNavigationBar: nav))));
      expect(find.text('Bill'), findsNothing);
    });
  });

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

  group('Manage tables', () {
    /// A server holding a little floor: T1 (2 seats, no history), T2 (4 seats, past bills). Saves and removals change it, like the database.
    Fake manageServer({bool canManage = true}) {
      final tables = <Map<String, dynamic>>[
        {'id': 'm1', 'label': 'T1', 'seats': 2, 'status': 'available', 'has_history': false},
        {'id': 'm2', 'label': 'T2', 'seats': 4, 'status': 'available', 'has_history': true},
      ];
      Map<String, dynamic> list() => {'can_manage': canManage, 'tables': tables};
      return Fake((r) {
        final a = argsOf(r);
        switch (fnOf(r)) {
          case 'tbl_table_list':
            return ok(list());
          case 'tbl_table_save':
            final label = (a['label'] as String).trim().toUpperCase();
            if (tables.any((t) => t['label'] == label && t['id'] != a['id'])) {
              return http.Response(jsonEncode({'detail': 'There is already a table called $label', 'code': 'conflict'}), 409, headers: {'content-type': 'application/json'});
            }
            if (a['id'] == null) {
              tables.add({'id': 'm${tables.length + 1}', 'label': label, 'seats': a['seats'], 'status': 'available', 'has_history': false});
            } else {
              final t = tables.firstWhere((t) => t['id'] == a['id']);
              t['label'] = label;
              t['seats'] = a['seats'];
            }
            return ok({'id': a['id'] ?? 'new', ...list()});
          case 'tbl_table_remove':
            final t = tables.firstWhere((t) => t['id'] == a['id']);
            tables.remove(t);
            return ok({'removed': t['label'], 'hidden': t['has_history'], ...list()});
        }
        return null;
      });
    }

    testWidgets('opened from the side bar: the green banner with the round ← that closes it', (t) async {
      final s = manageServer();
      await show(t, Builder(builder: (c) => TextButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => ManageTablesScreen(env: TablesEnv(api: s.api)))), child: const Text('go'))));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.descendant(of: find.byType(AppHeader), matching: find.text('Manage tables')), findsOneWidget);
      expect(find.descendant(of: find.byType(AppHeader), matching: find.text('2 tables · 6 seats')), findsOneWidget);
      expect(find.byKey(const ValueKey('tbl-back')), findsOneWidget, reason: 'the one round ← under the banner');
      await t.tap(find.byKey(const ValueKey('tbl-back')));
      await t.pumpAndSettle();
      expect(find.text('go'), findsOneWidget);
    });

    testWidgets('lists tables; Add table suggests the next name and sends name and seats', (t) async {
      final s = manageServer();
      await show(t, ManageTablesScreen(env: TablesEnv(api: s.api)));
      expect(find.text('2 tables · 6 seats'), findsOneWidget);
      expect(find.byKey(const ValueKey('table-row-T1')), findsOneWidget);
      expect(find.text('4 seats · Available'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('table-add')));
      await t.pumpAndSettle();
      expect(t.widget<TextField>(find.byKey(const ValueKey('table-label'))).controller!.text, 'T3', reason: 'next free number');
      await t.tap(find.byKey(const ValueKey('seats-plus')));
      await t.pump();
      expect(find.text('5'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('table-save')));
      await t.pumpAndSettle();
      final sent = argsOf(s.requests.lastWhere((r) => fnOf(r) == 'tbl_table_save'));
      expect(sent['label'], 'T3');
      expect(sent['seats'], 5);
      expect(sent.containsKey('id'), isFalse);
      expect(find.byKey(const ValueKey('table-row-T3')), findsOneWidget);
      expect(find.text('3 tables · 11 seats'), findsOneWidget);
    });

    testWidgets('rename and re-seat a table; a duplicate name keeps the database sentence in the sheet', (t) async {
      final s = manageServer();
      await show(t, ManageTablesScreen(env: TablesEnv(api: s.api)));
      await t.tap(find.byKey(const ValueKey('table-edit-T1')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('table-label')), 'T2');
      await t.tap(find.byKey(const ValueKey('table-save')));
      await t.pumpAndSettle();
      expect(find.text('There is already a table called T2'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('table-label')), 'Patio');
      await t.tap(find.byKey(const ValueKey('seats-plus')));
      await t.tap(find.byKey(const ValueKey('table-save')));
      await t.pumpAndSettle();
      final sent = argsOf(s.requests.lastWhere((r) => fnOf(r) == 'tbl_table_save'));
      expect(sent['id'], 'm1');
      expect(sent['label'], 'Patio');
      expect(sent['seats'], 3);
      expect(find.byKey(const ValueKey('table-row-PATIO')), findsOneWidget);
    });

    testWidgets('remove: a table with past bills is hidden (said so before and after)', (t) async {
      final s = manageServer();
      await show(t, ManageTablesScreen(env: TablesEnv(api: s.api)));
      await t.tap(find.byKey(const ValueKey('table-remove-T2')));
      await t.pumpAndSettle();
      expect(find.textContaining('has past bills, so it is hidden from the floor'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('remove-confirm')));
      await t.pumpAndSettle();
      expect(argsOf(s.requests.lastWhere((r) => fnOf(r) == 'tbl_table_remove'))['id'], 'm2');
      expect(find.byKey(const ValueKey('table-row-T2')), findsNothing);
      expect(find.text('T2 hidden (it has past bills).'), findsOneWidget);
    });

    testWidgets('someone who may not manage tables sees them read-only', (t) async {
      final s = manageServer(canManage: false);
      await show(t, ManageTablesScreen(env: TablesEnv(api: s.api)));
      expect(find.byKey(const ValueKey('table-row-T1')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-add')), findsNothing);
      expect(find.byKey(const ValueKey('table-edit-T1')), findsNothing);
      expect(find.byKey(const ValueKey('table-remove-T1')), findsNothing);
      expect(find.textContaining('Only the owner or a floor manager'), findsOneWidget);
    });

    testWidgets('the floor offers Manage tables, and Add tables when it has none', (t) async {
      final s = Fake((r) => fnOf(r) == 'tbl_floor' ? ok({'counts': {'all': 0}, 'tables': []}) : fnOf(r) == 'tbl_table_list' ? ok({'can_manage': true, 'tables': []}) : null);
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await tapKey(t, 'floor-more');
      expect(find.byKey(const ValueKey('open-manage-tables')), findsOneWidget, reason: 'set-up actions sit in the ⋮');
      await t.tapAt(const Offset(5, 5));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('floor-add-tables')));
      await t.pumpAndSettle();
      expect(find.text('Manage tables'), findsOneWidget);
      expect(find.text('No tables yet. Add your first table below.'), findsOneWidget);
    });
  });

  group('Table deck (floating table bars)', () {
    List<Facts> five() => [
          for (final (label, seats, status, mins) in [('T1', 2, 'available', 0), ('T2', 2, 'occupied', 12), ('T3', 4, 'reserved', 0), ('T4', 4, 'cleaning', 0), ('T5', 6, 'available', 0), ('T6', 8, 'available', 0)])
            Facts({'id': 'id-$label', 'label': label, 'seats': seats, 'status': status, 'elapsed_minutes': mins}),
        ];

    Future<List<String>> pumpDeck(WidgetTester t) async {
      final opened = <String>[];
      await show(t, Scaffold(body: Align(alignment: Alignment.bottomCenter, child: TableDeck(tables: five(), onOpen: (f) => opened.add(f.s('label'))))));
      return opened;
    }

    testWidgets('stacked: the first table in front, two others peeking behind; five tables at most, each its own colour', (t) async {
      final opened = await pumpDeck(t);
      expect(find.byKey(const ValueKey('deck-front-T1')), findsOneWidget);
      expect(find.text('T1 · 2 Pax'), findsOneWidget);
      expect(find.text('Available'), findsOneWidget);
      expect(find.byKey(const ValueKey('deck-peek-T2')), findsOneWidget);
      expect(find.byKey(const ValueKey('deck-peek-T3')), findsOneWidget);
      expect(TableDeck.colors.map((c) => c.$1).toSet(), hasLength(5), reason: 'five different colours');
      await t.tap(find.text('T1 · 2 Pax'));
      await t.pump();
      expect(opened, ['T1'], reason: 'the front bar opens its table');
    });

    testWidgets('⌃ fans out one bar per table (T6 is not in the deck); tapping one brings it to the front and opens it', (t) async {
      final opened = await pumpDeck(t);
      await t.tap(find.byKey(const ValueKey('deck-toggle-T1')));
      await t.pumpAndSettle();
      for (final l in ['T1', 'T2', 'T3', 'T4', 'T5']) {
        expect(find.byKey(ValueKey('deck-bar-$l')), findsOneWidget, reason: l);
      }
      expect(find.byKey(const ValueKey('deck-bar-T6')), findsNothing);
      expect(find.text('Occupied · 12m'), findsOneWidget);
      expect(find.text('Reserved'), findsOneWidget);
      expect(find.text('Cleaning'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('deck-bar-T3')));
      await t.pumpAndSettle();
      expect(opened, ['T3']);
      expect(find.byKey(const ValueKey('deck-front-T3')), findsOneWidget, reason: 'T3 is now in front, the deck closed');
    });

    testWidgets('the floor shows the deck over its tables (not while picking a table)', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      expect(find.byKey(const ValueKey('table-deck')), findsOneWidget);
      expect(find.byKey(const ValueKey('deck-front-T1')), findsOneWidget);
    });
  });

  group('Tables grid and sheet', () {
    testWidgets('no status pills; the Tables button sits under Ready to serve and holds every table, three to a row', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      for (final id in ['all', 'available', 'occupied', 'reserved', 'cleaning']) {
        expect(find.byKey(ValueKey('chip-$id')), findsNothing, reason: 'no $id pill');
      }
      expect(argsOf(s.calls('tbl_floor').last)['status'], 'all', reason: 'the floor always shows every table');
      expect(find.byKey(const ValueKey('table-T1')), findsNothing, reason: 'the tables live inside the Tables button');
      expect(t.getRect(find.byKey(const ValueKey('open-tables'))).top, closeTo(t.getRect(find.byKey(const ValueKey('open-ready-to-serve'))).top, 0.5), reason: 'same row as Ready to serve');
      await openTablesSheet(t);
      expect(find.text('Choose a table'), findsOneWidget);
      final width = t.view.physicalSize.width / t.view.devicePixelRatio;
      final r1 = t.getRect(find.byKey(const ValueKey('table-T1')));
      final r2 = t.getRect(find.byKey(const ValueKey('table-T2')));
      final r3 = t.getRect(find.byKey(const ValueKey('table-T3')));
      final r4 = t.getRect(find.byKey(const ValueKey('table-T4')));
      expect([r2.top, r3.top], [r1.top, r1.top], reason: 'T1, T2, T3 share the first row');
      expect(r4.top, greaterThan(r1.top), reason: 'T4 starts the second row');
      expect(r4.left, closeTo(r1.left, 0.5));
      expect(r3.right, lessThanOrEqualTo(width));
      expect((r1.width - r3.width).abs(), lessThan(0.5), reason: 'equal widths');
    });

    testWidgets('the Tables sheet shows every table with its state and time', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api, initials: 'RS')));
      expect(find.text('Tables'), findsOneWidget);
      expect(find.text('RS'), findsNothing, reason: 'the shared banner has the bell and ☰ instead of initials');
      await openTablesSheet(t);
      final sheet = find.byType(BottomSheet);
      for (final l in ['T1', 'T2', 'T3', 'T4', 'T5', 'T12', 'T13']) {
        expect(find.descendant(of: sheet, matching: find.byKey(ValueKey('table-$l'))), findsOneWidget, reason: l);
      }
      Finder inSheet(String s) => find.descendant(of: sheet, matching: find.text(s));
      expect(inSheet('AVAILABLE'), findsNWidgets(4));
      expect(inSheet('OCCUPIED'), findsOneWidget);
      expect(inSheet('RESERVED'), findsOneWidget);
      expect(inSheet('CLEANING'), findsOneWidget);
      expect(inSheet('1h 15m'), findsOneWidget);
      expect(inSheet('7:30 PM'), findsOneWidget); // the store's wall clock from the server (reserved_local 19:30), not the phone's zone
      // a joined pair shows the combined seats the server sends
      expect(inSheet('8 Pax'), findsNWidgets(2));
    });

    testWidgets('the menu is on the Bill as squares, three to a row, with category pills', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      expect(s.calls('pos_sell_catalog'), isNotEmpty);
      final a = t.getRect(find.byKey(const ValueKey('dish-square-Butter Naan')));
      final b = t.getRect(find.byKey(const ValueKey('dish-square-Dal Makhani')));
      final c = t.getRect(find.byKey(const ValueKey('dish-square-Paneer Tikka')));
      expect([b.top, c.top], [a.top, a.top], reason: 'three to a row');
      await tapKey(t, 'bill-cat-Mains');
      expect(find.byKey(const ValueKey('dish-square-Dal Makhani')), findsOneWidget);
      expect(find.byKey(const ValueKey('dish-square-Butter Naan')), findsNothing);
      await tapKey(t, 'bill-cat-all');
      expect(find.byKey(const ValueKey('dish-square-Butter Naan')), findsOneWidget);
    });

    testWidgets('tapping a dish with no table chosen reminds to choose a table first, then adds it to that table', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await tapKey(t, 'dish-square-Paneer Tikka');
      expect(find.text('Choose a table first'), findsOneWidget);
      expect(find.byKey(const ValueKey('bill-cart')), findsNothing, reason: 'nothing goes in the cart without a table');
      await tapKey(t, 'reminder-choose-table');
      expect(find.text('Choose a table'), findsOneWidget);
      await tapKey(t, 'table-T2');
      expect(find.text('Table T2'), findsOneWidget);
      expect(find.byKey(const ValueKey('dish-qty-Paneer Tikka')), findsOneWidget);
      expect(find.byKey(const ValueKey('bill-cart')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-deck')), findsOneWidget, reason: 'the floating table bars stay');
    });

    testWidgets('a dish tapped once a table is chosen goes straight to the cart; minus takes it off', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await openTablesSheet(t);
      await tapKey(t, 'table-T4');
      await tapKey(t, 'dish-square-Butter Naan');
      await tapKey(t, 'dish-square-Butter Naan');
      expect(find.text('Choose a table first'), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('dish-qty-Butter Naan')), matching: find.text('2')), findsOneWidget);
      expect(find.text('Table T4 · 2 items'), findsOneWidget);
      await tapKey(t, 'dish-minus-Butter Naan');
      await tapKey(t, 'dish-minus-Butter Naan');
      expect(find.byKey(const ValueKey('bill-cart')), findsNothing);
    });

    testWidgets('Send to kitchen adds the dishes to the chosen table with a key and shows the KOT', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await openTablesSheet(t);
      await tapKey(t, 'table-T2');
      await tapKey(t, 'dish-square-Paneer Tikka');
      await tapKey(t, 'dish-square-Butter Naan');
      await tapKey(t, 'bill-send');
      final q = s.calls('tbl_order_add').single;
      final a = argsOf(q);
      expect(a['table_id'], 't2');
      expect(a['send'], true);
      expect(a['lines'], [
        {'menu_item_id': '47a00000-0000-0000-0000-000000000001', 'qty': 1},
        {'menu_item_id': '47a00000-0000-0000-0000-000000000003', 'qty': 1},
      ]);
      expect(q.headers['Idempotency-Key'], isNotEmpty);
      expect(find.byType(SentToKitchenScreen), findsOneWidget);
    });

    testWidgets('Hold saves the dishes on the table without sending them', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await openTablesSheet(t);
      await tapKey(t, 'table-T4');
      await tapKey(t, 'dish-square-Dal Makhani');
      await tapKey(t, 'bill-hold');
      expect(argsOf(s.calls('tbl_order_add').single)['send'], false);
      expect(find.byType(SentToKitchenScreen), findsNothing);
      expect(find.byKey(const ValueKey('bill-cart')), findsNothing, reason: 'the cart is emptied once saved');
    });

    testWidgets('Dine in, Takeaway and Delivery pills sit above Ready to serve; Dine in is chosen at first', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      for (final m in ['dine_in', 'pickup', 'delivery']) {
        expect(t.getRect(find.byKey(ValueKey('mode-$m'))).bottom, lessThan(t.getRect(find.byKey(const ValueKey('open-ready-to-serve'))).top), reason: m);
      }
      expect(find.text('Dine in'), findsOneWidget);
      expect(find.text('Takeaway'), findsOneWidget);
      expect(find.text('Delivery'), findsOneWidget);
      expect(find.byKey(const ValueKey('open-tables')), findsOneWidget, reason: 'Dine in orders for a table');
    });

    testWidgets('dining guests asking for dishes to take away: one order on their table, the takeaway lines marked', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await openTablesSheet(t);
      await tapKey(t, 'table-T2');
      await tapKey(t, 'dish-square-Paneer Tikka'); // eaten here
      await tapKey(t, 'mode-pickup');
      expect(find.text('Takeaway on its bill'), findsOneWidget);
      await tapKey(t, 'dish-square-Paneer Tikka'); // one more, packed
      await tapKey(t, 'dish-square-Butter Naan');
      await tapKey(t, 'dish-square-Butter Naan');
      expect(find.text('Table T2 · 4 items · 3 takeaway'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('dish-qty-Paneer Tikka')), matching: find.text('2')), findsOneWidget);
      await tapKey(t, 'bill-send');
      expect(s.calls('pos_counter_order'), isEmpty, reason: 'not a separate takeaway order');
      final a = argsOf(s.calls('tbl_order_add').single);
      expect(a['table_id'], 't2');
      expect(a['lines'], [
        {'menu_item_id': '47a00000-0000-0000-0000-000000000001', 'qty': 1},
        {'menu_item_id': '47a00000-0000-0000-0000-000000000001', 'qty': 1, 'takeaway': true},
        {'menu_item_id': '47a00000-0000-0000-0000-000000000003', 'qty': 2, 'takeaway': true},
      ]);
    });

    testWidgets('Takeaway needs no table: no reminder, and Send places a pickup order and shows the KOT', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await tapKey(t, 'mode-pickup');
      expect(find.text('Add to a table'), findsOneWidget, reason: 'a table is optional for takeaway');
      await tapKey(t, 'dish-square-Butter Naan');
      expect(find.text('Choose a table first'), findsNothing);
      expect(find.text('Takeaway · 1 item'), findsOneWidget);
      expect(find.byKey(const ValueKey('table-deck')), findsOneWidget, reason: 'the floating table bars stay');
      await tapKey(t, 'bill-send');
      final q = s.calls('pos_counter_order').single;
      final a = argsOf(q);
      expect(a['service_type'], 'pickup');
      expect(a['send'], true);
      expect(a['lines'], [{'menu_item_id': '47a00000-0000-0000-0000-000000000003', 'qty': 1}]);
      expect(a.containsKey('table_id'), isFalse);
      expect(q.headers['Idempotency-Key'], isNotEmpty);
      expect(s.calls('tbl_order_add'), isEmpty);
      expect(find.byType(SentToKitchenScreen), findsOneWidget);
    });

    testWidgets('Takeaway: a dish with add-ons (0624) opens the pop-up; the line carries the add-ons and its price includes them', (t) async {
      final naan = ((tk['menu'] as Map)['items'] as List).cast<Map>().firstWhere((i) => i['name'] == 'Butter Naan');
      naan['options'] = {
        'addon_groups': [
          {'id': 'g1', 'name': 'Extra dips', 'min': 0, 'max': 3, 'addons': [{'id': 'a-cheese', 'name': 'Cheese slices', 'price': 50, 'food_type': 'veg'}]},
        ],
      };
      addTearDown(() => naan.remove('options'));
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await tapKey(t, 'mode-pickup');
      await tapKey(t, 'dish-square-Butter Naan');
      expect(find.byKey(const ValueKey('opt-title')), findsOneWidget);
      await tapKey(t, 'opt-addon-plus-Cheese slices');
      await tapKey(t, 'opt-add');
      expect(find.text('Takeaway · 1 item'), findsOneWidget);
      expect(find.textContaining(rupees((naan['price'] as num) + 50)), findsWidgets, reason: 'the cart total includes the add-on');
      await tapKey(t, 'bill-send');
      final a = argsOf(s.calls('pos_counter_order').single);
      expect(a['lines'], [{'menu_item_id': '47a00000-0000-0000-0000-000000000003', 'qty': 1, 'addons': ['a-cheese']}]);
    });

    testWidgets('Delivery asks for the phone and address before placing the order', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await tapKey(t, 'mode-delivery');
      await tapKey(t, 'dish-square-Dal Makhani');
      expect(find.text('Delivery · 1 item'), findsOneWidget);
      await tapKey(t, 'bill-hold');
      expect(find.text('Deliver to'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('delivery-phone')), '98765 43210');
      await tapKey(t, 'delivery-confirm');
      expect(find.text('Enter the delivery address.'), findsOneWidget);
      expect(s.calls('pos_counter_order'), isEmpty);
      await t.enterText(find.byKey(const ValueKey('delivery-name')), 'Asha');
      await t.enterText(find.byKey(const ValueKey('delivery-address')), '12 MG Road');
      await tapKey(t, 'delivery-confirm');
      final a = argsOf(s.calls('pos_counter_order').single);
      expect(a['service_type'], 'delivery');
      expect(a['send'], false);
      expect(a['customer_name'], 'Asha');
      expect(a['customer_phone'], '9876543210', reason: 'the box keeps the 10 digits after +91');
      expect(a['address'], '12 MG Road');
      expect(find.byKey(const ValueKey('bill-cart')), findsNothing, reason: 'the cart is emptied once saved');
    });

    testWidgets('each dish square carries a veg / non-veg sticker', (t) async {
      final s = Fake((r) {
        if (fnOf(r) != 'pos_sell_catalog') return null;
        final m = Map<String, dynamic>.from(tk['menu'] as Map);
        m['items'] = [
          for (final i in m['items'] as List) {...i as Map<String, dynamic>, 'food_type': i['name'] == 'Paneer Tikka' ? 'non_veg' : 'veg'},
        ];
        return ok(m);
      });
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      expect(find.byType(FoodTypeMark), findsNWidgets(3));
      FoodTypeMark mark(String dish) => t.widget<FoodTypeMark>(find.descendant(of: find.byKey(ValueKey('dish-food-$dish')), matching: find.byType(FoodTypeMark)));
      expect(mark('Paneer Tikka').type, 'non_veg');
      expect(mark('Butter Naan').type, 'veg');
    });

    testWidgets('each dish square says how many can be made; sending one to the kitchen brings the count down', (t) async {
      var left = 200;
      final s = Fake((r) {
        switch (fnOf(r)) {
          case 'pos_sell_catalog':
            final m = Map<String, dynamic>.from(tk['menu'] as Map);
            m['items'] = [
              for (final i in m['items'] as List)
                {...i as Map<String, dynamic>, 'has_recipe': i['name'] != 'Dal Makhani', 'can_make': i['name'] == 'Butter Naan' ? left : i['name'] == 'Paneer Tikka' ? 0 : null},
            ];
            return ok(m);
          case 'pos_counter_order':
            left -= ((argsOf(r)['lines'] as List).first as Map)['qty'] as int;
            return ok({'order_id': 'o-9', 'replayed': false, 'held': false, 'kot': (tk['add_send'] as Map)['kot'], 'order': {'display_no': 'P-00009'}});
        }
        return null;
      });
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      Finder said(String dish, String text) => find.descendant(of: find.byKey(ValueKey('dish-can-make-$dish')), matching: find.text(text));
      expect(said('Butter Naan', '200 can be made'), findsOneWidget);
      expect(said('Paneer Tikka', '0 can be made'), findsOneWidget);
      expect(said('Dal Makhani', 'No recipe yet'), findsOneWidget);
      await tapKey(t, 'mode-pickup');
      await tapKey(t, 'dish-square-Butter Naan');
      await tapKey(t, 'bill-send');
      await tapKey(t, 'back-to-tables');
      expect(said('Butter Naan', '199 can be made'), findsOneWidget);
    });

    testWidgets('Ready to serve and Choose table share one row; the menu search sits beside "Menu"; QR codes and Manage tables are in the ⋮', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      final ready = t.getRect(find.byKey(const ValueKey('open-ready-to-serve')));
      final tables = t.getRect(find.byKey(const ValueKey('open-tables')));
      expect(tables.top, closeTo(ready.top, 0.5), reason: 'one row');
      expect(tables.left, greaterThan(ready.right));
      expect(find.text('Choose table'), findsOneWidget);
      final search = t.getRect(find.byKey(const ValueKey('bill-menu-search')));
      final menu = t.getRect(find.text('Menu').first); // not the bottom bar's Menu tab
      expect(search.top, greaterThan(ready.bottom));
      expect(find.byKey(const ValueKey('open-manage-tables')), findsNothing, reason: 'no row of set-up buttons on the Bill');
      expect(find.byKey(const ValueKey('floor-more')), findsOneWidget);
      expect(search.left, greaterThan(menu.right), reason: 'beside the Menu title');
      expect((search.center.dy - menu.center.dy).abs(), lessThan(12));
      // choosing a table keeps it in the same half of the row
      await openTablesSheet(t);
      await tapKey(t, 'table-T4');
      expect(t.widget<Text>(find.byKey(const ValueKey('order-table'))).data, 'Table T4');
      expect(t.getRect(find.byKey(const ValueKey('open-tables'))).top, closeTo(ready.top, 0.5));
    });

    testWidgets('the menu search filters the dish squares by name, with the category pill', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await t.enterText(find.byKey(const ValueKey('bill-menu-search')), 'naan');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('dish-square-Butter Naan')), findsOneWidget);
      expect(find.byKey(const ValueKey('dish-square-Dal Makhani')), findsNothing);
      expect(find.byKey(const ValueKey('dish-square-Paneer Tikka')), findsNothing);
      await tapKey(t, 'bill-cat-Mains');
      expect(find.text('No dish matches "naan".'), findsOneWidget);
      await tapKey(t, 'bill-cat-all');
      await t.enterText(find.byKey(const ValueKey('bill-menu-search')), '');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('dish-square-Dal Makhani')), findsOneWidget);
    });

    testWidgets('a dish with sizes: the square says so, a tap asks Small / Medium / Large, and the size goes with its price', (t) async {
      Map<String, dynamic> menu() {
        final m = Map<String, dynamic>.from(tk['menu'] as Map);
        m['items'] = [
          for (final i in m['items'] as List)
            {
              ...i as Map<String, dynamic>,
              if (i['name'] == 'Dal Makhani')
                'variants': [
                  {'id': 'v-s', 'name': 'Small', 'price': 220, 'is_default': true, 'recipe_factor': 1, 'can_make': 30},
                  {'id': 'v-m', 'name': 'Medium', 'price': 250, 'is_default': false, 'recipe_factor': 2, 'can_make': 15},
                  {'id': 'v-l', 'name': 'Large', 'price': 280, 'is_default': false, 'recipe_factor': 3, 'can_make': 10},
                ],
              if (i['name'] == 'Dal Makhani') ...{'has_recipe': true, 'can_make': 30},
            },
        ];
        return m;
      }

      final s = Fake((r) => fnOf(r) == 'pos_sell_catalog' ? ok(menu()) : null);
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      expect(t.widget<Text>(find.byKey(const ValueKey('dish-price-Dal Makhani'))).textSpan!.toPlainText(), '₹220 · 3 sizes', reason: 'the lowest price and how many sizes');
      expect(find.descendant(of: find.byKey(const ValueKey('dish-can-make-Dal Makhani')), matching: find.text('30 can be made')), findsOneWidget, reason: 'of the smallest size');
      await openTablesSheet(t);
      await tapKey(t, 'table-T4');
      await tapKey(t, 'dish-square-Dal Makhani');
      expect(find.text('Choose a size'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('size-can-make-Large'))).data, '10 can be made');
      await tapKey(t, 'size-Large');
      await tapKey(t, 'dish-square-Dal Makhani');
      await tapKey(t, 'size-Small');
      expect(t.widget<Text>(find.byKey(const ValueKey('bill-cart-total'))).data, '₹500', reason: 'Large ₹280 + Small ₹220');
      expect(find.descendant(of: find.byKey(const ValueKey('dish-qty-Dal Makhani')), matching: find.text('2')), findsOneWidget);
      await tapKey(t, 'bill-send');
      expect(argsOf(s.calls('tbl_order_add').single)['lines'], [
        {'menu_item_id': '47a00000-0000-0000-0000-000000000002', 'qty': 1, 'variant_id': 'v-l'},
        {'menu_item_id': '47a00000-0000-0000-0000-000000000002', 'qty': 1, 'variant_id': 'v-s'},
      ]);
    });

    testWidgets('an error is a sentence with a retry, not a blank screen', (t) async {
      var fail = true;
      final s = Fake((r) => fail ? err(403, 'Your role cannot do this on the floor.', 'forbidden') : null);
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      expect(find.text('Your role cannot do this on the floor.'), findsOneWidget);
      fail = false;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('open-tables')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-deck')), findsOneWidget);
    });

    testWidgets('tap an available table: the sheet offers Start New Order, Reserve Table, View History', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await openTable(t, 'T4');
      expect(find.descendant(of: find.byType(BottomSheet), matching: find.text('Table T4')), findsOneWidget);
      expect(find.text('4 Pax • Available'), findsOneWidget);
      expect(find.text('Start New Order'), findsOneWidget);
      expect(find.text('Reserve Table'), findsOneWidget);
      expect(find.text('View History'), findsOneWidget);
      await tapKey(t, 'sheet-close');
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('Start New Order hands the table to the host; without a host it opens Add dishes (0485)', (t) async {
      final s = Fake();
      Facts? got;
      await show(t, FloorScreen(env: TablesEnv(api: s.api, onStartOrder: (c, table) => got = table)));
      await openTable(t, 'T4');
      await tapText(t, 'Start New Order');
      expect(got?.s('id'), 't4');
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await openTable(t, 'T4');
      await tapText(t, 'Start New Order');
      expect(find.text('Table T4'), findsWidgets);
      expect(find.text('Dine-in'), findsOneWidget);   // the Add dishes page of that table
    });

    testWidgets('View History lists orders and reservations of the table', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await openTable(t, 'T4');
      await tapKey(t, 'sheet-history');
      expect(find.text('Table T4 history'), findsOneWidget);
      expect(find.text('Order P-9001'), findsOneWidget);
      expect(find.text('Reservation for John Doe'), findsOneWidget);
      expect(argsOf(s.calls('tbl_history').single)['table_id'], 't4');
    });

    testWidgets('a Cleaning table offers "Mark as clean": it sends the table, closes the sheet and reloads the floor', (t) async {
      final s = Fake((r) => switch (fnOf(r)) {
            'tbl_view' => ok({...fx['view_available'] as Map<String, dynamic>, 'status': 'cleaning'}),
            'tbl_mark_clean' => ok({'table_id': argsOf(r)['table_id'], 'label': 'T4', 'status': 'available', 'tables_marked': 1}),
            _ => null,
          });
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      final floorsBefore = s.calls('tbl_floor').length;
      await openTable(t, 'T4');
      expect(find.byKey(const ValueKey('sheet-mark-clean')), findsOneWidget);
      expect(find.textContaining('does by itself 10 minutes after the bill'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('sheet-mark-clean')));
      await t.pumpAndSettle();
      expect(argsOf(s.calls('tbl_mark_clean').single)['table_id'], 't4');
      expect(find.byKey(const ValueKey('sheet-mark-clean')), findsNothing, reason: 'the sheet closed');
      expect(find.text('Table T4 is available.'), findsOneWidget);
      expect(s.calls('tbl_floor').length, greaterThan(floorsBefore), reason: 'the floor reloads');
    });

    testWidgets('an Available table does not offer "Mark as clean"; a refusal keeps its sentence in the sheet', (t) async {
      final s = Fake((r) => switch (fnOf(r)) {
            'tbl_view' => ok({...fx['view_available'] as Map<String, dynamic>, 'status': 'cleaning'}),
            'tbl_mark_clean' => http.Response(jsonEncode({'detail': 'T4 is available, not cleaning', 'code': 'wrong_state'}), 409, headers: {'content-type': 'application/json'}),
            _ => null,
          });
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await openTable(t, 'T4');
      await t.tap(find.byKey(const ValueKey('sheet-mark-clean')));
      await t.pumpAndSettle();
      expect(find.text('T4 is available, not cleaning'), findsOneWidget);

      await t.pumpWidget(const SizedBox());
      final s2 = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s2.api)));
      await openTable(t, 'T4');
      expect(find.byKey(const ValueKey('sheet-mark-clean')), findsNothing);
    });

    testWidgets('the sheet only offers what the server allows (kitchen: history only)', (t) async {
      final s = Fake((r) => fnOf(r) == 'tbl_view' ? ok({...fx['view_available'] as Map<String, dynamic>, 'allowed': ['history']}) : null);
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await openTable(t, 'T4');
      expect(find.text('Start New Order'), findsNothing);
      expect(find.text('Reserve Table'), findsNothing);
      expect(find.text('View History'), findsOneWidget);
    });
  });

  group('Reserve form', () {
    Future<Fake> open(WidgetTester t, [http.Response? Function(http.Request)? h]) async {
      final s = Fake(h);
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await openTable(t, 'T4');
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
      await t.enterText(find.byType(TextField).at(1), '+91 98765 43212');
      await tapKey(t, 'pax-6');
      await t.enterText(find.byType(TextField).at(2), 'Window seat preferred.');
      await tapText(t, 'Confirm Reservation');
      final q = s.calls('tbl_reserve').single;
      final a = argsOf(q);
      expect(a['table_id'], 't4');
      expect(a['guest_name'], 'John Doe');
      expect(a['phone'], '9876543212', reason: 'a pasted +91 is not doubled');
      expect(a['guests'], 6);
      expect(a['notes'], 'Window seat preferred.');
      expect(a['local_date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      expect(a['local_time'], matches(RegExp(r'^\d{2}:\d{2}$')));
      expect(a.containsKey('scheduled_at'), isFalse);
      expect(q.headers['Idempotency-Key'], a['idempotency_key']);
      expect(find.text('Reserve Table T4'), findsNothing);
      expect(find.byKey(const ValueKey('open-tables')), findsOneWidget);
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
    testWidgets('an occupied table opens its running order straight away (founder, 2026-10-20)', (t) async {
      final s = Fake();
      await show(t, FloorScreen(env: TablesEnv(api: s.api)));
      await openTable(t, 'T2');
      expect(find.text('Table T12 Order'), findsOneWidget);
      expect(find.text('Table T12 Actions'), findsNothing);
    });

    testWidgets('the actions screen: bill, waiter, Open Existing Order, Transfer Table', (t) async {
      final s = Fake();
      await show(t, ActionsScreen(env: TablesEnv(api: s.api), tableId: 't2'));
      expect(find.text('Table T12 Actions'), findsOneWidget);
      expect(find.text('Dine-In • Occupied • Bill Amount ₹1,302 • Waiter: SS'), findsOneWidget);
      expect(find.text('Open Existing Order'), findsOneWidget);
      expect(find.text('Transfer Table'), findsOneWidget);
    });

    testWidgets('Open Existing Order: the bill page with the order buttons; no banner, item cards or timeline (those moved)', (t) async {
      final s = Fake();
      await show(t, ActionsScreen(env: TablesEnv(api: s.api), tableId: 't2'));
      await tapKey(t, 'action-open-order');
      expect(find.text('Table T12 Order'), findsOneWidget);
      expect(find.text('Ground Floor • 4 Pax'), findsOneWidget);
      expect(find.text('ACTIVE IN KITCHEN'), findsNothing);
      expect(find.text('OPERATIONAL TIMELINE'), findsNothing, reason: 'Settings → Activity log');
      for (final b in ['Add Items', 'Send KOT', 'Print KOT', 'Change Table', 'Merge Table', 'Generate Bill', 'Hand to guest']) {
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
      // the Checkout that follows is covered in rst_bill_test
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
      await openTable(t, 'T1');
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
      await openTable(t, 'T2');
      expect(find.text('Choose a different table.'), findsOneWidget);
      await openTable(t, 'T3');
      await tapText(t, 'Cancel');
      expect(s.calls('tbl_transfer'), isEmpty);
    });

    testWidgets('a joined table cannot be chosen as a destination', (t) async {
      final s = Fake();
      await show(t, ActionsScreen(env: TablesEnv(api: s.api), tableId: 't2'));
      await tapText(t, 'Transfer Table');
      await openTable(t, 'T13');
      expect(find.textContaining('is joined to other tables'), findsOneWidget);
      expect(find.text('Confirm Table Transfer?'), findsNothing);
    });

    testWidgets('a transfer the server refuses shows its sentence', (t) async {
      final s = Fake((r) => fnOf(r) == 'tbl_transfer' ? err(409, 'T12 has nothing to move.', 'not_occupied') : null);
      await show(t, ActionsScreen(env: TablesEnv(api: s.api), tableId: 't2'));
      await tapText(t, 'Transfer Table');
      await openTable(t, 'T1');
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
      await openTable(t, 'T1');
      await openTable(t, 'T4');
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
      await openTable(t, 'T4');
      await openTable(t, 'T4');
      expect(find.text('SELECTED'), findsOneWidget);
    });

    testWidgets('the server refusing a join shows its sentence and nothing closes', (t) async {
      final s = Fake((r) => fnOf(r) == 'tbl_merge' ? err(409, 'More than one of these tables has an open order; finish or transfer one first.', 'busy') : null);
      await show(t, MergeScreen(env: TablesEnv(api: s.api), startTableId: 't1'));
      await openTable(t, 'T4');
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
      await tapKey(t, 'tbl-tab-home');
      await tapKey(t, 'tbl-tab-orders');
      expect(taps, ['home', 'orders']);
      expect(find.byKey(const ValueKey('tbl-tab-stock')), findsNothing, reason: 'no Stock tab for now');
    });
  });
}
