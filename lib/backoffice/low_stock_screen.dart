import 'dart:async';

import 'package:flutter/material.dart';

import '../orders/order_widgets.dart' show PosBottomNav, SmallPill, kDark, kGreenText;
import '../orders/orders_api.dart' show rupees;
import '../ui/theme.dart';
import 'backoffice_api.dart';
import 'backoffice_widgets.dart';
import 'purchase_suggestions_screen.dart';

/// Figma "OneLocal · Low Stock" (section J): items needing replenishment at this location, critical first, with search and
/// All / Critical / Low Stock. Every level, cover and shortfall comes from the server; missing facts read "Not set" / "Not recorded".
/// [onNavigate] gets the bottom-bar tabs ('money', 'item', 'bill', 'online', 'stock'); [onViewItem] opens section H's stock detail.
class LowStockScreen extends StatefulWidget {
  const LowStockScreen({super.key, this.api, this.onNavigate, this.onMenu, this.onItems, this.onViewItem});
  final BackofficeApi? api;
  final ValueChanged<String>? onNavigate;
  final VoidCallback? onMenu, onItems;
  final void Function(BuildContext context, String itemId)? onViewItem;
  @override
  State<LowStockScreen> createState() => _LowStockScreenState();
}

class _LowStockScreenState extends State<LowStockScreen> {
  late final BackofficeApi _api = widget.api ?? BackofficeApi();
  final _search = TextEditingController();
  Timer? _debounce;
  String _filter = 'all';
  LowStockView? _view;
  String? _error;
  int _seq = 0;

  static const _filters = [('all', 'All'), ('critical', 'Critical'), ('low', 'Low Stock')];

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
      final v = await _api.lowStock(filter: _filter, q: _search.text);
      if (!mounted || mine != _seq) return;
      setState(() {
        _view = v;
        _error = null;
      });
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() => _error = e.toString());
    }
  }

  void _tab(String id) {
    if (id == 'stock') return;
    if (widget.onNavigate != null) {
      widget.onNavigate!(id);
    } else {
      showToast(context, 'That part of the app is not built yet.');
    }
  }

  void _restock() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PurchaseSuggestionsScreen(api: _api, onNavigate: widget.onNavigate, onMenu: widget.onMenu, onItems: widget.onItems),
    ));
    if (mounted) _load();
  }

  void _viewItem(LowStockItem i) {
    if (widget.onViewItem != null) {
      widget.onViewItem!(context, i.id);
    } else {
      showToast(context, 'Stock detail opens in a later release.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _view;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        BackofficeTopBar(initials: initialsOf(v?.snapshot.viewerName), onMenu: widget.onMenu, onItems: widget.onItems),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                BackofficeHeader(title: 'Low Stock', snapshotLine: v == null ? ' ' : snapshotLine(v.snapshot.at, v.snapshot.locationName)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      v == null ? 'Items needing replenishment' : 'Items needing replenishment · ${v.low} low stock · ${v.critical} critical',
                      style: inter(11.5, 400, color: kMuted),
                    ),
                    const SizedBox(height: 10),
                    _searchField(),
                    const SizedBox(height: 9),
                    _filterRow(),
                    if (v != null && v.missingLevels) ...[
                      const SizedBox(height: 8),
                      Text('Showing recorded items only. Reorder levels and short quantities are not recorded.', style: inter(9.5, 400, color: kMuted, height: 1.4)),
                    ],
                    const SizedBox(height: 8),
                    ..._body(),
                    const SizedBox(height: 24),
                    LimeCta(label: 'Restock Items', onPressed: v == null ? null : _restock),
                    const SizedBox(height: 8),
                    Text(snapshotFootnote(v?.snapshot.at), style: inter(9.5, 400, color: kMuted, height: 1.4)),
                  ]),
                ),
              ],
            ),
          ),
        ),
        PosBottomNav(active: 'stock', onTap: _tab),
      ]),
    );
  }

  Widget _searchField() => Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: kBoCardLine)),
        child: TextField(
          controller: _search,
          style: inter(12, 400),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(border: InputBorder.none, isCollapsed: true, hintText: 'Search items', hintStyle: inter(12, 400, color: kMuted)),
          onChanged: (_) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 350), _load);
          },
          onSubmitted: (_) => _load(),
        ),
      );

  Widget _filterRow() => Row(children: [
        for (final (id, label) in _filters) ...[
          if (id != 'all') const SizedBox(width: 9),
          Expanded(
            child: Semantics(
              selected: _filter == id,
              button: true,
              child: Material(
                color: _filter == id ? kDark : Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: _filter == id ? kDark : kBoCardLine)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    setState(() => _filter = id);
                    _load();
                  },
                  child: SizedBox(height: 31, child: Center(child: Text(label, style: inter(11, 600, color: _filter == id ? Colors.white : kInk)))),
                ),
              ),
            ),
          ),
        ],
      ]);

  List<Widget> _body() {
    if (_error != null && _view == null) {
      return [
        const SizedBox(height: 40),
        Text(_error!, textAlign: TextAlign.center, style: inter(13, 400, color: kMuted)),
        const SizedBox(height: 12),
        Center(child: SmallPill('Try again', onTap: _load)),
      ];
    }
    if (_view == null) return const [SizedBox(height: 60), Center(child: CircularProgressIndicator(color: kGreenText))];
    if (_view!.items.isEmpty) {
      return [
        const SizedBox(height: 32),
        Text(
          _search.text.trim().isEmpty && _filter == 'all' ? 'Nothing is running low. Items at or under their reorder level show here.' : 'No items match.',
          textAlign: TextAlign.center,
          style: inter(13, 400, color: kMuted),
        ),
      ];
    }
    return [for (final i in _view!.items) Padding(padding: const EdgeInsets.only(bottom: 8), child: LowStockCard(item: i, onView: () => _viewItem(i)))];
  }
}

/// One item of the Low Stock list.
class LowStockCard extends StatelessWidget {
  const LowStockCard({super.key, required this.item, required this.onView});
  final LowStockItem item;
  final VoidCallback onView;
  @override
  Widget build(BuildContext context) {
    final i = item;
    final inbound = inboundTitle(daysCover: i.daysCover, inboundQty: i.inboundQty, inboundEta: i.inboundEta, unit: i.unit);
    return BoCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const ItemTile(),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(i.name, style: inter(12.5, 500), overflow: TextOverflow.ellipsis),
              Text(withUnit(i.available, i.unit), style: inter(16, 700, color: i.critical ? kBoRed : kBoAmber)),
            ]),
          ),
          Padding(padding: const EdgeInsets.only(top: 4), child: LevelBadge(critical: i.critical)),
        ]),
        if (inbound != null) ...[
          const SizedBox(height: 8),
          InboundBox(title: inbound, body: 'Review inbound before ordering.'),
        ],
        const SizedBox(height: 8),
        BoRow('Minimum / reorder level', i.reorderLevel == null ? 'Not set' : withUnit(i.reorderLevel!, i.unit)),
        BoRow('Quantity short', i.quantityShort == null ? 'Not recorded' : withUnit(i.quantityShort!, i.unit)),
        const SizedBox(height: 6),
        Text(
          'Supplier: ${i.supplierName ?? 'Not recorded'} · Last purchase price: ${i.lastPurchasePrice == null ? 'Not recorded' : rupees(i.lastPurchasePrice!)}',
          style: inter(10, 400, color: kMuted),
        ),
        const SizedBox(height: 8),
        DarkCardButton(label: 'View Item', onPressed: onView),
      ]),
    );
  }
}
