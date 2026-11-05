import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/menu/menu_sheets.dart';
import 'package:vinii_pos/stock/closing_stock_screen.dart' show saveSpreadsheet;
import 'package:vinii_pos/ui/xlsx.dart';

import 'menu_build_test.dart' show FakeServer, ingJson, json, rcpListJson, recipeJson, settingsJson, show;

// Import / Export of Menu, Recipe and Ingredients as an Excel sheet (founder, 4 Nov 2026).

final _beansLine = {'inventory_item_id': 'i-beans', 'name': 'Espresso coffee beans', 'unit': 'kg', 'qty': 0.018, 'wastage_pct': 0, 'is_key': true, 'unit_cost_minor': 140000, 'cost_source': 'set_by_you'};

FakeServer _server() => FakeServer((fn, body) => switch (fn) {
      'ing_list' || 'ing_save' => json(ingJson()),
      'rcp_list' => json(rcpListJson()),
      'rcp_view' => json(recipeJson(lines: [_beansLine])),
      'rcp_save' => json(recipeJson()),
      'menu_item_settings' || 'menu_price_save' || 'menu_item_settings_save' || 'menu_item_quick_add' => json(settingsJson()),
      _ => json({'detail': 'unexpected $fn'}, 500),
    });

Uint8List _csv(List<List<String>> rows) => Uint8List.fromList(utf8.encode(rows.map((r) => r.map((c) => c.contains(',') ? '"$c"' : c).join(',')).join('\n')));

void main() {
  late List<(String, Uint8List)> saved;
  setUp(() {
    saved = [];
    final realSave = saveSpreadsheet, realPick = pickMenuSheetFile;
    saveSpreadsheet = (bytes, name) async => saved.add((name, bytes));
    addTearDown(() {
      saveSpreadsheet = realSave;
      pickMenuSheetFile = realPick;
    });
  });

  Future<int> open(WidgetTester t, SheetKind kind, FakeServer s) async {
    var imported = 0;
    await show(t, Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: SheetButtons(kind: kind, api: s.build, onImported: () => imported++))));
    return imported;
  }

  group('Export', () {
    testWidgets('Ingredients: every ingredient with its category, unit, cost, reorder level, active and ID', (t) async {
      final s = _server();
      await open(t, SheetKind.ingredients, s);
      await t.tap(find.byKey(const ValueKey('sheet-export-ingredients')));
      await t.pumpAndSettle();
      expect(saved.single.$1, startsWith('ingredients-'));
      final rows = readXlsx(saved.single.$2);
      expect(rows.first, ['Ingredient*', 'Category', 'Unit*', 'Cost per unit (₹)', 'Reorder level', 'Barcode', 'Active', 'ID']);
      expect(rows[1], ['Espresso coffee beans', 'Coffee & Tea', 'kg', '1400', '1', '', 'Yes', 'i-beans']);
      expect(rows[3].take(4), ['Hazelnut syrup', 'Syrups', 'l', ''], reason: 'no cost yet: blank');
      expect(rows.length, 4);
    });

    testWidgets('Menu: each dish with category, price, food type and ID', (t) async {
      final s = _server();
      await open(t, SheetKind.menu, s);
      await t.tap(find.byKey(const ValueKey('sheet-export-menu')));
      await t.pumpAndSettle();
      final rows = readXlsx(saved.single.$2);
      expect(rows.first, ['Dish*', 'Category*', 'Price (₹)*', 'Food type', 'ID']);
      expect(rows[1], ['Americano', 'Hot Beverages', '69', 'Veg', 'd-americano']);
      expect(rows[2], ['Salted Fries', 'Fries', '179', 'Veg', 'd-fries']);
    });

    testWidgets('Recipes: one row per ingredient of each dish that has a recipe', (t) async {
      final s = _server();
      await open(t, SheetKind.recipes, s);
      await t.tap(find.byKey(const ValueKey('sheet-export-recipes')));
      await t.pumpAndSettle();
      final rows = readXlsx(saved.single.$2);
      expect(rows, [
        ['Dish*', 'Ingredient*', 'Qty*', 'Unit', 'Wastage %', 'Key ingredient'],
        ['Americano', 'Espresso coffee beans', '0.018', 'kg', '', 'Yes'],
      ]);
      expect(s.calls.where((c) => c.$1 == 'rcp_view').map((c) => c.$2['menu_item_id']), ['d-americano'], reason: 'only dishes with a recipe are read');
    });
  });

  group('Import', () {
    testWidgets('Ingredients: checked first (new, change, no change, problems), then only the new and changed rows are saved', (t) async {
      final s = _server();
      pickMenuSheetFile = () async => (name: 'ingredients.csv', bytes: _csv([
            ['Ingredient*', 'Category', 'Unit*', 'Cost per unit (₹)', 'Reorder level', 'Barcode', 'Active', 'ID'],
            ['Espresso coffee beans', 'Coffee & Tea', 'kg', '1400', '1', '', 'Yes', 'i-beans'],
            ['Full cream milk', 'Dairy', 'L', '70', '', '', '', 'i-milk'],
            ['Sugar', 'Dry store', 'g', '0.05', '', '', '', ''],
            ['Salt', '', 'litre', '', '', '', '', ''],
            ['Sugar', '', 'kg', '', '', '', '', ''],
          ]));
      var imported = 0;
      await show(t, Scaffold(body: SheetButtons(kind: SheetKind.ingredients, api: s.build, onImported: () => imported++)));
      await t.tap(find.byKey(const ValueKey('sheet-import-ingredients')));
      await t.pumpAndSettle();
      expect(find.text('Import ingredients'), findsOneWidget);
      expect(find.textContaining('Row 2 · No change'), findsOneWidget);
      expect(find.textContaining('Row 3 · cost ₹68 → ₹70'), findsOneWidget, reason: 'blank reorder level keeps the old one');
      expect(find.textContaining('Row 4 · New · g'), findsOneWidget);
      expect(find.textContaining('Row 5 · Unit is one of kg, g, l, ml, pc'), findsOneWidget);
      expect(find.textContaining('Row 6 · Sugar is in this sheet twice'), findsOneWidget);
      expect(s.calls.where((c) => c.$1 == 'ing_save'), isEmpty, reason: 'nothing is saved before Import');
      expect(find.text('Import 2 rows'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('sheet-import-go')));
      await t.pumpAndSettle();
      final saves = [for (final c in s.calls) if (c.$1 == 'ing_save') c.$2];
      expect(saves.length, 2);
      expect(saves[0]['id'], 'i-milk');
      expect(saves[0]['cost_minor'], 7000);
      expect(saves[0]['reorder_level'], 2);
      expect(saves[0]['unit'], 'l');
      expect(saves[1].containsKey('id'), isFalse);
      expect([saves[1]['name'], saves[1]['unit'], saves[1]['cost_minor']], ['Sugar', 'g', 5]);
      expect(find.text('Saved'), findsNWidgets(2));
      await t.tap(find.byKey(const ValueKey('sheet-import-go'))); // Done
      await t.pumpAndSettle();
      expect(imported, 1, reason: 'the list reloads');
    });

    testWidgets('Menu: a price change goes through Price control, a new dish through Quick add; bad rows are skipped', (t) async {
      final s = _server();
      pickMenuSheetFile = () async => (name: 'menu.csv', bytes: _csv([
            ['Dish*', 'Category*', 'Price (₹)*', 'Food type', 'ID'],
            ['Americano', 'Hot Beverages', '79', 'Veg', 'd-americano'],
            ['Salted Fries', 'Fries', '179', '', 'd-fries'],
            ['Masala Chai', 'Hot Beverages', '40', 'veg', ''],
            ['Fish Fry', 'Starters', '0', 'Non-veg', ''],
            ['Paneer Roll', 'Rolls', '120', 'Fish', ''],
          ]));
      await open(t, SheetKind.menu, s);
      await t.tap(find.byKey(const ValueKey('sheet-import-menu')));
      await t.pumpAndSettle();
      expect(find.textContaining('Row 2 · price ₹69 → ₹79'), findsOneWidget);
      expect(find.textContaining('Row 3 · No change'), findsOneWidget);
      expect(find.textContaining('Row 4 · New in Hot Beverages · ₹40 · Veg'), findsOneWidget);
      expect(find.textContaining('Row 5 · Enter a price above zero'), findsOneWidget);
      expect(find.textContaining('Row 6 · Food type is Veg, Non-veg or Egg'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('sheet-import-go')));
      await t.pumpAndSettle();
      expect(s.last('menu_price_save'), {'id': 'd-americano', 'version': 1, 'price': 79});
      expect(s.calls.where((c) => c.$1 == 'menu_item_settings_save'), isEmpty, reason: 'only the price changed');
      expect(s.last('menu_item_quick_add'), {'name': 'Masala Chai', 'category': 'Hot Beverages', 'price': 40, 'food_type': 'veg', 'course': 'eat'});
    });

    testWidgets('Recipes: a dish\'s rows replace its recipe; unknown dishes or ingredients, and wrong units, are named', (t) async {
      final s = _server();
      pickMenuSheetFile = () async => (name: 'recipes.csv', bytes: _csv([
            ['Dish*', 'Ingredient*', 'Qty*', 'Unit', 'Wastage %', 'Key ingredient'],
            ['Americano', 'Espresso coffee beans', '0.02', 'kg', '', 'Yes'],
            ['Americano', 'Full cream milk', '0.05', 'l', '5', ''],
            ['Salted Fries', 'Potato', '0.2', 'kg', '', ''],
            ['Cold Coffee', 'Full cream milk', '0.2', 'l', '', ''],
            ['americano', 'Hazelnut syrup', '1', 'kg', '', ''],
          ]));
      await open(t, SheetKind.recipes, s);
      await t.tap(find.byKey(const ValueKey('sheet-import-recipes')));
      await t.pumpAndSettle();
      // the third Americano row has the wrong unit: the whole recipe waits
      expect(find.textContaining('Row 6: Hazelnut syrup is measured in l, not kg'), findsOneWidget);
      expect(find.textContaining('Row 4: no ingredient called Potato'), findsOneWidget);
      expect(find.textContaining('No dish called Cold Coffee on the menu'), findsOneWidget);
      expect(find.text('Nothing to import'), findsOneWidget);
    });

    testWidgets('Recipes: a valid dish is saved with its lines', (t) async {
      final s = _server();
      pickMenuSheetFile = () async => (name: 'recipes.csv', bytes: _csv([
            ['Dish*', 'Ingredient*', 'Qty*', 'Unit', 'Wastage %', 'Key ingredient'],
            ['Americano', 'Espresso coffee beans', '0.02', 'kg', '', 'Yes'],
            ['Americano', 'Full cream milk', '0.05', '', '5%', ''],
          ]));
      await open(t, SheetKind.recipes, s);
      await t.tap(find.byKey(const ValueKey('sheet-import-recipes')));
      await t.pumpAndSettle();
      expect(find.textContaining('Recipe replaced: 2 ingredients (was 1)'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('sheet-import-go')));
      await t.pumpAndSettle();
      expect(s.last('rcp_save'), {
        'menu_item_id': 'd-americano',
        'lines': [
          {'inventory_item_id': 'i-beans', 'qty': 0.02, 'wastage_pct': 0.0, 'is_key': true},
          {'inventory_item_id': 'i-milk', 'qty': 0.05, 'wastage_pct': 5.0, 'is_key': false},
        ],
      });
    });

    testWidgets('a sheet without the needed columns is refused with a sentence', (t) async {
      final s = _server();
      pickMenuSheetFile = () async => (name: 'other.csv', bytes: _csv([['Name', 'Qty'], ['x', '1']]));
      await open(t, SheetKind.menu, s);
      await t.tap(find.byKey(const ValueKey('sheet-import-menu')));
      await t.pumpAndSettle();
      expect(find.textContaining('This is not the Menu sheet'), findsOneWidget);
      expect(find.text('Import menu'), findsNothing);
    });
  });
}
