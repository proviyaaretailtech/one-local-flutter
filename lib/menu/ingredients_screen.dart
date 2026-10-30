import 'dart:async';

import 'package:flutter/material.dart';
import '../api/live_sync.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_nav.dart';
import '../ui/theme.dart';
import 'menu_api.dart' show MenuApiException;
import 'menu_build_api.dart';
import 'menu_build_widgets.dart';
import 'menu_widgets.dart' show MenuError;

/// The Ingredients sub-master of the Menu tab: every ingredient the business uses, its cost per unit (last purchase, else the supplier's
/// price, else the business's own figure), what is on hand, and how many recipes use it. Ingredients come from a preloaded library of
/// ~200 (each added copy is the business's own and editable) or are typed in; "Buy from supplier" opens a purchase order.
class IngredientsView extends StatefulWidget {
  const IngredientsView({super.key, required this.api});
  final MenuBuildApi api;
  @override
  State<IngredientsView> createState() => _IngredientsViewState();
}

class _IngredientsViewState extends State<IngredientsView> {
  // KOT, KDS, orders and stock in step: re-read when the business's live channel says so (lib/api/live_sync.dart)
  late final VoidCallback _live;

  @override
  void initState() {
    super.initState();
    _live = LiveSync.watch({'stock'}, () {
      if (mounted) _reload();
    });
  }

  late Future<IngredientList> _f = widget.api.ingredients();
  IngredientList? _last;
  String _q = '';
  String? _cat;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _live();
    super.dispose();
  }

  Future<void> _reload() async {
    final next = widget.api.ingredients(q: _q, category: _cat);
    setState(() { _f = next; });
    try {
      _last = await next;
    } catch (_) {/* drawn by the builder */}
  }

  Future<void> _openLibrary() async {
    final added = await Navigator.of(context).push<int>(MaterialPageRoute(builder: (_) => LibraryPickerScreen(api: widget.api)));
    if (!mounted) return;
    if (added != null && added > 0) showToast(context, added == 1 ? '1 ingredient added.' : '$added ingredients added.');
    _reload();
  }

  Future<void> _edit([Ingredient? i]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => IngredientSheet(api: widget.api, ingredient: i, categories: _last?.categories ?? const []),
    );
    if (saved == true && mounted) {
      showToast(context, 'Saved.');
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<IngredientList>(
      future: _f,
      builder: (context, snap) {
        final d = snap.data ?? _last;
        if (d == null && snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator(color: kLink));
        if (d == null) return MenuError(error: snap.error ?? 'Could not load the ingredients.', onRetry: _reload);
        _last = d;
        return RefreshIndicator(
          onRefresh: _reload,
          child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 110), children: [
            Row(children: [
              StatTile(label: 'Ingredients', value: '${d.total}'),
              const SizedBox(width: 8),
              StatTile(label: 'Without a cost', value: '${d.noCost}', tone: d.noCost > 0 ? (kMbAmberBg, kMbAmber) : null),
              const SizedBox(width: 8),
              StatTile(label: 'Low stock', value: '${d.low}', tone: d.low > 0 ? (kMbRedBg, kMbRed) : null),
            ]),
            const SizedBox(height: 12),
            if (d.canEdit)
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('ing-library'),
                    style: FilledButton.styleFrom(backgroundColor: kInk, minimumSize: const Size.fromHeight(46), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    onPressed: _openLibrary,
                    icon: const Icon(LucideIcons.libraryBig, size: 18, color: kMbLime),
                    label: Text('Add from library', style: inter(14, 700, color: kMbLime)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('ing-custom'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46), side: const BorderSide(color: kInk), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    onPressed: () => _edit(),
                    icon: const Icon(LucideIcons.plus, size: 18, color: kInk),
                    label: Text('New ingredient', style: inter(14, 600)),
                  ),
                ),
              ]),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('ing-search'),
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), () {
                  _q = v;
                  _reload();
                });
              },
              style: inter(14, 500),
              decoration: InputDecoration(
                hintText: 'Search ingredient',
                prefixIcon: const Icon(LucideIcons.search, size: 18, color: kMuted),
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kLine)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kLine)),
              ),
            ),
            if (d.categories.isNotEmpty) ...[
              const SizedBox(height: 10),
              FilterChips(
                keyPrefix: 'ing-cat',
                items: [(null, 'All'), for (final c in d.categories) (c, c)],
                selected: _cat,
                onSelect: (c) {
                  _cat = c;
                  _reload();
                },
              ),
            ],
            const SizedBox(height: 12),
            if (d.items.isEmpty)
              MbEmpty(
                icon: LucideIcons.carrot,
                title: d.total == 0 ? 'No ingredients yet' : 'Nothing matches',
                body: d.total == 0
                    ? 'Start from the library of 200+ common ingredients with typical prices, then edit them to yours.'
                    : 'Try another word or category.',
                action: d.total == 0 && d.canEdit ? 'Open the library' : null,
                onAction: _openLibrary,
              )
            else
              for (final i in d.items) _IngredientRow(i: i, onTap: d.canEdit ? () => _edit(i) : null),
          ]),
        );
      },
    );
  }
}

class _IngredientRow extends StatelessWidget {
  const _IngredientRow({required this.i, this.onTap});
  final Ingredient i;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final noCost = i.costMinor == null;
    return MbRowSurface(
      child: InkWell(
        key: ValueKey('ing-${i.name}'),
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(i.name, style: inter(15, 600)),
                const SizedBox(height: 2),
                Text([if (i.category.isNotEmpty) i.category, 'per ${i.unit}', if (i.usedIn > 0) 'in ${i.usedIn} recipe${i.usedIn == 1 ? '' : 's'}'].join(' · '),
                    style: inter(12, 400, color: kMuted)),
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  _Tag('On hand ${_qty(i.onHand)} ${i.unit}', i.low ? kMbRedBg : kField, i.low ? kMbRed : kMuted),
                  if (i.supplier != null) _Tag('${i.supplier!['name']}', kField, kMuted),
                ]),
              ]),
            ),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(noCost ? 'Set cost' : '${rupeesMinor(i.costMinor)}/${i.unit}', style: inter(14, 700, color: noCost ? kMbAmber : kInk)),
              const SizedBox(height: 2),
              Text(costSourceLabel(i.costSource), style: inter(11, 500, color: kMuted)),
            ]),
          ]),
        ),
      ),
    );
  }
}

String _qty(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');

class _Tag extends StatelessWidget {
  const _Tag(this.text, this.bg, this.fg);
  final String text;
  final Color bg, fg;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: inter(11, 600, color: fg)),
      );
}

/// Create or edit one ingredient: name, category, unit, cost per unit, reorder level; and "Buy from supplier".
class IngredientSheet extends StatefulWidget {
  const IngredientSheet({super.key, required this.api, this.ingredient, this.categories = const []});
  final MenuBuildApi api;
  final Ingredient? ingredient;
  final List<String> categories;
  @override
  State<IngredientSheet> createState() => _IngredientSheetState();
}

class _IngredientSheetState extends State<IngredientSheet> {
  late final _name = TextEditingController(text: widget.ingredient?.name ?? '');
  late final _cat = TextEditingController(text: widget.ingredient?.category ?? '');
  late final _cost = TextEditingController(text: widget.ingredient?.costMinor == null ? '' : (widget.ingredient!.costMinor! / 100).toStringAsFixed(2));
  late final _reorder = TextEditingController(text: widget.ingredient == null || widget.ingredient!.reorderLevel == 0 ? '' : _qty(widget.ingredient!.reorderLevel));
  late String _unit = widget.ingredient?.unit.isNotEmpty == true ? widget.ingredient!.unit : 'kg';
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    final cost = numOf(_cost.text);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.saveIngredient(
        id: widget.ingredient?.id,
        name: _name.text.trim(),
        category: _cat.text,
        unit: _unit,
        costMinor: cost == null ? null : (cost * 100).round(),
        reorderLevel: numOf(_reorder.text) ?? 0,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on MenuApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.ingredient;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 16, 18, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(i == null ? 'New ingredient' : 'Edit ingredient', style: inter(18, 700)),
          if (i != null && i.costSource != 'set_by_you' && i.costSource != 'none')
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Recipes use the ${costSourceLabel(i.costSource).toLowerCase()} (${rupeesMinor(i.costMinor)}/${i.unit}). The cost below is used only until there is a purchase.',
                  style: inter(12, 400, color: kMuted, height: 1.35)),
            ),
          const SizedBox(height: 14),
          MbField(label: 'Name', controller: _name, hint: 'e.g. Paneer', fieldKey: const ValueKey('ing-name'), maxLength: 80),
          MbField(label: 'Category', controller: _cat, hint: 'e.g. Dairy', fieldKey: const ValueKey('ing-category'), maxLength: 40),
          if (widget.categories.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                for (final c in widget.categories.take(12))
                  ActionChip(label: Text(c, style: inter(12, 500)), backgroundColor: kField, side: const BorderSide(color: kFieldBorder), onPressed: () => setState(() => _cat.text = c)),
              ]),
            ),
          MbSegments(
            label: 'Unit',
            keyPrefix: 'ing-unit',
            options: const [('kg', 'kg'), ('g', 'g'), ('l', 'litre'), ('ml', 'ml'), ('pc', 'piece'), ('dozen', 'dozen'), ('pack', 'pack'), ('bunch', 'bunch')],
            value: _unit,
            onChanged: (u) => setState(() => _unit = u),
          ),
          MbField(label: 'Cost per $_unit', controller: _cost, number: true, prefix: '₹ ', hint: '0.00', fieldKey: const ValueKey('ing-cost')),
          MbField(label: 'Reorder when stock falls to ($_unit)', controller: _reorder, number: true, hint: 'Optional', fieldKey: const ValueKey('ing-reorder')),
          if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_error!, style: inter(13, 500, color: kError))),
          MbPrimaryButton(i == null ? 'Add ingredient' : 'Save', busy: _busy, onPressed: _save, key: const ValueKey('ing-save')),
          if (i != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              key: const ValueKey('ing-buy'),
              onPressed: () {
                Navigator.of(context).pop();
                HomeNav.go(context, HomeNav.newPurchase, 'Purchasing');
              },
              icon: const Icon(LucideIcons.truck, size: 18, color: kLink),
              label: Text('Buy from supplier', style: inter(14, 600, color: kLink)),
            ),
          ],
        ]),
      ),
    );
  }
}

/// The preloaded library: search or pick a category, tick what the business uses, add them in one go.
class LibraryPickerScreen extends StatefulWidget {
  const LibraryPickerScreen({super.key, required this.api});
  final MenuBuildApi api;
  @override
  State<LibraryPickerScreen> createState() => _LibraryPickerScreenState();
}

class _LibraryPickerScreenState extends State<LibraryPickerScreen> {
  late Future<List<LibraryIngredient>> _f = widget.api.library();
  List<LibraryIngredient> _all = const [];
  final _picked = <String>{};
  String _q = '';
  String? _cat;
  bool _busy = false;

  Future<void> _add() async {
    setState(() => _busy = true);
    try {
      final r = await widget.api.addFromLibrary(_picked.toList());
      if (mounted) Navigator.of(context).pop(r.added ?? _picked.length);
    } on MenuApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        title: Text('Ingredient library', style: inter(17, 700)),
      ),
      body: FutureBuilder<List<LibraryIngredient>>(
        future: _f,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done && _all.isEmpty) return const Center(child: CircularProgressIndicator(color: kLink));
          if (snap.hasError && _all.isEmpty) return MenuError(error: snap.error!, onRetry: () => setState(() { _f = widget.api.library(); }));
          if (snap.hasData) _all = snap.data!;
          final cats = {for (final l in _all) l.category}.toList()..sort();
          final shown = _all.where((l) => (_cat == null || l.category == _cat) && (_q.isEmpty || l.name.toLowerCase().contains(_q.toLowerCase()))).toList();
          return ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 100), children: [
            Text('Typical Indian wholesale prices to start from. Once added, each ingredient is yours to edit, and your purchases update its cost.',
                style: inter(12.5, 400, color: kMuted, height: 1.4)),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('lib-search'),
              onChanged: (v) => setState(() => _q = v.trim()),
              style: inter(14, 500),
              decoration: InputDecoration(
                hintText: 'Search ${_all.length} ingredients',
                prefixIcon: const Icon(LucideIcons.search, size: 18, color: kMuted),
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kLine)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kLine)),
              ),
            ),
            const SizedBox(height: 10),
            FilterChips(keyPrefix: 'lib-cat', items: [(null, 'All'), for (final c in cats) (c, c)], selected: _cat, onSelect: (c) => setState(() => _cat = c)),
            const SizedBox(height: 10),
            for (final l in shown)
              MbRowSurface(
                radius: 12,
                margin: const EdgeInsets.only(bottom: 6),
                child: CheckboxListTile(
                  key: ValueKey('lib-${l.code}'),
                  value: l.added || _picked.contains(l.code),
                  onChanged: l.added ? null : (v) => setState(() => v == true ? _picked.add(l.code) : _picked.remove(l.code)),
                  activeColor: kInk,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  title: Text(l.name, style: inter(14, 600, color: l.added ? kMuted : kInk)),
                  subtitle: Text(l.added ? '${l.category} · already added' : '${l.category} · ~${rupeesMinor(l.typicalCostMinor)}/${l.unit}', style: inter(12, 400, color: kMuted)),
                  secondary: Icon(LucideIcons.squareDot, size: 16, color: l.isVeg ? kMbGreen : kMbRed),
                ),
              ),
          ]);
        },
      ),
      bottomNavigationBar: _picked.isEmpty
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: MbPrimaryButton('Add ${_picked.length} ingredient${_picked.length == 1 ? '' : 's'}', busy: _busy, onPressed: _add, key: const ValueKey('lib-add')),
            ),
    );
  }
}
