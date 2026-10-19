import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/home/control_centre_screen.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/menu/dish_screen.dart';
import 'package:vinii_pos/menu/menu_api.dart';
import 'package:vinii_pos/menu/menu_screen.dart';

import 'home_test.dart' show FakeHome, summaryJson, showTall;
import 'restaurant_dashboard_test.dart' show FakeRst, dash, ok;

const _json = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic> menuJson({bool burgerInStock = false}) => {
      'location': {'id': 'l1', 'name': 'Niks Browni And Burger'},
      'outlets': [
        {'id': 'l1', 'name': 'Niks Browni And Burger'},
      ],
      'can_edit': true,
      'counts': {'total': 3, 'in_stock': burgerInStock ? 3 : 2, 'out_of_stock': burgerInStock ? 0 : 1, 'needs_image': 2, 'with_image': 1, 'missing_description': 2},
      'categories': [
        {
          'id': 'c1',
          'name': 'Hot Cafe',
          'count': 2,
          'all_in_stock': true,
          'items': [
            {'id': 'd1', 'name': 'Americano ( Large )', 'price_minor': 12500, 'description': 'Coffee shot with hot water', 'food_type': 'veg', 'in_stock': true, 'variants': 0, 'has_windows': false, 'orderable_now': true},
            {'id': 'd2', 'name': 'Cappuccino', 'price_minor': 13900, 'description': null, 'food_type': 'veg', 'in_stock': true, 'variants': 2, 'has_windows': false, 'orderable_now': true},
          ],
        },
        {
          'id': 'c2',
          'name': 'Burgers',
          'count': 1,
          'all_in_stock': burgerInStock,
          'items': [
            {'id': 'd3', 'name': 'Veg Burger', 'price_minor': 15000, 'description': null, 'food_type': 'veg', 'in_stock': burgerInStock, 'variants': 0, 'has_windows': true, 'orderable_now': false},
          ],
        },
      ],
    };

Map<String, dynamic> dishJson({String description = '', List<Map<String, dynamic>> availability = const [], int version = 7, bool canEdit = true}) => {
      'id': 'd1',
      'name': 'Americano ( Large )',
      'price_minor': 12500,
      'description': description,
      'food_type': 'veg',
      'images': <String>[],
      'in_stock': true,
      'orderable_now': true,
      'can_edit': canEdit,
      'version': version,
      'location_id': 'l1',
      'category': {'id': 'c1', 'name': 'Hot Cafe'},
      'ingredients': [
        {'name': 'Coffee shot', 'qty': 30, 'unit': 'ml'},
        {'name': 'Hot water', 'qty': 200, 'unit': 'ml'},
      ],
      'variants': <Map<String, dynamic>>[],
      'availability': availability,
      'channels': {'status': 'coming_soon'},
    };

/// A fake gateway: answers by function name and records every call.
class FakeGateway {
  FakeGateway(this.answer);
  final http.Response Function(String fn, Map<String, dynamic> body) answer;
  final calls = <(String, Map<String, dynamic>)>[];
  late final api = MenuApi(
    baseUrl: 'http://pos.test',
    accessToken: () => 'token-123',
    client: MockClient((r) async {
      final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      final fn = r.url.pathSegments.last;
      calls.add((fn, body));
      return answer(fn, body);
    }),
  );
  List<Map<String, dynamic>> bodies(String fn) => [for (final c in calls) if (c.$1 == fn) c.$2];
}

http.Response json(Object j, [int status = 200]) => http.Response(jsonEncode(j), status, headers: _json);

Future<void> showScreen(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(900, 4200);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: w));
  await t.pumpAndSettle();
}

/// The dish screen with a gateway whose save echoes the sent description / windows back (as the database would).
FakeGateway dishGateway({http.Response Function()? ai, String description = ''}) => FakeGateway((fn, b) => switch (fn) {
      'rst_menu_item_view' => json(dishJson(description: description)),
      'menu_ai_describe' => ai!(),
      'rst_menu_item_save' => json(dishJson(
          version: 8,
          description: (b['description'] ?? '') as String,
          availability: [
            for (final w in (b['availability'] as List? ?? const []).cast<Map>())
              switch (w['slot']) {
                'morning' => {'slot': 'morning', 'starts_at': '06:00', 'ends_at': '12:00', 'days': null},
                'evening' => {'slot': 'evening', 'starts_at': '16:00', 'ends_at': '20:00', 'days': null},
                'night' => {'slot': 'night', 'starts_at': '20:00', 'ends_at': '24:00', 'days': null},
                _ => {'slot': 'custom', 'starts_at': w['starts_at'], 'ends_at': w['ends_at'], 'days': null},
              },
          ])),
      _ => json({'detail': 'Not found'}, 404),
    });

TextField descField(WidgetTester t) => t.widget<TextField>(find.byKey(const ValueKey('dish-description')));

void main() {
  setUp(HomeNav.reset);

  group('dish detail: Write with AI', () {
    testWidgets('AI not configured: the screen says so and manual writing still saves', (t) async {
      final g = dishGateway(ai: () => json({'detail': 'AI writing is not set up yet.', 'code': 'ai_not_configured'}, 503));
      await showScreen(t, DishScreen(api: g.api, dishId: 'd1', locationId: 'l1'));
      expect(find.text('Description'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('dish-description')), 'coffee shot, hot water');
      await t.tap(find.byKey(const ValueKey('dish-ai')));
      await t.pumpAndSettle();
      expect(find.text('AI writing is not set up yet. You can still write the description yourself.'), findsOneWidget);
      expect(descField(t).controller!.text, 'coffee shot, hot water', reason: 'the owner\'s text is kept');
      expect(g.bodies('menu_ai_describe').single, {'item_id': 'd1', 'notes': 'coffee shot, hot water'});
      expect(g.bodies('rst_menu_item_save'), isEmpty, reason: 'nothing is saved by the AI step');

      await t.enterText(find.byKey(const ValueKey('dish-description')), 'Bold espresso topped with hot water.');
      await t.tap(find.byKey(const ValueKey('dish-save')));
      await t.pumpAndSettle();
      final save = g.bodies('rst_menu_item_save').single;
      expect(save['description'], 'Bold espresso topped with hot water.');
      expect(save['version'], 7);
      expect(find.text('Saved'), findsOneWidget);
    });

    testWidgets('AI result accepted: the draft fills the box, the owner edits it, Save sends the edited text', (t) async {
      final g = dishGateway(ai: () => json({'text': 'A bold shot of espresso topped with hot water.', 'model': 'claude-opus-5-5'}));
      await showScreen(t, DishScreen(api: g.api, dishId: 'd1'));
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('dish-save'))).onPressed, isNull, reason: 'nothing to save yet');
      await t.tap(find.byKey(const ValueKey('dish-ai')));
      await t.pumpAndSettle();
      expect(descField(t).controller!.text, 'A bold shot of espresso topped with hot water.');
      expect(find.text('AI draft. Read it, change anything, then tap Save.'), findsOneWidget);
      expect(find.text('Write again'), findsOneWidget);
      expect(g.bodies('rst_menu_item_save'), isEmpty, reason: 'an AI draft is never saved on its own');

      await t.enterText(find.byKey(const ValueKey('dish-description')), 'A bold shot of espresso topped with hot water. Served large.');
      await t.tap(find.byKey(const ValueKey('dish-save')));
      await t.pumpAndSettle();
      expect(g.bodies('rst_menu_item_save').single['description'], 'A bold shot of espresso topped with hot water. Served large.');
      expect(find.text('AI draft. Read it, change anything, then tap Save.'), findsNothing);
      expect(descField(t).controller!.text, 'A bold shot of espresso topped with hot water. Served large.', reason: 'shown from the saved dish');
    });

    testWidgets('a saved description shows right away next time', (t) async {
      final g = dishGateway(description: 'Coffee shot with hot water');
      await showScreen(t, DishScreen(api: g.api, dishId: 'd1'));
      expect(descField(t).controller!.text, 'Coffee shot with hot water');
    });

    testWidgets('a role that cannot edit sees no Write with AI and no Save', (t) async {
      final g = FakeGateway((fn, b) => json(dishJson(canEdit: false, description: 'x')));
      await showScreen(t, DishScreen(api: g.api, dishId: 'd1'));
      expect(find.byKey(const ValueKey('dish-ai')), findsNothing);
      expect(find.byKey(const ValueKey('dish-save')), findsNothing);
      expect(descField(t).enabled, isFalse);
    });
  });

  group('dish detail: Select availability', () {
    testWidgets('Morning, Night and a Custom time are sent; preset times are the database\'s', (t) async {
      final g = dishGateway();
      await showScreen(t, DishScreen(api: g.api, dishId: 'd1'));
      expect(find.text('Select availability'), findsOneWidget);
      expect(find.text('Select Unavailable Duration'), findsNothing);
      for (final l in ['Morning', 'Evening', 'Night', 'Custom', '06:00 – 12:00', '16:00 – 20:00', '20:00 – 24:00']) {
        expect(find.text(l), findsOneWidget, reason: l);
      }
      expect(find.text('Afternoon'), findsNothing, reason: 'not in the founder\'s list (open question)');
      expect(find.text('Orderable all day. Choose times to sell it only then.'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('slot-morning')));
      await t.tap(find.byKey(const ValueKey('slot-night')));
      await t.pumpAndSettle();
      expect(find.text('Orderable only inside the chosen times.'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('slot-custom')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('custom-start')));
      await t.pumpAndSettle();
      await t.tap(find.text('22:30').last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('custom-end')));
      await t.pumpAndSettle();
      await t.tap(find.text('02:00').last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('custom-add')));
      await t.pumpAndSettle();
      expect(find.text('Custom 22:30 – 02:00'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('dish-save')));
      await t.pumpAndSettle();
      expect(g.bodies('rst_menu_item_save').single['availability'], [
        {'slot': 'morning'},
        {'slot': 'night'},
        {'slot': 'custom', 'starts_at': '22:30', 'ends_at': '02:00'},
      ]);
      expect(find.text('Custom 22:30 – 02:00'), findsOneWidget, reason: 'drawn from the saved windows');
    });

    testWidgets('removing every window sends an empty list (all day again)', (t) async {
      final g = FakeGateway((fn, b) => switch (fn) {
            'rst_menu_item_view' => json(dishJson(availability: [
                {'slot': 'evening', 'starts_at': '16:00', 'ends_at': '20:00', 'days': null},
              ])),
            _ => json(dishJson(version: 8)),
          });
      await showScreen(t, DishScreen(api: g.api, dishId: 'd1'));
      expect(find.text('Orderable only inside the chosen times.'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('slot-evening')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('dish-save')));
      await t.pumpAndSettle();
      expect(g.bodies('rst_menu_item_save').single['availability'], isEmpty);
    });

    testWidgets('a stale version is explained, not overwritten', (t) async {
      final g = FakeGateway((fn, b) => switch (fn) {
            'rst_menu_item_view' => json(dishJson()),
            _ => json({'detail': 'This dish was changed on another device.', 'code': 'version_conflict'}, 409),
          });
      await showScreen(t, DishScreen(api: g.api, dishId: 'd1'));
      await t.tap(find.byKey(const ValueKey('slot-morning')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('dish-save')));
      await t.pumpAndSettle();
      expect(find.text('This dish was changed on another device. Pull down to load the latest.'), findsOneWidget);
    });
  });

  group('dish detail: Apply to Channels', () {
    testWidgets('shown greyed with Coming soon; the switches do nothing and send nothing', (t) async {
      final g = dishGateway();
      await showScreen(t, DishScreen(api: g.api, dishId: 'd1'));
      expect(find.text('Apply to Channels'), findsOneWidget);
      expect(find.text('Coming soon'), findsOneWidget);
      for (final c in ['All Channels', 'Zomato only', 'Swiggy only', 'Dine-in QR']) {
        final s = t.widget<Switch>(find.byKey(ValueKey('channel-$c')));
        expect(s.onChanged, isNull, reason: c);
        expect(s.value, isFalse);
      }
      await t.tap(find.byKey(const ValueKey('channel-Zomato only')), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(g.calls.map((c) => c.$1), ['rst_menu_item_view']);
      expect(t.widget<Opacity>(find.byKey(const ValueKey('channels-coming-soon'))).opacity, lessThan(1));
    });
  });

  group('menu list', () {
    testWidgets('header, tabs, chips with server counts, categories, dish cards', (t) async {
      final g = FakeGateway((fn, b) => json(menuJson()));
      await showScreen(t, MenuScreen(api: g.api));
      for (final l in ['EDIT MENU FOR', 'Niks Browni And Burger', 'All items', 'Add ons', 'Out of stock 1', 'In stock 2', 'Needs image 2', 'Hot Cafe (2)', 'Burgers (1)',
          'All items in stock', 'Some items out of stock', 'Americano ( Large )', '₹125', 'Coffee shot with hot water', '2 Variants', 'ADD', 'Add images to items', '1/3 items complete']) {
        expect(find.text(l), findsWidgets, reason: l);
      }
      expect(find.text('Serving times set · not orderable now'), findsOneWidget);
      expect(g.calls.map((c) => c.$1), ['rst_menu']);
      expect(g.calls.single.$2, {'filter': 'all'});
    });

    testWidgets('chip filters and the in-stock switches go to the server', (t) async {
      var on = false;
      final g = FakeGateway((fn, b) {
        if (fn == 'rst_menu_stock_set') on = b['in_stock'] as bool;
        return fn == 'rst_menu' ? json(menuJson(burgerInStock: on)) : json({'updated': 1, 'in_stock': on});
      });
      await showScreen(t, MenuScreen(api: g.api));
      await t.tap(find.byKey(const ValueKey('chip-out_of_stock')));
      await t.pumpAndSettle();
      expect(g.bodies('rst_menu').last, {'filter': 'out_of_stock'});
      await t.tap(find.byKey(const ValueKey('chip-out_of_stock')));
      await t.pumpAndSettle();
      expect(g.bodies('rst_menu').last, {'filter': 'all'});

      await t.tap(find.byKey(const ValueKey('stock-d3')));
      await t.pumpAndSettle();
      expect(g.bodies('rst_menu_stock_set').single, {'id': 'd3', 'in_stock': true});
      expect(find.text('Burgers (1)'), findsOneWidget);
      expect(t.widget<Switch>(find.byKey(const ValueKey('cat-switch-Burgers'))).value, isTrue, reason: 'redrawn from the server');

      await t.tap(find.byKey(const ValueKey('cat-switch-Hot Cafe')));
      await t.pumpAndSettle();
      expect(g.bodies('rst_menu_stock_set').last, {'category_id': 'c1', 'in_stock': false});
    });

    testWidgets('View details opens the dish screen; Add ons says it is not set up', (t) async {
      final g = FakeGateway((fn, b) => fn == 'rst_menu' ? json(menuJson()) : json(dishJson(description: 'Coffee shot with hot water')));
      await showScreen(t, MenuScreen(api: g.api));
      await t.tap(find.byKey(const ValueKey('view-d1')));
      await t.pumpAndSettle();
      expect(find.text('Dish details'), findsOneWidget);
      expect(find.text('Ingredients'), findsOneWidget);
      expect(find.text('Coffee shot'), findsOneWidget);
      expect(g.bodies('rst_menu_item_view').single, {'id': 'd1', 'location_id': 'l1'});
      await t.tap(find.byKey(const ValueKey('dish-back')));
      await t.pumpAndSettle();
      await t.tap(find.text('Add ons'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('addons-empty')), findsOneWidget);
    });
  });

  group('restaurant Menu tab', () {
    testWidgets('opens the restaurant menu, not the store catalogue', (t) async {
      final opened = <String>[];
      HomeNav.items = (_) => opened.add('catalogue');
      HomeNav.menu = (_) => opened.add('menu');
      final r = FakeRst((_) => ok(dash()));
      await showTall(t, ControlCentreScreen(api: FakeHome(summary: summaryJson(kind: 'restaurant')), restaurantApi: r.api, now: () => DateTime.utc(2026, 10, 18, 10)));
      await t.tap(find.byKey(const ValueKey('tab-Menu')));
      await t.pumpAndSettle();
      expect(opened, ['menu']);
    });

    testWidgets('a store\'s Item tab still opens the catalogue', (t) async {
      final opened = <String>[];
      HomeNav.items = (_) => opened.add('catalogue');
      HomeNav.menu = (_) => opened.add('menu');
      await showTall(t, ControlCentreScreen(api: FakeHome(summary: summaryJson()), now: () => DateTime.utc(2026, 10, 18, 10)));
      await t.tap(find.byKey(const ValueKey('tab-Item')));
      await t.pumpAndSettle();
      expect(opened, ['catalogue']);
    });
  });
}
