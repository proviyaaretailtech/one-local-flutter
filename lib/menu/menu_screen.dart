import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../service/service_widgets.dart' show svcRupees;
import '../ui/app_header.dart';
import '../ui/theme.dart';
import 'dish_screen.dart';
import 'menu_api.dart';
import 'menu_widgets.dart';

/// The restaurant Menu tab: Figma `screen-menu.png` (improvements) on top of "Menu – All items" / "Menu – Add ons".
/// Every count and switch state comes from `rst_menu`; switching stock goes through `rst_menu_stock_set`.
class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key, this.api});
  final MenuApi? api;
  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  late final MenuApi _api = widget.api ?? MenuApi();
  String? _location;
  String _q = '';
  String _filter = 'all';
  late Future<MenuData> _f = _load();
  MenuData? _last;
  final _collapsed = <String>{};
  final _busy = <String>{};
  Timer? _debounce;

  /// Loads the menu and keeps the last answer for the header (outlet name), which lives outside the FutureBuilder.
  Future<MenuData> _load() async {
    final m = await _api.menu(locationId: _location, q: _q, filter: _filter);
    if (mounted) setState(() => _last = m);
    return m;
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
    _debounce?.cancel();
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

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: kBg,
        floatingActionButton: FloatingActionButton.extended(
          key: const ValueKey('menu-add'),
          backgroundColor: const Color(0xFFE4E4E0),
          foregroundColor: kInk,
          elevation: 0,
          onPressed: () => showToast(context, 'Adding dishes opens in a later release.'),
          icon: const Icon(LucideIcons.plus),
          label: Text('ADD', style: inter(15, 600)),
        ),
        body: Column(
          children: [
            // the banner (☰ always), the one back arrow with the outlet picker under it, then the two lists
            AppHeader(
              title: 'Menu',
              back: true,
              under: MenuOutletPicker(
                name: _last?.locationName.isNotEmpty == true ? _last!.locationName : 'My outlet',
                outlets: _last?.outlets ?? const [],
                selectedId: _location ?? _last?.locationId,
                onPicked: (id) {
                  _location = id;
                  _reload();
                },
              ),
            ),
            TabBar(
              labelStyle: inter(15, 600),
              unselectedLabelStyle: inter(15, 500, color: kMuted),
              labelColor: kInk,
              unselectedLabelColor: kMuted,
              indicatorColor: kInk,
              indicatorSize: TabBarIndicatorSize.tab,
              tabs: const [
                Tab(text: 'All items'),
                Tab(text: 'Add ons'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
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
                        collapsed: _collapsed,
                        busy: _busy,
                        onToggleCollapse: (k) => setState(() => _collapsed.contains(k) ? _collapsed.remove(k) : _collapsed.add(k)),
                        onStock: _stock,
                        onOpen: _open,
                        onRefresh: _reload,
                      );
                    },
                  ),
                  const _AddOns(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AllItems extends StatelessWidget {
  const _AllItems({
    required this.data,
    required this.filter,
    required this.onSearch,
    required this.onFilter,
    required this.collapsed,
    required this.busy,
    required this.onToggleCollapse,
    required this.onStock,
    required this.onOpen,
    required this.onRefresh,
  });
  final MenuData data;
  final String filter;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onFilter;
  final Set<String> collapsed;
  final Set<String> busy;
  final ValueChanged<String> onToggleCollapse;
  final Future<void> Function({String? dishId, String? categoryId, required bool on}) onStock;
  final Future<void> Function(MenuDish d, {bool edit}) onOpen;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final total = data.count('total');
    return RefreshIndicator(
      onRefresh: onRefresh,
      color: kLink,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
        children: [
          TextField(
            key: const ValueKey('menu-search'),
            onChanged: onSearch,
            style: inter(15, 400),
            decoration: InputDecoration(
              prefixIcon: const Icon(LucideIcons.search, size: 18, color: kMuted),
              hintText: 'Search item',
              hintStyle: inter(15, 400, color: kMuted),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: kFieldBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: kFieldBorder),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _Chip(
                  key: const ValueKey('chip-out_of_stock'),
                  label: 'Out of stock ${data.count('out_of_stock')}',
                  selected: filter == 'out_of_stock',
                  onTap: () => onFilter('out_of_stock'),
                ),
                _Chip(
                  key: const ValueKey('chip-in_stock'),
                  label: 'In stock ${data.count('in_stock')}',
                  selected: filter == 'in_stock',
                  onTap: () => onFilter('in_stock'),
                ),
                _Chip(
                  key: const ValueKey('chip-needs_image'),
                  label: 'Needs image ${data.count('needs_image')}',
                  selected: filter == 'needs_image',
                  onTap: () => onFilter('needs_image'),
                ),
              ],
            ),
          ),
          if (total > 0 && (data.count('needs_image') > 0 || data.count('missing_description') > 0)) ...[
            const SizedBox(height: 14),
            Text('RECOMMENDED IMPROVEMENTS', style: inter(12, 600, color: kMuted)),
            const SizedBox(height: 8),
            if (data.count('needs_image') > 0)
              _Improve(
                icon: LucideIcons.image,
                title: 'Add images to items',
                line: '${data.count('with_image')}/$total items complete',
                onTap: () => onFilter('needs_image'),
              ),
            if (data.count('missing_description') > 0)
              _Improve(
                icon: LucideIcons.alignLeft,
                title: 'Add descriptions',
                line: 'Missing for ${data.count('missing_description')} items · Write with AI on the dish',
              ),
          ],
          const SizedBox(height: 8),
          if (data.categories.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Text(
                total == 0 ? 'No dishes on the menu yet.' : 'No dish matches.',
                textAlign: TextAlign.center,
                style: inter(14, 500, color: kMuted),
              ),
            ),
          for (final c in data.categories) _category(context, c),
        ],
      ),
    );
  }

  Widget _category(BuildContext context, MenuCategory c) {
    final key = c.id ?? 'other';
    final open = !collapsed.contains(key);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(c.name, style: inter(18, 700)),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${c.name} (${c.count})', key: ValueKey('cat-${c.name}'), style: inter(16, 600)),
                            Text(
                              c.allInStock ? 'All items in stock' : 'Some items out of stock',
                              style: inter(12, 500, color: c.allInStock ? const Color(0xFF2E7D32) : const Color(0xFFB54708)),
                            ),
                          ],
                        ),
                      ),
                      if (data.canEdit && c.id != null)
                        Switch(
                          key: ValueKey('cat-switch-${c.name}'),
                          value: c.allInStock,
                          activeTrackColor: kCheck,
                          onChanged: busy.contains(c.id) ? null : (v) => onStock(categoryId: c.id, on: v),
                        ),
                      IconButton(
                        icon: Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown, color: kInk),
                        onPressed: () => onToggleCollapse(key),
                      ),
                    ],
                  ),
                ),
                if (open)
                  for (final d in c.items) _dish(d),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dish(MenuDish d) => Container(
    key: ValueKey('dish-${d.id}'),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: kLine)),
    ),
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      FoodTypeMark(d.foodType),
                      const SizedBox(width: 8),
                      Expanded(child: Text(d.name, style: inter(16, 600))),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(svcRupees(d.priceMinor / 100), style: inter(15, 700)),
                  if ((d.description ?? '').isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      d.description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: inter(13, 400, color: kMuted),
                    ),
                  ],
                  if (d.hasWindows)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        d.orderableNow ? 'Serving times set · orderable now' : 'Serving times set · not orderable now',
                        style: inter(11, 500, color: kMuted),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            DishPhoto(urls: [?d.imageUrl], height: 80, width: 80),
          ],
        ),
        if (d.variants > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('${d.variants} Variant${d.variants == 1 ? '' : 's'}', style: inter(13, 600)),
          ),
        Row(
          children: [
            Expanded(
              child: Text(
                d.inStock ? 'Item is in stock' : 'Item is out of stock',
                style: inter(13, 500, color: d.inStock ? const Color(0xFF2E7D32) : const Color(0xFFB42318)),
              ),
            ),
            if (data.canEdit)
              Switch(
                key: ValueKey('stock-${d.id}'),
                value: d.inStock,
                activeTrackColor: kCheck,
                onChanged: busy.contains(d.id) ? null : (v) => onStock(dishId: d.id, on: v),
              ),
          ],
        ),
        const Divider(height: 1, color: kLine),
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                key: ValueKey('view-${d.id}'),
                onPressed: () => onOpen(d),
                icon: const Icon(LucideIcons.eye, size: 16, color: kInk),
                label: Text('View details', style: inter(13, 600)),
              ),
            ),
            if (data.canEdit)
              Expanded(
                child: TextButton.icon(
                  key: ValueKey('edit-${d.id}'),
                  onPressed: () => onOpen(d, edit: true),
                  icon: const Icon(LucideIcons.pencil, size: 16, color: kMuted),
                  label: Text('Edit', style: inter(13, 500, color: kMuted)),
                ),
              ),
          ],
        ),
      ],
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label, style: inter(13, 500, color: selected ? Colors.white : kInk)),
      selected: selected,
      showCheckmark: false,
      selectedColor: kPrimary,
      backgroundColor: Colors.white,
      side: const BorderSide(color: kFieldBorder),
      shape: const StadiumBorder(),
      onSelected: (_) => onTap(),
    ),
  );
}

class _Improve extends StatelessWidget {
  const _Improve({required this.icon, required this.title, required this.line, this.onTap});
  final IconData icon;
  final String title;
  final String line;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: ListTile(
      tileColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kLine),
      ),
      onTap: onTap,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, size: 20, color: kMuted),
      ),
      title: Text(title, style: inter(14, 600)),
      subtitle: Text(line, style: inter(12, 400, color: kMuted)),
    ),
  );
}

/// Figma "Menu – Add ons": no add-on groups exist in the database yet (spec open question 4), so the tab says so plainly.
class _AddOns extends StatelessWidget {
  const _AddOns();
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.layers, size: 36, color: kMuted),
          const SizedBox(height: 12),
          Text('Add-on groups are not set up in this app yet.', key: const ValueKey('addons-empty'), textAlign: TextAlign.center, style: inter(15, 600)),
          const SizedBox(height: 6),
          Text(
            'Combos, extra cheese and similar choices will be managed here.',
            textAlign: TextAlign.center,
            style: inter(13, 400, color: kMuted),
          ),
        ],
      ),
    ),
  );
}
