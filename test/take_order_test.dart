import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/tables/table_order_screen.dart';
import 'package:vinii_pos/tables/table_widgets.dart';
import 'package:vinii_pos/tables/tables_api.dart';
import 'package:vinii_pos/tables/take_order_screens.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

/// Answers captured from the real local database (the story of database/tests/485_table_order_flow.sql: a restaurant with no kitchen setup
/// takes an order at Table 4, holds two naans, sends them, the cook marks dishes ready, the waiter serves them).
final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/take_order_server.json').readAsStringSync()) as Map<String, dynamic>;

http.Response ok(Object? body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) =>
    http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;
Map<String, dynamic> argsOf(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

class Fake {
  Fake([this._handler]);
  final http.Response? Function(http.Request r)? _handler;
  final requests = <http.Request>[];
  late final env = TablesEnv(
    api: TablesApi(
      baseUrl: 'http://tbl.test',
      accessToken: () => 'token-123',
      client: MockClient((r) async {
        requests.add(r);
        final custom = _handler?.call(r);
        if (custom != null) return custom;
        return switch (fnOf(r)) {
          'pos_sell_catalog' => ok(fx['menu']),
          'tbl_order_view' => ok(fx['order_view_held']),
          'tbl_order_add' => ok(argsOf(r)['send'] == false ? fx['add_hold'] : fx['add_send']),
          'tbl_kot_send' => ok(fx['send_held']),
          'tbl_ready_list' => ok(fx['ready']),
          'tbl_mark_served' => ok(fx['served']),
          _ => err(404, 'not found: ${fnOf(r)}'),
        };
      }),
    ),
  );
  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
}

Future<void> show(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 3000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

/// Opens [screen] from a plain page, so popping it can be seen.
Future<void> showPushed(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 3000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: posTheme(),
    home: Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => screen)), child: const Text('tables')))),
  ));
  await t.tap(find.text('tables'));
  await t.pumpAndSettle();
}

const naan = '47a00000-0000-0000-0000-000000000003';
const dal = '47a00000-0000-0000-0000-000000000002';
const table4 = '47b00000-0000-0000-0000-000000000001';

void main() {
  // A free table: nothing on the bill yet.
  Fake freeTable([http.Response? Function(http.Request r)? h]) => Fake((r) => h?.call(r) ?? (fnOf(r) == 'tbl_order_view' ? ok({'subtotal': 0}) : null));

  group('Add dishes (Figma 18:403)', () {
    testWidgets('category tabs, quantities, a note and the total so far', (t) async {
      final f = freeTable();
      await show(t, AddDishesScreen(env: f.env, tableId: table4, tableLabel: 'Table 4', guests: 2));
      expect(find.text('Table 4'), findsOneWidget);
      expect(find.text('2 guests · Dine-in'), findsOneWidget);
      for (final c in ['Breads', 'Mains', 'Starters']) {
        expect(find.byKey(ValueKey('cat-$c')), findsOneWidget);
      }
      expect(find.text('Butter Naan'), findsOneWidget);
      expect(find.text('Dal Makhani'), findsNothing); // another category
      await t.tap(find.byKey(const ValueKey('plus-$naan')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('plus-$naan')));
      await t.pump();
      expect(find.text('Quantity 2'), findsOneWidget);
      expect(find.text('₹120'), findsWidgets);
      await t.tap(find.text('Add a note'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('dish-note-field')), 'less butter');
      await t.tap(find.byKey(const ValueKey('dish-note-save')));
      await t.pumpAndSettle();
      expect(find.text('Quantity 2 · less butter'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('cat-Mains')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('plus-$dal')));
      await t.pump();
      final total = t.widget<Text>(find.byKey(const ValueKey('total-so-far')));
      expect(total.data, '₹340');
    });

    testWidgets('a dish with sizes has a line per size, each with its price and counter; the size goes with the dish', (t) async {
      final menu = jsonDecode(jsonEncode(fx['menu'])) as Map<String, dynamic>;
      for (final i in menu['items'] as List) {
        if (i['id'] == naan) {
          i['variants'] = [
            {'id': 'v-s', 'name': 'Small', 'price': 60, 'is_default': true},
            {'id': 'v-l', 'name': 'Large', 'price': 90, 'is_default': false},
          ];
        }
      }
      final f = Fake((r) => fnOf(r) == 'pos_sell_catalog' ? ok(menu) : fnOf(r) == 'tbl_order_view' ? err(404, 'no order yet') : null);
      await showPushed(t, AddDishesScreen(env: f.env, tableId: table4, tableLabel: 'Table 4'));
      expect(find.text('Small · ₹60'), findsOneWidget);
      expect(find.text('Large · ₹90'), findsOneWidget);
      await t.tap(find.byKey(ValueKey('plus-$naan-Large')));
      await t.pump();
      await t.tap(find.byKey(ValueKey('plus-$naan-Large')));
      await t.pump();
      expect(find.byKey(ValueKey('qty-$naan-Large')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('send-to-kitchen')));
      await t.pumpAndSettle();
      expect(argsOf(f.calls('tbl_order_add').single)['lines'], [{'menu_item_id': naan, 'qty': 2, 'variant_id': 'v-l'}]);
    });

    testWidgets('a dish with add-ons and combos (0624) opens one pop-up; what is chosen is priced on its own line and sent with the dish', (t) async {
      final menu = jsonDecode(jsonEncode(fx['menu'])) as Map<String, dynamic>;
      for (final i in menu['items'] as List) {
        if (i['id'] == naan) {
          i['price'] = 199;
          i['options'] = {
            'addon_groups': [
              {'id': 'g1', 'name': 'Extra dips', 'min': 0, 'max': 3, 'addons': [{'id': 'a-cheese', 'name': 'Cheese slices', 'price': 50, 'food_type': 'veg'}]},
              {'id': 'g2', 'name': 'Choose a dip', 'min': 1, 'max': 1, 'addons': [{'id': 'a-mint', 'name': 'Mint', 'price': 0, 'food_type': 'veg'}, {'id': 'a-mayo', 'name': 'Mayo', 'price': 10, 'food_type': 'veg'}]},
            ],
            'combo_groups': [
              {'id': 'cg1', 'name': 'Make it a meal', 'min': 0, 'max': 1, 'combos': [{'id': 'c1', 'name': 'fries & Cole', 'price': 325, 'items': 'Ice Blue, Salted Fries'}]},
            ],
          };
        }
      }
      final f = Fake((r) => fnOf(r) == 'pos_sell_catalog' ? ok(menu) : fnOf(r) == 'tbl_order_view' ? err(404, 'no order yet') : null);
      await showPushed(t, AddDishesScreen(env: f.env, tableId: table4, tableLabel: 'Table 4'));
      await t.tap(find.byKey(const ValueKey('options-$naan')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('opt-title')), findsOneWidget);
      expect(find.text('Optional · up to 3'), findsOneWidget);
      expect(find.byKey(const ValueKey('opt-missing')), findsOneWidget, reason: 'Choose a dip needs one');
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('opt-add'))).onPressed, isNull);
      await t.tap(find.byKey(const ValueKey('opt-addon-plus-Cheese slices')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('opt-addon-plus-Cheese slices')));
      await t.pump();
      expect(find.byKey(const ValueKey('opt-addon-qty-Cheese slices')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('opt-addon-check-Mayo')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('opt-combo-fries & Cole')));
      await t.pump();
      expect(find.text('Add · ₹634'), findsOneWidget, reason: '199 + 2 × 50 + 10 + 325');
      await t.tap(find.byKey(const ValueKey('opt-add')));
      await t.pumpAndSettle();
      expect(find.textContaining('2 × Cheese slices · Mayo · fries & Cole (combo)'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('total-so-far'))).data, '₹634');
      await t.tap(find.byKey(const ValueKey('send-to-kitchen')));
      await t.pumpAndSettle();
      final line = (argsOf(f.calls('tbl_order_add').single)['lines'] as List).single as Map;
      expect(line['menu_item_id'], naan);
      expect(line['qty'], 1);
      expect(line['addons'], unorderedEquals(['a-cheese', 'a-cheese', 'a-mayo']));
      expect(line['combos'], ['c1']);
    });

    testWidgets('Send to kitchen sends the dishes once, with a key, and shows the KOT (Figma 18:467)', (t) async {
      final f = freeTable();
      await showPushed(t, AddDishesScreen(env: f.env, tableId: table4, tableLabel: 'Table 4'));
      await t.tap(find.byKey(const ValueKey('plus-$naan')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('send-to-kitchen')));
      await t.pumpAndSettle();
      final r = f.calls('tbl_order_add').single;
      expect(argsOf(r)['table_id'], table4);
      expect(argsOf(r)['send'], true);
      expect(argsOf(r)['lines'], [{'menu_item_id': naan, 'qty': 1}]);
      expect(r.headers['Idempotency-Key'] ?? r.headers['idempotency-key'], isNotNull);
      expect(find.text('KOT #1 sent'), findsOneWidget);
      expect(find.text('3 items. The kitchen screen shows it now.'), findsOneWidget);
      expect(find.text('Main Kitchen'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('back-to-tables')));
      await t.pumpAndSettle();
      expect(find.text('tables'), findsOneWidget);
    });

    testWidgets('a failed send is retried with the same key (never two orders)', (t) async {
      var first = true;
      final f = freeTable((r) {
        if (fnOf(r) == 'tbl_order_add' && first) {
          first = false;
          return err(503, 'Could not reach the server.');
        }
        return null;
      });
      await show(t, AddDishesScreen(env: f.env, tableId: table4, tableLabel: 'Table 4'));
      await t.tap(find.byKey(const ValueKey('plus-$naan')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('send-to-kitchen')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('send-to-kitchen')));
      await t.pumpAndSettle();
      final keys = f.calls('tbl_order_add').map((r) => r.headers['Idempotency-Key'] ?? r.headers['idempotency-key']).toList();
      expect(keys, hasLength(2));
      expect(keys[0], keys[1]);
    });

    testWidgets('Save and hold sends send=false and goes back to the tables', (t) async {
      final f = freeTable();
      await showPushed(t, AddDishesScreen(env: f.env, tableId: table4, tableLabel: 'Table 4'));
      await t.tap(find.byKey(const ValueKey('plus-$naan')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('save-and-hold')));
      await t.pumpAndSettle();
      expect(argsOf(f.calls('tbl_order_add').single)['send'], false);
      expect(find.text('tables'), findsOneWidget);
      expect(toast('Saved on Table 4. Send to the kitchen when ready.'), findsOneWidget);
    });

    testWidgets('nothing chosen: Send to kitchen is off', (t) async {
      await show(t, AddDishesScreen(env: freeTable().env, tableId: table4, tableLabel: 'Table 4'));
      await t.tap(find.byKey(const ValueKey('send-to-kitchen')));
      await t.pumpAndSettle();
      expect(find.text('KOT #1 sent'), findsNothing);
    });
  });

  group('the table order screen', () {
    testWidgets('Add Items opens Add dishes; Send KOT sends the held dishes as a new KOT', (t) async {
      final f = Fake();
      await show(t, TableOrderScreen(env: f.env, tableId: table4));
      expect(t.widget<Opacity>(find.ancestor(of: find.text('Send KOT'), matching: find.byType(Opacity)).first).opacity, 1, reason: 'held dishes: Send KOT is on');
      await t.tap(find.text('Send KOT'));
      await t.pumpAndSettle();
      expect(f.calls('tbl_kot_send').single.headers['Idempotency-Key'] ?? f.calls('tbl_kot_send').single.headers['idempotency-key'], isNotNull);
      expect(find.text('KOT #2 sent'), findsOneWidget);
      expect(find.text('1 item. The kitchen screen shows it now.'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('back-to-tables')));
      await t.pumpAndSettle();
      await t.tap(find.text('Add Items'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('send-to-kitchen')), findsOneWidget);
    });
  });

  group('Ready to serve (Figma 18:556)', () {
    testWidgets('ready dishes first, then the ones still in the kitchen; Mark as served sends the ready ones', (t) async {
      final f = Fake();
      await show(t, ReadyToServeScreen(env: f.env));
      expect(find.text('Table 4 · Paneer Tikka'), findsOneWidget);
      expect(find.text('KOT #1 · Main Kitchen'), findsNWidgets(3));
      expect(find.text('Ready'), findsNWidgets(3));
      expect(find.text('Waiting'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('mark-served')));
      await t.pumpAndSettle();
      final ids = (argsOf(f.calls('tbl_mark_served').single)['item_ids'] as List).cast<String>();
      final ready = [for (final i in (fx['ready'] as Map)['items'] as List) if ((i as Map)['status'] == 'ready') i['item_id']];
      expect(ids, ready);
      expect(toast('3 dishes served.'), findsOneWidget);
    });

    testWidgets('a second tap is harmless: the server says already served', (t) async {
      final f = Fake((r) => fnOf(r) == 'tbl_mark_served' ? ok(fx['served_again']) : null);
      await show(t, ReadyToServeScreen(env: f.env));
      await t.tap(find.byKey(const ValueKey('mark-served')));
      await t.pumpAndSettle();
      expect(toast('Already served.'), findsOneWidget);
    });

    testWidgets('everything on the table served: offer the bill and open the table order', (t) async {
      final f = Fake((r) => fnOf(r) == 'tbl_mark_served' ? ok(fx['served_all']) : null);
      await show(t, ReadyToServeScreen(env: f.env));
      await t.tap(find.byKey(const ValueKey('mark-served')));
      await t.pumpAndSettle();
      expect(find.text('Table 4: everything served'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('open-bill')));
      await t.pumpAndSettle();
      expect(find.byType(TableOrderScreen), findsOneWidget);
      expect(find.text('Generate Bill'), findsOneWidget);
    });

    testWidgets('nothing ready: Mark as served is off and nothing is sent', (t) async {
      final noneReady = {...(fx['ready'] as Map<String, dynamic>), 'items': [for (final i in (fx['ready'] as Map)['items'] as List) if ((i as Map)['status'] != 'ready') i], 'ready_count': 0};
      final f = Fake((r) => fnOf(r) == 'tbl_ready_list' ? ok(noneReady) : null);
      await show(t, ReadyToServeScreen(env: f.env));
      await t.tap(find.byKey(const ValueKey('mark-served')));
      await t.pumpAndSettle();
      expect(f.calls('tbl_mark_served'), isEmpty);
    });
  });
}
