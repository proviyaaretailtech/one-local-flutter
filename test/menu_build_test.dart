import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/catalogue/item_photo.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/menu/categories_screen.dart';
import 'package:vinii_pos/menu/ingredients_screen.dart';
import 'package:vinii_pos/menu/menu_api.dart';
import 'package:vinii_pos/menu/menu_build_api.dart';
import 'package:vinii_pos/menu/menu_build_screens.dart';
import 'package:vinii_pos/menu/menu_build_widgets.dart' show kMbLime;
import 'package:vinii_pos/menu/menu_hub.dart';
import 'package:vinii_pos/menu/price_control_screen.dart';
import 'package:vinii_pos/menu/recipes_screen.dart';
import 'package:vinii_pos/outlets/outlet_header.dart';
import 'package:vinii_pos/outlets/outlet_scope.dart';
import 'package:vinii_pos/ui/app_header.dart';

import 'menu_test.dart' show menuJson;

const _json = {'content-type': 'application/json; charset=utf-8'};
http.Response json(Object j, [int status = 200]) => http.Response(jsonEncode(j), status, headers: _json);

/// One fake gateway for both the menu (`rst_*`) and the menu module (`ing_*`, `rcp_*`, `menu_*`) calls.
class FakeServer {
  FakeServer(this.answer);
  final http.Response Function(String fn, Map<String, dynamic> body) answer;
  final calls = <(String, Map<String, dynamic>)>[];
  late final _client = MockClient((r) async {
    final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
    final fn = r.url.pathSegments.last;
    calls.add((fn, body));
    return answer(fn, body);
  });
  late final menu = MenuApi(baseUrl: 'http://pos.test', accessToken: () => 'token-123', client: _client);
  late final build = MenuBuildApi(baseUrl: 'http://pos.test', accessToken: () => 'token-123', client: _client);
  Map<String, dynamic> last(String fn) => calls.lastWhere((c) => c.$1 == fn).$2;
}

Map<String, dynamic> ingJson({List<Map<String, dynamic>>? items}) => {
      'counts': {'total': (items ?? _ings).length, 'no_cost': 1, 'low': 1},
      'categories': ['Coffee & Tea', 'Dairy'],
      'units': ['kg', 'g', 'l', 'ml', 'pc'],
      'can_edit': true,
      'items': items ?? _ings,
    };

final _ings = [
  {'id': 'i-beans', 'name': 'Espresso coffee beans', 'category': 'Coffee & Tea', 'unit': 'kg', 'cost_minor': 140000, 'cost_source': 'set_by_you', 'on_hand': 2, 'reorder_level': 1, 'low': false, 'used_in': 1},
  {'id': 'i-milk', 'name': 'Full cream milk', 'category': 'Dairy', 'unit': 'l', 'cost_minor': 6800, 'cost_source': 'last_purchase', 'on_hand': 0.5, 'reorder_level': 2, 'low': true, 'used_in': 0,
   'supplier': {'id': 's1', 'name': 'Latur Dairy', 'price_minor': 6600}},
  {'id': 'i-syrup', 'name': 'Hazelnut syrup', 'category': 'Syrups', 'unit': 'l', 'cost_minor': null, 'cost_source': 'none', 'on_hand': 0, 'reorder_level': 0, 'low': false, 'used_in': 0},
];

Map<String, dynamic> recipeJson({List<Map<String, dynamic>> lines = const []}) {
  var cost = 0;
  for (final l in lines) {
    cost += ((l['unit_cost_minor'] as int) * (l['qty'] as num) * (1 + ((l['wastage_pct'] ?? 0) as num) / 100)).round();
  }
  return {
    'menu_item_id': 'd-americano', 'name': 'Americano', 'category': 'Hot Beverages', 'food_type': 'veg', 'price_minor': 6900,
    'lines': lines, 'line_count': lines.length, 'key_count': lines.where((l) => l['is_key'] == true).length, 'missing_cost': 0,
    'cost_minor': cost, 'food_cost_pct': lines.isEmpty ? null : double.parse((cost / 6900 * 100).toStringAsFixed(1)),
    'margin_minor': lines.isEmpty ? null : 6900 - cost, 'margin_pct': lines.isEmpty ? null : double.parse(((6900 - cost) / 6900 * 100).toStringAsFixed(1)),
  };
}

Map<String, dynamic> rcpListJson() => {
      'summary': {'dishes': 2, 'with_recipe': 1, 'without_recipe': 1, 'avg_food_cost_pct': 37.2},
      'items': [
        recipeJson(lines: [
          {'inventory_item_id': 'i-beans', 'name': 'Espresso coffee beans', 'unit': 'kg', 'qty': 0.018, 'wastage_pct': 0, 'is_key': true, 'unit_cost_minor': 140000, 'cost_source': 'set_by_you'},
        ])..remove('lines'),
        {'menu_item_id': 'd-fries', 'name': 'Salted Fries', 'category': 'Fries', 'food_type': 'veg', 'price_minor': 17900, 'line_count': 0, 'key_count': 0, 'missing_cost': 0, 'cost_minor': 0},
      ],
    };

Map<String, dynamic> settingsJson({String name = 'Peri Peri Fries', String category = 'Fries'}) => {
      'id': 'd-new', 'version': 1, 'name': name, 'price_minor': 19900, 'category_id': 'c-fries', 'category': category, 'food_type': 'veg', 'course': 'eat',
      'station': 'main', 'prep_minutes': 10, 'is_recommended': false, 'sku': null, 'addon_group_ids': [],
      'recipe': {'menu_item_id': 'd-new', 'name': name, 'price_minor': 19900, 'line_count': 0, 'cost_minor': 0},
      'categories': [{'id': 'c-hot', 'name': 'Hot Beverages'}, {'id': 'c-fries', 'name': 'Fries'}],
      'addon_groups': [{'id': 'g1', 'name': 'Extra dips', 'addons': 2}],
      'stations': ['main', 'grill', 'beverage'],
    };

Future<void> show(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(780, 3200);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: w));
  await t.pumpAndSettle();
}

void main() {
  categoriesTests();
  setUp(() {
    HomeNav.reset();
    OutletScope.reset();
  });

  group('MenuBuildApi', () {
    test('ingredients, recipe save and quick add go through the gateway with the token; answers parse', () async {
      final s = FakeServer((fn, b) => switch (fn) {
            'ing_list' => json(ingJson()),
            'rcp_save' => json(recipeJson(lines: [
                {'inventory_item_id': 'i-beans', 'name': 'Espresso coffee beans', 'unit': 'kg', 'qty': 0.018, 'wastage_pct': 0, 'is_key': true, 'unit_cost_minor': 140000, 'cost_source': 'set_by_you'},
              ])),
            'menu_item_quick_add' => json(settingsJson()),
            _ => json({}),
          });
      final ings = await s.build.ingredients(q: ' milk ');
      expect(s.last('ing_list'), {'q': 'milk'});
      expect(ings.items, hasLength(3));
      expect(ings.items[1].supplier!['name'], 'Latur Dairy');
      expect(costSourceLabel(ings.items[1].costSource), 'Last purchase');

      final r = await s.build.saveRecipe('d-americano', [DraftLine(ingredientId: 'i-beans', name: 'Espresso coffee beans', unit: 'kg', qty: 0.018, isKey: true, unitCostMinor: 140000)]);
      expect(s.last('rcp_save'), {
        'menu_item_id': 'd-americano',
        'lines': [{'inventory_item_id': 'i-beans', 'qty': 0.018, 'wastage_pct': 0.0, 'is_key': true}],
      });
      expect(r.costMinor, 2520);
      expect(r.foodCostPct, 36.5);
      expect(rupeesMinor(r.costMinor), '₹25.20');

      final d = await s.build.quickAdd(name: 'Peri Peri Fries', category: 'Fries', price: 199);
      expect(s.last('menu_item_quick_add'), {'name': 'Peri Peri Fries', 'category': 'Fries', 'price': 199.0, 'food_type': 'veg', 'course': 'eat'});
      expect(d.addonGroups.single.name, 'Extra dips');
    });

    test('a database refusal keeps its sentence', () async {
      final s = FakeServer((fn, b) => json({'detail': 'Paneer is already in your ingredients', 'code': 'conflict'}, 409));
      expect(() => s.build.saveIngredient(name: 'Paneer', unit: 'kg'), throwsA(isA<MenuApiException>().having((e) => e.message, 'message', 'Paneer is already in your ingredients')));
    });
  });

  group('Menu hub', () {
    testWidgets('opened on top (Price control, Recipe, Ingredients from the side bar): the green banner with the round ← that closes it', (t) async {
      final s = FakeServer((fn, b) => switch (fn) {
            'rst_menu' => json(menuJson()),
            'rcp_list' => json(rcpListJson()),
            'ing_list' => json(ingJson()),
            _ => json({}),
          });
      for (final (page, title) in [(PriceControlScreen(api: s.build), 'Price control'), (MenuHub(menuApi: s.menu, buildApi: s.build, initial: 1), 'Recipe'), (MenuHub(menuApi: s.menu, buildApi: s.build, initial: 2), 'Ingredients')]) {
        await show(t, Builder(builder: (c) => TextButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => page)), child: const Text('go'))));
        await t.tap(find.text('go'));
        await t.pumpAndSettle();
        expect(find.byType(AppHeader), findsOneWidget, reason: title);
        expect(find.byType(OutletHeader), findsNothing, reason: title);
        expect(find.descendant(of: find.byType(AppHeader), matching: find.text(title)), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('app-header-back')));
        await t.pumpAndSettle();
        expect(find.text('go'), findsOneWidget, reason: 'back from $title');
      }
      await show(t, MenuHub(menuApi: s.menu, buildApi: s.build));
      expect(find.byType(OutletHeader), findsOneWidget, reason: 'as a tab it keeps the outlet header');
      expect(find.byKey(const ValueKey('app-header-back')), findsNothing);
    });

    testWidgets('three sub-masters on top: Menu (default), Recipe, Ingredients, each with its own data', (t) async {
      final s = FakeServer((fn, b) => switch (fn) {
            'rst_menu' => json(menuJson()),
            'rcp_list' => json(rcpListJson()),
            'ing_list' => json(ingJson()),
            _ => json({}),
          });
      await show(t, MenuHub(menuApi: s.menu, buildApi: s.build));
      for (final l in ['Menu', 'Recipe', 'Ingredients']) {
        expect(find.byKey(ValueKey('sub-master-${l.toLowerCase()}')), findsOneWidget, reason: l);
      }
      expect(find.text('All items'), findsOneWidget);
      expect(find.text('Add-ons'), findsOneWidget);
      expect(find.text('Combos'), findsOneWidget);
      expect(s.calls.map((c) => c.$1), isNot(contains('rcp_list')), reason: 'a sub-master loads when it is first opened');

      await t.tap(find.byKey(const ValueKey('sub-master-recipe')));
      await t.pumpAndSettle();
      expect(find.text('1/2'), findsOneWidget);
      expect(find.text('37.2%'), findsOneWidget);
      expect(find.text('Cost ₹25.20 · 36.5%'), findsOneWidget);
      expect(find.text('Add recipe ›'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('sub-master-ingredients')));
      await t.pumpAndSettle();
      expect(find.text('Espresso coffee beans'), findsOneWidget);
      expect(find.text('₹1400/kg'), findsOneWidget);
      expect(find.text('Set cost'), findsOneWidget, reason: 'an ingredient without a cost asks for one');
      expect(find.text('On hand 0.5 l'), findsOneWidget);
      expect(find.text('Latur Dairy'), findsOneWidget);
    });
  });

  group('Recipe editor', () {
    testWidgets('Selling price can be edited from the recipe: a plain dish has one price', (t) async {
      final s = FakeServer((fn, b) => switch (fn) {
            'rcp_view' => json(recipeJson()),
            'menu_item_settings' => json({...settingsJson(name: 'Salted Fries'), 'sizes': []}),
            'menu_price_save' => json({...settingsJson(name: 'Salted Fries'), 'price_minor': 18500, 'sizes': []}),
            _ => json({}),
          });
      await show(t, RecipeEditorScreen(api: s.build, dishId: 'd-new'));
      expect(t.widget<Text>(find.byKey(const ValueKey('rcp-price'))).data, '₹69');
      await t.tap(find.byKey(const ValueKey('rcp-price-edit')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('price-main')), '185');
      await t.tap(find.byKey(const ValueKey('price-save')));
      await t.pumpAndSettle();
      expect(s.last('menu_price_save'), {'id': 'd-new', 'version': 1, 'price': 185.0});
      expect(t.widget<Text>(find.byKey(const ValueKey('rcp-price'))).data, '₹185', reason: 'the margin follows the new price');
    });

    testWidgets('a beverage edits its Small, Medium and Large prices together; a price of zero is stopped', (t) async {
      final sizes = [
        {'id': 'v-s', 'name': 'Small', 'price': 69, 'recipe_factor': 1, 'is_default': true},
        {'id': 'v-m', 'name': 'Medium', 'price': 89, 'recipe_factor': 2, 'is_default': false},
        {'id': 'v-l', 'name': 'Large', 'price': 109, 'recipe_factor': 3, 'is_default': false},
      ];
      final s = FakeServer((fn, b) => switch (fn) {
            'rcp_view' => json(recipeJson()),
            'menu_item_settings' => json({...settingsJson(name: 'Americano'), 'price_minor': 6900, 'sizes': sizes}),
            'menu_price_save' => json({...settingsJson(name: 'Americano'), 'price_minor': 7900, 'sizes': sizes}),
            _ => json({}),
          });
      await show(t, RecipeEditorScreen(api: s.build, dishId: 'd-americano'));
      await t.tap(find.byKey(const ValueKey('rcp-price-edit')));
      await t.pumpAndSettle();
      expect(find.text('Small (this recipe)'), findsOneWidget);
      expect(find.text('Medium · uses the recipe 2×'), findsOneWidget);
      expect(find.text('Large · uses the recipe 3×'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('price-Large')), '0');
      await t.tap(find.byKey(const ValueKey('price-save')));
      await t.pumpAndSettle();
      expect(find.text('Enter a price above zero.'), findsOneWidget);
      expect(s.calls.where((c) => c.$1 == 'menu_price_save'), isEmpty);
      await t.enterText(find.byKey(const ValueKey('price-main')), '79');
      await t.enterText(find.byKey(const ValueKey('price-Medium')), '99');
      await t.enterText(find.byKey(const ValueKey('price-Large')), '119');
      await t.tap(find.byKey(const ValueKey('price-save')));
      await t.pumpAndSettle();
      expect(s.last('menu_price_save'), {
        'id': 'd-americano', 'version': 1, 'price': 79.0,
        'sizes': [{'id': 'v-m', 'price': 99.0}, {'id': 'v-l', 'price': 119.0}],
      });
      expect(t.widget<Text>(find.byKey(const ValueKey('rcp-price'))).data, '₹79');
    });

    testWidgets('add-on recipes (0626): the Add-ons tab lists add-ons; one opens its recipe, saved with addon_id, then the editor closes', (t) async {
      final addonRecipe = {
        ...recipeJson(), 'kind': 'addon', 'addon_id': 'a-tukda', 'menu_item_id': 'a-tukda', 'name': 'cheese tukda', 'category': 'Extra toppings', 'price_minor': 2500,
      };
      final s = FakeServer((fn, b) => switch (fn) {
            'rcp_list' => json({
                ...rcpListJson(),
                'addons': [
                  {...addonRecipe, 'single': {'name': 'Mozzarella cheese', 'unit': 'kg', 'qty': 0.02}}..remove('lines'),
                ],
              }),
            'rcp_view' => json(addonRecipe),
            'ing_list' => json(ingJson()),
            'rcp_save' => json(addonRecipe),
            _ => json({}),
          });
      await show(t, Scaffold(body: RecipesView(api: s.build)));
      expect(find.text('Americano'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('rcp-tab-addons')));
      await t.pumpAndSettle();
      expect(find.text('Americano'), findsNothing);
      expect(find.text('Extra toppings · Uses 0.02 kg Mozzarella cheese · no recipe yet'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('rcp-cheese tukda')));
      await t.pumpAndSettle();
      expect(s.last('rcp_view'), {'addon_id': 'a-tukda'});
      expect(find.text('ADD-ON RECIPE'), findsOneWidget);
      expect(find.text('Ingredients per add-on'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('rcp-add-ingredient')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('rcp-pick-Espresso coffee beans')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('rcp-qty-i-beans')), '20');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('rcp-save')));
      await t.pumpAndSettle();
      expect(s.last('rcp_save')['addon_id'], 'a-tukda');
      expect(s.last('rcp_save').containsKey('menu_item_id'), isFalse);
      expect(find.byType(RecipeEditorScreen), findsNothing, reason: 'save & exit');
    });

    testWidgets('price control (0627): every dish in one table with price, cost, food cost and margin; Add-ons too; a row opens its recipe', (t) async {
      final s = FakeServer((fn, b) => switch (fn) {
            'rcp_list' => json({
                ...rcpListJson(),
                'addons': [
                  {...recipeJson(), 'kind': 'addon', 'menu_item_id': 'a-tukda', 'addon_id': 'a-tukda', 'name': 'cheese tukda', 'category': 'Extra toppings', 'price_minor': 2500}..remove('lines'),
                ],
              }),
            'rcp_view' => json(recipeJson()),
            'ing_list' => json(ingJson()),
            _ => json({}),
          });
      await show(t, PriceControlScreen(api: s.build));
      expect(find.byKey(const ValueKey('pc-table')), findsOneWidget);
      expect(find.text('Americano'), findsOneWidget);
      expect(find.text('Salted Fries'), findsOneWidget);
      expect(find.text('₹69'), findsOneWidget);
      expect(find.text('₹25.20'), findsOneWidget, reason: 'the recipe cost');
      expect(t.widget<Text>(find.byKey(const ValueKey('pc-pct-Americano'))).data, '36.5%');
      expect(find.text('No recipe'), findsOneWidget, reason: 'Salted Fries has none');
      expect(t.getRect(find.text('Americano')).top, lessThan(t.getRect(find.text('Salted Fries')).top), reason: 'highest food cost first');
      // 0627: Selling price, then OneLocal, Zomato and Swiggy, before the cost
      final heads = [for (final k in ['name', 'price', 'onelocal', 'zomato', 'swiggy', 'cost', 'pct', 'margin']) t.getRect(find.byKey(ValueKey('pc-col-$k'))).left];
      expect(heads, [...heads]..sort(), reason: 'in this order');
      expect(find.text('Selling price'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('pc-zomato-Americano'))).data, '—', reason: 'no Zomato price: sold at the selling price');
      await t.ensureVisible(find.byKey(const ValueKey('pc-zomato-Americano')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('pc-zomato-Americano')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('pc-channel-price')), '79');
      await t.tap(find.byKey(const ValueKey('pc-channel-save')));
      await t.pumpAndSettle();
      expect(s.last('menu_channel_price_save'), {'menu_item_id': 'd-americano', 'channel': 'zomato', 'price': 79.0});
      expect(find.byType(RecipeEditorScreen), findsNothing, reason: 'a price cell edits the price, not the recipe');
      await t.tap(find.byKey(const ValueKey('pc-tab-addons')));
      await t.pumpAndSettle();
      expect(find.text('cheese tukda'), findsOneWidget);
      expect(find.text('Americano'), findsNothing);
      expect(find.byKey(const ValueKey('pc-col-zomato')), findsNothing, reason: 'an add-on is sold with its dish');
      await t.tap(find.byKey(const ValueKey('pc-tab-dishes')));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Americano'));
      await t.pumpAndSettle();
      await t.tap(find.text('Americano'));
      await t.pumpAndSettle();
      expect(find.byType(RecipeEditorScreen), findsOneWidget);
      expect(s.last('rcp_view'), {'menu_item_id': 'd-americano'});
    });

    testWidgets('cost, food cost and margin update as you type; grams are saved as kg', (t) async {
      final s = FakeServer((fn, b) => switch (fn) {
            'rcp_view' => json(recipeJson()),
            'ing_list' => json(ingJson()),
            'rcp_save' => json(recipeJson(lines: [
                for (final l in (b['lines'] as List).cast<Map<String, dynamic>>())
                  {...l, 'name': 'Espresso coffee beans', 'unit': 'kg', 'unit_cost_minor': 140000, 'cost_source': 'set_by_you'},
              ])),
            _ => json({}),
          });
      await show(t, Builder(builder: (c) => TextButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => RecipeEditorScreen(api: s.build, dishId: 'd-americano'))), child: const Text('recipes'))));
      await t.tap(find.text('recipes'));
      await t.pumpAndSettle();
      expect(find.text('Add ingredients to see the food cost'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('rcp-add-ingredient')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('rcp-pick-Espresso coffee beans')));
      await t.pumpAndSettle();
      // kg is typed in grams: 18 g of beans at ₹1400/kg is ₹25.20 on a ₹69 dish = 36.5% food cost, ₹43.80 margin
      await t.enterText(find.byKey(const ValueKey('rcp-qty-i-beans')), '18');
      await t.pump();
      expect(find.byKey(const ValueKey('rcp-line-cost-i-beans')), findsOneWidget);
      expect(find.text('₹25.20'), findsWidgets);
      expect(find.text('Food cost 36.5% · watch it'), findsOneWidget);
      expect(find.text('₹43.80'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('rcp-key-i-beans')));
      await t.tap(find.byKey(const ValueKey('rcp-save')));
      await t.pumpAndSettle();
      expect(s.last('rcp_save'), {
        'menu_item_id': 'd-americano',
        'lines': [{'inventory_item_id': 'i-beans', 'qty': 0.018, 'wastage_pct': 0.0, 'is_key': true}],
      });
      expect(find.byType(RecipeEditorScreen), findsNothing, reason: 'save & exit');
      expect(find.text('recipes'), findsOneWidget);
    });
  });

  group('Ingredients', () {
    testWidgets('the library: tick two, Add sends their codes; already-added ones cannot be ticked', (t) async {
      final s = FakeServer((fn, b) => switch (fn) {
            'ing_library' => json({
                'categories': ['Dairy'],
                'items': [
                  {'code': 'DAI-01', 'name': 'Full cream milk', 'category': 'Dairy', 'unit': 'l', 'typical_cost_minor': 6800, 'added': true},
                  {'code': 'DAI-10', 'name': 'Paneer', 'category': 'Dairy', 'unit': 'kg', 'typical_cost_minor': 38000, 'added': false},
                  {'code': 'DAI-05', 'name': 'Butter (salted)', 'category': 'Dairy', 'unit': 'kg', 'typical_cost_minor': 52000, 'added': false},
                ],
              }),
            'ing_add_from_library' => json({...ingJson(), 'added': 2}),
            _ => json({}),
          });
      int? added;
      await show(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () async => added = await Navigator.of(c).push<int>(MaterialPageRoute(builder: (_) => LibraryPickerScreen(api: s.build))), child: const Text('open')))));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('Dairy · already added'), findsOneWidget);
      expect(find.text('Dairy · ~₹380/kg'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('lib-DAI-10')));
      await t.tap(find.byKey(const ValueKey('lib-DAI-05')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('lib-DAI-01')));
      await t.pump();
      expect(find.text('Add 2 ingredients'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('lib-add')));
      await t.pumpAndSettle();
      expect((s.last('ing_add_from_library')['codes'] as List).toSet(), {'DAI-10', 'DAI-05'});
      expect(added, 2);
    });

    testWidgets('edit an ingredient: cost in rupees goes as paise; Buy from supplier opens a purchase order', (t) async {
      var purchases = 0;
      HomeNav.newPurchase = (_) => purchases++;
      final s = FakeServer((fn, b) => switch (fn) { 'ing_list' => json(ingJson()), 'ing_save' => json({'id': 'i-syrup', ...ingJson()}), _ => json({}) });
      await show(t, Scaffold(body: IngredientsView(api: s.build)));
      await t.tap(find.byKey(const ValueKey('ing-Hazelnut syrup')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('ing-cost')), '650.50');
      await t.tap(find.byKey(const ValueKey('ing-save')));
      await t.pumpAndSettle();
      expect(s.last('ing_save'), containsPair('cost_minor', 65050));
      expect(s.last('ing_save'), containsPair('id', 'i-syrup'));

      await t.tap(find.byKey(const ValueKey('ing-Full cream milk')));
      await t.pumpAndSettle();
      expect(find.textContaining('Recipes use the last purchase (₹68/l)'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ing-buy')));
      await t.pumpAndSettle();
      expect(purchases, 1);
    });
  });

  group('Menu: quick add, settings, add-ons, combos', () {
    testWidgets('+ ADD: quick add sends name, category, price and type, then opens the dish settings', (t) async {
      final s = FakeServer((fn, b) => switch (fn) {
            'rst_menu' => json(menuJson()),
            'menu_item_quick_add' => json(settingsJson()),
            'menu_item_settings' => json(settingsJson()),
            _ => json({}),
          });
      await show(t, MenuHub(menuApi: s.menu, buildApi: s.build));
      await t.tap(find.byKey(const ValueKey('menu-quick-add')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('qa-name')), 'Peri Peri Fries');
      // the category is a dropdown; "+ New category" lets a new one be typed
      await t.tap(find.byKey(const ValueKey('qa-category-dropdown')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('qa-cat-new')).last);
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('qa-category')), 'Fries');
      await t.enterText(find.byKey(const ValueKey('qa-price')), '199');
      await t.tap(find.byKey(const ValueKey('qa-save')));
      await t.pumpAndSettle();
      expect(s.last('menu_item_quick_add'), {'name': 'Peri Peri Fries', 'category': 'Fries', 'price': 199.0, 'food_type': 'veg', 'course': 'eat'});
      expect(find.text('DISH SETTINGS'), findsOneWidget);
      expect(find.text('Add recipe ›'), findsOneWidget);
    });

    testWidgets('quick add: a photo beside the name, a category from the dropdown (no pills); the photo is saved on the new dish', (t) async {
      final s = FakeServer((fn, b) => fn == 'menu_item_quick_add' ? json(settingsJson()) : json({}));
      final photos = _QaPhotos();
      DishSettings? added;
      await show(t, Builder(builder: (c) => TextButton(onPressed: () async => added = await QuickAddSheet.open(c, s.build, categories: ['Hot Beverages', 'Fries'], photos: photos), child: const Text('open'))));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, 'Hot Beverages'), findsNothing, reason: 'no category pills');
      expect(find.widgetWithText(ChoiceChip, 'Fries'), findsNothing);
      final photo = t.getRect(find.byKey(const ValueKey('qa-photo')));
      final name = t.getRect(find.byKey(const ValueKey('qa-name')));
      expect(photo.right, lessThan(name.left), reason: 'the photo sits beside the dish name');
      expect(find.text('Tap to add\nphoto'), findsOneWidget);
      // a full page in the store's Quick add style, Add dish fixed at the bottom
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Quick add a dish'), findsOneWidget);
      expect(t.getRect(find.byKey(const ValueKey('qa-save'))).bottom, greaterThan(t.getRect(find.byKey(const ValueKey('qa-course-drink'))).bottom));
      await t.tap(find.byKey(const ValueKey('qa-food-non_veg')));
      await t.pump();
      expect((t.widget(find.byKey(const ValueKey('qa-food-non_veg'))) as Material).color, kMbLime, reason: 'the chosen chip is lime');
      await t.tap(find.byKey(const ValueKey('qa-photo')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('qa-photo-preview')), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('qa-name')), 'Peri Peri Fries');
      await t.tap(find.byKey(const ValueKey('qa-category-dropdown')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('qa-cat-Fries')).last);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('qa-category')), findsNothing, reason: 'typing is only for a new category');
      await t.enterText(find.byKey(const ValueKey('qa-price')), '199');
      await t.tap(find.byKey(const ValueKey('qa-save')));
      await t.pumpAndSettle();
      expect(s.last('menu_item_quick_add'), containsPair('category', 'Fries'));
      expect(photos.attached, ['d-new'], reason: 'the photo goes on the dish just added');
      expect(added?.id, 'd-new');
    });

    testWidgets('dish settings: station, preparation time, recommended and an add-on group are saved with the version', (t) async {
      final s = FakeServer((fn, b) => switch (fn) { 'menu_item_settings' || 'menu_item_settings_save' => json(settingsJson()), _ => json({}) });
      await show(t, DishSettingsScreen(api: s.build, dishId: 'd-new'));
      await t.tap(find.byKey(const ValueKey('ds-station-grill')));
      await t.enterText(find.byKey(const ValueKey('ds-prep')), '8');
      await t.tap(find.byKey(const ValueKey('ds-recommended')));
      await t.tap(find.byKey(const ValueKey('ds-group-Extra dips')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('ds-save')));
      await t.pumpAndSettle();
      final sent = s.last('menu_item_settings_save');
      expect(sent['version'], 1);
      expect(sent['station'], 'grill');
      expect(sent['prep_minutes'], 8);
      expect(sent['is_recommended'], true);
      expect(sent['addon_group_ids'], ['g1']);
      expect(sent['price'], 199.0);
    });

    testWidgets('combo editor shows what the customer saves and sends the dishes with quantities', (t) async {
      final s = FakeServer((fn, b) => json({'combos': [], 'dishes': []}));
      await show(t, ComboEditor(api: s.build, dishes: const [
        (id: 'd1', name: 'Americano', priceMinor: 6900, category: 'Hot Beverages'),
        (id: 'd2', name: 'Paneer Subway', priceMinor: 20900, category: 'Sandwiches'),
      ]));
      await t.enterText(find.byKey(const ValueKey('combo-name')), 'Coffee & Sub');
      await t.tap(find.byKey(const ValueKey('combo-plus-Americano')));
      await t.tap(find.byKey(const ValueKey('combo-plus-Paneer Subway')));
      await t.enterText(find.byKey(const ValueKey('combo-price')), '249');
      await t.pump();
      expect(find.text('Separately: ₹278 · customer saves ₹29'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('combo-save')));
      await t.pumpAndSettle();
      expect(s.last('menu_combo_save'), {
        'name': 'Coffee & Sub', 'price': 249.0,
        'items': [{'menu_item_id': 'd1', 'qty': 1}, {'menu_item_id': 'd2', 'qty': 1}],
      });
    });

    testWidgets('add-on group editor (0624): each add-on is an ingredient from the master, with how much it uses and its selling price', (t) async {
      final s = FakeServer((fn, b) => json({
            'groups': [],
            'ingredients': [
              {'id': 'i-cheese', 'name': 'Cheese slices', 'unit': 'pc'},
              {'id': 'i-mayo', 'name': 'Mayonnaise (veg)', 'unit': 'kg'},
            ],
          }));
      await show(t, AddonGroupEditor(api: s.build));
      await t.enterText(find.byKey(const ValueKey('addon-name')), 'Extra dips');
      await t.tap(find.byKey(const ValueKey('addon-save')));
      await t.pumpAndSettle();
      expect(s.calls.where((c) => c.$1 == 'menu_addon_group_save'), isEmpty, reason: 'no ingredient chosen yet');
      await t.tap(find.byKey(const ValueKey('addon-row-ingredient-0')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('addon-ingredient-Mayonnaise (veg)')));
      await t.pumpAndSettle();
      expect(find.text('Mayonnaise (veg)'), findsOneWidget);
      expect(find.text('kg'), findsOneWidget, reason: 'the quantity is in the ingredient\'s unit');
      await t.tap(find.byKey(const ValueKey('addon-save')));
      await t.pumpAndSettle();
      expect(s.calls.where((c) => c.$1 == 'menu_addon_group_save'), isEmpty, reason: 'how much it uses is needed');
      await t.enterText(find.byKey(const ValueKey('addon-row-qty-0')), '0.03');
      await t.enterText(find.byKey(const ValueKey('addon-row-price-0')), '20');
      await t.tap(find.byKey(const ValueKey('addon-save')));
      await t.pumpAndSettle();
      expect(s.last('menu_addon_group_save'), {
        'name': 'Extra dips', 'min_select': 0, 'max_select': 1,
        'addons': [{'inventory_item_id': 'i-mayo', 'consume_qty': 0.03, 'name': 'Mayonnaise (veg)', 'price': 20.0, 'food_type': 'veg'}],
      });
    });

    testWidgets('dish settings (0624): combo groups are ticked like add-on groups and saved with the dish', (t) async {
      final s = FakeServer((fn, b) => switch (fn) {
            'menu_item_settings' || 'menu_item_settings_save' => json({
                ...settingsJson(),
                'combo_group_ids': <String>[],
                'combo_groups': [{'id': 'cg1', 'name': 'Make it a meal', 'combos': 2}],
              }),
            _ => json({}),
          });
      await show(t, DishSettingsScreen(api: s.build, dishId: 'd-new'));
      await t.scrollUntilVisible(find.byKey(const ValueKey('ds-combo-group-Make it a meal')), 200, scrollable: find.byType(Scrollable).first);
      await t.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await t.pumpAndSettle();
      expect(find.text('2 combos'), findsOneWidget);
      await t.tap(find.descendant(of: find.byKey(const ValueKey('ds-combo-group-Make it a meal')), matching: find.byType(Checkbox)));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('ds-save')));
      await t.pumpAndSettle();
      expect(s.last('menu_item_settings_save')['combo_group_ids'], ['cg1']);
    });

    testWidgets('combo group editor: name, how many may be picked, and the combos', (t) async {
      final s = FakeServer((fn, b) => json({
            'id': 'cg-new',
            'groups': [],
            'combos': [
              {'id': 'c1', 'name': 'fries & Cole', 'price_minor': 32500, 'items': 'Ice Blue, Salted Fries'},
              {'id': 'c2', 'name': 'Ice blue+Peri Peri Fries', 'price_minor': 40000, 'items': ''},
            ],
          }));
      await show(t, ComboGroupEditor(api: s.build));
      expect(find.text('fries & Cole · ₹325'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('combo-group-name')), 'Make it a meal');
      await t.tap(find.byKey(const ValueKey('combo-group-combo-fries & Cole')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('combo-group-save')));
      await t.pumpAndSettle();
      expect(s.last('menu_combo_group_save'), {'name': 'Make it a meal', 'min_select': 0, 'max_select': 1, 'combo_ids': ['c1']});
    });
  });
}

/// Photo tools for Quick add: a fixed 1×1 PNG, and the dishes a photo was attached to.
class _QaPhotos extends ItemPhotoService {
  _QaPhotos();
  final attached = <String>[];
  static final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');
  @override
  Future<ItemPhoto?> pick() async => ItemPhoto(bytes: _png, contentType: 'image/png');
  @override
  Future<ItemPhoto> removeBackground(ItemPhoto photo, {String? bgColor}) async => photo;
  @override
  Future<void> attach(String itemId, ItemPhoto photo) async => attached.add(itemId);
  @override
  Future<void> remove(String itemId) async {}
}

Map<String, dynamic> catJson({bool canEdit = true, List<Map<String, dynamic>>? cats}) => {
      'can_edit': canEdit,
      'categories': cats ??
          [
            {'id': 'k1', 'name': 'Beverages', 'parent_id': null, 'sort_order': 0, 'dishes': 3},
            {'id': 'k2', 'name': 'Cold coffee', 'parent_id': 'k1', 'sort_order': 1, 'dishes': 2},
            {'id': 'k3', 'name': 'Fries', 'parent_id': null, 'sort_order': 2, 'dishes': 0},
          ],
    };

void categoriesTests() {
  group('Menu → Categories', () {
    testWidgets('main categories with their subcategories and dish counts', (t) async {
      final s = FakeServer((fn, b) => json(catJson()));
      await show(t, CategoriesScreen(api: s.build));
      expect(find.byKey(const ValueKey('cat-main-Beverages')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('cat-main-Beverages')), matching: find.text('Cold coffee')), findsOneWidget, reason: 'the subcategory sits inside its main card');
      expect(find.text('3 dishes · 1 subcategory'), findsOneWidget);
      expect(find.text('0 dishes'), findsOneWidget);
      expect(find.byKey(const ValueKey('cat-add')), findsOneWidget);
    });

    testWidgets('Add subcategory sends the name with its parent; New category can be put under a main one', (t) async {
      final s = FakeServer((fn, b) => json(catJson()));
      await show(t, CategoriesScreen(api: s.build));
      await t.tap(find.byKey(const ValueKey('cat-more-Fries')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cat-sub-Fries')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('cat-name')), 'Loaded fries');
      await t.tap(find.byKey(const ValueKey('cat-save')));
      await t.pumpAndSettle();
      expect(s.last('menu_category_save'), {'name': 'Loaded fries', 'parent_id': 'k3'});
      await t.tap(find.byKey(const ValueKey('cat-add')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('cat-name')), 'Desserts');
      await t.tap(find.byKey(const ValueKey('cat-save')));
      await t.pumpAndSettle();
      expect(s.last('menu_category_save'), {'name': 'Desserts'}, reason: 'no parent: a main category');
    });

    testWidgets('rename, make a subcategory main, and a refused delete shows the reason', (t) async {
      final s = FakeServer((fn, b) => fn == 'menu_category_delete' ? json({'detail': 'Move its 3 dishes to another category first.', 'code': 'conflict'}, 409) : json(catJson()));
      await show(t, CategoriesScreen(api: s.build));
      await t.tap(find.byKey(const ValueKey('cat-more-Cold coffee')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cat-main-Cold coffee')));
      await t.pumpAndSettle();
      expect(s.last('menu_category_save'), {'id': 'k2', 'name': 'Cold coffee', 'parent_id': null});
      await t.tap(find.byKey(const ValueKey('cat-more-Beverages')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cat-rename-Beverages')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('cat-name')), 'Drinks');
      await t.tap(find.byKey(const ValueKey('cat-save')));
      await t.pumpAndSettle();
      expect(s.last('menu_category_save'), {'id': 'k1', 'name': 'Drinks'});
      await t.tap(find.byKey(const ValueKey('cat-more-Beverages')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cat-delete-Beverages')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cat-delete-yes')));
      await t.pumpAndSettle();
      expect(find.textContaining('Move its 3 dishes'), findsOneWidget);
    });

    testWidgets('a role that cannot change the menu sees the list only', (t) async {
      final s = FakeServer((fn, b) => json(catJson(canEdit: false)));
      await show(t, CategoriesScreen(api: s.build));
      expect(find.byKey(const ValueKey('cat-add')), findsNothing);
      expect(find.byKey(const ValueKey('cat-more-Beverages')), findsNothing);
      expect(find.textContaining('cannot'), findsNothing);
      expect(find.text('Your role can see the categories but not change them.'), findsOneWidget);
    });
  });
}
