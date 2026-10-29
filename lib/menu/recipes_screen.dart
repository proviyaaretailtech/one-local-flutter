import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/net_guard.dart';
import '../ui/theme.dart';
import 'ingredients_screen.dart' show LibraryPickerScreen;
import 'menu_api.dart' show MenuApiException;
import 'menu_build_api.dart';
import 'menu_build_widgets.dart';
import 'menu_widgets.dart' show FoodTypeMark, MenuError;

/// The Recipe sub-master: every dish with what it costs to make (from its recipe and each ingredient's cost), its food cost % and its
/// margin. A dish opens its recipe editor. Selling a dish deducts its recipe from stock, so a recipe is also the stock rule.
class RecipesView extends StatefulWidget {
  const RecipesView({super.key, required this.api});
  final MenuBuildApi api;
  @override
  State<RecipesView> createState() => _RecipesViewState();
}

class _RecipesViewState extends State<RecipesView> {
  late Future<RecipeList> _f = widget.api.recipes();
  RecipeList? _last;
  String _q = '';
  String? _show; // null all, 'with', 'without'
  String _tab = 'dishes'; // dishes | addons (0626: an add-on's recipe lives here too)
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final next = widget.api.recipes(q: _q);
    setState(() { _f = next; });
    try {
      _last = await next;
    } catch (_) {/* drawn by the builder */}
  }

  Future<void> _open(Recipe r) async {
    await Navigator.of(context).push(RecipeEditorScreen.route(widget.api, r.dishId, addon: r.isAddon));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RecipeList>(
      future: _f,
      builder: (context, snap) {
        final d = snap.data ?? _last;
        if (d == null && snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator(color: kLink));
        if (d == null) return MenuError(error: snap.error ?? 'Could not load the recipes.', onRetry: _reload);
        _last = d;
        final all = _tab == 'addons' ? d.addons : d.items;
        final withRecipe = all.where((r) => r.hasRecipe).length;
        final items = all.where((r) => _show == null || (_show == 'with') == r.hasRecipe).toList();
        return RefreshIndicator(
          onRefresh: _reload,
          child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 110), children: [
            Row(children: [
              StatTile(label: 'Dishes with a recipe', value: '${d.withRecipe}/${d.withRecipe + d.withoutRecipe}'),
              const SizedBox(width: 8),
              StatTile(label: 'Average food cost', value: pct(d.avgFoodCostPct), tone: d.avgFoodCostPct == null ? null : foodCostTone(d.avgFoodCostPct)),
            ]),
            const SizedBox(height: 12),
            FilterChips(
              keyPrefix: 'rcp-tab',
              items: [('dishes', 'Dishes (${d.items.length})'), ('addons', 'Add-ons (${d.addons.length})')],
              selected: _tab,
              onSelect: (v) => setState(() {
                _tab = v ?? 'dishes';
                _show = null;
              }),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('rcp-search'),
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), () {
                  _q = v;
                  _reload();
                });
              },
              style: inter(14, 500),
              decoration: InputDecoration(
                hintText: _tab == 'addons' ? 'Search add-on' : 'Search dish',
                prefixIcon: const Icon(LucideIcons.search, size: 18, color: kMuted),
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kLine)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kLine)),
              ),
            ),
            const SizedBox(height: 10),
            FilterChips(
              keyPrefix: 'rcp-show',
              items: [(null, 'All'), ('with', 'With recipe ($withRecipe)'), ('without', 'No recipe yet (${all.length - withRecipe})')],
              selected: _show,
              onSelect: (v) => setState(() => _show = v),
            ),
            const SizedBox(height: 12),
            if (items.isEmpty)
              MbEmpty(
                icon: LucideIcons.chefHat,
                title: 'Nothing here',
                body: _tab == 'addons' ? 'Add add-ons in Menu → Add-ons, then give each a recipe here.' : 'Add dishes in Menu, then give each a recipe here.',
              )
            else
              for (final r in items) _RecipeRow(r: r, onTap: () => _open(r)),
          ]),
        );
      },
    );
  }
}

class _RecipeRow extends StatelessWidget {
  const _RecipeRow({required this.r, required this.onTap});
  final Recipe r;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final tone = foodCostTone(r.foodCostPct);
    return MbRowSurface(
      child: InkWell(
        key: ValueKey('rcp-${r.name}'),
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(children: [
            FoodTypeMark(r.foodType),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.name, style: inter(15, 600)),
                const SizedBox(height: 2),
                Text(
                  r.hasRecipe
                      ? '${r.lineCount} ingredient${r.lineCount == 1 ? '' : 's'}${r.keyCount > 0 ? ' (${r.keyCount} key)' : ''}${r.missingCost > 0 ? ' · ${r.missingCost} without cost' : ''}'
                      // an add-on without a recipe may still use its one ingredient (0624)
                      : r.single != null
                          ? '${r.category.isEmpty ? '' : '${r.category} · '}Uses ${r.single!.qty ?? ''} ${r.single!.unit} ${r.single!.name} · no recipe yet'
                          : '${r.category.isEmpty ? '' : '${r.category} · '}No recipe yet',
                  style: inter(12, 400, color: r.missingCost > 0 ? kMbAmber : kMuted),
                ),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(rupeesMinor(r.priceMinor), style: inter(14, 700)),
              const SizedBox(height: 4),
              if (r.hasRecipe)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: tone.$1, borderRadius: BorderRadius.circular(999)),
                  child: Text('Cost ${rupeesMinor(r.costMinor)} · ${pct(r.foodCostPct)}', style: inter(11, 700, color: tone.$2)),
                )
              else
                Text('Add recipe ›', style: inter(12, 600, color: kLink)),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// One dish's recipe: its ingredients with quantity per serving, wastage and key flag; the cost, food cost % and margin update as you
/// type. Save replaces the recipe (and so what selling the dish deducts from stock).
class RecipeEditorScreen extends StatefulWidget {
  const RecipeEditorScreen({super.key, required this.api, required this.dishId, this.addon = false});
  final MenuBuildApi api;
  final String dishId;
  /// With [addon], [dishId] is an add-on's id and this is its recipe (0626).
  final bool addon;
  static Route<void> route(MenuBuildApi api, String dishId, {bool addon = false}) =>
      MaterialPageRoute(builder: (_) => RecipeEditorScreen(api: api, dishId: dishId, addon: addon));
  @override
  State<RecipeEditorScreen> createState() => _RecipeEditorScreenState();
}

class _RecipeEditorScreenState extends State<RecipeEditorScreen> {
  Recipe? _r;
  Object? _error;
  List<DraftLine> _lines = [];
  bool _dirty = false, _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await widget.api.recipe(widget.dishId, addon: widget.addon);
      if (!mounted) return;
      setState(() {
        _r = r;
        _lines = [for (final l in r.lines) DraftLine.of(l)];
        _dirty = false;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  int get _cost => _lines.fold(0, (s, l) => s + (l.lineCostMinor ?? 0));
  int? _savedPrice; // the selling price just saved here (minor), until the recipe is read again
  int get _price => _savedPrice ?? _r?.priceMinor ?? 0;

  /// Selling price, edited here (0613). A dish with sizes edits each size: Small is the dish's price and the recipe as written.
  Future<void> _editPrice() async {
    final DishSettings s;
    try {
      s = await widget.api.settings(widget.dishId);
    } catch (e) {
      if (mounted) showToast(context, errorSentence(e));
      return;
    }
    if (!mounted) return;
    String fmt(num v) => v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(2);
    final main = TextEditingController(text: fmt(s.priceMinor / 100));
    final others = {for (final z in s.sizes) if (!z.isDefault) z.id: TextEditingController(text: fmt(z.price))};
    final small = s.sizes.where((z) => z.isDefault).firstOrNull;
    String? problem;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) {
          Widget field(String label, TextEditingController ctl, String key, {String? hint}) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TextField(
                  key: ValueKey(key),
                  controller: ctl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: label, prefixText: '₹ ', helperText: hint, border: const OutlineInputBorder()),
                ),
              );
          return AlertDialog(
            title: Text('Selling price · ${s.name}', style: inter(17, 700)),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                field(small == null ? 'Selling price' : '${small.name} (this recipe)', main, 'price-main'),
                for (final z in s.sizes.where((z) => !z.isDefault))
                  field('${z.name} · uses the recipe ${z.factor == z.factor.roundToDouble() ? z.factor.toInt() : z.factor}×', others[z.id]!, 'price-${z.name}'),
                if (problem != null) Text(problem!, style: inter(13, 500, color: kError)),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              TextButton(
                key: const ValueKey('price-save'),
                onPressed: () {
                  final all = [main, ...others.values];
                  if (all.any((x) => (double.tryParse(x.text.trim()) ?? 0) <= 0)) return set(() => problem = 'Enter a price above zero.');
                  Navigator.pop(c, true);
                },
                child: Text('Save', style: inter(14, 700)),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final saved = await widget.api.savePrice(widget.dishId, s.version, double.parse(main.text.trim()),
          sizes: {for (final e in others.entries) e.key: double.parse(e.value.text.trim())});
      if (!mounted) return;
      setState(() => _savedPrice = saved.priceMinor);
      showToast(context, 'Price saved for ${s.name}.');
    } catch (e) {
      if (mounted) showToast(context, errorSentence(e));
    }
  }
  double? get _foodPct => _price > 0 && _lines.isNotEmpty ? _cost / _price * 100 : null;
  int get _missing => _lines.where((l) => l.unitCostMinor == null).length;

  Future<void> _addIngredient() async {
    final picked = await showModalBottomSheet<Ingredient>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _IngredientPicker(api: widget.api, exclude: {for (final l in _lines) l.ingredientId}),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _lines.add(DraftLine(ingredientId: picked.id, name: picked.name, unit: picked.unit, qty: _defaultQty(picked.unit), unitCostMinor: picked.costMinor));
      _dirty = true;
    });
  }

  double _defaultQty(String unit) => switch (unit) { 'kg' || 'l' => 0.05, 'g' || 'ml' => 50, _ => 1 };

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final r = await widget.api.saveRecipe(widget.dishId, _lines, addon: widget.addon);
      if (!mounted) return;
      setState(() {
        _r = r;
        _lines = [for (final l in r.lines) DraftLine.of(l)];
        _dirty = false;
      });
      showToast(context, 'Recipe saved. Selling ${r.name} now deducts these quantities from stock.');
      // save & exit (founder, 29 Oct 2026): back to where the recipe was opened from
      Navigator.of(context).pop(true);
    } on MenuApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Leave without saving?'),
            content: const Text('Your changes to this recipe will be lost.'),
            actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep editing')), TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Leave'))],
          ),
        );
        if (leave == true && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          elevation: 0,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.addon ? 'ADD-ON RECIPE' : 'RECIPE', style: inter(10, 700, color: kMuted).copyWith(letterSpacing: 0.8)),
            Text(r?.name ?? '', style: inter(17, 700)),
          ]),
        ),
        body: r == null
            ? (_error != null ? MenuError(error: _error!, onRetry: _load) : const Center(child: CircularProgressIndicator(color: kLink)))
            : ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 120), children: [
                _Totals(price: _price, cost: _cost, foodPct: _foodPct, missing: _missing, hasLines: _lines.isNotEmpty, onEditPrice: widget.addon ? null : _editPrice),
                MbCard(
                  title: widget.addon ? 'Ingredients per add-on' : 'Ingredients per serving',
                  trailing: TextButton.icon(
                    key: const ValueKey('rcp-add-ingredient'),
                    onPressed: _addIngredient,
                    icon: const Icon(LucideIcons.plus, size: 16, color: kLink),
                    label: Text('Add', style: inter(14, 600, color: kLink)),
                  ),
                  child: _lines.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Text('No ingredients yet. Add what goes into one serving; mark the ones the dish cannot be made without as key.',
                              style: inter(13, 400, color: kMuted, height: 1.4)),
                        )
                      : Column(children: [
                          for (var i = 0; i < _lines.length; i++)
                            _LineEditor(
                              key: ValueKey('rcp-line-${_lines[i].ingredientId}'),
                              line: _lines[i],
                              onChanged: () => setState(() => _dirty = true),
                              onRemove: () => setState(() {
                                _lines.removeAt(i);
                                _dirty = true;
                              }),
                            ),
                        ]),
                ),
                Text('Costs come from each ingredient: its last purchase, else its supplier price, else the cost you set. Wastage adds to the quantity used.',
                    style: inter(12, 400, color: kMuted, height: 1.4)),
              ]),
        bottomNavigationBar: r == null
            ? null
            : SafeArea(
                minimum: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                child: MbPrimaryButton(_dirty ? 'Save & exit' : 'Saved', busy: _busy, onPressed: _dirty ? _save : null, key: const ValueKey('rcp-save')),
              ),
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.price, required this.cost, required this.foodPct, required this.missing, required this.hasLines, this.onEditPrice});
  final VoidCallback? onEditPrice;
  final int price, cost, missing;
  final double? foodPct;
  final bool hasLines;
  @override
  Widget build(BuildContext context) {
    final tone = foodCostTone(foodPct);
    final margin = price - cost;
    return MbCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          // tap to change the price (and each size's); the cost and margin follow
          Expanded(
            child: InkWell(
              key: const ValueKey('rcp-price-edit'),
              borderRadius: BorderRadius.circular(10),
              onTap: onEditPrice,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text('Selling price', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 500, color: kMuted))),
                  if (onEditPrice != null) ...[const SizedBox(width: 4), const Icon(LucideIcons.pencil, size: 13, color: kLink)],
                ]),
                const SizedBox(height: 2),
                Text(rupeesMinor(price), key: const ValueKey('rcp-price'), style: inter(17, 700, color: onEditPrice != null ? kLink : kInk)),
                if (onEditPrice != null) Text('Tap to edit', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 600, color: kMuted)),
              ]),
            ),
          ),
          _Fig('Cost to make', hasLines ? rupeesMinor(cost) : '—', key: const ValueKey('rcp-cost')),
          _Fig('Margin', hasLines ? rupeesMinor(margin) : '—', sub: hasLines && price > 0 ? pct(margin / price * 100) : null, key: const ValueKey('rcp-margin')),
        ]),
        const SizedBox(height: 10),
        Container(
          key: const ValueKey('rcp-food-cost'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: tone.$1, borderRadius: BorderRadius.circular(10)),
          child: Text(
            !hasLines
                ? 'Add ingredients to see the food cost'
                : 'Food cost ${pct(foodPct)} · ${foodPct == null ? '' : foodPct! <= 35 ? 'healthy' : foodPct! <= 45 ? 'watch it' : 'too high for the price'}',
            style: inter(13, 700, color: tone.$2),
          ),
        ),
        if (missing > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('$missing ingredient${missing == 1 ? ' has' : 's have'} no cost yet, so the cost is understated. Set it in Ingredients.',
                style: inter(12, 500, color: kMbAmber, height: 1.35)),
          ),
      ]),
    );
  }
}

class _Fig extends StatelessWidget {
  const _Fig(this.label, this.value, {super.key, this.sub});
  final String label, value;
  final String? sub;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: inter(12, 500, color: kMuted)),
          const SizedBox(height: 2),
          Text(value, style: inter(17, 700)),
          if (sub != null) Text(sub!, style: inter(12, 600, color: kMuted)),
        ]),
      );
}

String _num(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');

/// One recipe line: quantity per serving (in the ingredient's unit; kg and litre can be typed in g and ml), wastage %, key flag.
class _LineEditor extends StatefulWidget {
  const _LineEditor({super.key, required this.line, required this.onChanged, required this.onRemove});
  final DraftLine line;
  final VoidCallback onChanged, onRemove;
  @override
  State<_LineEditor> createState() => _LineEditorState();
}

class _LineEditorState extends State<_LineEditor> {
  late final bool _small = widget.line.unit == 'kg' || widget.line.unit == 'l'; // typed in g / ml
  late final _qty = TextEditingController(text: _num(_small ? widget.line.qty * 1000 : widget.line.qty));
  late final _waste = TextEditingController(text: widget.line.wastagePct == 0 ? '' : _num(widget.line.wastagePct));
  String get _typedUnit => _small ? (widget.line.unit == 'kg' ? 'g' : 'ml') : widget.line.unit;

  @override
  Widget build(BuildContext context) {
    final l = widget.line;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: kLine))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          IconButton(
            key: ValueKey('rcp-key-${l.ingredientId}'),
            tooltip: l.isKey ? 'Key ingredient' : 'Mark as key ingredient',
            visualDensity: VisualDensity.compact,
            onPressed: () {
              setState(() => l.isKey = !l.isKey);
              widget.onChanged();
            },
            icon: Icon(LucideIcons.star, size: 18, color: l.isKey ? const Color(0xFFF59E0B) : kLine),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.name, style: inter(14, 600)),
              Text(l.unitCostMinor == null ? 'No cost yet' : '${rupeesMinor(l.unitCostMinor)}/${l.unit}${l.isKey ? ' · key' : ''}',
                  style: inter(11.5, 500, color: l.unitCostMinor == null ? kMbAmber : kMuted)),
            ]),
          ),
          Text(rupeesMinor(l.lineCostMinor), key: ValueKey('rcp-line-cost-${l.ingredientId}'), style: inter(14, 700)),
          IconButton(tooltip: 'Remove', visualDensity: VisualDensity.compact, onPressed: widget.onRemove, icon: const Icon(LucideIcons.x, size: 18, color: kMuted)),
        ]),
        Row(children: [
          const SizedBox(width: 40),
          Expanded(
            child: _SmallField(
              fieldKey: ValueKey('rcp-qty-${l.ingredientId}'),
              controller: _qty,
              suffix: _typedUnit,
              onChanged: (v) {
                final n = numOf(v);
                if (n == null || n <= 0) return;
                l.qty = _small ? n / 1000 : n;
                widget.onChanged();
              },
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 110,
            child: _SmallField(
              fieldKey: ValueKey('rcp-waste-${l.ingredientId}'),
              controller: _waste,
              hint: 'Wastage',
              suffix: '%',
              onChanged: (v) {
                l.wastagePct = (numOf(v) ?? 0).clamp(0, 90).toDouble();
                widget.onChanged();
              },
            ),
          ),
        ]),
      ]),
    );
  }
}

class _SmallField extends StatelessWidget {
  const _SmallField({required this.controller, required this.onChanged, this.suffix, this.hint, this.fieldKey});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String? suffix, hint;
  final Key? fieldKey;
  @override
  Widget build(BuildContext context) => TextField(
        key: fieldKey,
        controller: controller,
        onChanged: onChanged,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: inter(14, 600),
        decoration: InputDecoration(
          hintText: hint,
          suffixText: suffix,
          isDense: true,
          filled: true,
          fillColor: kField,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kFieldBorder)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kFieldBorder)),
        ),
      );
}

/// Pick one of the business's ingredients for a recipe (or go to the library when it is not there yet).
class _IngredientPicker extends StatefulWidget {
  const _IngredientPicker({required this.api, required this.exclude});
  final MenuBuildApi api;
  final Set<String> exclude;
  @override
  State<_IngredientPicker> createState() => _IngredientPickerState();
}

class _IngredientPickerState extends State<_IngredientPicker> {
  late Future<IngredientList> _f = widget.api.ingredients();
  String _q = '';

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 12 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Add an ingredient', style: inter(18, 700)),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('rcp-pick-search'),
            autofocus: true,
            onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
            style: inter(14, 500),
            decoration: InputDecoration(
              hintText: 'Search your ingredients',
              prefixIcon: const Icon(LucideIcons.search, size: 18, color: kMuted),
              isDense: true,
              filled: true,
              fillColor: kField,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kFieldBorder)),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: FutureBuilder<IngredientList>(
              future: _f,
              builder: (context, snap) {
                if (!snap.hasData) return snap.hasError ? MenuError(error: snap.error!, onRetry: () => setState(() { _f = widget.api.ingredients(); })) : const Center(child: CircularProgressIndicator(color: kLink));
                final items = snap.data!.items.where((i) => !widget.exclude.contains(i.id) && (_q.isEmpty || i.name.toLowerCase().contains(_q))).toList();
                return ListView(children: [
                  for (final i in items)
                    ListTile(
                      key: ValueKey('rcp-pick-${i.name}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(i.name, style: inter(14, 600)),
                      subtitle: Text('${i.category.isEmpty ? '' : '${i.category} · '}${i.costMinor == null ? 'no cost yet' : '${rupeesMinor(i.costMinor)}/${i.unit}'}', style: inter(12, 400, color: kMuted)),
                      trailing: const Icon(LucideIcons.plus, size: 18, color: kLink),
                      onTap: () => Navigator.of(context).pop(i),
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('rcp-pick-library'),
                    onPressed: () async {
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LibraryPickerScreen(api: widget.api)));
                      if (mounted) setState(() { _f = widget.api.ingredients(); });
                    },
                    icon: const Icon(LucideIcons.libraryBig, size: 18, color: kInk),
                    label: Text(items.isEmpty ? 'Not here? Add from the library' : 'More from the library', style: inter(14, 600)),
                  ),
                ]);
              },
            ),
          ),
        ]),
      ),
    );
  }
}
