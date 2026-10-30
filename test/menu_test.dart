import 'dart:convert';

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/catalogue/item_photo.dart';
import 'package:vinii_pos/home/control_centre_screen.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/menu/dish_screen.dart';
import 'package:vinii_pos/menu/menu_api.dart';
import 'package:vinii_pos/menu/menu_build_api.dart';
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
  late final _client = MockClient((r) async {
    final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
    final fn = r.url.pathSegments.last;
    calls.add((fn, body));
    return answer(fn, body);
  });
  late final api = MenuApi(baseUrl: 'http://pos.test', accessToken: () => 'token-123', client: _client);
  // The Menu module calls (add-ons, combos, quick add, settings) through the same fake.
  late final build = MenuBuildApi(baseUrl: 'http://pos.test', accessToken: () => 'token-123', client: _client);
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
      // The banner every main tab shows (ONELOCAL PARTNER over the business / outlet), then the two tabs.
      // laid out like the store catalogue: category pills (All first), then compact rows (name, "Category · Veg", availability, price, ⋮)
      for (final l in ['ONELOCAL PARTNER', 'All items', 'Add-ons', 'Combos', 'All', 'Hot Cafe', 'Burgers',
          'Americano ( Large )', '₹125', 'Quick add']) {
        expect(find.text(l), findsWidgets, reason: l);
      }
      expect(find.byKey(const ValueKey('cat-pill-all')), findsOneWidget);
      expect(find.byKey(const ValueKey('cat-pill-Hot Cafe')), findsOneWidget);
      expect(find.textContaining('Hot Cafe · Veg · 2 Variants'), findsOneWidget);
      expect(find.textContaining('Available'), findsWidgets);
      expect(find.textContaining('Out of stock', findRichText: true), findsWidgets);
      expect(find.byKey(const ValueKey('more-d1')), findsOneWidget, reason: 'every row has ⋮ for its actions');
      expect(find.byKey(const ValueKey('menu-quick-add')), findsOneWidget, reason: 'Quick add sits beside the search');
      expect(find.byType(FloatingActionButton), findsNothing, reason: 'no floating ADD over the bottom bar');
      for (final moved in ['RECOMMENDED IMPROVEMENTS', 'Add images to items', 'Add descriptions']) {
        expect(find.text(moved), findsNothing, reason: '$moved now lives in the Notification Centre');
      }
      for (final gone in ['chip-out_of_stock', 'chip-in_stock', 'chip-needs_image']) {
        expect(find.byKey(ValueKey(gone)), findsNothing, reason: 'no stock filter pills: stock shows as tags');
      }
      expect(find.byKey(const ValueKey('tag-out-d3')), findsOneWidget, reason: 'the switched-off burger: red Out of stock beside its row');
      expect(find.byKey(const ValueKey('tag-out-d1')), findsNothing);
      expect(find.byKey(const ValueKey('menu-filter-clear')), findsNothing, reason: 'no filter, no pill');
      expect(g.calls.map((c) => c.$1), ['rst_menu']);
      expect(g.calls.single.$2, {'filter': 'all'});
    });

    testWidgets('top left is ☰ (opens the side menu), not a back arrow', (t) async {
      var opened = 0;
      HomeNav.openMenu = (_) => opened++;
      final g = FakeGateway((fn, b) => json(menuJson()));
      await showScreen(t, MenuScreen(api: g.api));
      expect(find.byIcon(LucideIcons.chevronLeft), findsNothing);
      await t.tap(find.byKey(const ValueKey('menu-side-nav')));
      await t.pump();
      expect(opened, 1);
    });

    testWidgets('subcategories sit under their main pill: picking it shows a second row, and each subcategory filters its dishes', (t) async {
      final m = jsonDecode(jsonEncode(menuJson())) as Map<String, dynamic>;
      final cats = (m['categories'] as List).cast<Map<String, dynamic>>();
      // Burgers becomes a subcategory of Hot Cafe, and a second one, Iced, lives under a main category with no dishes of its own
      cats[1]
        ..['parent_id'] = 'c1'
        ..['parent_name'] = 'Hot Cafe';
      cats.add({
        'id': 'c3', 'name': 'Iced', 'count': 1, 'all_in_stock': true, 'parent_id': 'c9', 'parent_name': 'Cold drinks',
        'items': [{'id': 'd4', 'name': 'Iced Latte', 'price_minor': 18000, 'food_type': 'veg', 'in_stock': true, 'variants': 0, 'has_windows': false, 'orderable_now': true}],
      });
      final g = FakeGateway((fn, b) => json(m));
      await showScreen(t, MenuScreen(api: g.api, buildApi: g.build));
      expect(find.byKey(const ValueKey('cat-pill-Burgers')), findsNothing, reason: 'a subcategory has no main pill');
      expect(find.byKey(const ValueKey('cat-pill-Cold drinks')), findsOneWidget, reason: 'a main category holding only subcategories still has its pill');
      expect(find.byKey(const ValueKey('menu-categories')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('cat-pill-Hot Cafe')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('sub-pill-all')), findsOneWidget);
      expect(find.text('Veg Burger'), findsOneWidget, reason: 'the main pill shows its subcategories\' dishes too');
      expect(find.text('Cappuccino'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('sub-pill-Burgers')));
      await t.pumpAndSettle();
      expect(find.text('Veg Burger'), findsOneWidget);
      expect(find.text('Cappuccino'), findsNothing);
      await t.tap(find.byKey(const ValueKey('cat-pill-Cold drinks')));
      await t.pumpAndSettle();
      expect(find.text('Iced Latte'), findsOneWidget);
      expect(find.byKey(const ValueKey('sub-pill-Iced')), findsOneWidget);
    });

    testWidgets('a filter asked for elsewhere (Notification Centre "Add images") opens the menu on it, once', (t) async {
      MenuScreen.requestedFilter.value = 'needs_image';
      final g = FakeGateway((fn, b) => json(menuJson()));
      await showScreen(t, MenuScreen(api: g.api, buildApi: g.build));
      expect(g.bodies('rst_menu').first, containsPair('filter', 'needs_image'));
      expect(MenuScreen.requestedFilter.value, isNull, reason: 'applied once, then cleared');
      // asked again while the menu is open
      MenuScreen.requestedFilter.value = 'out_of_stock';
      await t.pumpAndSettle();
      expect(g.bodies('rst_menu').last, containsPair('filter', 'out_of_stock'));
    });

    testWidgets('stock tags beside Available: orange "Low in stock", red "Out of stock" from the ingredients, say which one', (t) async {
      final g = FakeGateway((fn, b) => switch (fn) {
            'menu_stock_signals' => json({'items': [
                {'menu_item_id': 'd1', 'state': 'low', 'ingredient': 'Espresso coffee beans'},
                {'menu_item_id': 'd2', 'state': 'out', 'ingredient': 'Full cream milk'},
              ]}),
            _ => json(menuJson(burgerInStock: true)),
          });
      await showScreen(t, MenuScreen(api: g.api, buildApi: g.build));
      expect(find.byKey(const ValueKey('tag-low-d1')), findsOneWidget);
      expect(find.byKey(const ValueKey('tag-out-d2')), findsOneWidget);
      expect(find.byKey(const ValueKey('tag-out-d3')), findsNothing, reason: 'the burger is in stock and stock says nothing about it');
      expect(find.text('Low in stock'), findsOneWidget);
      expect(find.text('Out of stock'), findsOneWidget);
      final low = t.widget<Text>(find.text('Low in stock'));
      final out = t.widget<Text>(find.text('Out of stock'));
      expect(low.style!.color, const Color(0xFFC2410C), reason: 'orange');
      expect(out.style!.color, const Color(0xFFB42318), reason: 'red');
      expect(find.byTooltip('Espresso coffee beans is running low'), findsOneWidget);
      expect(find.byTooltip('Full cream milk has run out'), findsOneWidget);
      expect(find.textContaining('Available'), findsNWidgets(3), reason: 'Available stays, the tag sits beside it');
    });

    testWidgets('a beverage with sizes shows Small, Medium and Large with their prices', (t) async {
      final m = menuJson();
      ((m['categories'] as List).first['items'] as List).first['sizes'] = [
        {'name': 'Small', 'price': 69, 'recipe_factor': 1},
        {'name': 'Medium', 'price': 89, 'recipe_factor': 2},
        {'name': 'Large', 'price': 109, 'recipe_factor': 3},
      ];
      // 100 Smalls can be made: Medium uses the recipe twice (50), Large three times (33)
      final g = FakeGateway((fn, b) => fn == 'menu_stock_signals' ? json({'items': [], 'can_make': [{'menu_item_id': 'd1', 'can_make': 100}]}) : json(m));
      await showScreen(t, MenuScreen(api: g.api, buildApi: g.build));
      final sizes = find.byKey(const ValueKey('sizes-d1'));
      expect(sizes, findsOneWidget);
      // one quiet line (founder, 29 Oct 2026), not a chip per size; how many can be made shows once, for the smallest
      expect(t.widget<Text>(sizes).data, 'S ₹69  ·  M ₹89  ·  L ₹109');
      expect(find.byKey(const ValueKey('sizes-d2')), findsNothing, reason: 'a dish without sizes shows none');
    });

    testWidgets('each dish says how many can be made from its recipe and stock, or that it has no recipe', (t) async {
      final g = FakeGateway((fn, b) => switch (fn) {
            'menu_stock_signals' => json({'items': [], 'can_make': [
                {'menu_item_id': 'd1', 'can_make': 200},
                {'menu_item_id': 'd2', 'can_make': null},
              ]}),
            _ => json(menuJson(burgerInStock: true)),
          });
      await showScreen(t, MenuScreen(api: g.api, buildApi: g.build));
      expect(find.descendant(of: find.byKey(const ValueKey('can-make-d1')), matching: find.text('200 can be made')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('can-make-d2')), matching: find.text('Stock not counted')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('can-make-d3')), matching: find.text('No recipe yet')), findsOneWidget);
    });

    testWidgets('a filter set elsewhere shows as one "Showing" pill that clears it; the stock switches go to the server', (t) async {
      var on = false;
      final g = FakeGateway((fn, b) {
        if (fn == 'rst_menu_stock_set') on = b['in_stock'] as bool;
        return fn == 'rst_menu' ? json(menuJson(burgerInStock: on)) : json({'updated': 1, 'in_stock': on});
      });
      MenuScreen.requestedFilter.value = 'needs_image';
      await showScreen(t, MenuScreen(api: g.api));
      expect(g.bodies('rst_menu').last, {'filter': 'needs_image'});
      expect(find.text('Showing: Needs image'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('menu-filter-clear')));
      await t.pumpAndSettle();
      expect(g.bodies('rst_menu').last, {'filter': 'all'});
      expect(find.byKey(const ValueKey('menu-filter-clear')), findsNothing);

      // one dish: ⋮ → Mark in stock
      await t.tap(find.byKey(const ValueKey('more-d3')));
      await t.pumpAndSettle();
      expect(find.text('Mark in stock'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('stock-d3')));
      await t.pumpAndSettle();
      expect(g.bodies('rst_menu_stock_set').single, {'id': 'd3', 'in_stock': true});

      // a whole category: choose its pill, then its switch
      await t.tap(find.byKey(const ValueKey('cat-pill-Burgers')));
      await t.pumpAndSettle();
      expect(find.text('Burgers (1) · All items in stock'), findsOneWidget);
      expect(find.text('Americano ( Large )'), findsNothing, reason: 'only the chosen category is listed');
      expect(t.widget<Switch>(find.byKey(const ValueKey('cat-switch-Burgers'))).value, isTrue, reason: 'redrawn from the server');

      await t.tap(find.byKey(const ValueKey('cat-pill-Hot Cafe')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cat-switch-Hot Cafe')));
      await t.pumpAndSettle();
      expect(g.bodies('rst_menu_stock_set').last, {'category_id': 'c1', 'in_stock': false});

      await t.tap(find.byKey(const ValueKey('cat-pill-all')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('cat-switch-Hot Cafe')), findsNothing, reason: 'All lists every dish without a category switch');
    });

    testWidgets('View details opens the dish screen; the Add-ons tab lists the add-on groups from the server', (t) async {
      final g = FakeGateway((fn, b) => switch (fn) {
            'rst_menu' => json(menuJson()),
            'menu_addon_list' => json({'groups': []}),
            _ => json(dishJson(description: 'Coffee shot with hot water')),
          });
      await showScreen(t, MenuScreen(api: g.api, buildApi: g.build));
      await t.tap(find.byKey(const ValueKey('more-d1')));
      await t.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('view-d1')));
      await t.pumpAndSettle();
      expect(find.text('Dish details'), findsOneWidget);
      expect(find.text('Ingredients'), findsOneWidget);
      expect(find.text('Coffee shot'), findsOneWidget);
      expect(g.bodies('rst_menu_item_view').single, {'id': 'd1', 'location_id': 'l1'});
      await t.tap(find.byKey(const ValueKey('dish-back')));
      await t.pumpAndSettle();
      await t.tap(find.text('Add-ons'));
      await t.pumpAndSettle();
      expect(g.calls.map((c) => c.$1), contains('menu_addon_list'));
      expect(find.text('No add-ons yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('addon-new')), findsOneWidget);
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

  group('AI picture (with / without background)', () {
    // a real 1×1 PNG, so the previews draw
    final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');
    Map<String, dynamic> withPhoto() {
      final m = menuJson();
      ((m['categories'] as List).first['items'] as List).first['image_url'] = 'http://img.test/americano.jpg';
      return m;
    }

    testWidgets('⋮ → AI picture: With background sends the cream backdrop, Use this picture saves it on the dish and reloads', (t) async {
      final photos = _FakeAiPhotos(png);
      final g = FakeGateway((fn, b) => json(withPhoto()));
      await showScreen(t, MenuScreen(api: g.api, buildApi: g.build, photos: photos));
      await t.tap(find.byKey(const ValueKey('more-d1')));
      await t.pumpAndSettle();
      expect(find.text('With or without background'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ai-photo-d1')));
      await t.pumpAndSettle();
      expect(find.text('AI picture · Americano ( Large )'), findsOneWidget);
      expect(find.text('With background'), findsOneWidget);
      expect(find.text('Without background'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ai-with-bg')));
      await t.pumpAndSettle();
      expect(photos.loaded, ['http://img.test/americano.jpg'], reason: 'works on the dish\'s own photo');
      expect(photos.bg, ['f6efe2']);
      expect(find.byKey(const ValueKey('ai-result')), findsOneWidget);
      final before = g.calls.where((c) => c.$1 == 'rst_menu').length;
      await t.tap(find.byKey(const ValueKey('ai-use')));
      await t.pumpAndSettle();
      expect(photos.attached.single.$1, 'd1');
      expect(photos.attached.single.$2.contentType, 'image/jpeg');
      expect(find.byKey(const ValueKey('ai-result')), findsNothing, reason: 'the sheet closes');
      expect(g.calls.where((c) => c.$1 == 'rst_menu').length, greaterThan(before), reason: 'the menu reloads with the new photo');
    });

    testWidgets('Without background asks for a transparent cut-out; nothing is saved until Use this picture', (t) async {
      final photos = _FakeAiPhotos(png);
      final g = FakeGateway((fn, b) => json(withPhoto()));
      await showScreen(t, MenuScreen(api: g.api, buildApi: g.build, photos: photos));
      await t.tap(find.byKey(const ValueKey('more-d1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ai-photo-d1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ai-without-bg')));
      await t.pumpAndSettle();
      expect(photos.bg, [null]);
      expect(find.textContaining('Background removed'), findsOneWidget);
      expect(photos.attached, isEmpty);
    });

    testWidgets('the server\'s sentence is shown when background removal is not set up', (t) async {
      final photos = _FakeAiPhotos(png, refuse: 'Background removal is not set up yet. Your photo is kept as it is.');
      final g = FakeGateway((fn, b) => json(withPhoto()));
      await showScreen(t, MenuScreen(api: g.api, buildApi: g.build, photos: photos));
      await t.tap(find.byKey(const ValueKey('more-d1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ai-photo-d1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ai-with-bg')));
      await t.pumpAndSettle();
      expect(find.text('Background removal is not set up yet. Your photo is kept as it is.'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-use')), findsNothing);
    });

    testWidgets('a dish with no photo asks for one first; a chosen photo is what the AI works on', (t) async {
      final photos = _FakeAiPhotos(png);
      final g = FakeGateway((fn, b) => json(menuJson()));
      await showScreen(t, MenuScreen(api: g.api, buildApi: g.build, photos: photos));
      await t.tap(find.byKey(const ValueKey('more-d2')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ai-photo-d2')));
      await t.pumpAndSettle();
      expect(find.text('Choose a photo'), findsOneWidget);
      expect(t.widget<OutlinedButton>(find.byKey(const ValueKey('ai-with-bg'))).onPressed, isNull);
      await t.tap(find.byKey(const ValueKey('ai-pick')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ai-without-bg')));
      await t.pumpAndSettle();
      expect(photos.loaded, isEmpty);
      expect(photos.bg, [null]);
    });
  });
}

class _FakeAiPhotos extends ItemPhotoService {
  _FakeAiPhotos(this.png, {this.refuse});
  final List<int> png;
  final String? refuse;
  final loaded = <String>[];
  final bg = <String?>[];
  final attached = <(String, ItemPhoto)>[];
  ItemPhoto get _p => ItemPhoto(bytes: Uint8List.fromList(png), contentType: 'image/png');
  @override
  Future<ItemPhoto?> pick() async => _p;
  @override
  Future<ItemPhoto> load(String url) async {
    loaded.add(url);
    return _p;
  }
  @override
  Future<ItemPhoto> removeBackground(ItemPhoto photo, {String? bgColor}) async {
    bg.add(bgColor);
    if (refuse != null) throw ItemPhotoUnavailable(refuse!);
    return ItemPhoto(bytes: photo.bytes, contentType: bgColor == null ? 'image/png' : 'image/jpeg', backgroundRemoved: true);
  }
  @override
  Future<void> attach(String itemId, ItemPhoto photo) async => attached.add((itemId, photo));
  @override
  Future<void> remove(String itemId) async {}
}
