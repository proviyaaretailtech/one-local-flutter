import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/kitchen/add_station_screen.dart';
import 'package:vinii_pos/kitchen/kds_screen.dart';
import 'package:vinii_pos/kitchen/kitchen_api.dart';
import 'package:vinii_pos/kitchen/kitchen_setup_screen.dart';
import 'package:vinii_pos/kitchen/kitchen_widgets.dart';
import 'package:vinii_pos/kitchen/station_detail_screen.dart';
import 'package:vinii_pos/inventory/inventory_api.dart' show Facts;
import 'package:vinii_pos/ui/theme.dart';

/// Answers captured from the real local database (database/tests/480_kitchen.sql story): the screens are built against what the server sends.
final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/kitchen_server.json').readAsStringSync()) as Map<String, dynamic>;

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) =>
    http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;
Map<String, dynamic> argsOf(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;
Map<String, dynamic> copy(Object o) => jsonDecode(jsonEncode(o)) as Map<String, dynamic>;

/// The signed-in person can configure (the fixture was captured as a kitchen cook, who cannot).
Map<String, dynamic> owner(Map<String, dynamic> cfg) => copy(cfg)..['can'] = {'configure': true};

class Fake {
  Fake([this.handler]);
  final http.Response? Function(http.Request r)? handler;
  final calls = <http.Request>[];
  List<http.Request> of(String fn) => calls.where((r) => fnOf(r) == fn).toList();
  http.Response answer(http.Request r) {
    calls.add(r);
    final h = handler?.call(r);
    if (h != null) return h;
    return switch (fnOf(r)) {
      'kitchen_config' => ok(owner(fx['config'] as Map<String, dynamic>)),
      'kitchen_station_view' => ok(fx['station']),
      'kds_queue' => ok(fx['queue']),
      'kds_ticket_act' => ok(fx['ticket']),
      'kitchen_station_save' => ok((fx['station'] as Map<String, dynamic>)),
      _ => err(404, 'Not found'),
    };
  }

  KitchenApi get api => KitchenApi(baseUrl: 'http://kitchen.test', accessToken: () => 'tok', client: MockClient((r) async => answer(r)));
  KitchenEnv env({ValueChanged<String>? onNavigate}) => KitchenEnv(api: api, onNavigate: onNavigate, refreshEvery: null);
}

Future<void> show(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(810, 3600);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: w));
  await t.pumpAndSettle();
}

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });

  group('KitchenApi', () {
    test('config and queue are plain POSTs to /rpc with the bearer and no nulls', () async {
      final f = Fake();
      final cfg = await f.api.config();
      expect(cfg.l('stations').length, 5);
      final q = await f.api.queue(station: 'tandoor', status: 'new', q: ' naan ');
      expect(q.n('live'), 4);
      final r = f.of('kds_queue').single;
      expect(r.method, 'POST');
      expect(r.url.toString(), 'http://kitchen.test/rpc/kds_queue');
      expect(r.headers['Authorization'], 'Bearer tok');
      expect(argsOf(r), {'station': 'tandoor', 'status': 'new', 'q': 'naan'});
      await f.api.queue();
      expect(argsOf(f.of('kds_queue').last), {'status': 'all'});
    });

    test('saveStation sends an Idempotency-Key (the given one on a retry); act sends the version the person saw', () async {
      final f = Fake();
      await f.api.saveStation(name: 'Grill', printerId: 'p1', key: 'k-1');
      await f.api.saveStation(name: 'Grill', printerId: 'p1', key: 'k-1');
      final s = f.of('kitchen_station_save');
      expect(s.map((r) => r.headers['Idempotency-Key']).toSet(), {'k-1'});
      expect(argsOf(s.first), {'name': 'Grill', 'printer_id': 'p1'});
      await f.api.saveStation(name: 'Other');
      expect(f.of('kitchen_station_save').last.headers['Idempotency-Key'], startsWith('kit-'));
      await f.api.act('t1', 'item_done', station: 'tandoor', itemId: 'i1', version: 'abc');
      final a = f.of('kds_ticket_act').single;
      expect(argsOf(a), {'ticket_id': 't1', 'action': 'item_done', 'station': 'tandoor', 'item_id': 'i1', 'expected_version': 'abc'});
      expect(a.headers['Idempotency-Key'], startsWith('kit-'));
    });

    test('a stale screen is a version_conflict the app can tell apart', () async {
      final f = Fake((r) => fnOf(r) == 'kds_ticket_act' ? err(409, 'This ticket was changed on another screen.', 'version_conflict') : null);
      await expectLater(f.api.act('t1', 'start'), throwsA(isA<KitchenApiException>().having((e) => e.stale, 'stale', true).having((e) => e.message, 'message', contains('another screen'))));
    });
  });

  group('Kitchen Setup (Figma Kitchen Configuration)', () {
    testWidgets('lists stations, printer groups and the empty preparation areas', (t) async {
      final f = Fake();
      await show(t, KitchenSetupScreen(env: f.env()));
      expect(find.text('Kitchen Setup'), findsOneWidget);
      expect(find.text('Stations, printers & prep areas'), findsOneWidget);
      for (final n in ['Main Kitchen', 'Tandoor', 'Beverages', 'Sweet shop', 'Cold Desserts']) {
        expect(find.text(n), findsOneWidget);
      }
      expect(find.text('Kitchen station'), findsNWidgets(5));
      expect(find.text('Hot kitchen'), findsOneWidget);
      expect(find.text('Printer group'), findsOneWidget);
      expect(find.text('No preparation areas yet'), findsOneWidget);
      expect(find.text('Create an area to organize kitchen prep.'), findsOneWidget);
      expect(find.text('Add station'), findsOneWidget);
    });

    testWidgets('kitchen setup is optional: it says so and "Skip for now" leaves (founder, 2026-10-20)', (t) async {
      t.view.physicalSize = const Size(780, 4000);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(theme: posTheme(), home: Builder(builder: (c) => TextButton(
          onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => KitchenSetupScreen(env: Fake().env()))), child: const Text('open')))));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('kitchen-optional')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('kitchen-skip')));
      await t.pumpAndSettle();
      expect(find.text('Kitchen Setup'), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('warns about a menu station that has no station row (its orders show as Unassigned)', (t) async {
      await show(t, KitchenSetupScreen(env: Fake().env()));
      expect(find.byKey(const ValueKey('unassigned-warning')), findsOneWidget);
      expect(find.textContaining('grill_unmade (1 item)'), findsOneWidget);
    });

    testWidgets('no warning when every menu station has a station', (t) async {
      final cfg = owner(fx['config'] as Map<String, dynamic>)..['unassigned'] = [];
      await show(t, KitchenSetupScreen(env: Fake((r) => fnOf(r) == 'kitchen_config' ? ok(cfg) : null).env()));
      expect(find.byKey(const ValueKey('unassigned-warning')), findsNothing);
    });

    testWidgets('a person who cannot configure sees no add buttons; the server said so', (t) async {
      final f = Fake((r) => fnOf(r) == 'kitchen_config' ? ok(copy(fx['config'] as Map<String, dynamic>)..['can'] = {'configure': false}) : null);
      await show(t, KitchenSetupScreen(env: f.env()));
      expect(find.text('Add station'), findsNothing);
      expect(find.text('Add printer'), findsNothing);
      expect(find.text('Main Kitchen'), findsOneWidget);
    });

    testWidgets('Add printer and Add area say they are not in this release (no frame for their forms)', (t) async {
      await show(t, KitchenSetupScreen(env: Fake().env()));
      await t.tap(find.text('Add printer'));
      await t.pump();
      expect(find.text('Adding a printer opens in a later release.'), findsOneWidget);
    });

    testWidgets('a failed load shows the reason and Try again reloads', (t) async {
      var fail = true;
      final f = Fake((r) => fnOf(r) == 'kitchen_config' && fail ? err(403, 'Your role cannot see the kitchen setup.') : null);
      await show(t, KitchenSetupScreen(env: f.env()));
      expect(find.textContaining('cannot see the kitchen setup'), findsOneWidget);
      fail = false;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(find.text('Main Kitchen'), findsOneWidget);
    });

    testWidgets('tapping a station opens its detail, which asks the server for that station', (t) async {
      final f = Fake();
      await show(t, KitchenSetupScreen(env: f.env()));
      await t.tap(find.byKey(const ValueKey('station-tandoor')));
      await t.pumpAndSettle();
      expect(argsOf(f.of('kitchen_station_view').single)['id'], isNotEmpty);
      expect(find.text('Station routing'), findsOneWidget);
    });

    testWidgets('the bottom bar: POS is the section; other tabs go out through onNavigate', (t) async {
      final seen = <String>[];
      await show(t, KitchenSetupScreen(env: Fake().env(onNavigate: seen.add)));
      await t.tap(find.byKey(const ValueKey('kit-tab-orders')));
      await t.tap(find.byKey(const ValueKey('kit-tab-stock')));
      expect(seen, ['orders', 'stock']);
    });
  });

  group('Add Station (Figma Add Kitchen Station)', () {
    Facts cfg() => Facts(owner(fx['config'] as Map<String, dynamic>));

    testWidgets('shows the four fields, the first printer group chosen, and the hint while there are no areas', (t) async {
      await show(t, AddStationScreen(env: Fake().env(), config: cfg()));
      expect(find.text('Station details'), findsOneWidget);
      expect(find.text('Station name *'), findsOneWidget);
      expect(find.text('Enter station name'), findsOneWidget);
      expect(find.textContaining('No areas configured'), findsOneWidget);
      expect(find.textContaining('Select a KDS group'), findsOneWidget);
      expect(find.textContaining('Hot kitchen'), findsOneWidget);
      expect(find.text('You can assign a preparation area after one is created.'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('Create station with an empty name asks for one and sends nothing', (t) async {
      final f = Fake();
      await show(t, AddStationScreen(env: f.env(), config: cfg()));
      await t.tap(find.byKey(const ValueKey('create-station')));
      await t.pump();
      expect(find.text('Enter a station name.'), findsOneWidget);
      expect(f.calls, isEmpty);
    });

    testWidgets('Create station sends the name and the chosen printer; a lost answer then a retry reuses the same key', (t) async {
      var first = true;
      final f = Fake((r) {
        if (fnOf(r) != 'kitchen_station_save') return null;
        if (first) {
          first = false;
          return err(503, 'The database is not connected yet.');
        }
        return null;
      });
      final nav = GlobalKey<NavigatorState>();
      t.view.physicalSize = const Size(810, 3600);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(navigatorKey: nav, theme: posTheme(), home: const Scaffold(body: SizedBox())));
      Future<bool?> open() => nav.currentState!.push<bool>(MaterialPageRoute(builder: (_) => AddStationScreen(env: f.env(), config: cfg())));
      final result = open();
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '  Grill ');
      await t.tap(find.byKey(const ValueKey('create-station')));
      await t.pumpAndSettle();
      expect(find.text('The database is not connected yet.'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('create-station')));
      await t.pumpAndSettle();
      expect(await result, true);
      final saves = f.of('kitchen_station_save');
      expect(saves.length, 2);
      expect(argsOf(saves.first), {'name': 'Grill', 'printer_id': (fx['config'] as Map)['printers'][0]['id']});
      expect(saves.map((r) => r.headers['Idempotency-Key']).toSet().length, 1);
    });

    testWidgets('a refusal from the server (duplicate name) stays on the form with the server sentence', (t) async {
      final f = Fake((r) => fnOf(r) == 'kitchen_station_save' ? err(409, 'A station with this name already exists.', 'duplicate') : null);
      await show(t, AddStationScreen(env: f.env(), config: cfg()));
      await t.enterText(find.byType(TextField), 'Tandoor');
      await t.tap(find.byKey(const ValueKey('create-station')));
      await t.pumpAndSettle();
      expect(find.text('A station with this name already exists.'), findsOneWidget);
      expect(find.text('Station details'), findsOneWidget);
    });

    testWidgets('choosing a KDS group sends its id', (t) async {
      final f = Fake();
      await show(t, AddStationScreen(env: f.env(), config: cfg()));
      await t.enterText(find.byType(TextField), 'Cold desserts');
      await t.tap(find.textContaining('Select a KDS group'));
      await t.pumpAndSettle();
      await t.tap(find.text('Tandoor').last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('create-station')));
      await t.pumpAndSettle();
      final stations = (fx['config'] as Map)['stations'] as List;
      final tandoor = stations.firstWhere((s) => s['key'] == 'tandoor');
      expect(argsOf(f.of('kitchen_station_save').single)['kds_group_id'], tandoor['id']);
    });
  });

  group('Station detail (Figma Main Kitchen station detail)', () {
    testWidgets('shows the station, its routing with "Not assigned" for what is empty, and the queue note', (t) async {
      final f = Fake((r) => fnOf(r) == 'kitchen_station_view' ? ok({...(fx['config'] as Map)['stations'][0] as Map, 'can': {'configure': true}}) : null);
      await show(t, StationDetailScreen(env: f.env(), stationId: 'x'));
      expect(find.text('Main Kitchen'), findsNWidgets(3)); // title bar, card, display group
      expect(find.text('Kitchen station · KDS'), findsOneWidget);
      expect(find.text('Station routing'), findsOneWidget);
      expect(find.text('Kitchen display group'), findsOneWidget);
      expect(find.text('Not assigned'), findsNWidgets(2));
      expect(find.text("Orders assigned to Main Kitchen appear in this station's KDS queue."), findsOneWidget);
    });

    testWidgets('a routed station shows its group, printer and area by name', (t) async {
      final st = copy((fx['config'] as Map)['stations'][1])
        ..['kds_group'] = {'id': 'g', 'name': 'Main Kitchen'}
        ..['printer'] = {'id': 'p', 'name': 'Hot kitchen'}
        ..['prep_area'] = {'id': 'a', 'name': 'Grill area'};
      final f = Fake((r) => fnOf(r) == 'kitchen_station_view' ? ok(st) : null);
      await show(t, StationDetailScreen(env: f.env(), stationId: 'x'));
      expect(find.text('Hot kitchen'), findsOneWidget);
      expect(find.text('Grill area'), findsOneWidget);
      expect(find.text('Not assigned'), findsNothing);
    });
  });

  group('Kitchen Display System (Figma Kitchen Display System)', () {
    Map<String, dynamic> queueWith(void Function(Map<String, dynamic> q) edit) {
      final q = copy(fx['queue'] as Map<String, dynamic>);
      edit(q);
      return q;
    }

    testWidgets('draws the live count, the six counters, the chips and the first ticket exactly as the server sent them', (t) async {
      await show(t, KdsScreen(env: Fake().env()));
      expect(find.text('LIVE · 4 ORDERS'), findsOneWidget);
      expect(find.text('Search orders or items...'), findsOneWidget);
      for (final s in ['All', 'Main Kitchen', 'Tandoor', 'Beverages']) {
        expect(find.text(s), findsWidgets);
      }
      for (final l in ['QUEUE / CRITICAL', 'PENDING', 'DINE-IN ORDERS', 'ONLINE DELIVERY', 'DELAYED', 'COMPLETED TODAY']) {
        expect(find.text(l), findsOneWidget);
      }
      expect(find.bySemanticsLabel('QUEUE / CRITICAL 1'), findsOneWidget);
      expect(find.bySemanticsLabel('PENDING 4'), findsOneWidget);
      expect(find.bySemanticsLabel('DINE-IN ORDERS 2'), findsOneWidget);
      expect(find.bySemanticsLabel('ONLINE DELIVERY 1'), findsOneWidget);
      expect(find.bySemanticsLabel('DELAYED 1'), findsOneWidget);
      expect(find.bySemanticsLabel('COMPLETED TODAY 0'), findsOneWidget);
      expect(find.text('All 4'), findsOneWidget);
      expect(find.text('New 4'), findsOneWidget);
      expect(find.text('In progress 0'), findsOneWidget);
      expect(find.text('#P-00001'), findsOneWidget);
      expect(find.text('URGENT · 0m'), findsOneWidget);
      expect(find.text('NEW'), findsWidgets);
      expect(find.text('Dine-in'), findsWidgets);
      expect(find.text('0/2 items done'), findsOneWidget);
      expect(find.text('Paneer Tikka'), findsOneWidget);
      expect(find.text('x2'), findsWidgets);
      expect(find.text('Table T1'), findsWidgets);
      expect(find.text('Pickup'), findsOneWidget);
      expect(find.text('Order note · No custom note'), findsWidgets);
      expect(find.text('Order note · extra spicy'), findsOneWidget);
      expect(find.text('Start'), findsWidgets);
    });

    testWidgets('Start sends start with the ticket and the version seen, then asks the queue again', (t) async {
      final f = Fake();
      await show(t, KdsScreen(env: f.env()));
      final tk = (fx['queue'] as Map)['tickets'][0];
      await t.tap(find.byKey(ValueKey('act-start-${tk['card_id']}')));
      await t.pumpAndSettle();
      final a = argsOf(f.of('kds_ticket_act').single);
      expect(a['ticket_id'], tk['id']);
      expect(a['action'], 'start');
      expect(a['station'], tk['station']);
      expect(a['expected_version'], tk['version']);
      expect(f.of('kds_queue').length, 2);
    });

    testWidgets('an item switch sends item_done for that item; a done item sends item_undo', (t) async {
      final q = queueWith((q) {
        final tk = (q['tickets'] as List)[0] as Map<String, dynamic>;
        tk..['status'] = 'preparing'..['chip'] = 'in_progress'..['done_count'] = 1;
        (tk['items'] as List)[0]..['done'] = true..['status'] = 'ready';
      });
      final f = Fake((r) => fnOf(r) == 'kds_queue' ? ok(q) : null);
      await show(t, KdsScreen(env: f.env()));
      final items = (q['tickets'][0]['items'] as List);
      expect(find.text('1/2 items done'), findsOneWidget);
      expect(find.text('IN PROGRESS'), findsOneWidget);
      expect(find.text('Ready'), findsWidgets); // the action button
      await t.tap(find.byKey(ValueKey('item-${items[1]['id']}')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(ValueKey('item-${items[0]['id']}')));
      await t.pumpAndSettle();
      final acts = f.of('kds_ticket_act').map(argsOf).toList();
      expect(acts[0]['action'], 'item_done');
      expect(acts[0]['item_id'], items[1]['id']);
      expect(acts[1]['action'], 'item_undo');
      expect(acts[1]['item_id'], items[0]['id']);
    });

    testWidgets('Ready on a ticket in progress; Mark served on a ready ticket', (t) async {
      final q = queueWith((q) {
        final ts = q['tickets'] as List;
        (ts[0] as Map<String, dynamic>)..['status'] = 'preparing'..['chip'] = 'in_progress';
        (ts[1] as Map<String, dynamic>)..['status'] = 'ready'..['chip'] = 'ready';
      });
      final f = Fake((r) => fnOf(r) == 'kds_queue' ? ok(q) : null);
      await show(t, KdsScreen(env: f.env()));
      await t.tap(find.byKey(ValueKey('act-ready-${q['tickets'][0]['card_id']}')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(ValueKey('act-serve-${q['tickets'][1]['card_id']}')));
      await t.pumpAndSettle();
      expect(f.of('kds_ticket_act').map((r) => argsOf(r)['action']).toList(), ['ready', 'serve']);
    });

    testWidgets('Print ticket sends print and says so', (t) async {
      final f = Fake();
      await show(t, KdsScreen(env: f.env()));
      final tk = (fx['queue'] as Map)['tickets'][1];
      await t.tap(find.byKey(ValueKey('print-${tk['card_id']}')));
      await t.pump();
      await t.pump();
      expect(argsOf(f.of('kds_ticket_act').single)['action'], 'print');
      expect(find.text('Ticket sent to the printer.'), findsOneWidget);
    });

    testWidgets('a stale ticket: the server sentence is replaced by a plain one and the screen reloads', (t) async {
      final f = Fake((r) => fnOf(r) == 'kds_ticket_act' ? err(409, 'This ticket was changed on another screen.', 'version_conflict') : null);
      await show(t, KdsScreen(env: f.env()));
      await t.tap(find.byKey(ValueKey('act-start-${(fx['queue'] as Map)['tickets'][0]['card_id']}')));
      await t.pumpAndSettle();
      expect(find.textContaining('changed on another screen'), findsOneWidget);
      expect(f.of('kds_queue').length, 2);
    });

    testWidgets('a person who may not act sees the display but no Start, Print or switches that work', (t) async {
      final q = queueWith((q) => q['can'] = {'act': false});
      final f = Fake((r) => fnOf(r) == 'kds_queue' ? ok(q) : null);
      await show(t, KdsScreen(env: f.env()));
      expect(find.text('Start'), findsNothing);
      expect(find.text('Print ticket'), findsNothing);
      final sw = t.widget<Switch>(find.byKey(ValueKey('item-${q['tickets'][0]['items'][0]['id']}')));
      expect(sw.onChanged, isNull);
    });

    testWidgets('a station chip, a status chip and a search each ask the server with that filter', (t) async {
      final f = Fake();
      await show(t, KdsScreen(env: f.env()));
      await t.tap(find.byKey(const ValueKey('station-chip-tandoor')));
      await t.pumpAndSettle();
      expect(argsOf(f.of('kds_queue').last)['station'], 'tandoor');
      await t.tap(find.byKey(const ValueKey('status-ready')));
      await t.pumpAndSettle();
      expect(argsOf(f.of('kds_queue').last), {'station': 'tandoor', 'status': 'ready'});
      await t.enterText(find.byType(TextField), 'lassi');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(argsOf(f.of('kds_queue').last)['q'], 'lassi');
      await t.tap(find.text('All').first);
      await t.pumpAndSettle();
      expect(argsOf(f.of('kds_queue').last).containsKey('station'), false);
    });

    testWidgets('an empty kitchen says so; a filter with no match says "No orders match."', (t) async {
      final q = queueWith((q) {
        q['tickets'] = [];
        q['live'] = 0;
      });
      final f = Fake((r) => fnOf(r) == 'kds_queue' ? ok(q) : null);
      await show(t, KdsScreen(env: f.env()));
      expect(find.text('No orders in the kitchen right now.'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('status-new')));
      await t.pumpAndSettle();
      expect(find.text('No orders match.'), findsOneWidget);
    });

    testWidgets('a multi-station order is one card per station; each button acts on its own station only; Unassigned has its chip', (t) async {
      final q = copy(fx['queue_multi'] as Map<String, dynamic>);
      final f = Fake((r) => fnOf(r) == 'kds_queue' ? ok(q) : null);
      await show(t, KdsScreen(env: f.env()));
      final cards = q['tickets'] as List;
      expect(cards.map((c) => c['station']).toSet(), {'tandoor', 'beverages', 'unassigned'});
      expect(find.text('Unassigned'), findsWidgets); // the chip and the card tag
      expect(find.byKey(const ValueKey('station-chip-unassigned')), findsOneWidget);
      expect(find.text('Start'), findsNWidgets(3));
      final bev = cards.firstWhere((c) => c['station'] == 'beverages');
      await t.tap(find.byKey(ValueKey('act-start-${bev['card_id']}')));
      await t.pumpAndSettle();
      final a = argsOf(f.of('kds_ticket_act').single);
      expect(a['station'], 'beverages');
      expect(a['ticket_id'], bev['id']);
      expect(a['expected_version'], bev['version']);
    });

    testWidgets('the display asks again by itself on the interval and stops when closed', (t) async {
      final f = Fake();
      await t.pumpWidget(MaterialApp(theme: posTheme(), home: KdsScreen(env: KitchenEnv(api: f.api, refreshEvery: const Duration(seconds: 5)))));
      await t.pump();
      expect(f.of('kds_queue').length, 1);
      await t.pump(const Duration(seconds: 5));
      expect(f.of('kds_queue').length, 2);
      await t.pumpWidget(const MaterialApp(home: SizedBox()));
      await t.pump(const Duration(seconds: 20));
      expect(f.of('kds_queue').length, 2);
    });
  });
}
