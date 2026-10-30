import 'dart:async';

import 'package:flutter/material.dart';
import '../api/live_sync.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../catalogue/item_photo.dart';
import '../outlets/outlet_header.dart';
import '../outlets/outlet_scope.dart';
import '../service/service_widgets.dart' show svcRupees;
import '../ui/theme.dart';
import 'ai_picture_sheet.dart';
import 'categories_screen.dart';
import 'dish_screen.dart';
import 'menu_api.dart';
import 'menu_build_api.dart';
import 'menu_build_screens.dart';
import 'menu_build_widgets.dart' show kMbLime;
import 'menu_widgets.dart';

/// The Menu sub-master of the restaurant Menu tab: Figma `screen-menu.png` (improvements) on top of "Menu – All items", plus the
/// Add-ons and Combos tabs and Quick add (+ ADD). Every count and switch state comes from `rst_menu`; switching stock goes through
/// `rst_menu_stock_set`. Inside [MenuHub] ([embedded]) the hub draws the banner; on its own this screen draws it.
class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key, this.api, this.buildApi, this.photos, this.embedded = false});
  final MenuApi? api;
  /// The photo tools for "AI picture" (remove.bg through the server); tests pass a fake.
  final ItemPhotoService? photos;
  final MenuBuildApi? buildApi;
  final bool embedded;

  /// Another screen asks the menu to open on one filter (the Notification Centre's "Add images to items" sets 'needs_image').
  /// The menu applies it once and clears it.
  static final requestedFilter = ValueNotifier<String?>(null);

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  // KOT, KDS, orders and stock in step: re-read when the business's live channel says so (lib/api/live_sync.dart)
  late final VoidCallback _live;

  late final MenuApi _api = widget.api ?? MenuApi();
  late final MenuBuildApi _build = widget.buildApi ?? MenuBuildApi();
  late final ItemPhotoService _photos = widget.photos ?? const DeviceItemPhotos();
  // The outlet chosen in the banner's switcher (OutletScope), like the dashboard and the other tabs.
  String? _location = OutletScope.selected.value;

  @override
  void initState() {
    super.initState();
    _live = LiveSync.watch({'stock'}, () {
      if (mounted) _reload();
    });
    OutletScope.selected.addListener(_followScope);
    final asked = MenuScreen.requestedFilter.value;
    if (asked != null) {
      _filter = asked;
      MenuScreen.requestedFilter.value = null;
    }
    MenuScreen.requestedFilter.addListener(_followRequest);
  }

  void _followRequest() {
    final asked = MenuScreen.requestedFilter.value;
    if (asked == null || !mounted) return;
    MenuScreen.requestedFilter.value = null;
    _filter = asked;
    _reload();
  }

  void _followScope() {
    if (!mounted || OutletScope.selected.value == _location) return;
    _location = OutletScope.selected.value;
    _reload();
  }
  String _q = '';
  String _filter = 'all';
  late Future<MenuData> _f = _load();
  MenuData? _last;
  String? _category; // the chosen category pill; null = All
  final _busy = <String>{};
  Timer? _debounce;

  /// What stock says about each dish (red "Out of stock" / orange "Low in stock" tags); empty when it cannot be read.
  Map<String, ({String state, String ingredient})> _signals = const {};
  Map<String, int?> _canMake = const {};

  /// Loads the menu and keeps the last answer for the header (outlet name), which lives outside the FutureBuilder.
  Future<MenuData> _load() async {
    _loadSignals();
    final m = await _api.menu(locationId: _location, q: _q, filter: _filter);
    if (mounted) setState(() => _last = m);
    return m;
  }

  Future<void> _loadSignals() async {
    try {
      final s = await _build.stockAll();
      if (mounted) {
        setState(() {
          _signals = s.signals;
          _canMake = s.canMake;
        });
      }
    } catch (_) {/* the tags are extra: without them the list still shows Available / Out of stock from the menu */}
  }

  Future<void> _reload() async {
    final next = _load();
    setState(() {
      _f = next;
    });
    try {
      await next;
    } catch (_) {
      /* drawn by the builder */
    }
  }

  @override
  void dispose() {
    OutletScope.selected.removeListener(_followScope);
    MenuScreen.requestedFilter.removeListener(_followRequest);
    _debounce?.cancel();
    _live();
    super.dispose();
  }

  void _search(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _q = v;
      _reload();
    });
  }

  void _setFilter(String f) {
    _filter = _filter == f ? 'all' : f;
    _reload();
  }

  Future<void> _stock({String? dishId, String? categoryId, required bool on}) async {
    final key = dishId ?? categoryId ?? '';
    setState(() => _busy.add(key));
    try {
      await _api.setStock(dishId: dishId, categoryId: categoryId, inStock: on);
      await _reload();
    } on MenuApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Future<void> _open(MenuDish d, {bool edit = false}) async {
    await Navigator.of(context).push(DishScreen.route(_api, d.id, locationId: _location ?? _last?.locationId, edit: edit));
    if (mounted) _reload();
  }

  /// "AI picture" on a dish: with or without background; the menu reloads when the dish's photo was replaced.
  Future<void> _aiPicture(MenuDish d) async {
    if (await showAiPictureSheet(context, d, _photos) && mounted) {
      showToast(context, 'New picture saved for ${d.name}.');
      await _reload();
    }
  }

  Future<void> _settings(String dishId) async {
    await Navigator.of(context).push(DishSettingsScreen.route(_build, dishId));
    if (mounted) _reload();
  }

  /// + ADD: quick add (name, category, price, type), then straight into the new dish's detailed settings.
  Future<void> _quickAdd() async {
    var cats = [for (final c in _last?.categories ?? const <MenuCategory>[]) c.name];
    var labels = const <String, String>{};
    // every category, empty ones and subcategories too ("Beverages › Cold coffee"); the menu's own list when that cannot be read
    try {
      final all = await _build.categories();
      if (all.choices.isNotEmpty) {
        cats = [for (final c in all.choices) c.name];
        labels = {for (final c in all.choices) c.name: c.label};
      }
    } catch (_) {}
    if (!mounted) return;
    final s = await QuickAddSheet.open(context, _build, categories: cats, labels: labels, photos: _photos);
    if (s == null || !mounted) return;
    showToast(context, '${s.name} added to ${s.category}.');
    await _settings(s.id);
  }

  /// Menu → Categories; the menu reloads when something changed there.
  Future<void> _categories() async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => CategoriesScreen(api: _build)));
    if (changed == true && mounted) {
      setState(() => _category = null);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: kBg,
        // The banner every main tab shows (ONELOCAL PARTNER, the business, the outlet ▾ and its status, bell, profile; ☰ opens the
        // side menu), then the All items / Add-ons / Combos tabs. The outlet switcher in the banner picks the menu's outlet (OutletScope).
        body: Column(children: [
          if (!widget.embedded) const OutletHeader(title: 'Menu', allowAll: false, menuKey: ValueKey('menu-side-nav')),
          Material(
            color: Colors.white,
            child: TabBar(
              labelStyle: inter(15, 600),
              unselectedLabelStyle: inter(15, 500, color: kMuted),
              labelColor: kInk,
              unselectedLabelColor: kMuted,
              indicatorColor: kInk,
              indicatorSize: TabBarIndicatorSize.tab,
              tabs: const [Tab(text: 'All items'), Tab(text: 'Add-ons'), Tab(text: 'Combos')],
            ),
          ),
          Expanded(child: TabBarView(children: [
          FutureBuilder<MenuData>(
            future: _f,
            builder: (context, snap) {
              final m = snap.data ?? _last;
              if (m == null && snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator(color: kLink));
              if (m == null || (snap.hasError && snap.connectionState == ConnectionState.done && snap.data == null && _last == null)) {
                return MenuError(error: snap.error ?? 'Could not load the menu.', onRetry: _reload);
              }
              return _AllItems(
                data: m,
                filter: _filter,
                onSearch: _search,
                onFilter: _setFilter,
                category: _category,
                onCategory: (c) => setState(() => _category = c),
                signals: _signals,
                canMake: _canMake,
                busy: _busy,
                onStock: _stock,
                onOpen: _open,
                onSettings: (d) => _settings(d.id),
                onAiPicture: _aiPicture,
                onQuickAdd: _quickAdd,
                onCategories: _categories,
                onRefresh: _reload,
              );
            },
          ),
          AddonsView(api: _build),
          CombosView(api: _build),
          ])),
        ]),
      ),
    );
  }
}

/// "All items", laid out like the store catalogue (founder, 27 Oct 2026): search and Quick add, a row of category pills (All first),
/// the stock filters, then one card of compact rows (photo, name, category and type, availability, price, ⋮ for the actions).
class _AllItems extends StatelessWidget {
  const _AllItems({
    required this.data,
    required this.filter,
    required this.onSearch,
    required this.onFilter,
    required this.category,
    required this.onCategory,
    this.signals = const {},
    this.canMake = const {},
    required this.busy,
    required this.onStock,
    required this.onOpen,
    required this.onSettings,
    required this.onAiPicture,
    required this.onQuickAdd,
    this.onCategories,
    required this.onRefresh,
  });
  final MenuData data;
  final String filter;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onFilter;
  /// The chosen category pill ([MenuCategory.id], or its name when it has none); null = All.
  final String? category;
  final ValueChanged<String?> onCategory;
  final Map<String, ({String state, String ingredient})> signals;
  /// How many of each dish can be made (dish id → count; null = not stocked; missing = no recipe).
  final Map<String, int?> canMake;
  final Set<String> busy;
  final Future<void> Function({String? dishId, String? categoryId, required bool on}) onStock;
  final Future<void> Function(MenuDish d, {bool edit}) onOpen;
  final ValueChanged<MenuDish> onSettings;
  final Future<void> Function(MenuDish d) onAiPicture;
  final VoidCallback onQuickAdd;

  /// Opens Menu → Categories (editors only).
  final VoidCallback? onCategories;
  final Future<void> Function() onRefresh;

  static String _key(MenuCategory c) => c.id ?? c.name;

  static String _filterLabel(String f) => switch (f) {
        'needs_image' => 'Needs image',
        'out_of_stock' => 'Out of stock',
        'in_stock' => 'In stock',
        _ => f,
      };

  @override
  Widget build(BuildContext context) {
    final total = data.count('total');
    final cats = data.categories;
    // Subcategories (0616) sit under their main category's pill: the main pills are the categories without a parent, plus a parent
    // that holds only subcategories. Choosing a main pill shows it and its subcategories, with a second row to pick one of them.
    String topOf(MenuCategory c) => c.parentId ?? _key(c);
    final mains = <({String key, String name})>[];
    for (final c in cats) {
      final k = topOf(c);
      if (!mains.any((m) => m.key == k)) mains.add((key: k, name: c.parentName ?? c.name));
    }
    final picked = category == null ? null : cats.where((c) => _key(c) == category).firstOrNull;
    final top = category == null ? null : (picked == null ? category : topOf(picked)); // the main pill that is lit
    final pickedIsTop = category != null && category == top;
    final subs = top == null ? const <MenuCategory>[] : [for (final c in cats) if (c.parentId == top) c];
    final shown = category == null ? cats : pickedIsTop ? [for (final c in cats) if (topOf(c) == top) c] : [?picked];
    // the whole-category stock switch: when one category's dishes are all that shows
    final chosen = shown.length == 1 && category != null ? shown.first : null;
    final rows = [for (final c in shown) for (final d in c.items) (c, d)];
    return RefreshIndicator(
      onRefresh: onRefresh,
      color: kLink,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
        children: [
          // Search, and beside it the lime "+ Quick add" (as on the store catalogue); it replaces the floating ADD button.
          Row(children: [
            Expanded(
              child: TextField(
                key: const ValueKey('menu-search'),
                onChanged: onSearch,
                style: inter(15, 400),
                decoration: InputDecoration(
                  prefixIcon: const Icon(LucideIcons.search, size: 18, color: kMuted),
                  hintText: 'Search items',
                  hintStyle: inter(15, 400, color: kMuted),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kFieldBorder)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kFieldBorder)),
                ),
              ),
            ),
            if (data.canEdit) ...[
              const SizedBox(width: 10),
              Material(
                color: kMbLime,
                borderRadius: BorderRadius.circular(999),
                child: InkWell(
                  key: const ValueKey('menu-quick-add'),
                  borderRadius: BorderRadius.circular(999),
                  onTap: onQuickAdd,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(LucideIcons.plus, size: 18, color: kInk),
                      const SizedBox(width: 6),
                      Text('Quick add', style: inter(15, 700)),
                    ]),
                  ),
                ),
              ),
            ],
          ]),
          const SizedBox(height: 14),
          // Category pills, as on the catalogue: All (lime when chosen), then each category.
          // the pills scroll; the Categories button stays in view at the end of the row (it was hidden past the last pill)
          Row(children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  _CatPill(key: const ValueKey('cat-pill-all'), label: 'All', on: category == null, onTap: () => onCategory(null)),
                  for (final m in mains) ...[
                    const SizedBox(width: 10),
                    _CatPill(key: ValueKey('cat-pill-${m.name}'), label: m.name, on: top == m.key, onTap: () => onCategory(m.key)),
                  ],
                ]),
              ),
            ),
            if (data.canEdit && onCategories != null) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: 'Categories',
                child: Material(
                  color: Colors.white,
                  shape: const CircleBorder(side: BorderSide(color: kFieldBorder)),
                  child: InkWell(
                    key: const ValueKey('menu-categories'),
                    customBorder: const CircleBorder(),
                    onTap: onCategories,
                    child: const SizedBox(width: 42, height: 42, child: Icon(LucideIcons.folderTree, size: 18, color: kInk)),
                  ),
                ),
              ),
            ],
          ]),
          // the chosen main category's subcategories
          if (subs.isNotEmpty) ...[
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                _SubPill(key: const ValueKey('sub-pill-all'), label: 'All ${mains.firstWhere((m) => m.key == top).name}', on: pickedIsTop, onTap: () => onCategory(top)),
                for (final s in subs) ...[
                  const SizedBox(width: 8),
                  _SubPill(key: ValueKey('sub-pill-${s.name}'), label: s.name, on: category == _key(s), onTap: () => onCategory(_key(s))),
                ],
              ]),
            ),
          ],
          // No stock filter pills (founder, 27 Oct 2026): stock shows as tags on each dish. A filter asked for elsewhere (Notification
          // Centre "Add images" → needs_image) shows here as one pill to clear it.
          if (filter != 'all')
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: InputChip(
                  key: const ValueKey('menu-filter-clear'),
                  label: Text('Showing: ${_filterLabel(filter)}', style: inter(13, 600, color: Colors.white)),
                  backgroundColor: kPrimary,
                  deleteIconColor: Colors.white,
                  side: BorderSide.none,
                  shape: const StadiumBorder(),
                  onDeleted: () => onFilter(filter),
                  onPressed: () => onFilter(filter),
                ),
              ),
            ),
          // One category chosen: its whole-category stock switch.
          if (chosen != null && data.canEdit && chosen.id != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(children: [
                Expanded(
                  child: Text('${chosen.name} (${chosen.count}) · ${chosen.allInStock ? 'All items in stock' : 'Some items out of stock'}',
                      key: ValueKey('cat-${chosen.name}'), style: inter(13, 600, color: chosen.allInStock ? const Color(0xFF2E7D32) : const Color(0xFFB54708))),
                ),
                Switch(
                  key: ValueKey('cat-switch-${chosen.name}'),
                  value: chosen.allInStock,
                  activeTrackColor: kCheck,
                  onChanged: busy.contains(chosen.id) ? null : (v) => onStock(categoryId: chosen.id, on: v),
                ),
              ]),
            ),
          const SizedBox(height: 12),
          // "Add images" / "Add descriptions" tips live in the Notification Centre (menuTips in app_routes), not on the menu.
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Text(total == 0 ? 'No dishes on the menu yet.' : 'No dish matches.', textAlign: TextAlign.center, style: inter(14, 500, color: kMuted)),
            )
          else
            Material(
              color: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0xFFECEDE8))),
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) const Divider(height: 1, color: kLine),
                  _DishRow(dish: rows[i].$2, category: rows[i].$1.name, canEdit: data.canEdit, busy: busy.contains(rows[i].$2.id), signal: signals[rows[i].$2.id], hasRecipe: canMake.containsKey(rows[i].$2.id), canMake: canMake[rows[i].$2.id],
                      onOpen: onOpen, onSettings: onSettings, onStock: onStock, onAiPicture: onAiPicture),
                ],
              ]),
            ),
        ],
      ),
    );
  }
}

/// A subcategory pill, smaller and outlined: dark when chosen.
class _SubPill extends StatelessWidget {
  const _SubPill({super.key, required this.label, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: on ? kInk : Colors.white,
        shape: StadiumBorder(side: BorderSide(color: on ? kInk : kFieldBorder)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Text(label, style: inter(13, on ? 700 : 500, color: on ? Colors.white : kInk)),
          ),
        ),
      );
}

/// A category pill of the catalogue: lime and bold when chosen, white and muted otherwise.
class _CatPill extends StatelessWidget {
  const _CatPill({super.key, required this.label, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: on,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(color: on ? kMbLime : Colors.white, borderRadius: BorderRadius.circular(999)),
            child: Text(label, style: inter(13, on ? 700 : 500, color: on ? kInk : kMuted)),
          ),
        ),
      );
}

/// One dish as a catalogue row: photo (or a tinted tile), name, "Category · Veg", "● Available", price, and ⋮ for the actions.
class _DishRow extends StatelessWidget {
  const _DishRow({required this.dish, required this.category, required this.canEdit, required this.busy, this.signal, this.hasRecipe = false, this.canMake, required this.onOpen, required this.onSettings, required this.onStock, required this.onAiPicture});
  /// What stock says about this dish ('out' | 'low' and the ingredient), from `menu_stock_signals`; null = nothing to say.
  final ({String state, String ingredient})? signal;
  final bool hasRecipe;
  final int? canMake;
  final MenuDish dish;
  final String category;
  final bool canEdit, busy;
  final Future<void> Function(MenuDish d, {bool edit}) onOpen;
  final ValueChanged<MenuDish> onSettings;
  final Future<void> Function({String? dishId, String? categoryId, required bool on}) onStock;
  final Future<void> Function(MenuDish d) onAiPicture;

  static const _tints = [Color(0xFFE3F1FC), Color(0xFFFDF0DC), Color(0xFFFBF3D0), Color(0xFFFCE9E7), Color(0xFFE9F2FB), Color(0xFFFFF7D6)];
  static String _type(String t) => switch (t) { 'non_veg' => 'Non-veg', 'egg' => 'Egg', _ => 'Veg' };
  /// Small, Medium, Large read S, M, L; any other size name keeps its first letter.
  static String _sizeLetter(String name) => name.trim().isEmpty ? '' : name.trim()[0].toUpperCase();

  Future<void> _more(BuildContext context) async {
    final d = dish;
    final pick = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8), child: Text(d.name, style: inter(17, 700))),
            ListTile(key: ValueKey('view-${d.id}'), leading: const Icon(LucideIcons.eye, color: kInk), title: Text('View details', style: inter(15, 600)), onTap: () => Navigator.pop(c, 'view')),
            if (canEdit) ...[
              ListTile(key: ValueKey('edit-${d.id}'), leading: const Icon(LucideIcons.pencil, color: kInk), title: Text('Edit description & timings', style: inter(15, 600)), onTap: () => Navigator.pop(c, 'edit')),
              ListTile(key: ValueKey('settings-${d.id}'), leading: const Icon(LucideIcons.settings2, color: kInk), title: Text('Settings', style: inter(15, 600)), onTap: () => Navigator.pop(c, 'settings')),
              ListTile(
                key: ValueKey('ai-photo-${d.id}'),
                leading: const Icon(LucideIcons.sparkles, color: kInk),
                title: Text('AI picture', style: inter(15, 600)),
                subtitle: Text('With or without background', style: inter(12.5, 400, color: kMuted)),
                onTap: () => Navigator.pop(c, 'ai'),
              ),
              ListTile(
                key: ValueKey('stock-${d.id}'),
                leading: Icon(d.inStock ? LucideIcons.circleOff : LucideIcons.circleCheck, color: d.inStock ? const Color(0xFFB42318) : const Color(0xFF2E7D32)),
                title: Text(d.inStock ? 'Mark out of stock' : 'Mark in stock', style: inter(15, 600)),
                onTap: () => Navigator.pop(c, 'stock'),
              ),
            ],
          ]),
        ),
      ),
    );
    switch (pick) {
      case 'view':
        await onOpen(d);
      case 'edit':
        await onOpen(d, edit: true);
      case 'settings':
        onSettings(d);
      case 'ai':
        await onAiPicture(d);
      case 'stock':
        await onStock(dishId: d.id, on: !d.inStock);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = dish;
    final tint = _tints[(d.name.isEmpty ? 0 : d.name.codeUnitAt(0)) % _tints.length];
    // "● Available" (green), then beside it red "Out of stock" or orange "Low in stock" when stock says so. A dish switched off on
    // the menu shows only the red tag.
    final status = ['Available', if (d.hasWindows) d.orderableNow ? 'Serving now' : 'Not orderable now'].join(' · ');
    final out = !d.inStock || signal?.state == 'out';
    final low = !out && signal?.state == 'low';
    return Semantics(
      button: true,
      label: 'Open ${d.name}',
      child: InkWell(
        key: ValueKey('dish-${d.id}'),
        onTap: () => onOpen(d),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 52,
              height: 52,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(14)),
              child: d.imageUrl != null
                  ? Image.network(d.imageUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.utensils, size: 22, color: kMuted))
                  : const Icon(LucideIcons.utensils, size: 22, color: kMuted),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(d.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(17, 600)),
                const SizedBox(height: 4),
                Row(children: [
                  FoodTypeMark(d.foodType),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text([category, _type(d.foodType), if (d.variants > 0 && d.sizes.isEmpty) '${d.variants} Variant${d.variants == 1 ? '' : 's'}'].join(' · '),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13, 400, color: kMuted)),
                  ),
                ]),
                // its sizes with their prices (0611), on one quiet line: "S ₹69 · M ₹89 · L ₹109" (founder, 29 Oct 2026: one chip per size
                // was too busy). S / M / L for Small / Medium / Large; the full names stay for screen readers. How many can be made shows once,
                // below, for the smallest size.
                if (d.sizes.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Semantics(
                    label: d.sizes.map((s) => '${s.name} ${svcRupees(s.price)}').join(', '),
                    excludeSemantics: true,
                    child: Text(
                      d.sizes.map((s) => '${_sizeLetter(s.name)} ${svcRupees(s.price)}').join('  ·  '),
                      key: ValueKey('sizes-${d.id}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: inter(12.5, 600, color: const Color(0xFF2F6B0E)),
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  if (d.inStock)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 9, height: 9, decoration: const BoxDecoration(color: Color(0xFF2E7D32), shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      Text(status, style: inter(13, 400, color: kMuted)),
                    ]),
                  if (out)
                    _StockTag(
                      key: ValueKey('tag-out-${d.id}'),
                      label: 'Out of stock',
                      bg: const Color(0xFFFEE4E2),
                      fg: const Color(0xFFB42318),
                      why: !d.inStock ? 'Switched off on the menu' : '${signal!.ingredient} has run out',
                    ),
                  if (low)
                    _StockTag(
                      key: ValueKey('tag-low-${d.id}'),
                      label: 'Low in stock',
                      bg: const Color(0xFFFFEDD5),
                      fg: const Color(0xFFC2410C),
                      why: '${signal!.ingredient} is running low',
                    ),
                  CanMakeLabel(key: ValueKey('can-make-${d.id}'), hasRecipe: hasRecipe, count: canMake, size: 13),
                ]),
              ]),
            ),
            const SizedBox(width: 8),
            Text(svcRupees(d.priceMinor / 100), style: inter(17, 700)),
            busy
                ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: kMuted)))
                : IconButton(
                    key: ValueKey('more-${d.id}'),
                    tooltip: 'Actions for ${d.name}',
                    onPressed: () => _more(context),
                    icon: const Icon(LucideIcons.ellipsisVertical, size: 20, color: kMuted),
                  ),
          ]),
        ),
      ),
    );
  }
}

/// A small stock tag beside "Available": red "Out of stock", orange "Low in stock". Long-press (or hover) says why.
class _StockTag extends StatelessWidget {
  const _StockTag({super.key, required this.label, required this.bg, required this.fg, required this.why});
  final String label, why;
  final Color bg, fg;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: why,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
          child: Text(label, style: inter(12, 700, color: fg)),
        ),
      );
}
