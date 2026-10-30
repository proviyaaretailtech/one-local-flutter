import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:vinii_pos/kitchen/add_station_screen.dart';
import 'package:vinii_pos/kitchen/kds_board_screen.dart';
import 'package:vinii_pos/kitchen/kds_screen.dart';
import 'package:vinii_pos/kitchen/kitchen_api.dart';
import 'package:vinii_pos/kitchen/kitchen_setup_screen.dart';
import 'package:vinii_pos/kitchen/kitchen_widgets.dart';
import 'package:vinii_pos/kitchen/kot_screen.dart';
import 'package:vinii_pos/kitchen/station_detail_screen.dart';
import 'package:vinii_pos/inventory/inventory_api.dart' show Facts;
import 'package:vinii_pos/orders/order_alerts.dart';
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
  final sounds = SoundLog();
  KitchenEnv env({ValueChanged<String>? onNavigate}) => KitchenEnv(api: api, onNavigate: onNavigate, refreshEvery: null, sounds: sounds);
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
      await t.tap(find.byKey(const ValueKey('kit-tab-menu')));
      expect(seen, ['orders', 'menu']);
      expect(find.byKey(const ValueKey('kit-tab-stock')), findsNothing, reason: 'no Stock tab for now');
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

    testWidgets('top left is a back arrow (not ☰) and it goes back', (t) async {
      final env = Fake().env();
      t.view.physicalSize = const Size(810, 3600);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: posTheme(),
        home: Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => KdsScreen(env: env))), child: const Text('open kds')))),
      ));
      await t.tap(find.text('open kds'));
      await t.pumpAndSettle();
      expect(find.text('Kitchen Display System'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('kitchen-back')), matching: find.byIcon(LucideIcons.arrowLeft)), findsOneWidget);
      expect(find.byIcon(LucideIcons.menu), findsNothing);
      expect(find.bySemanticsLabel('Back'), findsWidgets);
      await t.tap(find.byKey(const ValueKey('kitchen-back')));
      await t.pumpAndSettle();
      expect(find.text('Kitchen Display System'), findsNothing);
      expect(find.text('open kds'), findsOneWidget, reason: 'back where it was opened from');
    });

    testWidgets('a takeaway dish on a dine-in order says TAKEAWAY on its kitchen card (pack it)', (t) async {
      final q = copy(fx['queue'] as Map<String, dynamic>);
      void mark(Object? j) {
        if (j is Map) {
          if (j['id'] == '630be6f9-42bb-470c-a3ec-30bc2026ade2') j['takeaway'] = true;
          j.values.forEach(mark);
        } else if (j is List) {
          j.forEach(mark);
        }
      }
      mark(q);
      await show(t, KdsScreen(env: Fake((r) => fnOf(r) == 'kds_queue' ? ok(q) : null).env()));
      expect(find.byKey(const ValueKey('kds-takeaway-630be6f9-42bb-470c-a3ec-30bc2026ade2')), findsOneWidget);
      expect(find.text('TAKEAWAY'), findsOneWidget, reason: 'only that dish');
    });

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

  group('KDS view (kitchen board)', () {
    Map<String, dynamic> first() => ((fx['queue'] as Map)['tickets'] as List).first as Map<String, dynamic>;
    // these cover the grid; the list view has its own group below
    setUp(() => KdsBoardScreen.layout = 'grid');
    tearDown(() => KdsBoardScreen.layout = 'list');

    testWidgets('on a phone: two compact tickets to a row; a tap pops up the full ticket (header, Hand over, KOT, MM:SS, dishes, footer)', (t) async {
      final f = Fake();
      await show(t, KdsBoardScreen(env: f.env()));
      final tickets = ((fx['queue'] as Map)['tickets'] as List).cast<Map>();
      // the late ticket (the fixture's second) leads the board, then the others oldest first
      final a = t.getRect(find.byKey(ValueKey('kds-mini-${tickets[1]['card_id']}')));
      final b = t.getRect(find.byKey(ValueKey('kds-mini-${tickets[0]['card_id']}')));
      expect(b.top, closeTo(a.top, 2), reason: 'two in a row (a late card has a thicker border)');
      expect(b.left, greaterThan(a.right));
      expect(find.byKey(ValueKey('kds-card-${first()['card_id']}')), findsNothing, reason: 'the full ticket opens on a tap');
      await t.tap(find.byKey(ValueKey('kds-mini-${first()['card_id']}')));
      await t.pumpAndSettle();
      final card = first()['card_id'] as String;
      final full = find.descendant(of: find.byKey(const ValueKey('kds-detail')), matching: find.byKey(ValueKey('kds-card-$card')));
      expect(full, findsOneWidget);
      expect(find.descendant(of: full, matching: find.text('Hand over')), findsOneWidget);
      expect(find.descendant(of: full, matching: find.text('KOT-${first()['kot_no']}')), findsOneWidget);
      expect(find.byKey(ValueKey('kds-timer-$card')), findsOneWidget);
      expect(find.descendant(of: full, matching: find.text('Butter Naan')), findsOneWidget);
      expect(t.widget<Text>(find.byKey(ValueKey('kds-foot-$card'))).data!, startsWith('KOT ${first()['kot_no']} • DINE-IN • T1'));
      await t.tap(find.byKey(const ValueKey('kds-detail-close')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('kds-detail')), findsNothing);
      expect(argsOf(f.of('kds_queue').first)['status'], 'all');
    });

    testWidgets('in the pop-up a switch marks the dish done on its station; Hand over makes the card ready, then serves it', (t) async {
      final f = Fake();
      await show(t, KdsBoardScreen(env: f.env()));
      final c = first();
      final item = ((c['items'] as List).first as Map)['id'];
      await t.tap(find.byKey(ValueKey('kds-mini-${c['card_id']}')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(ValueKey('kds-item-$item')));
      await t.pumpAndSettle();
      final a = argsOf(f.of('kds_ticket_act').single);
      expect([a['action'], a['item_id'], a['station']], ['item_done', item, c['station']]);
      expect(find.byKey(const ValueKey('kds-detail')), findsOneWidget, reason: 'the pop-up stays open with the latest data');
      await t.tap(find.byKey(ValueKey('kds-handover-${c['card_id']}')));
      await t.pumpAndSettle();
      expect([for (final r in f.of('kds_ticket_act').skip(1)) argsOf(r)['action']], ['ready', 'serve']);
    });

    testWidgets('a ready ticket stops its timer at the time it took, in green, labelled READY IN', (t) async {
      final q = copy(fx['queue'] as Map<String, dynamic>);
      final c = (q['tickets'] as List).first as Map<String, dynamic>;
      c['chip'] = 'ready';
      c['created_at'] = '2026-10-27T10:00:00Z';
      c['ready_at'] = '2026-10-27T10:05:07Z';
      await show(t, KdsBoardScreen(env: Fake((r) => fnOf(r) == 'kds_queue' ? ok(q) : null).env()));
      expect(find.descendant(of: find.byKey(ValueKey('kds-mini-${c['card_id']}')), matching: find.text('05:07')), findsOneWidget);
      await t.tap(find.byKey(ValueKey('kds-mini-${c['card_id']}')));
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(ValueKey('kds-timer-${c['card_id']}'))).data, '05:07');
      expect(t.widget<Text>(find.byKey(ValueKey('kds-timer-${c['card_id']}'))).style!.color, const Color(0xFF15803D));
      expect(find.text('READY IN'), findsOneWidget);
    });

    testWidgets('on a tablet: the full tickets side by side, no pop-up needed', (t) async {
      final f = Fake();
      await show(t, KdsBoardScreen(env: f.env()));
      t.view.physicalSize = const Size(2000, 1400);
      await t.pumpAndSettle();
      expect(find.byKey(ValueKey('kds-card-${first()['card_id']}')), findsOneWidget);
      expect(find.byKey(ValueKey('kds-mini-${first()['card_id']}')), findsNothing);
    });

    testWidgets('the left panel: what is left to cook by Category, by Item, and Overall', (t) async {
      final f = Fake();
      await show(t, KdsBoardScreen(env: f.env()));
      expect(find.byKey(const ValueKey('kds-cat-Other')), findsNothing, reason: 'folded on a phone');
      expect(find.textContaining('To cook · '), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('kds-todo-toggle')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('kds-cat-Other')), findsOneWidget, reason: 'no menu categories in this fake: Other');
      await t.tap(find.byKey(const ValueKey('kds-side-item')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('kds-todo-Butter Naan')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('kds-side-overall')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('kds-overall-Open tickets')), findsOneWidget);
    });

    testWidgets('status filters count the tickets; late first and tagged LATE; a filter shows only its tickets', (t) async {
      final q = copy(fx['queue'] as Map<String, dynamic>);
      final tickets = (q['tickets'] as List).cast<Map<String, dynamic>>();
      tickets[2]['chip'] = 'ready';
      tickets[3]['chip'] = 'in_progress';
      await show(t, KdsBoardScreen(env: Fake((r) => fnOf(r) == 'kds_queue' ? ok(q) : null).env()));
      Finder chip(String k, String text) => find.descendant(of: find.byKey(ValueKey('kds-filter-$k')), matching: find.text(text));
      expect(chip('all', '4'), findsOneWidget);
      expect(chip('late', '1'), findsOneWidget);
      expect(chip('new', '1'), findsOneWidget);
      expect(chip('cooking', '1'), findsOneWidget);
      expect(chip('ready', '1'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(ValueKey('kds-status-${tickets[1]['card_id']}'))).data, 'LATE');
      final tops = [for (final c in tickets) t.getRect(find.byKey(ValueKey('kds-mini-${c['card_id']}'))).top];
      expect(tops[2], greaterThan(tops[1]), reason: 'ready goes after late');
      expect(find.byKey(ValueKey('kds-mini-handover-${tickets[2]['card_id']}')), findsOneWidget, reason: 'Hand over right on a ready ticket');
      await t.tap(find.byKey(const ValueKey('kds-filter-ready')));
      await t.pumpAndSettle();
      expect(find.byKey(ValueKey('kds-mini-${tickets[2]['card_id']}')), findsOneWidget);
      expect(find.byKey(ValueKey('kds-mini-${tickets[1]['card_id']}')), findsNothing);
    });

    testWidgets('Hand over on a ready ticket on the board serves it without opening it', (t) async {
      final q = copy(fx['queue'] as Map<String, dynamic>);
      final c = (q['tickets'] as List).first as Map<String, dynamic>;
      c['chip'] = 'ready';
      final f = Fake((r) => fnOf(r) == 'kds_queue' ? ok(q) : null);
      await show(t, KdsBoardScreen(env: f.env()));
      await t.tap(find.byKey(ValueKey('kds-mini-handover-${c['card_id']}')));
      await t.pumpAndSettle();
      expect([for (final r in f.of('kds_ticket_act')) argsOf(r)['action']], ['serve']);
      expect(find.byKey(const ValueKey('kds-detail')), findsNothing);
    });

    testWidgets('sounds: nothing on opening; a chime for a new ticket, a warning when one runs late, a beep when one is ready; mute stops them', (t) async {
      final q = copy(fx['queue'] as Map<String, dynamic>);
      final tickets = (q['tickets'] as List).cast<Map<String, dynamic>>();
      final extra = copy(tickets.first)..['card_id'] = 'card-new';
      addTearDown(() => KdsBoardScreen.muted = false);
      final f = Fake((r) => fnOf(r) == 'kds_queue' ? ok(q) : null);
      await show(t, KdsBoardScreen(env: f.env()));
      expect(f.sounds.played, isEmpty, reason: 'what is already there on opening is not news');
      Future<void> refresh() async {
        await t.tap(find.byKey(const ValueKey('kds-refresh')));
        await t.pumpAndSettle();
      }

      (q['tickets'] as List).add(extra);
      await refresh();
      expect(f.sounds.played, ['arrive']);
      tickets[0]['delayed'] = true;
      await refresh();
      expect(f.sounds.played, ['arrive', 'warning']);
      tickets[2]['chip'] = 'ready';
      await refresh();
      expect(f.sounds.played, ['arrive', 'warning', 'ready']);
      await refresh();
      expect(f.sounds.played.length, 3, reason: 'each change sounds once');
      await t.tap(find.byKey(const ValueKey('kds-sound')));
      await t.pumpAndSettle();
      expect(KdsBoardScreen.muted, isTrue);
      tickets[3]['chip'] = 'ready';
      await refresh();
      expect(f.sounds.played.length, 3, reason: 'muted');
      await t.tap(find.byKey(const ValueKey('kds-sound')));
      await t.pumpAndSettle();
      expect(f.sounds.played.last, 'ready', reason: 'turning sound on plays a test beep');
    });
  });

  group('KDS list view (a checklist per ticket)', () {
    Map<String, dynamic> first() => ((fx['queue'] as Map)['tickets'] as List).first as Map<String, dynamic>;
    tearDown(() => KdsBoardScreen.layout = 'list');

    testWidgets('opens as a list: one ticket under the other, every dish a checklist row, no pop-up', (t) async {
      final f = Fake();
      await show(t, KdsBoardScreen(env: f.env()));
      final tickets = ((fx['queue'] as Map)['tickets'] as List).cast<Map>();
      final a = t.getRect(find.byKey(ValueKey('kds-list-${tickets[1]['card_id']}')));
      final b = t.getRect(find.byKey(ValueKey('kds-list-${tickets[0]['card_id']}')));
      expect(b.top, greaterThan(a.bottom - 1), reason: 'one under the other, the late one first');
      expect(find.byKey(ValueKey('kds-mini-${first()['card_id']}')), findsNothing);
      final item = ((first()['items'] as List).first as Map)['id'];
      expect(find.byKey(ValueKey('kds-check-$item')), findsOneWidget);
      expect(find.descendant(of: find.byKey(ValueKey('kds-list-${first()['card_id']}')), matching: find.text('Butter Naan')), findsOneWidget);
    });

    testWidgets('tapping a dish ticks it on its station; Hand over makes the ticket ready, then serves it', (t) async {
      final f = Fake();
      await show(t, KdsBoardScreen(env: f.env()));
      final c = first();
      final item = ((c['items'] as List).first as Map)['id'];
      await t.tap(find.byKey(ValueKey('kds-check-$item')));
      await t.pumpAndSettle();
      final a = argsOf(f.of('kds_ticket_act').single);
      expect([a['action'], a['item_id'], a['station']], ['item_done', item, c['station']]);
      expect(find.byKey(const ValueKey('kds-detail')), findsNothing, reason: 'no pop-up in the list');
      await t.tap(find.byKey(ValueKey('kds-list-handover-${c['card_id']}')));
      await t.pumpAndSettle();
      expect([for (final r in f.of('kds_ticket_act').skip(1)) argsOf(r)['action']], ['ready', 'serve']);
    });

    testWidgets('List / Grid switch: Grid shows the compact cards that pop up; the choice stays for the session', (t) async {
      final f = Fake();
      await show(t, KdsBoardScreen(env: f.env()));
      await t.tap(find.byKey(const ValueKey('kds-view-grid')));
      await t.pumpAndSettle();
      expect(find.byKey(ValueKey('kds-mini-${first()['card_id']}')), findsOneWidget);
      expect(find.byKey(ValueKey('kds-list-${first()['card_id']}')), findsNothing);
      expect(KdsBoardScreen.layout, 'grid');
      await t.tap(find.byKey(ValueKey('kds-mini-${first()['card_id']}')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('kds-detail')), findsOneWidget);
    });
  });

  group('a cancelled order on the KDS', () {
    tearDown(() {
      KdsBoardScreen.layout = 'list';
      KdsBoardScreen.dismissedCancels.clear();
    });
    Map<String, dynamic> cancelled() => {
          'order_id': 'o-cx', 'display_no': 'P-00040', 'channel': 'dine_in', 'table_label': 'T2', 'at': '2026-10-28T18:25:51Z', 'kots': [33],
          'items': [
            {'qty': 2, 'name': 'Brownie Pancake', 'variant': null},
          ],
        };

    testWidgets('buzzes once and shows a red Stop cooking alert with the dishes; Got it hides it', (t) async {
      final q = copy(fx['queue'] as Map<String, dynamic>);
      final f = Fake((r) => fnOf(r) == 'kds_queue' ? ok(q) : null);
      await show(t, KdsBoardScreen(env: f.env()));
      expect(find.byKey(const ValueKey('kds-cancel-P-00040')), findsNothing);
      q['cancelled'] = [cancelled()];
      await t.tap(find.byKey(const ValueKey('kds-refresh')));
      await t.pumpAndSettle();
      expect(f.sounds.played, ['cancelled']);
      expect(find.text('CANCELLED · Stop cooking'), findsOneWidget);
      expect(find.text('#P-00040 · T2 · KOT 33'), findsOneWidget);
      expect(find.text('2× Brownie Pancake'), findsOneWidget);
      expect(t.getRect(find.byKey(const ValueKey('kds-cancel-P-00040'))).top, lessThan(t.getRect(find.byKey(const ValueKey('kds-filter-all'))).top), reason: 'above everything');
      await t.tap(find.byKey(const ValueKey('kds-refresh')));
      await t.pumpAndSettle();
      expect(f.sounds.played, ['cancelled'], reason: 'once per order');
      await t.tap(find.byKey(const ValueKey('kds-cancel-ok-P-00040')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('kds-cancel-P-00040')), findsNothing);
    });

    testWidgets('a cancellation already there when the board opens shows, without the alarm', (t) async {
      final q = copy(fx['queue'] as Map<String, dynamic>)..['cancelled'] = [cancelled()];
      final f = Fake((r) => fnOf(r) == 'kds_queue' ? ok(q) : null);
      await show(t, KdsBoardScreen(env: f.env()));
      expect(find.byKey(const ValueKey('kds-cancel-P-00040')), findsOneWidget);
      expect(f.sounds.played, isEmpty);
    });
  });

  group('table transfer on the kitchen tickets', () {
    tearDown(() => KdsBoardScreen.layout = 'list');

    testWidgets('a moved ticket shows its new table and "Moved T1 → T5" in the list, the grid and the full ticket; the KDS sounds once', (t) async {
      final q = copy(fx['queue'] as Map<String, dynamic>);
      final c = (q['tickets'] as List).first as Map<String, dynamic>;
      final f = Fake((r) => fnOf(r) == 'kds_queue' ? ok(q) : null);
      await show(t, KdsBoardScreen(env: f.env()));
      expect(find.byKey(ValueKey('kds-moved-${c['card_id']}')), findsNothing);
      c['table_label'] = 'T5';
      c['moved'] = {'from': 'T1', 'to': 'T5', 'at': '2026-10-28T18:20:47Z'};
      await t.tap(find.byKey(const ValueKey('kds-refresh')));
      await t.pumpAndSettle();
      expect(find.byKey(ValueKey('kds-moved-${c['card_id']}')), findsOneWidget);
      expect(find.text('Moved T1 → T5'), findsOneWidget);
      expect(find.descendant(of: find.byKey(ValueKey('kds-list-${c['card_id']}')), matching: find.textContaining('T5', findRichText: true)), findsWidgets);
      expect(f.sounds.played, ['warning']);
      await t.tap(find.byKey(const ValueKey('kds-refresh')));
      await t.pumpAndSettle();
      expect(f.sounds.played, ['warning'], reason: 'once per move');
      await t.tap(find.byKey(const ValueKey('kds-view-grid')));
      await t.pumpAndSettle();
      expect(find.byKey(ValueKey('kds-moved-${c['card_id']}')), findsOneWidget);
      await t.tap(find.byKey(ValueKey('kds-mini-${c['card_id']}')));
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(ValueKey('kds-foot-${c['card_id']}'))).data!, contains('MOVED T1 → T5'));
    });

    testWidgets('the KOT view says the order moved', (t) async {
      final f = Fake((r) => fnOf(r) == 'rst_kot_orders'
          ? ok({
              'counts': {'all': 1, 'preparing': 1, 'ready': 0, 'completed': 0},
              'orders': [
                {
                  'id': 'o1', 'display_no': 'P-00050', 'total': 300, 'stage': 'preparing', 'channel': 'dine_in', 'table_id': 't5', 'table_label': 'T5',
                  'captain': null, 'paid': false, 'created_at': '2026-10-28T18:00:00Z', 'minutes': 3, 'items': 1, 'ready': 0,
                  'kots': [{'id': 'k1', 'kot_no': 9, 'status': 'new', 'items': 1, 'ready': 0}], 'stations': [], 'ready_item_ids': [], 'latest_ticket': 'k1',
                  'moved': {'from': 'T1', 'to': 'T5', 'at': '2026-10-28T18:02:00Z'},
                },
              ],
            })
          : null);
      await show(t, KotScreen(env: f.env(), openOrder: (_, _) {}));
      expect(find.text('T5'), findsOneWidget);
      expect(find.byKey(const ValueKey('kot-moved-P-00050')), findsOneWidget);
      expect(find.text('Moved T1 → T5'), findsOneWidget);
    });
  });

  group('KOT view (one card per order)', () {
    Map<String, dynamic> kotOrders() => {
          'counts': {'all': 2, 'preparing': 0, 'ready': 1, 'completed': 1},
          'orders': [
            {
              'id': 'o1', 'display_no': 'P-00042', 'total': 1798, 'stage': 'ready', 'channel': 'dine_in', 'table_id': 't1', 'table_label': 'T1',
              'captain': null, 'paid': false, 'created_at': '2026-10-27T17:00:00Z', 'minutes': 12, 'items': 5, 'ready': 5,
              'kots': [
                {'id': 'k1', 'kot_no': 1, 'status': 'ready', 'items': 3, 'ready': 3},
                {'id': 'k2', 'kot_no': 2, 'status': 'ready', 'items': 2, 'ready': 2},
              ],
              'stations': [{'name': 'Main Kitchen', 'done': true}, {'name': 'Beverages', 'done': true}],
              'ready_item_ids': ['i1', 'i2'], 'latest_ticket': 'k2',
            },
            {
              'id': 'o2', 'display_no': 'P-00040', 'total': 476, 'stage': 'completed', 'channel': 'pickup', 'table_id': null, 'table_label': null,
              'captain': 'Ravi', 'paid': true, 'created_at': '2026-10-27T16:00:00Z', 'minutes': 70, 'items': 3, 'ready': 3,
              'kots': [{'id': 'k3', 'kot_no': 3, 'status': 'delivered', 'items': 3, 'ready': 3}],
              'stations': [{'name': 'Main Kitchen', 'done': true}],
              'ready_item_ids': [], 'latest_ticket': 'k3',
            },
          ],
        };

    testWidgets('status, number, total, table and dishes, tags, the KOT chain, ready count and stations', (t) async {
      final f = Fake((r) => switch (fnOf(r)) { 'rst_kot_orders' => ok(kotOrders()), 'tbl_mark_served' => ok({'served': 2}), _ => null });
      await show(t, KotScreen(env: f.env(), openOrder: (_, _) {}));
      expect(find.text('KOT view'), findsOneWidget);
      expect(find.text('READY'), findsOneWidget);
      expect(find.text('COMPLETED'), findsOneWidget);
      expect(find.text('T1'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('kot-line-P-00042'))).data, startsWith('#P-00042 · 5 items · '));
      expect(find.text('₹1,798'), findsOneWidget);
      expect(find.text('Unpaid'), findsOneWidget);
      expect(find.text('Paid'), findsOneWidget);
      expect(find.text('Ravi'), findsOneWidget, reason: 'the captain, when there is one');
      expect(find.text('12 min'), findsOneWidget);
      expect(find.text('1h 10m'), findsOneWidget);
      expect(find.byKey(const ValueKey('kot-chip-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('kot-chip-2')), findsOneWidget);
      expect(find.text('5/5 ready'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('kot-stations-P-00042'))).data, 'Main Kitchen ✓  ·  Beverages ✓');
      expect(find.text('Serve 2'), findsOneWidget);
      expect(t.getRect(find.byKey(const ValueKey('kot-order-P-00042'))).top, lessThan(t.getRect(find.byKey(const ValueKey('kot-order-P-00040'))).top), reason: 'dishes to serve first');
      await t.tap(find.byKey(const ValueKey('kot-serve-P-00042')));
      await t.pumpAndSettle();
      expect(argsOf(f.of('tbl_mark_served').single)['item_ids'], ['i1', 'i2']);
      expect(find.byKey(const ValueKey('kot-serve-P-00040')), findsNothing, reason: 'a completed order has no Serve');
    });

    testWidgets('the status chips ask the database again; Bill and View open the order', (t) async {
      final opened = <String>[];
      final f = Fake((r) => fnOf(r) == 'rst_kot_orders' ? ok(kotOrders()) : null);
      await show(t, KotScreen(env: f.env(), openOrder: (_, o) => opened.add(o.s('display_no'))));
      await t.tap(find.byKey(const ValueKey('kot-status-ready')));
      await t.pumpAndSettle();
      expect(argsOf(f.of('rst_kot_orders').last)['status'], 'ready');
      await t.tap(find.byKey(const ValueKey('kot-bill-P-00042')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('kot-view-P-00040')));
      await t.pumpAndSettle();
      expect(opened, ['P-00042', 'P-00040']);
    });

    testWidgets('a ready order whose dishes are all served says so and leads with Bill; the timer is red only for a late order still cooking', (t) async {
      final d = kotOrders();
      final orders = (d['orders'] as List).cast<Map<String, dynamic>>();
      orders[0]['ready_item_ids'] = <String>[];
      orders[0]['minutes'] = 1109;
      orders[1]
        ..['stage'] = 'preparing'
        ..['minutes'] = 25;
      final f = Fake((r) => fnOf(r) == 'rst_kot_orders' ? ok(d) : null);
      await show(t, KotScreen(env: f.env(), openOrder: (_, _) {}));
      expect(find.byKey(const ValueKey('kot-served-P-00042')), findsOneWidget);
      expect(find.byKey(const ValueKey('kot-serve-P-00042')), findsNothing, reason: 'nothing left to serve');
      expect(find.byKey(const ValueKey('kot-bill-P-00042')), findsOneWidget);
      expect(find.text('18h 29m'), findsOneWidget);
      Color ageColor(String no) => t.widget<Container>(find.byKey(ValueKey('kot-age-$no'))).decoration is BoxDecoration
          ? (t.widget<Container>(find.byKey(ValueKey('kot-age-$no'))).decoration! as BoxDecoration).color!
          : Colors.transparent;
      expect(ageColor('P-00042'), isNot(const Color(0xFFFFE1E3)), reason: 'ready, not cooking: not red');
      expect(ageColor('P-00040'), const Color(0xFFFFE1E3), reason: 'still cooking after 20 minutes: red');
    });

    // 0621: a customer cancels mid-way; the KOT view keeps the order, red, first, with who and why, and sounds the cancel alarm once
    Map<String, dynamic> cancelledOrder({bool recent = true}) => {
          'id': 'o9', 'display_no': 'P-00009', 'total': 420, 'stage': 'cancelled', 'channel': 'online', 'table_id': null, 'table_label': null,
          'captain': null, 'paid': true, 'created_at': '2026-10-29T07:48:00Z', 'minutes': 6, 'items': 2, 'ready': 0,
          'cancel': {'by': 'Customer', 'reason': 'Ordered by mistake', 'at': '2026-10-29T07:53:00Z', 'recent': recent},
          'dishes': [{'qty': 2, 'name': 'Paneer Subway'}],
          'kots': [{'id': 'k9', 'kot_no': 26, 'status': 'cancelled', 'items': 2, 'ready': 0}], 'stations': [], 'ready_item_ids': [], 'latest_ticket': 'k9',
        };

    testWidgets('a cancelled order stays on the KOT view: red, first, Stop cooking, by whom and why, dishes and KOT struck out, only View', (t) async {
      final d = kotOrders();
      (d['orders'] as List).add(cancelledOrder());
      (d['counts'] as Map)['cancelled'] = 1;
      final opened = <String>[];
      final f = Fake((r) => fnOf(r) == 'rst_kot_orders' ? ok(d) : null);
      await show(t, KotScreen(env: f.env(), openOrder: (_, o) => opened.add(o.s('display_no'))));
      expect(find.text('CANCELLED'), findsOneWidget);
      expect(find.text('Stop cooking'), findsOneWidget);
      expect(find.textContaining('By Customer · '), findsOneWidget, reason: 'who, then the time it was cancelled');
      expect(find.text('“Ordered by mistake”'), findsOneWidget);
      expect(find.text('2× Paneer Subway'), findsOneWidget);
      expect(find.byKey(const ValueKey('kot-chip-26')), findsOneWidget);
      expect(t.getRect(find.byKey(const ValueKey('kot-order-P-00009'))).top, lessThan(t.getRect(find.byKey(const ValueKey('kot-order-P-00042'))).top), reason: 'a fresh cancel comes first');
      expect(find.byKey(const ValueKey('kot-serve-P-00009')), findsNothing);
      expect(find.byKey(const ValueKey('kot-bill-P-00009')), findsNothing);
      expect(find.byKey(const ValueKey('kot-print-P-00009')), findsNothing);
      await t.tap(find.byKey(const ValueKey('kot-view-P-00009')));
      expect(opened, ['P-00009']);
      expect(find.text('1'), findsWidgets, reason: 'the Cancelled count tile');
      await t.tap(find.byKey(const ValueKey('kot-status-cancelled')));
      await t.pumpAndSettle();
      expect(argsOf(f.of('rst_kot_orders').last)['status'], 'cancelled');
    });

    testWidgets('the KOT view sounds the cancel alarm when an order is cancelled while it is open (not for one already there)', (t) async {
      final d = kotOrders();
      final f = Fake((r) => fnOf(r) == 'rst_kot_orders' ? ok(d) : null);
      await show(t, KotScreen(env: f.env(), openOrder: (_, _) {}));
      expect(f.sounds.played, isEmpty);
      (d['orders'] as List).add(cancelledOrder());
      await t.tap(find.byKey(const ValueKey('kot-refresh')));
      await t.pumpAndSettle();
      expect(f.sounds.played, ['cancelled']);
      await t.tap(find.byKey(const ValueKey('kot-refresh')));
      await t.pumpAndSettle();
      expect(f.sounds.played, ['cancelled'], reason: 'once per order');
    });

    testWidgets('an older cancel is quiet: Cancelled, not Stop cooking, and it goes last', (t) async {
      final d = kotOrders();
      (d['orders'] as List).add(cancelledOrder(recent: false));
      final f = Fake((r) => fnOf(r) == 'rst_kot_orders' ? ok(d) : null);
      await show(t, KotScreen(env: f.env(), openOrder: (_, _) {}));
      expect(find.text('Stop cooking'), findsNothing);
      expect(find.text('Cancelled'), findsWidgets);
      expect(t.getRect(find.byKey(const ValueKey('kot-order-P-00009'))).top, greaterThan(t.getRect(find.byKey(const ValueKey('kot-order-P-00040'))).top));
    });
  });

  testWidgets('the KDS cancel alert says who cancelled and why', (t) async {
    final q = copy(fx['queue'] as Map<String, dynamic>)
      ..['cancelled'] = [
        {
          'order_id': 'o9', 'display_no': 'P-00009', 'channel': 'online', 'table_label': null, 'at': '2026-10-29T07:53:00Z', 'kots': [26],
          'items': [{'qty': 2, 'name': 'Paneer Subway', 'variant': null}], 'by': 'Customer', 'reason': 'Ordered by mistake',
        },
      ];
    final f = Fake((r) => fnOf(r) == 'kds_queue' ? ok(q) : null);
    await show(t, KdsBoardScreen(env: f.env()));
    expect(find.text('By Customer · “Ordered by mistake”'), findsOneWidget);
    KdsBoardScreen.dismissedCancels.clear();
  });
}

/// Records the KDS sounds instead of playing them.
class SoundLog extends OrderAlertSounds {
  SoundLog();
  final played = <String>[];
  @override
  Future<void> arrive() async => played.add('arrive');
  @override
  Future<void> warning() async => played.add('warning');
  @override
  Future<void> ready() async => played.add('ready');
  @override
  Future<void> cancelled() async => played.add('cancelled');
}
