import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart';
import '../ui/theme.dart';
import 'sell_api.dart';
import 'sell_env.dart';
import 'sell_widgets.dart';

/// Figma "Search" and "Negative and all screening for Product Search": find a product by name, SKU or barcode, with every state the frames
/// draw: suggestions, recent searches, loading, no result, a failed request that keeps the query, filters (category, price, availability),
/// sort, group by category and clear filters. [onAdd] puts a result in the active cart.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.env, this.onAdd, this.initialQuery = ''});
  final SellEnv env;
  final ValueChanged<SellItem>? onAdd;
  final String initialQuery;
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

enum _Phase { landing, loading, results, error }

class _SearchScreenState extends State<SearchScreen> {
  late final _q = TextEditingController(text: widget.initialQuery);
  static final List<String> _recent = []; // this session only
  static const _sorts = [('price_asc', 'Price: low to high', 'Cheapest first'), ('price_desc', 'Price: high to low', 'Highest price first'), ('name', 'Name: A–Z', 'Alphabetical product name')];
  _Phase _phase = _Phase.landing;
  List<SellItem> _items = const [];
  List<String> _categories = const [];
  String _category = '', _sort = 'price_asc', _error = '', _ran = '';
  bool _availableOnly = false, _groupBy = false;
  num? _min, _max;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _loadCategories();
    if (widget.initialQuery.isNotEmpty) _run();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  int get _filterCount => (_category.isNotEmpty ? 1 : 0) + (_availableOnly ? 1 : 0) + (_min != null || _max != null ? 1 : 0);

  Future<void> _loadCategories() async {
    try {
      final c = await widget.env.sell.catalog();
      if (mounted) setState(() => _categories = c.categories);
    } catch (_) {/* the landing page still works without the chips */}
  }

  Future<void> _run() async {
    final term = _q.text.trim();
    if (term.isEmpty && _filterCount == 0) {
      setState(() => _phase = _Phase.landing);
      return;
    }
    final mine = ++_seq;
    setState(() {
      _phase = _Phase.loading;
      _ran = term;
    });
    try {
      final c = await widget.env.sell.catalog(q: term, category: _category, availableOnly: _availableOnly, sort: _sort);
      if (!mounted || mine != _seq) return;
      var items = c.items;
      if (_min != null) items = items.where((i) => i.price >= _min!).toList();
      if (_max != null) items = items.where((i) => i.price <= _max!).toList();
      if (term.isNotEmpty) {
        _recent.remove(term);
        _recent.insert(0, term);
        if (_recent.length > 6) _recent.removeLast();
      }
      setState(() {
        _items = items;
        if (c.categories.isNotEmpty) _categories = c.categories;
        _phase = _Phase.results;
      });
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() {
        _error = sellErrorText(e);
        _phase = _Phase.error;
      });
    }
  }

  void _clearAll() {
    _q.clear();
    _category = '';
    _availableOnly = false;
    _min = _max = null;
    setState(() => _phase = _Phase.landing);
  }

  void _clearFilters() {
    _category = '';
    _availableOnly = false;
    _min = _max = null;
    _run();
  }

  Future<void> _scan() async {
    final c = TextEditingController();
    final code = await showOrderSheet<String>(
      context,
      title: 'Scan barcode',
      body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Scan with the barcode scanner or type the EAN or SKU.', style: inter(13, 400, color: kMuted)),
        const SizedBox(height: 12),
        TextField(controller: c, autofocus: true, textInputAction: TextInputAction.search, onSubmitted: (v) => Navigator.pop(ctx, v.trim()), decoration: const InputDecoration(hintText: 'EAN or SKU')),
        const SizedBox(height: 14),
        DarkCta(label: 'Find', onPressed: () => Navigator.pop(ctx, c.text.trim())),
      ]),
    );
    if (code == null || code.isEmpty) return;
    _q.text = code;
    _run();
  }

  Future<void> _filters() async {
    var cat = _category, avail = _availableOnly;
    final min = TextEditingController(text: _min?.toString() ?? ''), max = TextEditingController(text: _max?.toString() ?? '');
    final apply = await showOrderSheet<bool>(
      context,
      title: 'Filter products',
      body: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Choose criteria, then apply.', style: inter(13, 400, color: kMuted)),
            const SizedBox(height: 12),
            const Kick('Category'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in ['', ..._categories])
                ChoiceChip(label: Text(c.isEmpty ? 'Any category' : c), selected: cat == c, selectedColor: const Color(0xFFA5FF2D), onSelected: (_) => set(() => cat = c)),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: TextField(controller: min, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Minimum price', hintText: 'No minimum'))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: max, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Maximum price', hintText: 'No maximum'))),
            ]),
            const SizedBox(height: 14),
            const Kick('Availability'),
            Row(children: [
              ChoiceChip(label: const Text('Available'), selected: avail, selectedColor: const Color(0xFFA5FF2D), onSelected: (v) => set(() => avail = v)),
              const SizedBox(width: 8),
              ChoiceChip(label: const Text('Any availability'), selected: !avail, onSelected: (v) => set(() => avail = !v)),
            ]),
            const SizedBox(height: 16),
            DarkCta(label: 'Apply filters', onPressed: () => Navigator.pop(ctx, true)),
            const SizedBox(height: 8),
            LightCta(label: 'Cancel', onPressed: () => Navigator.pop(ctx, false)),
          ]),
        ),
      ),
    );
    if (apply != true) return;
    _category = cat;
    _availableOnly = avail;
    _min = num.tryParse(min.text.trim());
    _max = num.tryParse(max.text.trim());
    _run();
  }

  Future<void> _sortSheet() async {
    var chosen = _sort;
    final go = await showOrderSheet<bool>(
      context,
      title: 'Sort products',
      body: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final (id, label, sub) in _sorts)
            ListTile(
              contentPadding: EdgeInsets.zero,
              selected: chosen == id,
              onTap: () => set(() => chosen = id),
              trailing: Icon(chosen == id ? LucideIcons.circleCheck : LucideIcons.circle, color: chosen == id ? kGreenText : kMuted),
              title: Text(label, style: inter(14, 600)),
              subtitle: Text(sub, style: inter(12, 400, color: kMuted)),
            ),
          const SizedBox(height: 10),
          DarkCta(label: 'Apply sort', onPressed: () => Navigator.pop(ctx, true)),
        ]),
      ),
    );
    if (go == true) {
      _sort = chosen;
      _run();
    }
  }

  void _add(SellItem i) {
    widget.onAdd?.call(i);
    showToast(context, '${i.name} added to the cart.');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: Column(children: [
          SellTopBar(title: 'OneLocal', onBack: () => Navigator.maybePop(context), initials: widget.env.initials),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 16), children: [
              Row(children: [Expanded(child: Text(_title, style: inter(20, 700))), Text('Catalogue', style: inter(13, 400, color: kMuted))]),
              const SizedBox(height: 12),
              SellSearchField(controller: _q, hint: 'Search product name, Options, by category, by brand', onSubmitted: (_) => _run(), onClear: _q.text.isEmpty ? null : _clearAll),
              const SizedBox(height: 14),
              ..._content(),
            ]),
          ),
          PosBottomNav(active: 'item', onTap: (id) => widget.env.tab(context, id)),
        ]),
      );

  String get _title => switch (_phase) {
        _Phase.landing => 'Search',
        _Phase.loading => 'Search Loading',
        _Phase.error => 'Search Error',
        _Phase.results => _items.isEmpty ? (_filterCount > 0 ? 'No Matching Results' : 'Search Empty') : (_filterCount > 0 ? 'Filter Applied' : 'Search results'),
      };

  List<Widget> _content() {
    switch (_phase) {
      case _Phase.loading:
        return [Text('Searching catalogue', style: inter(22, 800)), const SizedBox(height: 6), Text('Looking for "$_ran"…', style: inter(13, 400, color: kMuted)), const SizedBox(height: 12), const SkeletonRows(), const SizedBox(height: 10), Text('Your query is kept while matching products load.', style: inter(12.5, 400, color: kMuted))];
      case _Phase.error:
        return [
          StateCard(icon: LucideIcons.database, danger: true, title: 'Search couldn\'t load', body: 'We couldn\'t fetch the results for "$_ran". Your search has been kept.\n$_error', primary: 'Retry', onPrimary: _run, secondary: 'Edit search', onSecondary: () => FocusScope.of(context).requestFocus(FocusNode())),
          const SizedBox(height: 10),
          Text('You can retry the same search or change the query.', style: inter(12.5, 400, color: kMuted)),
        ];
      case _Phase.results:
        return _results();
      case _Phase.landing:
        return _landing();
    }
  }

  List<Widget> _landing() => [
        Text('Find a product', style: inter(20, 800)),
        const SizedBox(height: 6),
        Text('Search the catalogue by product name or SKU. Or scan a barcode to find an item.', style: inter(14, 400, color: kMuted, height: 1.4)),
        const SizedBox(height: 14),
        if (_recent.isNotEmpty) ...[
          OrderCardBox(
            radius: 22,
            child: Material(type: MaterialType.transparency, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Recent searches', style: inter(16, 700)),
              for (final r in _recent)
                ListTile(contentPadding: EdgeInsets.zero, dense: true, leading: const Icon(LucideIcons.history, size: 18), title: Text(r, style: inter(15, 500)), trailing: const Icon(LucideIcons.arrowUpLeft, size: 16), onTap: () {
                  _q.text = r;
                  _run();
                }),
              Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => setState(_recent.clear), child: Text('Clear recent searches', style: inter(13, 600, color: kMuted)))),
            ])),
          ),
          const SizedBox(height: 14),
        ],
        OrderCardBox(
          radius: 22,
          child: Material(type: MaterialType.transparency, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Try a search', style: inter(18, 800)),
            for (final (term, hint) in const [('500', 'Search pack sizes and SKUs'), ('CC500', 'Search by product code')])
              ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(LucideIcons.search, size: 20), title: Text(term, style: inter(16, 500)), subtitle: Text(hint, style: inter(13, 400, color: kMuted)), trailing: const Icon(LucideIcons.arrowUpLeft, size: 16), onTap: () {
                _q.text = term;
                _run();
              }),
          ])),
        ),
        if (_categories.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Browse categories', style: inter(20, 800)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [for (final c in _categories) ActionChip(label: Text(c), backgroundColor: Colors.white, onPressed: () {
            _category = c;
            _run();
          })]),
        ],
        const SizedBox(height: 18),
        DarkCta(label: 'Search catalogue', onPressed: _run),
        const SizedBox(height: 10),
        LightCta(label: 'Scan barcode', onPressed: _scan),
      ];

  List<Widget> _results() {
    final chips = Row(children: [
      _pill(_filterCount > 0 ? 'Filters · $_filterCount' : 'Filters', _filterCount > 0, _filters),
      const SizedBox(width: 8),
      _pill('Sort', false, _sortSheet),
      const SizedBox(width: 8),
      _pill('Group by', _groupBy, () {
        setState(() => _groupBy = !_groupBy);
      }),
    ]);
    final active = Wrap(spacing: 8, children: [
      if (_category.isNotEmpty) InputChip(label: Text(_category), onDeleted: () {
        _category = '';
        _run();
      }),
      if (_availableOnly) InputChip(label: const Text('Available'), onDeleted: () {
        _availableOnly = false;
        _run();
      }),
      if (_min != null || _max != null) InputChip(label: Text('Price ${_min ?? 0}–${_max ?? '∞'}'), onDeleted: () {
        _min = _max = null;
        _run();
      }),
    ]);
    if (_items.isEmpty) {
      final filtered = _filterCount > 0;
      return [
        chips,
        if (filtered) ...[const SizedBox(height: 8), active],
        const SizedBox(height: 12),
        Text('0 matching products', style: inter(14, 600, color: kMuted)),
        const SizedBox(height: 8),
        StateCard(
          icon: LucideIcons.search,
          title: filtered ? 'No matching results' : 'No products found',
          body: filtered ? 'No products match "$_ran" with these filters. Clear the filters or edit your search.' : 'No products match "$_ran". Check the spelling or try a product name, SKU or barcode.',
          primary: filtered ? 'Clear filters' : 'Clear search',
          onPrimary: filtered ? _clearFilters : _clearAll,
          secondary: filtered ? 'Edit search' : 'Scan barcode',
          onSecondary: filtered ? () {} : _scan,
        ),
        const SizedBox(height: 10),
        Text(filtered ? 'Clearing filters keeps "$_ran" and restores matching items.' : 'No filters are applied. Clear the search to browse the catalogue.', style: inter(12.5, 400, color: kMuted)),
      ];
    }
    final groups = <String, List<SellItem>>{};
    for (final i in _items) {
      groups.putIfAbsent(_groupBy ? (i.category.isEmpty ? 'Other' : i.category) : '', () => []).add(i);
    }
    return [
      chips,
      if (_filterCount > 0) ...[const SizedBox(height: 8), active],
      const SizedBox(height: 12),
      Row(children: [Text(_items.length == 1 ? '1 matching product' : '${_items.length} matching products', style: inter(14, 600, color: kMuted)), const Spacer(), Text(_sorts.firstWhere((s) => s.$1 == _sort).$2, style: inter(12, 400, color: kMuted))]),
      const SizedBox(height: 8),
      for (final e in groups.entries) ...[
        if (e.key.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(2, 8, 2, 6), child: Text('${e.key} · ${e.value.length}', style: inter(15, 700))),
        for (final i in e.value) _row(i),
      ],
      if (_filterCount > 0) ...[const SizedBox(height: 10), LightCta(label: 'Clear filters', onPressed: _clearFilters)],
    ];
  }

  Widget _pill(String label, bool on, VoidCallback onTap) => Material(
        color: on ? const Color(0xFFA5FF2D) : Colors.white,
        shape: StadiumBorder(side: BorderSide(color: on ? const Color(0xFFA5FF2D) : const Color(0xFFDADCD5))),
        child: InkWell(customBorder: const StadiumBorder(), onTap: onTap, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), child: Text(label, style: inter(13, on ? 700 : 500, color: on ? kInk : kMuted)))),
      );

  Widget _row(SellItem i) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: OrderCardBox(
          padding: const EdgeInsets.all(10),
          child: Row(children: [
            Container(width: 44, height: 44, decoration: BoxDecoration(color: const Color(0xFFF3F4F1), borderRadius: BorderRadius.circular(10)), child: const Icon(LucideIcons.package, size: 22, color: kKicker)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(i.name, style: inter(14, 700), overflow: TextOverflow.ellipsis),
                Text('${i.sku}${i.category.isEmpty ? '' : ' · ${i.category}'}', style: inter(11.5, 400, color: kMuted)),
                Text(i.available ? 'Available' : 'Out of stock', style: inter(11.5, 500, color: i.available ? kGreenText : kBadText)),
              ]),
            ),
            Text(rupees(i.price), style: inter(15, 800)),
            const SizedBox(width: 8),
            Semantics(
              button: true,
              enabled: i.available,
              label: 'Add ${i.name}',
              child: IconButton(onPressed: i.available ? () => _add(i) : null, icon: const Icon(LucideIcons.plus, size: 20), style: IconButton.styleFrom(backgroundColor: i.available ? const Color(0xFF8BE800) : const Color(0xFFEEF0EB))),
            ),
          ]),
        ),
      );
}
