import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../catalogue/catalogue_api.dart';
import '../catalogue/catalogue_widgets.dart' show ItemTile;
import '../catalogue/item_parts.dart';
import '../catalogue/item_sheets.dart' show parsePriceMinor;
import '../inventory/inventory_api.dart';
import '../ui/barcode_scanner.dart';
import '../ui/theme.dart';
import 'prices_common.dart';
import 'stock_env.dart';
import 'stock_kit.dart';
import '../ui/i18n.dart';

/// Figma "Stock management": every item's stock, MRP, price and cost in one editable list (or grid), with two switches — "Shop" (sold
/// in the till) and "App" (shown on the OneLocal page). Changes stay on this screen until "Save changes":
///  * price, MRP and cost: cat_item_save in quick mode (an edit of price must not demand tax details);
///  * Shop: rst_menu_stock_set; App: sf_product_save (visible);
///  * stock quantities: ONE adjustment document for all changed items, sent for approval (the person who raises it cannot approve
///    it, so the stock changes once a manager approves it).
class UpdateStockScreen extends StatefulWidget {
  const UpdateStockScreen({super.key, required this.env, this.itemId, this.scan = scanBarcode});
  final StockEnv env;
  final String? itemId;

  /// The search bar's barcode button: opens the camera and answers the code read (null when closed). Tests pass their own.
  final Future<String?> Function(BuildContext) scan;
  @override
  State<UpdateStockScreen> createState() => _UpdateStockScreenState();
}

/// One item's edits. The controllers start at the saved values; a field counts as changed when its value differs from them.
class _Edit {
  _Edit(this.item, {required this.app})
      : stock = TextEditingController(text: item.stockQty == null ? '' : qty(item.stockQty!)),
        mrp = TextEditingController(text: _rs(item.mrpMinor)),
        price = TextEditingController(text: _rs(item.priceMinor)),
        cost = TextEditingController(text: _rs(item.costMinor)),
        shop = item.available;
  final CatItem item;
  final TextEditingController stock, mrp, price, cost;
  bool shop;
  bool? app; // null: the OneLocal page switch could not be read for this person

  static String _rs(int? minor) => minor == null ? '' : (minor % 100 == 0 ? '${minor ~/ 100}' : (minor / 100).toStringAsFixed(2));

  int? _minor(TextEditingController c) => c.text.trim().isEmpty ? null : parsePriceMinor(c.text);
  num? get newStock => num.tryParse(stock.text.trim());

  bool get stockChanged => item.stockQty != null && newStock != null && newStock != item.stockQty;
  bool get mrpChanged => _minor(mrp) != item.mrpMinor;
  bool get priceChanged => _minor(price) != item.priceMinor;
  bool get costChanged => _minor(cost) != item.costMinor;
  bool get pricesChanged => mrpChanged || priceChanged || costChanged;
  bool get shopChanged => shop != item.available;
  bool appChanged(bool? was) => app != null && was != null && app != was;
  bool changed(bool? appWas) => stockChanged || pricesChanged || shopChanged || appChanged(appWas);

  void reset(bool? appWas) {
    stock.text = item.stockQty == null ? '' : qty(item.stockQty!);
    mrp.text = _rs(item.mrpMinor);
    price.text = _rs(item.priceMinor);
    cost.text = _rs(item.costMinor);
    shop = item.available;
    app = appWas;
  }

  void dispose() {
    stock.dispose();
    mrp.dispose();
    price.dispose();
    cost.dispose();
  }
}

class _UpdateStockScreenState extends State<UpdateStockScreen> {
  static const _pageSize = 10;
  CatalogueList? _list;
  String? _error;
  Map<String, bool>? _appShown; // menu item id → shown on the OneLocal page
  String? _category; // the category chip picked; null = All
  List<String> _categories = const []; // every category, kept from the unfiltered list so the chips stay put
  int _page = 1;
  bool _grid = false; // List or Grid (with big photos), in both sections
  String _section = 'stock'; // stock: "Stock & price"; availability: "Store & app"
  bool _saving = false;
  final _search = TextEditingController();
  Timer? _debounce;
  final _edits = <String, _Edit>{};
  List<(String name, bool ok, String text)> _results = const [];

  // the number strip (inventory dashboard, J.96): stock value at cost, then low / out / expiring / damaged
  Facts? _dash;
  int? _worth;

  Future<void> _loadNumbers() async {
    try {
      final d = await widget.env.api.dashboard();
      if (mounted) setState(() => _dash = d);
    } catch (_) {}
    try {
      var value = 0;
      for (var page = 1; page <= 20; page++) {
        final list = await widget.env.catalogue.list(page: page, pageSize: 100);
        for (final it in list.items) {
          final cost = it.raw['cost_minor'], units = it.raw['stock_qty'];
          if (cost is num && units is num && units > 0) value += (cost * units).round();
        }
        if (list.items.length < 100) break;
      }
      if (mounted) setState(() => _worth = value);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _load();
    _loadApp();
    _loadNumbers();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    for (final e in _edits.values) {
      e.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final l = await widget.env.catalogue.list(q: _search.text, category: _category, page: _page, pageSize: _pageSize);
      if (mounted) {
        setState(() {
          _list = l;
          if (_category == null && l.categories.isNotEmpty) _categories = l.categories;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = stockError(e));
    }
  }

  /// The OneLocal page switch for every product (sf_products answers 50 at a time). A person who may not see the page keeps it off.
  Future<void> _loadApp() async {
    try {
      final shown = <String, bool>{};
      for (var offset = 0; offset < 1000; offset += 50) {
        final r = await widget.env.rpc.callMap('sf_products', {'limit': 50, 'offset': offset});
        final rows = Facts(r).l('items');
        for (final p in rows) {
          shown[p.s('id')] = p.b('visible');
        }
        if (rows.length < 50) break;
      }
      if (!mounted) return;
      setState(() {
        _appShown = shown;
        for (final e in _edits.values) {
          e.app ??= shown[e.item.id];
        }
      });
    } catch (_) {
      if (mounted) setState(() => _appShown = null);
    }
  }

  _Edit _edit(CatItem item) => _edits.putIfAbsent(item.id, () => _Edit(item, app: _appShown?[item.id]));

  List<_Edit> get _changed => _edits.values.where((e) => e.changed(_appShown?[e.item.id])).toList();

  void _searchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _page = 1;
      _load();
    });
  }

  /// Search by barcode: the camera reads it, the catalogue finds the product (by barcode or System Code), and the list shows just it.
  Future<void> _scanSearch() async {
    final code = await widget.scan(context);
    if (code == null || code.trim().isEmpty || !mounted) return;
    var term = code.trim();
    try {
      final item = await widget.env.catalogue.lookup(term);
      if (item.sku.isNotEmpty) term = item.sku;
    } catch (_) {
      if (mounted) showToast(context, 'No product has the code $term.');
    }
    if (!mounted) return;
    _debounce?.cancel();
    _search.text = term;
    _page = 1;
    await _load();
  }

  void _reset() => setState(() {
        for (final e in _edits.values) {
          e.reset(_appShown?[e.item.id]);
        }
        _results = const [];
      });

  // ---------------------------------------------------------------- save
  Future<void> _save() async {
    final changed = _changed;
    if (changed.isEmpty || _saving) return;
    for (final e in changed) {
      if (e.priceChanged && (e.price.text.trim().isEmpty || parsePriceMinor(e.price.text) == null)) {
        return showToast(context, 'Enter a selling price for ${e.item.name}.');
      }
      for (final c in [e.mrp, e.cost]) {
        if (c.text.trim().isNotEmpty && parsePriceMinor(c.text) == null) return showToast(context, 'Check the amounts for ${e.item.name}.');
      }
      final p = parsePriceMinor(e.price.text), m = e.mrp.text.trim().isEmpty ? null : parsePriceMinor(e.mrp.text);
      if (p != null && m != null && p > m) return showToast(context, 'The price of ${e.item.name} is above its MRP. Lower the price or raise the MRP.');
      if (e.stock.text.trim().isNotEmpty && (e.newStock == null || e.newStock! < 0)) return showToast(context, 'Check the stock quantity for ${e.item.name}.');
    }
    setState(() => _saving = true);
    final env = widget.env;
    final results = <(String, bool, String)>[];
    final lines = <DraftLine>[];
    for (final e in changed) {
      final name = e.item.name;
      final fails = <String>[];
      final saved = <String>[];
      if (e.pricesChanged) {
        try {
          await env.catalogue.save({
            'mode': 'quick',
            'version': e.item.version,
            if (e.priceChanged) 'price_minor': parsePriceMinor(e.price.text),
            if (e.mrpChanged) 'mrp_minor': e.mrp.text.trim().isEmpty ? null : parsePriceMinor(e.mrp.text),
            if (e.costChanged) 'cost_minor': e.cost.text.trim().isEmpty ? null : parsePriceMinor(e.cost.text),
          }, id: e.item.id);
          saved.add('prices');
        } catch (x) {
          fails.add('prices: ${stockError(x, 'not saved')}');
        }
      }
      if (e.shopChanged) {
        try {
          await env.rpc.call('rst_menu_stock_set', {'id': e.item.id, 'in_stock': e.shop});
          saved.add(e.shop ? 'on sale in the shop' : 'off sale in the shop');
        } catch (x) {
          fails.add('shop switch: ${stockError(x, 'not saved')}');
        }
      }
      final appWas = _appShown?[e.item.id];
      if (e.appChanged(appWas)) {
        try {
          await env.rpc.call('sf_product_save', {'id': e.item.id, 'visible': e.app});
          saved.add(e.app! ? 'shown on the app' : 'hidden from the app');
          _appShown?[e.item.id] = e.app!;
        } catch (x) {
          fails.add('app switch: ${stockError(x, 'not saved')}');
        }
      }
      if (e.stockChanged) {
        try {
          lines.addAll(await _stockLines(e));
        } catch (x) {
          fails.add('stock: ${stockError(x, 'not changed')}');
        }
      }
      if (saved.isNotEmpty) results.add((name, true, 'Saved: ${saved.join(', ')}.'));
      if (fails.isNotEmpty) results.add((name, false, 'Not saved — ${fails.join('; ')}'));
    }
    if (lines.isNotEmpty) {
      try {
        final doc = await env.api.createDraft('adjustment',
            fields: {'reason': 'Data entry correction', 'title': 'Stock update from Stock Management'}, lines: lines, key: InventoryApi.newKey());
        final sent = await env.api.act(doc.id, 'submit', version: doc.version);
        results.add(('Stock quantities', true, 'Sent for approval as ${sent.number.isEmpty ? doc.number : sent.number} — stock changes once a manager approves it.'));
      } catch (x) {
        results.add(('Stock quantities', false, 'Not sent — ${stockError(x, 'the stock change could not be sent')}'));
      }
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _results = results;
      // every edit is cleared: the list reloads with the saved values and versions; anything not saved is listed in "What was saved"
      for (final e in _edits.values) {
        e.dispose();
      }
      _edits.clear();
    });
    await _load();
  }

  /// The adjustment lines for one item's new stock: one "increase" line, or "decrease" lines taken from its places (largest first,
  /// never from quarantine — damaged stock is written off, not decreased).
  Future<List<DraftLine>> _stockLines(_Edit e) async {
    final invId = (e.item.raw['inventory_item_id'] ?? '').toString();
    if (invId.isEmpty) throw StateError('This item has no stock record yet.');
    final delta = e.newStock! - e.item.stockQty!;
    if (delta > 0) return [DraftLine(itemId: invId, itemName: e.item.name, sku: e.item.sku, adjustType: 'increase', qty: delta)];
    var left = -delta;
    final detail = await widget.env.api.stockDetail(invId);
    final places = detail.l('bins').where((b) => b.s('zone') != 'quarantine' && b.n('on_hand') > 0).toList()..sort((a, b) => b.n('on_hand').compareTo(a.n('on_hand')));
    final out = <DraftLine>[];
    for (final b in places) {
      if (left <= 0) break;
      final take = b.n('on_hand') < left ? b.n('on_hand') : left;
      out.add(DraftLine(itemId: invId, itemName: e.item.name, sku: e.item.sku, adjustType: 'decrease', qty: take, fromBinId: b.s('id')));
      left -= take;
    }
    if (left > 0) throw StateError('only ${qty(-delta - left)} can be taken off the shelves');
    return out;
  }

  // ---------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    final changed = _changed;
    final stockSide = _section == 'stock';
    return StockScaffold(
      env: widget.env,
      title: '', // the compact heading below, laid out like Item → Products
      onRefresh: _load,
      bottom: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(changed.isEmpty ? 'No changes yet' : '${changed.length} ${changed.length == 1 ? 'product' : 'products'} changed · review before saving',
                  style: inter(12.5, 500, color: kMuted)),
            ),
            Text(tr('This store only'), style: inter(12.5, 700, color: kPostedText)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(flex: 2, child: InvPrimary(tr('Save changes'), key: const ValueKey('stock-save'), busy: _saving, onPressed: changed.isEmpty ? null : _save)),
            const SizedBox(width: 10),
            Expanded(child: InvSecondary(tr('Reset'), key: const ValueKey('stock-reset'), onPressed: changed.isEmpty || _saving ? null : _reset)),
          ]),
        ]),
      ),
      children: [
        const ItemPartSwitcher(bottom: 10),
        // The same compact head as Products: heading with the view toggle, search, then the numbers, jobs, sections and chips.
        Row(children: [
          Text(tr('Stock Management'), style: inter(20, 800)),
          const Spacer(),
          _viewToggle(),
        ]),
        const SizedBox(height: 10),
        _searchField(),
        const SizedBox(height: 10),
        _numbers(),
        const SizedBox(height: 8),
        _tools(),
        const SizedBox(height: 10),
        _sections(),
        const SizedBox(height: 10),
        InvLoad<CatalogueList>(
          data: _list,
          error: _error,
          onRetry: _load,
          builder: (l) => [
            // categories, for picking products quickly (founder, 25 Oct 2026); All first
            // one line that scrolls sideways, like the chips on Products
            SingleChildScrollView(scrollDirection: Axis.horizontal, child: InvChips(
              active: _category ?? '',
              onTap: (c) {
                _category = c.isEmpty ? null : c;
                _page = 1;
                _load();
              },
              items: [('', 'All', _category == null ? l.count('total') : null), for (final c in (_categories.isEmpty ? l.categories : _categories)) (c, c, null)],
            )),
            const SizedBox(height: 2),
            if (_results.isNotEmpty) ...[_resultsCard(), const SizedBox(height: 12)],
            if (l.items.isEmpty)
              StockEmpty(
                _search.text.trim().isEmpty ? 'No items here' : 'No item matches',
                _search.text.trim().isEmpty ? 'Items you add in the catalogue show here.' : 'Try another name or System Code.',
              )
            else if (_grid)
              _gridOf(l.items, stockSide)
            else
              Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: kCardLine)),
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  for (var i = 0; i < l.items.length; i++) ...[
                    if (i > 0) const Divider(height: 1, color: kCardLine),
                    stockSide ? _stockRow(l.items[i]) : _switchRow(l.items[i]),
                  ],
                ]),
              ),
            const SizedBox(height: 10),
            _pager(l),
            const SizedBox(height: 4),
            Text(tr('Units: pc · kg · g · l · ml · pack · dozen · box'), textAlign: TextAlign.center, style: inter(11.5, 400, color: kMuted)),
            const SizedBox(height: 8),
            if (stockSide)
              InvNote('A stock change is sent for approval: the person who sends it cannot approve it, so a manager approves it before the stock changes. '
                  'Prices change as soon as you save.'),
            const SizedBox(height: 12),
          ],
        ),
      ],
    );
  }

  /// The search bar, the same as on Products: a barcode scan at its end.
  Widget _searchField() => Container(
        height: 42,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(21), border: Border.all(color: const Color(0xFFD9DCD6))),
        child: Row(children: [
          const SizedBox(width: 12),
          const Icon(LucideIcons.search, size: 18, color: kMuted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              style: inter(14, 400),
              decoration: InputDecoration.collapsed(hintText: tr('Search items'), hintStyle: inter(14, 400, color: kMuted)),
              onChanged: _searchChanged,
            ),
          ),
          IconButton(
            key: const ValueKey('search-scan'),
            tooltip: tr('Scan a barcode to search'),
            visualDensity: VisualDensity.compact,
            onPressed: _scanSearch,
            icon: const Icon(LucideIcons.scanBarcode, size: 20, color: kInk),
          ),
        ]),
      );

  /// Stock value, then low / out / expiring / damaged — each a tap to the alerts that list them (inventory dashboard, J.96).
  Widget _numbers() {
    final c = _dash?.m('counts');
    String n(num? v) => v == null ? '…' : qty(v);
    Widget cell(String key, String value, String label, Color color) => Expanded(
          child: InkWell(
            key: ValueKey('stock-number-$key'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => widget.env.open(context, StockPage.alerts),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(children: [
                Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(16, 800, color: color)),
                Text(tr(label), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 500, color: kMuted)),
              ]),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: kCardLine)),
      child: Row(children: [
        cell('value', _worth == null ? '…' : _rupeesShort(_worth!), 'Stock value', kInk),
        cell('low', n(c == null ? null : c.n('low') + c.n('critical')), 'Low', kAmberText),
        cell('out', n(c?.no('out')), 'Out', kRedText),
        cell('expiring', n(c?.no('near_expiry')), 'Expiring', kAmberText),
        cell('damaged', n(_dash?.m('damaged').no('units')), 'Damaged', kRedText),
      ]),
    );
  }

  static String _rupeesShort(int minor) {
    final r = minor / 100;
    if (r >= 10000000) return '₹${(r / 10000000).toStringAsFixed(1)}Cr';
    if (r >= 100000) return '₹${(r / 100000).toStringAsFixed(1)}L';
    if (r >= 1000) return '₹${(r / 1000).toStringAsFixed(1)}K';
    return '₹${r.round()}';
  }

  /// The stock jobs, one tap each, in one even row: what needs a look, fix stock, move it, its history, count it.
  Widget _tools() => Row(children: [
        for (final (i, (page, label, icon)) in [
          (StockPage.alerts, 'Alerts', LucideIcons.bellRing),
          (StockPage.adjust, 'Adjust', LucideIcons.slidersHorizontal),
          (StockPage.transfer, 'Transfer', LucideIcons.arrowLeftRight),
          (StockPage.movements, 'History', LucideIcons.history),
          (StockPage.count, 'Count', LucideIcons.clipboardCheck),
        ].indexed) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: Material(
              color: page == StockPage.alerts ? kLimeSoftH : Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: page == StockPage.alerts ? kLimeH : kCardLine)),
              child: InkWell(
                key: ValueKey('stock-tool-$page'),
                borderRadius: BorderRadius.circular(12),
                onTap: () => widget.env.open(context, page),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Column(children: [
                    Icon(icon, size: 17, color: kInk),
                    const SizedBox(height: 3),
                    Text(tr(label), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 600)),
                  ]),
                ),
              ),
            ),
          ),
        ],
      ]);

  /// The two sections of this page, side by side, always in sight.
  Widget _sections() => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kCardLine)),
        child: Row(children: [
          for (final (id, label, icon) in [('stock', 'Stock & price', LucideIcons.packageSearch), ('availability', 'Store & app', LucideIcons.toggleRight)])
            Expanded(
              child: Material(
                color: _section == id ? kNavyH : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  key: ValueKey('section-$id'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => setState(() => _section = id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(icon, size: 16, color: _section == id ? kLimeH : kMuted),
                      const SizedBox(width: 6),
                      Text(tr(label), style: inter(13.5, 700, color: _section == id ? kLimeH : kMuted)),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      );

  Widget _resultsCard() => InvCard(
        key: const ValueKey('stock-results'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(tr('What was saved'), style: inter(15, 700))),
            InkWell(onTap: () => setState(() => _results = const []), child: const Icon(LucideIcons.x, size: 18, color: kMuted)),
          ]),
          const SizedBox(height: 6),
          for (final (name, ok, text) in _results)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(ok ? LucideIcons.circleCheck : LucideIcons.circleX, size: 16, color: ok ? kPostedText : kRedText),
                const SizedBox(width: 8),
                Expanded(child: Text('$name — $text', style: inter(13, 400, color: ok ? kInk : kRedText, height: 1.35))),
              ]),
            ),
        ]),
      );

  // ---------------------------------------------------------------- rows
  static String _code(CatItem item) => [if (item.sku.isNotEmpty) item.sku, item.status == 'draft' ? 'Draft' : item.sellingUnit].join(' · ');

  /// Photo, name and "System Code · unit": the left half of both kinds of row.
  Widget _who(CatItem item, {Widget? under}) => Expanded(
        child: Row(children: [
          ItemTile(item, size: 52),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(15, 700)),
              Text(_code(item), style: inter(12, 400, color: kMuted)),
              if (under != null) ...[const SizedBox(height: 2), under],
            ]),
          ),
        ]),
      );

  /// Available (green) when sold in the store and the app, Partial (amber) in one, Off (grey) in neither, Out of stock (red) at zero.
  Widget _statusLine(_Edit e) {
    final stock = e.newStock ?? e.item.stockQty;
    final app = e.app ?? false;
    final (label, color) = stock != null && stock <= 0
        ? ('Out of stock', kRedText)
        : e.shop && app
            ? ('Available', kPostedText)
            : e.shop || app
                ? ('Partial', kAmberText)
                : ('Off', kMuted);
    TextSpan part(String t, bool on) => TextSpan(text: t, style: inter(12, 500, color: on ? kPostedText : kMuted));
    return Text.rich(TextSpan(children: [
      WidgetSpan(alignment: PlaceholderAlignment.middle, child: Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle))),
      TextSpan(text: ' $label', style: inter(12, 600, color: color)),
      TextSpan(text: '  ·  ', style: inter(12, 400, color: kMuted)),
      part('Store ${e.shop ? 'On' : 'Off'}', e.shop),
      TextSpan(text: '  ·  ', style: inter(12, 400, color: kMuted)),
      part('App ${e.app == null ? '—' : app ? 'On' : 'Off'}', app),
    ]));
  }

  /// "Stock & price": price (green), stock and cost on the right; tap the row or ⋮ to edit. A changed row is tinted.
  Widget _stockRow(CatItem item) {
    final e = _edit(item);
    final edited = e.changed(_appShown?[item.id]);
    final price = e.price.text.trim(), cost = e.cost.text.trim(), stock = e.stock.text.trim();
    return Material(
      key: ValueKey('stock-row-${item.id}'),
      color: edited ? kLimeSoftH : Colors.white,
      child: InkWell(
        onTap: () => _editSheet(item),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 2, 12),
          child: Row(children: [
            _who(item, under: _statusLine(e)),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(price.isEmpty ? '—' : '₹$price', style: inter(16, 800, color: kPostedText)),
              Text(item.stockQty == null ? 'No stock record' : '${stock.isEmpty ? '—' : stock} ${item.sellingUnit}', style: inter(12.5, 500, color: kMuted)),
              Text(cost.isEmpty ? 'Cost —' : 'Cost ₹$cost', style: inter(12.5, 500, color: kMuted)),
            ]),
            IconButton(
              key: ValueKey('stock-more-${item.id}'),
              tooltip: 'Edit ${item.name}',
              visualDensity: VisualDensity.compact,
              onPressed: () => _editSheet(item),
              icon: const Icon(LucideIcons.ellipsisVertical, size: 18, color: kMuted),
            ),
          ]),
        ),
      ),
    );
  }

  /// "Store & app": two on/off switches per product. A draft cannot be put on sale; the app switch is greyed when it cannot be read.
  Widget _switchRow(CatItem item) {
    final e = _edit(item);
    final edited = e.changed(_appShown?[item.id]);
    Widget toggle(String label, bool on, String key, ValueChanged<bool>? onChanged) => Column(mainAxisSize: MainAxisSize.min, children: [
          Text(tr(label), style: inter(11.5, 600, color: onChanged == null ? kMuted : kInk)),
          Transform.scale(
            scale: 0.85,
            child: Switch(
              key: ValueKey(key),
              value: on,
              onChanged: onChanged,
              activeThumbColor: kNavyH,
              activeTrackColor: kLimeH,
              inactiveThumbColor: Colors.white,
              inactiveTrackColor: const Color(0xFFE1E3DD),
              trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
            ),
          ),
        ]);
    return Container(
      key: ValueKey('switch-row-${item.id}'),
      color: edited ? kLimeSoftH : Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(children: [
        _who(item, under: _statusLine(e)),
        const SizedBox(width: 6),
        toggle('Store', e.shop, 'shop-${item.id}', item.status == 'draft' ? null : (v) => setState(() => e.shop = v)),
        toggle('App', e.app ?? false, 'app-${item.id}', e.app == null ? null : (v) => setState(() => e.app = v)),
      ]),
    );
  }

  static String _rupees(int minor) => (minor < 0 ? '−₹' : '₹') + (minor.abs() % 100 == 0 ? '${minor.abs() ~/ 100}' : (minor.abs() / 100).toStringAsFixed(2));

  // ---------------------------------------------------------------- grid
  /// List / Grid, as two small icon buttons.
  // List / Grid, the same pill as on Products
  Widget _viewToggle() => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: const Color(0xFFE9ECE7), borderRadius: BorderRadius.circular(18)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final (grid, icon, label) in [(false, LucideIcons.list, 'List'), (true, LucideIcons.layoutGrid, 'Grid')])
            Material(
              color: _grid == grid ? kNavyH : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                key: ValueKey('view-${label.toLowerCase()}'),
                borderRadius: BorderRadius.circular(14),
                onTap: () => setState(() => _grid = grid),
                child: Tooltip(
                  message: '$label view',
                  child: Padding(padding: const EdgeInsets.all(7), child: Icon(icon, size: 16, color: _grid == grid ? kLimeH : kMuted)),
                ),
              ),
            ),
        ]),
      );

  /// Two cards per row, each led by the product's photo.
  Widget _gridOf(List<CatItem> items, bool stockSide) => LayoutBuilder(builder: (_, c) {
        final w = (c.maxWidth - 10) / 2;
        return Wrap(spacing: 10, runSpacing: 10, children: [
          for (final it in items) SizedBox(width: w, child: stockSide ? _stockCard(it) : _switchCard(it)),
        ]);
      });

  /// The photo across the top of a card (the item's own photo, or a package mark on its tint — no stock photos are invented).
  Widget _photo(CatItem item) {
    const tints = [Color(0xFFE3F1FC), Color(0xFFFDF0DC), Color(0xFFFBF3D0), Color(0xFFFCE9E7), Color(0xFFE9F2FB), Color(0xFFFFF7D6)];
    final tint = tints[(item.name.isEmpty ? 0 : item.name.codeUnitAt(0)) % tints.length];
    final url = item.imageUrl;
    return AspectRatio(
      aspectRatio: 1.25,
      child: Container(
        color: tint,
        child: url != null && url.isNotEmpty
            ? Image.network(url, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.package, size: 34, color: kMuted))
            : const Icon(LucideIcons.package, size: 34, color: kMuted),
      ),
    );
  }

  /// A small coloured dot with the status word (Available / Partial / Off / Out of stock).
  Widget _statusDot(_Edit e) {
    final stock = e.newStock ?? e.item.stockQty;
    final app = e.app ?? false;
    final (label, color) = stock != null && stock <= 0
        ? ('Out of stock', kRedText)
        : e.shop && app
            ? ('Available', kPostedText)
            : e.shop || app
                ? ('Partial', kAmberText)
                : ('Off', kMuted);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 5),
      Text(tr(label), style: inter(11.5, 600, color: color)),
    ]);
  }

  Widget _cardFrame(CatItem item, String key, bool edited, List<Widget> body, {VoidCallback? onTap}) => Material(
        key: ValueKey(key),
        color: edited ? kLimeSoftH : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: edited ? kLimeH : kCardLine)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _photo(item),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(14, 700, height: 1.2)),
                const SizedBox(height: 2),
                Text(_code(item), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 400, color: kMuted)),
                const SizedBox(height: 8),
                ...body,
              ]),
            ),
          ]),
        ),
      );

  /// Grid, "Stock & price": photo, name, price (green), stock and cost; tap to edit.
  Widget _stockCard(CatItem item) {
    final e = _edit(item);
    final price = e.price.text.trim(), cost = e.cost.text.trim(), stock = e.stock.text.trim();
    return _cardFrame(item, 'stock-card-${item.id}', e.changed(_appShown?[item.id]), onTap: () => _editSheet(item), [
      Row(children: [
        Expanded(child: Text(price.isEmpty ? '—' : '₹$price', style: inter(17, 800, color: kPostedText))),
        _statusDot(e),
      ]),
      const SizedBox(height: 2),
      Text(item.stockQty == null ? 'No stock record' : 'Stock: ${stock.isEmpty ? '—' : stock} ${item.sellingUnit}', style: inter(12, 500, color: kMuted)),
      Text(cost.isEmpty ? 'Cost: —' : 'Cost: ₹$cost', style: inter(12, 500, color: kMuted)),
    ]);
  }

  /// Grid, "Store & app": photo, name and the two on/off switches.
  Widget _switchCard(CatItem item) {
    final e = _edit(item);
    Widget toggle(String label, bool on, String key, ValueChanged<bool>? onChanged) => Row(children: [
          Expanded(child: Text(tr(label), style: inter(12.5, 600, color: onChanged == null ? kMuted : kInk))),
          SizedBox(
            height: 30,
            child: FittedBox(
              child: Switch(
                key: ValueKey(key),
                value: on,
                onChanged: onChanged,
                activeThumbColor: kNavyH,
                activeTrackColor: kLimeH,
                inactiveThumbColor: Colors.white,
                inactiveTrackColor: const Color(0xFFE1E3DD),
                trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
              ),
            ),
          ),
        ]);
    return _cardFrame(item, 'switch-card-${item.id}', e.changed(_appShown?[item.id]), [
      _statusDot(e),
      const SizedBox(height: 4),
      toggle('Store', e.shop, 'grid-shop-${item.id}', item.status == 'draft' ? null : (v) => setState(() => e.shop = v)),
      toggle('App', e.app ?? false, 'grid-app-${item.id}', e.app == null ? null : (v) => setState(() => e.app = v)),
    ]);
  }

  Future<void> _editSheet(CatItem item) async {
    final e = _edit(item);
    int? minor(TextEditingController c) => c.text.trim().isEmpty ? null : parsePriceMinor(c.text);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        void changed(String _) {
          setSheet(() {});
          setState(() {});
        }

        Widget field(String label, TextEditingController c, String key, {bool enabled = true, (Color, Color, String)? tone}) => Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                InvLabel(label),
                if (!enabled)
                  Container(
                    height: 46,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(color: kGreyBg, borderRadius: BorderRadius.circular(14)),
                    child: Text(tr('No stock record'), style: inter(13, 400, color: kMuted)),
                  )
                else
                  SizedBox(
                    height: 46,
                    child: TextField(
                      key: ValueKey(key),
                      controller: c,
                      onChanged: changed,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: inter(15, tone == null ? 400 : 700, color: tone?.$2 ?? kInk),
                      decoration: InputDecoration(
                        hintText: '—',
                        filled: true,
                        fillColor: tone?.$1 ?? Colors.white,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: tone?.$2 ?? const Color(0xFFD9DBD5), width: tone == null ? 1 : 1.6)),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: tone?.$2 ?? kInk, width: 1.8)),
                      ),
                    ),
                  ),
                if (tone != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(tone.$3, key: ValueKey('$key-note'), style: inter(11.5, 600, color: tone.$2))),
              ]),
            );

        final price = minor(e.price), mrp = minor(e.mrp), cost = minor(e.cost);
        final tone = UpdateStockScreenTones.tone(price, mrp);
        final m = UpdateStockScreenTones.margin(price, cost);
        final low = m != null && m.pct < 5;
        return Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                ItemTile(item, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(item.name, style: inter(18, 700)),
                    Text(_code(item), style: inter(12.5, 400, color: kMuted)),
                  ]),
                ),
              ]),
              const SizedBox(height: 14),
              // the sketch: Stock | Cost, then MRP | Price, then the margin under them
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                field('Stock (${item.sellingUnit})', e.stock, 'sheet-stock', enabled: item.stockQty != null),
                const SizedBox(width: 10),
                field('Cost ₹', e.cost, 'sheet-cost'),
              ]),
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                field('MRP ₹', e.mrp, 'sheet-mrp'),
                const SizedBox(width: 10),
                field('Price ₹', e.price, 'sheet-price', tone: tone),
              ]),
              const SizedBox(height: 12),
              Center(
                child: Container(
                  key: const ValueKey('sheet-margin'),
                  width: 220,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: m == null ? kGreyBg : (low ? kRedBgH : const Color(0xFFEBFAE0)),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: m == null ? kCardLine : (low ? kRedText : kPostedText)),
                  ),
                  child: Column(children: [
                    Text(tr('Margin'), style: inter(12.5, 600, color: kMuted)),
                    const SizedBox(height: 2),
                    Text(
                      m == null ? 'Enter price and cost' : '${_rupees(m.amount)} · ${m.pct.toStringAsFixed(1)}%',
                      key: const ValueKey('sheet-margin-value'),
                      style: inter(m == null ? 13 : 17, 800, color: m == null ? kMuted : (low ? kRedText : kPostedText)),
                    ),
                    if (low) Text(tr('Below 5% — check the price or cost'), style: inter(11.5, 600, color: kRedText)),
                  ]),
                ),
              ),
              const SizedBox(height: 10),
              Text(tr('A stock change goes to a manager for approval. Prices change when you tap Save changes.'), style: inter(12.5, 400, color: kMuted, height: 1.35)),
              const SizedBox(height: 14),
              InvPrimary(tr('Done'), key: const ValueKey('sheet-done'), onPressed: () => Navigator.of(ctx).pop()),
              const SizedBox(height: 6),
              InvSecondary(tr('Open stock details'), onPressed: () {
                Navigator.of(ctx).pop();
                _openItem(item);
              }),
            ]),
          ),
        );
      }),
    );
    if (mounted) setState(() {});
  }

  void _openItem(CatItem item) {
    final inv = (item.raw['inventory_item_id'] ?? '').toString();
    if (inv.isEmpty) return showToast(context, '${item.name} has no stock record yet.');
    widget.env.open(context, StockPage.item, itemId: inv);
  }

  // ---------------------------------------------------------------- pager
  Widget _pager(CatalogueList l) {
    final total = l.totalMatching;
    if (total == 0) return const SizedBox.shrink();
    final from = (l.page - 1) * l.pageSize + 1;
    final to = (from + l.items.length - 1).clamp(from, total);
    final last = (total / l.pageSize).ceil();
    return Row(children: [
      Expanded(child: Text('Showing $from–$to of $total items', style: inter(12.5, 400, color: kMuted))),
      IconButton(
        key: const ValueKey('page-prev'),
        tooltip: tr('Previous page'),
        onPressed: l.page <= 1 ? null : () => setState(() {
          _page = l.page - 1;
          _load();
        }),
        icon: const Icon(LucideIcons.chevronLeft, size: 18),
      ),
      Text('${l.page} / $last', style: inter(13, 700, color: kPostedText)),
      IconButton(
        key: const ValueKey('page-next'),
        tooltip: tr('Next page'),
        onPressed: l.page >= last ? null : () => setState(() {
          _page = l.page + 1;
          _load();
        }),
        icon: const Icon(LucideIcons.chevronRight, size: 18),
      ),
    ]);
  }
}

/// The edit box's price colour and margin rules, kept apart so they can be checked on their own.
abstract final class UpdateStockScreenTones {
  /// How the selling price compares with the MRP (founder's sketch, 25 Oct 2026): equal = green, below MRP = yellow, above MRP = red
  /// (the database refuses a price above MRP). Null when either is blank.
  static (Color fill, Color line, String note)? tone(int? price, int? mrp) {
    if (price == null || mrp == null) return null;
    if (price == mrp) return (const Color(0xFFEBFAE0), kPostedText, 'Same as MRP');
    if (price < mrp) return (const Color(0xFFFEF9C3), const Color(0xFFCA8A04), 'Below MRP');
    return (kRedBgH, kRedText, 'Above MRP — not allowed');
  }

  /// The margin on one sale: price − cost, and as a share of the price. Below 5% is flagged (founder's sketch).
  static ({int amount, double pct})? margin(int? price, int? cost) {
    if (price == null || cost == null || price <= 0) return null;
    return (amount: price - cost, pct: (price - cost) * 100 / price);
  }
}
