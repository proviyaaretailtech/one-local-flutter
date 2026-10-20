import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_nav.dart';
import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'catalogue_api.dart';
import 'catalogue_format.dart';
import 'catalogue_widgets.dart';
import 'item_form_screen.dart';
import 'item_sheets.dart';

/// Section G entry (Figma "Catalogue · List" and "Catalogue · Grid"): every item of this business with search, categories, counts and pages.
/// The control centre (section D) links here through `HomeNav.items`.
class CatalogueScreen extends StatefulWidget {
  const CatalogueScreen({super.key, this.api, this.onNavigate, this.onMenu});
  final CatalogueApi? api;
  final ValueChanged<String>? onNavigate;
  final VoidCallback? onMenu;
  @override
  State<CatalogueScreen> createState() => _CatalogueScreenState();
}

class _CatalogueScreenState extends State<CatalogueScreen> {
  late final CatalogueApi _api = widget.api ?? CatalogueApi();
  final _search = TextEditingController();
  Timer? _debounce;
  CatalogueList? _data;
  String? _error;
  String? _category;
  bool _grid = false;
  bool _noteOpen = true;
  int _page = 1;
  int _seq = 0;
  static const _pageSize = 6;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final mine = ++_seq;
    try {
      final d = await _api.list(q: _search.text, category: _category, page: _page, pageSize: _pageSize);
      if (!mounted || mine != _seq) return;
      setState(() {
        _data = d;
        _error = null;
      });
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() => _error = e is CatalogueApiException ? e.message : 'Could not load the catalogue. Pull down to try again.');
    }
  }

  void _reload({bool toFirst = false}) {
    if (toFirst) _page = 1;
    _load();
  }

  void _tab(String id) {
    if (id == 'item') return;
    if (id == 'bill' && HomeNav.bill != null) return HomeNav.bill!(context);
    if (widget.onNavigate != null) return widget.onNavigate!(id);
    showToast(context, 'That part of the app is not built yet.');
  }

  Future<void> _edit(CatItem item) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ItemFormScreen(api: _api, item: item, onNavigate: widget.onNavigate)));
    if (saved == true && mounted) _reload();
  }

  Future<void> _add() async {
    final what = await showCatSheet<String>(context, title: 'Add Item', subtitle: 'Choose how much you want to fill in now', body: (ctx) => Column(children: [
          _AddChoice(icon: LucideIcons.zap, label: 'Quick Add', detail: 'Name, SKU and price — ready in seconds', primary: true, onTap: () => Navigator.of(ctx).pop('quick')),
          const SizedBox(height: 10),
          _AddChoice(icon: LucideIcons.shoppingCart, label: 'Item creation', detail: 'Photo, codes, units, tax and pricing', onTap: () => Navigator.of(ctx).pop('full')),
        ]));
    if (!mounted || what == null) return;
    if (what == 'quick') {
      final made = await showQuickAdd(context, _api);
      if (made != null && mounted) {
        showToast(context, '${made.name} added.');
        _reload(toFirst: true);
      }
    } else {
      final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ItemFormScreen(api: _api, onNavigate: widget.onNavigate)));
      if (saved == true && mounted) _reload(toFirst: true);
    }
  }

  Future<void> _scan() async {
    final found = await showScanSheet(context, _api);
    if (found != null && mounted) await showAbout(context, found, onOpen: () => _openDetail(found));
  }

  Future<void> _openDetail(CatItem item) async {
    final edit = await showDetailDrawer(context, _api, item);
    if (edit != null && mounted) _edit(edit);
  }

  Future<void> _actions(CatItem item) async {
    final what = await showCatSheet<String>(context, title: item.name, subtitle: '${item.sku} · ${money(item.priceMinor)} · Item actions', body: (ctx) => Column(children: [
          SheetOption('View product details', subtitle: 'Open the catalogue record', onTap: () => Navigator.of(ctx).pop('view')),
          SheetOption('Quick edit', subtitle: 'Update existing product information', onTap: () => Navigator.of(ctx).pop('edit')),
          SheetOption('View product image', subtitle: 'Open the image viewer', onTap: () => Navigator.of(ctx).pop('image')),
          const SizedBox(height: 4),
          SheetOption('Copy SKU', trailing: LucideIcons.copy, onTap: () => Navigator.of(ctx).pop('copy')),
          const SizedBox(height: 4),
          OutlineButton('Cancel', onPressed: () => Navigator.of(ctx).pop()),
        ]));
    if (!mounted || what == null) return;
    switch (what) {
      case 'view':
        await _openDetail(item);
      case 'edit':
        await _edit(item);
      case 'image':
        await showImageViewer(context, item);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: item.sku));
        if (mounted) showToast(context, 'SKU ${item.sku} copied.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        // Item is a main tab: the outlet header (specs/outlets-multi); ☰ falls back to Home when the screen has no menu of its own
        OrdersTopBar(title: 'Catalogue', onMenu: widget.onMenu),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 16), children: [
              BigTitle('Catalogue', trailing: d == null ? null : _CountPill('${d.count('total')} ${d.count('total') == 1 ? 'item' : 'items'}')),
              const SizedBox(height: 16),
              Row(children: [
                SizedBox(width: 124, child: LimeButton('+ Add Items', onPressed: _add)),
                const SizedBox(width: 12),
                Expanded(child: _searchField()),
              ]),
              const SizedBox(height: 14),
              Row(children: [
                _TextAction(LucideIcons.upload, 'Import', kInk, () => showToast(context, 'Import is not in this release.')),
                const Spacer(),
                _TextAction(LucideIcons.download, 'Sample Template', kLink, () => showToast(context, 'The sample template is not in this release.')),
              ]),
              const SizedBox(height: 18),
              Row(children: [
                Expanded(child: Text('Food products', style: inter(16, 600))),
                _ViewToggle(grid: _grid, onChanged: (g) => setState(() => _grid = g)),
              ]),
              const SizedBox(height: 14),
              _chips(d),
              const SizedBox(height: 16),
              if (d != null) _stats(d),
              if (_noteOpen) ...[const SizedBox(height: 14), _note()],
              const SizedBox(height: 14),
              ..._body(d),
              // pager and the POS link scroll with the list: pinned above the bar they left room for about one product
              if (d != null && d.totalMatching > 0) _pager(d),
              const SizedBox(height: 8),
              DarkButton('POS Items', trailing: LucideIcons.arrowRight, onPressed: () => _tab('bill')),
            ]),
          ),
        ),
        PosBottomNav(active: 'item', onTap: _tab),
      ]),
    );
  }

  Widget _searchField() => Container(
        height: 46,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(23), border: Border.all(color: const Color(0xFFD9DCD6))),
        child: Row(children: [
          const SizedBox(width: 14),
          const Icon(LucideIcons.search, size: 20, color: kMuted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              style: inter(14, 400),
              decoration: plainInput.copyWith(hintText: 'Search name, SKU...', hintStyle: inter(14, 400, color: kMuted)),
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), () => _reload(toFirst: true));
              },
            ),
          ),
          IconButton(tooltip: 'Scan a barcode', visualDensity: VisualDensity.compact, onPressed: _scan, icon: const Icon(LucideIcons.scanLine, size: 18, color: kMuted)),
        ]),
      );

  Widget _chips(CatalogueList? d) {
    final names = d?.categories ?? const <String>[];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        _Chip('All', _category == null, () {
          _category = null;
          _reload(toFirst: true);
        }),
        for (final c in names) ...[
          const SizedBox(width: 10),
          _Chip(c, _category == c, () {
            _category = c;
            _reload(toFirst: true);
          }),
        ],
      ]),
    );
  }

  Widget _stats(CatalogueList d) {
    final tiles = [
      StatTile('Active Items', d.count('active')), StatTile('Out of Stock', d.count('out_of_stock')), StatTile('Inactive Items', d.count('inactive')),
      StatTile('Combos', d.count('combos')), StatTile('Categories', d.count('categories')), StatTile('Drafts', d.count('drafts')),
    ];
    return Column(children: [
      for (var r = 0; r < 2; r++) ...[
        if (r > 0) const SizedBox(height: 10),
        Row(children: [for (var c = 0; c < 3; c++) ...[if (c > 0) const SizedBox(width: 10), Expanded(child: tiles[r * 3 + c])]]),
      ],
    ]);
  }

  Widget _note() => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFE3E5DF))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(padding: EdgeInsets.only(top: 1), child: Icon(LucideIcons.info, size: 18, color: kMuted)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('A simpler receipt preview', style: inter(14, 600)),
              const SizedBox(height: 4),
              Text('Item quantities and tax are now easier to review before you print or share.', style: inter(13, 400, color: kMuted, height: 1.35)),
            ]),
          ),
          IconButton(tooltip: 'Dismiss', onPressed: () => setState(() => _noteOpen = false), icon: const Icon(LucideIcons.x, size: 20, color: kInk)),
        ]),
      );

  List<Widget> _body(CatalogueList? d) {
    if (_error != null && d == null) {
      return [Padding(padding: const EdgeInsets.all(24), child: Center(child: Column(children: [Text(_error!, textAlign: TextAlign.center, style: inter(14, 400, color: kMuted)), const SizedBox(height: 12), OutlineButton('Try again', onPressed: _load, height: 44)])))];
    }
    if (d == null) return [const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))];
    if (d.items.isEmpty) {
      return [Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(_search.text.trim().isEmpty && _category == null ? 'No items yet. Tap + Add Items to start.' : 'No item matches.', textAlign: TextAlign.center, style: inter(15, 400, color: kMuted))))];
    }
    if (_grid) {
      return [
        for (var i = 0; i < d.items.length; i += 2)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: ItemGridCard(d.items[i], onTap: () => showAbout(context, d.items[i], onOpen: () => _openDetail(d.items[i])), onMore: () => _actions(d.items[i]))),
                const SizedBox(width: 14),
                Expanded(
                  child: i + 1 < d.items.length
                      ? ItemGridCard(d.items[i + 1], onTap: () => showAbout(context, d.items[i + 1], onOpen: () => _openDetail(d.items[i + 1])), onMore: () => _actions(d.items[i + 1]))
                      : const SizedBox.shrink(),
                ),
              ]),
            ),
          ),
      ];
    }
    return [
      Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFE3E5DF))),
        child: Column(children: [
          for (var i = 0; i < d.items.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: Color(0xFFE3E5DF)),
            ItemRow(d.items[i], onTap: () => showAbout(context, d.items[i], onOpen: () => _openDetail(d.items[i])), onMore: () => _actions(d.items[i])),
          ],
        ]),
      ),
    ];
  }

  Widget _pager(CatalogueList d) {
    final total = d.totalMatching, from = (d.page - 1) * d.pageSize + 1, to = (from + d.items.length - 1).clamp(0, total);
    final pages = (total / d.pageSize).ceil();
    Widget num(int p) => InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: p == d.page ? null : () {
            _page = p;
            _load();
          },
          child: Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: p == d.page ? kLimeSoft : null, borderRadius: BorderRadius.circular(10)),
            child: Text('$p', style: inter(16, p == d.page ? 700 : 400, color: p == d.page ? kGreenText : kMuted)),
          ),
        );
    final shown = <int>{1, if (d.page > 1) d.page - 1, d.page, if (d.page < pages) d.page + 1, pages}.where((p) => p >= 1 && p <= pages).toList()..sort();
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
      child: Row(children: [
        Expanded(child: Text('Showing $from–$to of $total items', style: inter(13, 400, color: kMuted))),
        IconButton(tooltip: 'Previous page', visualDensity: VisualDensity.compact, onPressed: d.page > 1 ? () { _page = d.page - 1; _load(); } : null, icon: const Icon(LucideIcons.chevronLeft, size: 20)),
        for (final p in shown) num(p),
        IconButton(tooltip: 'Next page', visualDensity: VisualDensity.compact, onPressed: d.page < pages ? () { _page = d.page + 1; _load(); } : null, icon: Icon(LucideIcons.chevronRight, size: 20, color: d.page < pages ? kLink : kMuted)),
      ]),
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: const Color(0xFFE3E5DF))),
        child: Text(text, style: inter(13, 500, color: kMuted)),
      );
}

class _TextAction extends StatelessWidget {
  const _TextAction(this.icon, this.label, this.color, this.onTap);
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 18, color: color), const SizedBox(width: 6), Text(label, style: inter(14, 600, color: color))]),
        ),
      );
}

class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.grid, required this.onChanged});
  final bool grid;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) {
    Widget seg(String label, IconData icon, bool on, bool value) => Semantics(
          button: true,
          selected: on,
          label: '$label view',
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => onChanged(value),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(color: on ? kPrimary : null, borderRadius: BorderRadius.circular(14)),
              child: Row(children: [Icon(icon, size: 16, color: on ? kLime : kMuted), const SizedBox(width: 6), Text(label, style: inter(13, 600, color: on ? kLime : kMuted))]),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: const Color(0xFFE9ECE7), borderRadius: BorderRadius.circular(18)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [seg('List', LucideIcons.list, !grid, false), seg('Grid', LucideIcons.layoutGrid, grid, true)]),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.on, this.onTap);
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
            decoration: BoxDecoration(color: on ? kLime : Colors.white, borderRadius: BorderRadius.circular(999)),
            child: Text(label, style: inter(13, on ? 700 : 500, color: on ? kDark : kMuted)),
          ),
        ),
      );
}

/// One way to add a product: round icon, name, what it is for, and a chevron (stacked, so both read the same size).
class _AddChoice extends StatelessWidget {
  const _AddChoice({required this.icon, required this.label, required this.detail, required this.onTap, this.primary = false});
  final IconData icon;
  final String label, detail;
  final VoidCallback onTap;
  final bool primary;
  @override
  Widget build(BuildContext context) => Material(
        color: primary ? const Color(0xFFF3FFE4) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: primary ? kLime : const Color(0xFFE3E5DF))),
        child: InkWell(
          customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: primary ? kLime : kSoftField, shape: BoxShape.circle),
                child: Icon(icon, size: 20, color: kDark),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: inter(15, 700, color: kDark)),
                  const SizedBox(height: 2),
                  Text(detail, style: inter(12, 400, color: kMuted)),
                ]),
              ),
              const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
            ]),
          ),
        ),
      );
}
