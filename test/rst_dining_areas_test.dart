// Dining areas in table management (0646) and the Kitchen setup that links to them. The answer is what the database gave on the local test
// database (server/scripts/rst-dining-areas-e2e.mjs with FIXTURES=…): AC Hall 1 with A1 and A2 (joined), Rooftop empty, a booking on A3.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/kitchen/kitchen_api.dart';
import 'package:vinii_pos/kitchen/kitchen_setup_screen.dart';
import 'package:vinii_pos/kitchen/kitchen_widgets.dart';
import 'package:vinii_pos/tables/dining_areas_screen.dart';
import 'package:vinii_pos/tables/table_widgets.dart';
import 'package:vinii_pos/tables/tables_api.dart';

import 'helpers.dart';

final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/rst_dining_areas_server.json').readAsStringSync()) as Map<String, dynamic>;
Map<String, dynamic> areas() => jsonDecode(jsonEncode(fx['areas'])) as Map<String, dynamic>;
http.Response ok(Object? body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail) => http.Response(jsonEncode({'detail': detail, 'code': 'conflict'}), status, headers: {'content-type': 'application/json; charset=utf-8'});

class Fake {
  Fake({this.on = const {}});
  final Map<String, http.Response Function(Map<String, dynamic> b)> on;
  final calls = <(String, Map<String, dynamic>)>[];
  List<Map<String, dynamic>> of(String fn) => [for (final c in calls) if (c.$1 == fn) c.$2];
  late final client = MockClient((r) async {
    final fn = r.url.pathSegments.last;
    final b = r.body.isEmpty ? <String, dynamic>{} : (jsonDecode(r.body) as Map).cast<String, dynamic>();
    calls.add((fn, b));
    final h = on[fn];
    if (h != null) return h(b);
    return switch (fn) {
      'tbl_areas' => ok(areas()),
      'tbl_area_save' || 'tbl_area_set_active' || 'tbl_area_tables' => ok({'area': (areas()['areas'] as List).first}),
      'tbl_area_reorder' => ok(areas()),
      'tbl_area_delete' => ok({'deleted': 'x', 'name': 'Rooftop'}),
      'tbl_table_list' => ok({'tables': [
          for (final a in areas()['areas'] as List) ...(a as Map)['tables'] as List,
          {'id': 'a3', 'label': 'A3', 'seats': 2},
        ]}),
      'kitchen_config' => ok({'can': {'configure': true}, 'stations': [], 'printers': [], 'prep_areas': [], 'unassigned': []}),
      _ => err(404, 'Not found'),
    };
  });
  late final api = TablesApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client);
  late final env = TablesEnv(api: api);
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

List<Map<String, dynamic>> areaList() => (areas()['areas'] as List).cast<Map<String, dynamic>>();

void main() {
  testWidgets('stats, the next bookings, the areas with their kind and tables, and the filters', (t) async {
    final f = Fake();
    await show(t, DiningAreasScreen(env: f.env));
    await t.pumpAndSettle();
    expect(find.text('Dining areas'), findsWidgets);
    expect(find.byKey(const ValueKey('area-stat-areas')), findsOneWidget);
    expect(find.text('Asha · 2 guests'), findsOneWidget, reason: 'the booking on A3');
    final first = areaList().first, second = areaList()[1];
    expect(find.byKey(ValueKey('area-${first['name']}')), findsOneWidget);
    expect(find.byKey(ValueKey('area-${second['name']}')), findsOneWidget);
    expect(find.textContaining('No tables yet'), findsWidgets);
    await tapKey(t, 'area-filter-empty');
    expect(find.byKey(ValueKey('area-${first['name']}')), findsNothing, reason: 'it has tables');
    await tapKey(t, 'area-filter-all');
    await t.enterText(find.byKey(const ValueKey('area-search')), 'roof');
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('area-${first['name']}')), findsNothing);
  });

  testWidgets('Add area: a name and a kind', (t) async {
    final f = Fake();
    await show(t, DiningAreasScreen(env: f.env));
    await t.pumpAndSettle();
    await tapKey(t, 'area-add');
    await t.enterText(find.byKey(const ValueKey('area-name')), 'Garden');
    await tapKey(t, 'area-type-garden');
    await tapKey(t, 'area-save');
    expect(f.of('tbl_area_save').single, {'name': 'Garden', 'area_type': 'garden'});
    expect(toast('Garden added.'), findsOneWidget);
  });

  testWidgets('switch off, move up, delete (Are you sure first)', (t) async {
    final f = Fake();
    await show(t, DiningAreasScreen(env: f.env));
    await t.pumpAndSettle();
    final a = areaList(), first = a[0]['name'], second = a[1]['name'];
    await tapKey(t, 'area-active-$first');
    expect(f.of('tbl_area_set_active').single, {'id': a[0]['id'], 'active': false});
    await tapKey(t, 'area-up-$second');
    expect(f.of('tbl_area_reorder').single['ids'], [a[1]['id'], a[0]['id']]);
    await tapKey(t, 'area-delete-$second');
    await tapKey(t, 'area-delete-no');
    expect(f.of('tbl_area_delete'), isEmpty);
    await tapKey(t, 'area-delete-$second');
    await tapKey(t, 'area-delete-yes');
    expect(f.of('tbl_area_delete').single, {'id': a[1]['id']});
  });

  testWidgets('a refusal (an area with tables cannot be deleted) says why', (t) async {
    final f = Fake(on: {'tbl_area_delete': (_) => err(409, 'AC Hall 1 has 2 tables; move them to another area first.')});
    await show(t, DiningAreasScreen(env: f.env));
    await t.pumpAndSettle();
    final first = areaList()[0]['name'];
    await tapKey(t, 'area-delete-$first');
    await tapKey(t, 'area-delete-yes');
    expect(toast('AC Hall 1 has 2 tables; move them to another area first.'), findsOneWidget);
  });

  testWidgets('tap an area: tick its tables (a table elsewhere says where it is now)', (t) async {
    final f = Fake();
    await show(t, DiningAreasScreen(env: f.env));
    await t.pumpAndSettle();
    final a = areaList();
    final empty = a.firstWhere((x) => (x['table_count'] as num) == 0);
    await tapKey(t, 'area-${empty['name']}');
    expect(find.text('Tables in ${empty['name']}'), findsOneWidget);
    expect(find.textContaining('now in ${a.firstWhere((x) => (x['table_count'] as num) > 0)['name']}'), findsWidgets);
    await tapKey(t, 'area-table-A3');
    await tapKey(t, 'area-tables-save');
    expect(f.of('tbl_area_tables').single, {'id': empty['id'], 'table_ids': ['a3']});
  });

  testWidgets('Kitchen setup: the dining areas with Manage areas (opens Dining areas)', (t) async {
    final f = Fake();
    final kitchen = KitchenEnv(api: KitchenApi(baseUrl: 'http://t.test', accessToken: () => 't', client: f.client), refreshEvery: null);
    await show(t, KitchenSetupScreen(env: kitchen, tables: f.api));
    await t.pumpAndSettle();
    expect(find.text('Dining areas'), findsOneWidget);
    expect(find.byKey(ValueKey('kitchen-area-${areaList().first['name']}')), findsOneWidget);
    expect(find.textContaining('later release'), findsNothing);
    await t.tap(find.text('Manage areas'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('area-search')), findsOneWidget, reason: 'the Dining areas page');
  });
}
