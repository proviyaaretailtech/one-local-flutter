import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../stock/closing_stock_screen.dart' show saveSpreadsheet;
import '../ui/theme.dart';
import '../ui/xlsx.dart';
import 'menu_api.dart' show MenuApiException;
import 'menu_build_api.dart';
import 'menu_build_widgets.dart';

// Import / Export for Menu, Recipe and Ingredients (founder, 4 Nov 2026: "an import button and export button in menu, ingredients and
// recipe … import or export the data from an external Excel sheet"). Export writes what the restaurant has as an .xlsx; the same sheet,
// edited in Excel (or saved as CSV), comes back through Import. Every row is checked against what is already there before anything is
// saved — new, an update (and what changes), no change, or what is wrong — and is then saved through the same calls the screens use, so
// every rule (names, units, prices, who may edit) stays the database's. Rows with a problem are skipped; nothing is ever deleted.

enum SheetKind { menu, ingredients, recipes }

extension on SheetKind {
  String get title => switch (this) { SheetKind.menu => 'Menu', SheetKind.ingredients => 'Ingredients', SheetKind.recipes => 'Recipes' };
  String get file => switch (this) { SheetKind.menu => 'menu', SheetKind.ingredients => 'ingredients', SheetKind.recipes => 'recipes' };

  /// The sheet's columns, in order. * = needed. "ID" finds the row's dish or ingredient again; leave it as exported, blank for a new one.
  List<String> get columns => switch (this) {
        SheetKind.menu => const ['Dish*', 'Category*', 'Price (₹)*', 'Food type', 'ID'],
        SheetKind.ingredients => const ['Ingredient*', 'Category', 'Unit*', 'Cost per unit (₹)', 'Reorder level', 'Barcode', 'Active', 'ID'],
        SheetKind.recipes => const ['Dish*', 'Ingredient*', 'Qty*', 'Unit', 'Wastage %', 'Key ingredient'],
      };
  List<double> get widths => switch (this) {
        SheetKind.menu => const [30, 22, 11, 11, 38],
        SheetKind.ingredients => const [28, 16, 8, 16, 13, 16, 8, 38],
        SheetKind.recipes => const [30, 26, 9, 8, 11, 14],
      };
}

/// Tests replace the file picker: a name and the bytes, or null.
Future<({String name, Uint8List bytes})?> Function() pickMenuSheetFile = () async {
  final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['xlsx', 'csv']);
  if (f == null) return null;
  return (name: f.name, bytes: await f.readAsBytes());
};

/// Import and Export side by side, for the top of the Menu, Recipe and Ingredients lists. [onImported] reloads the list after an import.
class SheetButtons extends StatefulWidget {
  const SheetButtons({super.key, required this.kind, required this.api, required this.onImported, this.canImport = true});
  final SheetKind kind;
  final MenuBuildApi api;
  final VoidCallback onImported;
  final bool canImport;
  @override
  State<SheetButtons> createState() => _SheetButtonsState();
}

class _SheetButtonsState extends State<SheetButtons> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() step) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await step();
    } on MenuApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } on FormatException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not do that. Try again.');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _export() => _run(() async {
        final rows = await exportRows(widget.kind, widget.api);
        final day = DateTime.now().toIso8601String().substring(0, 10);
        final name = '${widget.kind.file}-$day.xlsx';
        await saveSpreadsheet(buildXlsx(widget.kind.title, rows, widths: widget.kind.widths), name);
        if (mounted) showToast(context, '${widget.kind.title} exported: $name (${rows.length - 1} rows)');
      });

  Future<void> _import() => _run(() async {
        final f = await pickMenuSheetFile();
        if (f == null || !mounted) return;
        final table = f.name.toLowerCase().endsWith('.csv') ? readCsv(utf8.decode(f.bytes, allowMalformed: true)) : readXlsx(f.bytes);
        final plan = await planImport(widget.kind, table, widget.api);
        if (!mounted) return;
        final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => SheetImportScreen(kind: widget.kind, plan: plan, api: widget.api)));
        if (done == true) widget.onImported();
      });

  @override
  Widget build(BuildContext context) {
    final k = widget.kind.file;
    Widget button(String key, String label, IconData icon, VoidCallback? onTap) => Expanded(
          child: OutlinedButton.icon(
            key: ValueKey(key),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(40), side: const BorderSide(color: kLine), backgroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            onPressed: _busy ? null : onTap,
            icon: Icon(icon, size: 16, color: kInk),
            label: Text(label, style: inter(13.5, 600)),
          ),
        );
    return Row(children: [
      if (widget.canImport) ...[button('sheet-import-$k', 'Import', LucideIcons.fileUp, _import), const SizedBox(width: 8)],
      button('sheet-export-$k', 'Export', LucideIcons.fileDown, _export),
    ]);
  }
}

// ---------------------------------------------------------------- export

num? _num(int? minor) => minor == null ? null : (minor % 100 == 0 ? minor ~/ 100 : minor / 100);
String _food(String f) => switch (f) { 'non_veg' => 'Non-veg', 'egg' => 'Egg', _ => 'Veg' };
String _yes(bool b) => b ? 'Yes' : 'No';

/// The rows of the sheet, the header first.
Future<List<List<Object?>>> exportRows(SheetKind kind, MenuBuildApi api) async {
  switch (kind) {
    case SheetKind.menu:
      final dishes = (await api.recipes()).items;
      return [kind.columns, for (final d in dishes) [d.name, d.category, _num(d.priceMinor), _food(d.foodType), d.dishId]];
    case SheetKind.ingredients:
      final items = (await api.ingredients()).items;
      return [
        kind.columns,
        for (final i in items) [i.name, i.category, i.unit, _num(i.costMinor), i.reorderLevel == 0 ? null : i.reorderLevel, i.barcode, _yes(i.active), i.id],
      ];
    case SheetKind.recipes:
      final dishes = (await api.recipes()).items.where((d) => d.hasRecipe).toList();
      final rows = <List<Object?>>[kind.columns];
      for (final r in await _views(api, [for (final d in dishes) d.dishId])) {
        for (final l in r.lines) {
          rows.add([r.name, l.name, l.qty, l.unit, l.wastagePct == 0 ? null : l.wastagePct, l.isKey ? 'Yes' : null]);
        }
      }
      return rows;
  }
}

/// Each dish's recipe, four at a time, in the dishes' order.
Future<List<Recipe>> _views(MenuBuildApi api, List<String> ids) async {
  final out = <Recipe>[];
  for (var i = 0; i < ids.length; i += 4) {
    out.addAll(await Future.wait([for (final id in ids.skip(i).take(4)) api.recipe(id)]));
  }
  return out;
}

// ---------------------------------------------------------------- import: checking the sheet

enum RowState { add, update, same, problem }

/// One thing the import would do (a dish, an ingredient, or one dish's whole recipe), the sheet rows it comes from, and the step that saves it.
class PlanItem {
  PlanItem({required this.lines, required this.title, required this.state, required this.detail, this.save});
  final List<int> lines; // the row numbers, as Excel shows them
  final String title;
  final RowState state;
  final String detail; // what changes, or what is wrong
  final Future<void> Function()? save;
  String? result; // after the import: null = saved, else why not
  bool done = false;
}

/// The sheet's rows as maps keyed by column (the header row may be in any order; "*" and "(₹)" are ignored), each with its row number.
List<({int line, Map<String, String> cells})> _rows(SheetKind kind, List<List<String>> table) {
  String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\(.*?\)|[^a-z%]'), '');
  final head = table.indexWhere((r) => r.any((c) => c.trim().isNotEmpty));
  if (head < 0) throw const FormatException('The file is empty.');
  final want = {for (final c in kind.columns) norm(c): c};
  final at = <String, int>{};
  for (final (i, h) in table[head].indexed) {
    final c = want[norm(h)];
    if (c != null) at[c] = i;
  }
  final missing = [for (final c in kind.columns) if (c.endsWith('*') && !at.containsKey(c)) c.replaceAll('*', '')];
  if (missing.isNotEmpty) {
    throw FormatException('This is not the ${kind.title} sheet: it has no ${missing.join(', ')} column. Export the ${kind.title.toLowerCase()} first and use that file.');
  }
  return [
    for (var r = head + 1; r < table.length; r++)
      if (table[r].any((c) => c.trim().isNotEmpty))
        (line: r + 1, cells: {for (final e in at.entries) e.key: e.value < table[r].length ? table[r][e.value].trim() : ''}),
  ];
}

num? _parseNum(String s) => s.isEmpty ? null : num.tryParse(s.replaceAll(RegExp(r'[₹,\s]'), ''));
String _low(String s) => s.trim().toLowerCase();

/// Veg / Non-veg / Egg as the database's food types; '' when blank, null when not one of them.
String? _foodOf(String s) => switch (_low(s).replaceAll(RegExp(r'[^a-z]'), '')) {
      '' => '',
      'veg' || 'vegetarian' || 'v' => 'veg',
      'nonveg' || 'nonvegetarian' || 'nv' => 'non_veg',
      'egg' || 'eggetarian' => 'egg',
      _ => null,
    };

/// Yes / No; null when blank, false for anything not a yes.
bool? _yesOf(String s) => s.trim().isEmpty ? null : const {'yes', 'y', 'true', '1', 'active'}.contains(_low(s));

/// Reads the sheet and checks every row against what the restaurant already has.
Future<List<PlanItem>> planImport(SheetKind kind, List<List<String>> table, MenuBuildApi api) async {
  final rows = _rows(kind, table);
  if (rows.isEmpty) throw const FormatException('The sheet has no rows under its header.');
  return switch (kind) {
    SheetKind.menu => _planMenu(rows, (await api.recipes()).items, api),
    SheetKind.ingredients => _planIngredients(rows, await api.ingredients(), api),
    SheetKind.recipes => _planRecipes(rows, (await api.recipes()).items, (await api.ingredients()).items, api),
  };
}

List<PlanItem> _planMenu(List<({int line, Map<String, String> cells})> rows, List<Recipe> dishes, MenuBuildApi api) {
  final byId = {for (final d in dishes) d.dishId: d};
  final seen = <String>{};
  return [
    for (final r in rows)
      () {
        final c = r.cells;
        final name = c['Dish*'] ?? '', cat = c['Category*'] ?? '';
        final price = _parseNum(c['Price (₹)*'] ?? '');
        final food = _foodOf(c['Food type'] ?? '');
        PlanItem problem(String why) => PlanItem(lines: [r.line], title: name.isEmpty ? 'Row ${r.line}' : name, state: RowState.problem, detail: why);
        if (name.length < 2) return problem('Enter the dish name.');
        if (cat.isEmpty) return problem('Enter the category.');
        if (price == null || price <= 0) return problem('Enter a price above zero.');
        if (food == null) return problem('Food type is Veg, Non-veg or Egg.');
        if (!seen.add('${_low(name)}|${_low(cat)}')) return problem('$name is in this sheet twice in $cat.');
        // the dish: its ID, else its name (and category when two dishes share the name)
        Recipe? d = byId[c['ID'] ?? ''];
        if (d == null) {
          final same = dishes.where((x) => _low(x.name) == _low(name)).toList();
          d = same.length == 1 ? same.first : same.where((x) => _low(x.category) == _low(cat)).firstOrNull;
        }
        final priceMinor = (price * 100).round();
        if (d == null) {
          return PlanItem(lines: [r.line], title: name, state: RowState.add, detail: 'New in $cat · ${rupeesMinor(priceMinor)}${food.isEmpty ? '' : ' · ${_food(food)}'}',
              save: () => api.quickAdd(name: name, category: cat, price: price.toDouble(), foodType: food.isEmpty ? 'veg' : food));
        }
        final dish = d;
        final changes = <String>[
          if (dish.name != name) 'name ${dish.name} → $name',
          if (_low(dish.category) != _low(cat)) 'category ${dish.category} → $cat',
          if (dish.priceMinor != priceMinor) 'price ${rupeesMinor(dish.priceMinor)} → ${rupeesMinor(priceMinor)}',
          if (food.isNotEmpty && food != dish.foodType) '${_food(dish.foodType)} → ${_food(food)}',
        ];
        if (changes.isEmpty) return PlanItem(lines: [r.line], title: name, state: RowState.same, detail: 'No change');
        return PlanItem(
          lines: [r.line],
          title: name,
          state: RowState.update,
          detail: changes.join(' · '),
          save: () async {
            var s = await api.settings(dish.dishId);
            // the price through Price control's call, so a dish with sizes keeps its default size in step
            if (dish.priceMinor != priceMinor) s = await api.savePrice(dish.dishId, s.version, price.toDouble());
            final rest = {
              if (dish.name != name) 'name': name,
              if (_low(dish.category) != _low(cat)) 'category': cat,
              if (food.isNotEmpty && food != dish.foodType) 'food_type': food,
            };
            if (rest.isNotEmpty) await api.saveSettings(dish.dishId, s.version, rest);
          },
        );
      }(),
  ];
}

List<PlanItem> _planIngredients(List<({int line, Map<String, String> cells})> rows, IngredientList have, MenuBuildApi api) {
  final byId = {for (final i in have.items) i.id: i};
  final byName = {for (final i in have.items) _low(i.name): i};
  final units = {for (final u in have.units.isEmpty ? const ['kg', 'g', 'l', 'ml', 'pc', 'dozen', 'pack', 'bunch'] : have.units) _low(u): u};
  final seen = <String>{};
  return [
    for (final r in rows)
      () {
        final c = r.cells;
        final name = c['Ingredient*'] ?? '', cat = c['Category'] ?? '';
        final unit = units[_low(c['Unit*'] ?? '')];
        final costText = c['Cost per unit (₹)'] ?? '', reorderText = c['Reorder level'] ?? '';
        final cost = _parseNum(costText), reorder = _parseNum(reorderText);
        final active = _yesOf(c['Active'] ?? '');
        final barcode = c['Barcode'] ?? '';
        PlanItem problem(String why) => PlanItem(lines: [r.line], title: name.isEmpty ? 'Row ${r.line}' : name, state: RowState.problem, detail: why);
        if (name.isEmpty) return problem('Enter the ingredient name.');
        if (name.length > 80) return problem('The name is up to 80 characters.');
        if (cat.length > 40) return problem('A category is up to 40 characters.');
        if (unit == null) return problem('Unit is one of ${units.values.join(', ')}.');
        if (costText.isNotEmpty && (cost == null || cost < 0)) return problem('Cost per unit is a number, zero or more.');
        if (reorderText.isNotEmpty && (reorder == null || reorder < 0)) return problem('Reorder level is a number, zero or more.');
        if (!seen.add(_low(name))) return problem('$name is in this sheet twice.');
        final i = byId[c['ID'] ?? ''] ?? byName[_low(name)];
        final costMinor = cost == null ? null : (cost * 100).round();
        if (i == null) {
          return PlanItem(
            lines: [r.line],
            title: name,
            state: RowState.add,
            detail: 'New · $unit${costMinor == null ? '' : ' · ${rupeesMinor(costMinor)} a $unit'}',
            save: () => api.saveIngredient(
                name: name, category: cat, unit: unit, costMinor: costMinor, reorderLevel: reorder?.toDouble(), active: active, barcode: barcode.isEmpty ? null : barcode),
          );
        }
        // a blank cell keeps what is there
        final newCost = costText.isEmpty ? i.costMinor : costMinor;
        final newReorder = reorderText.isEmpty ? i.reorderLevel : reorder!.toDouble();
        final changes = <String>[
          if (i.name != name) 'name ${i.name} → $name',
          if (_low(i.category) != _low(cat)) 'category ${i.category.isEmpty ? '—' : i.category} → ${cat.isEmpty ? '—' : cat}',
          if (i.unit != unit) 'unit ${i.unit} → $unit',
          if (newCost != i.costMinor) 'cost ${i.costMinor == null ? '—' : rupeesMinor(i.costMinor)} → ${rupeesMinor(newCost)}',
          if (newReorder != i.reorderLevel) 'reorder ${_trim(i.reorderLevel)} → ${_trim(newReorder)}',
          if (barcode.isNotEmpty && barcode != i.barcode) 'barcode → $barcode',
          if (active != null && active != i.active) active ? 'made active' : 'made inactive',
        ];
        if (changes.isEmpty) return PlanItem(lines: [r.line], title: name, state: RowState.same, detail: 'No change');
        return PlanItem(
          lines: [r.line],
          title: name,
          state: RowState.update,
          detail: changes.join(' · '),
          save: () => api.saveIngredient(
              id: i.id, name: name, category: cat, unit: unit, costMinor: newCost, reorderLevel: newReorder, active: active, barcode: barcode.isEmpty ? null : barcode),
        );
      }(),
  ];
}

String _trim(num v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';

List<PlanItem> _planRecipes(List<({int line, Map<String, String> cells})> rows, List<Recipe> dishes, List<Ingredient> ings, MenuBuildApi api) {
  final byName = <String, List<Recipe>>{};
  for (final d in dishes) {
    byName.putIfAbsent(_low(d.name), () => []).add(d);
  }
  final ingBy = {for (final i in ings) _low(i.name): i};
  // the rows, one group per dish, in the sheet's order
  final groups = <String, List<({int line, Map<String, String> cells})>>{};
  for (final r in rows) {
    groups.putIfAbsent(_low(r.cells['Dish*'] ?? ''), () => []).add(r);
  }
  final out = <PlanItem>[];
  for (final g in groups.entries) {
    final lines = [for (final r in g.value) r.line];
    final title = g.value.first.cells['Dish*'] ?? '';
    PlanItem problem(String why) => PlanItem(lines: lines, title: title.isEmpty ? 'Row ${lines.first}' : title, state: RowState.problem, detail: why);
    if (g.key.isEmpty) {
      out.add(problem('Enter the dish on every row.'));
      continue;
    }
    final match = byName[g.key] ?? const [];
    if (match.isEmpty) {
      out.add(problem('No dish called $title on the menu. Add it in Menu first.'));
      continue;
    }
    if (match.length > 1) {
      out.add(problem('${match.length} dishes are called $title. Rename one in Menu first.'));
      continue;
    }
    final dish = match.first;
    final draft = <DraftLine>[];
    String? why;
    for (final r in g.value) {
      final c = r.cells;
      final ing = ingBy[_low(c['Ingredient*'] ?? '')];
      final qty = _parseNum(c['Qty*'] ?? '');
      final wText = c['Wastage %'] ?? '';
      final w = _parseNum(wText.replaceAll('%', ''));
      final unit = _low(c['Unit'] ?? '');
      if ((c['Ingredient*'] ?? '').isEmpty) {
        why = 'Row ${r.line}: enter the ingredient.';
      } else if (ing == null) {
        why = 'Row ${r.line}: no ingredient called ${c['Ingredient*']}. Add it in Ingredients first.';
      } else if (qty == null || qty <= 0) {
        why = 'Row ${r.line}: enter a quantity above zero.';
      } else if (unit.isNotEmpty && unit != _low(ing.unit)) {
        why = 'Row ${r.line}: ${ing.name} is measured in ${ing.unit}, not ${c['Unit']}.';
      } else if (wText.isNotEmpty && (w == null || w < 0 || w > 90)) {
        why = 'Row ${r.line}: wastage is 0 to 90 percent.';
      } else if (draft.any((l) => l.ingredientId == ing.id)) {
        why = 'Row ${r.line}: ${ing.name} is in this recipe twice.';
      }
      if (why != null) break;
      draft.add(DraftLine(ingredientId: ing!.id, name: ing.name, unit: ing.unit, qty: qty!.toDouble(), wastagePct: (w ?? 0).toDouble(), isKey: _yesOf(c['Key ingredient'] ?? '') ?? false));
    }
    if (why == null && draft.length > 60) why = 'Up to 60 ingredients in one recipe.';
    if (why != null) {
      out.add(problem(why));
      continue;
    }
    out.add(PlanItem(
      lines: lines,
      title: dish.name,
      state: dish.hasRecipe ? RowState.update : RowState.add,
      detail: dish.hasRecipe ? 'Recipe replaced: ${draft.length} ingredients (was ${dish.lineCount})' : 'New recipe: ${draft.length} ingredients',
      save: () => api.saveRecipe(dish.dishId, draft),
    ));
  }
  return out;
}

// ---------------------------------------------------------------- import: the check, then the save

/// What the sheet would do, row by row, and Import to save the new rows and the changes (rows with a problem are skipped).
class SheetImportScreen extends StatefulWidget {
  const SheetImportScreen({super.key, required this.kind, required this.plan, required this.api});
  final SheetKind kind;
  final List<PlanItem> plan;
  final MenuBuildApi api;
  @override
  State<SheetImportScreen> createState() => _SheetImportScreenState();
}

class _SheetImportScreenState extends State<SheetImportScreen> {
  bool _running = false, _finished = false;
  int _at = 0;

  List<PlanItem> get _todo => [for (final p in widget.plan) if (p.state == RowState.add || p.state == RowState.update) p];
  int _count(RowState s) => widget.plan.where((p) => p.state == s).length;

  Future<void> _import() async {
    setState(() => _running = true);
    for (final p in _todo) {
      setState(() => _at++);
      try {
        await p.save!();
      } on MenuApiException catch (e) {
        p.result = e.message;
      } catch (_) {
        p.result = 'Could not save this one.';
      }
      p.done = true;
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _finished = true;
    });
    final failed = _todo.where((p) => p.result != null).length;
    showToast(context, failed == 0 ? '${_todo.length} saved from the sheet.' : '${_todo.length - failed} saved, $failed not saved. See the red rows.');
  }

  @override
  Widget build(BuildContext context) {
    final todo = _todo.length;
    final noun = widget.kind == SheetKind.recipes ? (todo == 1 ? 'recipe' : 'recipes') : (todo == 1 ? 'row' : 'rows');
    return PopScope(
      canPop: !_running,
      child: Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          leading: IconButton(
              key: const ValueKey('sheet-back'), icon: const Icon(LucideIcons.arrowLeft, color: kInk), onPressed: _running ? null : () => Navigator.of(context).pop(_finished)),
          title: Text('Import ${widget.kind.title.toLowerCase()}', style: inter(18, 800)),
        ),
        body: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 120), children: [
          Row(children: [
            StatTile(label: 'New', value: '${_count(RowState.add)}', tone: const (kMbGreenBg, kMbGreen)),
            const SizedBox(width: 8),
            StatTile(label: 'Changes', value: '${_count(RowState.update)}'),
            const SizedBox(width: 8),
            StatTile(label: 'No change', value: '${_count(RowState.same)}'),
            const SizedBox(width: 8),
            StatTile(label: 'Problems', value: '${_count(RowState.problem)}', tone: _count(RowState.problem) > 0 ? const (kMbRedBg, kMbRed) : null),
          ]),
          const SizedBox(height: 10),
          Text(
            _finished
                ? 'Done. Rows still red were not saved: fix them in the sheet and import it again.'
                : 'Nothing is saved until you tap Import. Rows with a problem are skipped${widget.kind == SheetKind.recipes ? '; a recipe in the sheet replaces that dish\'s recipe' : ''}. Nothing is deleted.',
            style: inter(13, 500, color: kMuted),
          ),
          const SizedBox(height: 12),
          for (final (n, p) in widget.plan.indexed) _PlanRow(key: ValueKey('sheet-row-$n'), p: p),
        ]),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            child: FilledButton(
              key: const ValueKey('sheet-import-go'),
              style: FilledButton.styleFrom(backgroundColor: kInk, minimumSize: const Size.fromHeight(50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              onPressed: _running ? null : (_finished ? () => Navigator.of(context).pop(true) : (todo == 0 ? null : _import)),
              child: Text(
                _running ? 'Saving $_at of $todo…' : _finished ? 'Done' : todo == 0 ? 'Nothing to import' : 'Import $todo $noun',
                style: inter(15, 700, color: kMbLime),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlanRow extends StatelessWidget {
  const _PlanRow({super.key, required this.p});
  final PlanItem p;

  @override
  Widget build(BuildContext context) {
    final failed = p.result != null;
    final (label, bg, ink) = failed
        ? ('Not saved', kMbRedBg, kMbRed)
        : p.done
            ? ('Saved', kMbGreenBg, kMbGreen)
            : switch (p.state) {
                RowState.add => ('New', kMbGreenBg, kMbGreen),
                RowState.update => ('Change', kMbAmberBg, kMbAmber),
                RowState.same => ('No change', const Color(0xFFF1F2EE), kMuted),
                RowState.problem => ('Problem', kMbRedBg, kMbRed),
              };
    final rows = p.lines.length == 1 ? 'Row ${p.lines.first}' : 'Rows ${p.lines.first}–${p.lines.last}';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: failed || p.state == RowState.problem ? kMbRed.withValues(alpha: 0.35) : kLine)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.title, style: inter(14.5, 700)),
            const SizedBox(height: 2),
            Text('$rows · ${failed ? p.result : p.detail}', style: inter(12.5, 500, color: failed || p.state == RowState.problem ? kMbRed : kMuted)),
          ]),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
          child: Text(label, style: inter(11.5, 700, color: ink)),
        ),
      ]),
    );
  }
}
