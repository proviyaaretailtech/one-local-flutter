import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import 'prices_common.dart';
import 'stock_env.dart';
import 'stock_kit.dart';

/// Figma "Low Stock View", simplified: the items that are running out (low, critical, out of stock), the most urgent first, with what
/// is on the way. Each card opens the item; "See incoming" opens its movements, "Reorder" the reorder page.
class LowStockViewScreen extends StatefulWidget {
  const LowStockViewScreen({super.key, required this.env, this.itemId});
  final StockEnv env;
  final String? itemId;
  @override
  State<LowStockViewScreen> createState() => _LowStockViewScreenState();
}

class _LowStockViewScreenState extends State<LowStockViewScreen> {
  List<Facts>? _items;
  Facts? _first;
  String? _error;
  String _tab = 'priority';
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await loadAllStock(widget.env.api);
      if (mounted) {
        setState(() {
          _items = r.items;
          _first = r.first;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = stockError(e));
    }
  }

  static int _rank(String s) => switch (s) { 'out' => 0, 'critical' => 1, 'low' => 2, _ => 3 };

  List<Facts> _shown(List<Facts> all) {
    final q = _search.text.trim().toLowerCase();
    final rows = all.where((i) => switch (_tab) {
          'low' => i.s('status') == 'low',
          'critical' => i.s('status') == 'critical' || i.s('status') == 'out',
          _ => const {'low', 'critical', 'out'}.contains(i.s('status')),
        });
    final hits = rows.where((i) => q.isEmpty || i.s('name').toLowerCase().contains(q) || i.s('sku').toLowerCase().contains(q)).toList();
    hits.sort((a, b) {
      final r = _rank(a.s('status')).compareTo(_rank(b.s('status')));
      return r != 0 ? r : (a.no('stock_days') ?? 0).compareTo(b.no('stock_days') ?? 0);
    });
    return hits;
  }

  void _purchase() {
    final open = widget.env.onOpenPurchase;
    if (open != null) return open(context);
    showToast(context, 'Purchase orders open from the Purchase section in the side menu.');
  }

  @override
  Widget build(BuildContext context) {
    final env = widget.env;
    return StockScaffold(
      env: env,
      title: 'Low stock',
      line: 'Items that are running out, the most urgent first, with what is already on the way.',
      onRefresh: _load,
      children: [
        InvLoad<List<Facts>>(
          data: _items,
          error: _error,
          onRetry: _load,
          builder: (all) {
            final counts = _first!.m('counts');
            final shown = _shown(all);
            return [
              StockNumbers([
                StockNumber(qty(counts.n('low')), 'Low on stock', color: kAmberText),
                StockNumber(qty(counts.n('critical')), 'Critical or out of stock', color: kRedText),
              ]),
              const SizedBox(height: 14),
              InvChips(
                active: _tab,
                onTap: (t) => setState(() => _tab = t),
                items: [('priority', 'Most urgent', null), ('low', 'Low', counts.n('low')), ('critical', 'Critical', counts.n('critical'))],
              ),
              const SizedBox(height: 12),
              InvInput(controller: _search, hint: 'Search product name or System Code', prefixIcon: LucideIcons.search, onChanged: (_) => setState(() {})),
              const SizedBox(height: 12),
              if (shown.isEmpty)
                StockEmpty(
                  _search.text.trim().isEmpty ? 'Nothing is running low' : 'No item matches',
                  _search.text.trim().isEmpty ? 'Every item has enough stock right now.' : 'Try another name or System Code.',
                  icon: LucideIcons.packageCheck,
                )
              else
                for (final it in shown) _card(it),
              const SizedBox(height: 6),
              InvPrimary('Create purchase order', onPressed: _purchase),
              const SizedBox(height: 8),
              InvNote('"On the way" is stock already ordered or being received. It is not on the shelf until it is received.'),
            ];
          },
        ),
      ],
    );
  }

  Widget _card(Facts it) {
    final env = widget.env;
    final code = it.s('sku');
    return InvCard(
      key: ValueKey('low-${it.s('id')}'),
      onTap: () => env.open(context, StockPage.item, itemId: it.s('id')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InvCardHead(it.s('name'), subtitle: code.isEmpty ? null : 'System Code: $code', chip: StockStatusChip(it.s('status'))),
        const SizedBox(height: 8),
        StockRow('Available', unitsOf(it, 'available'), color: it.n('available') <= 0 ? kRedText : null),
        StockRow('Lasts about', coverText(it)),
        StockRow('On the way', unitsOf(it, 'in_transit')),
        StockRow('On hold for orders', unitsOf(it, 'reserved')),
        StockRow('Expiry', expiryText(it), color: (it.no('expiry_days') ?? 99) < 0 ? kRedText : null),
        const SizedBox(height: 10),
        TwoButtons(
          'See incoming', () => env.open(context, StockPage.movements, itemId: it.s('id')),
          'Reorder', () => env.open(context, StockPage.reorder, itemId: it.s('id')),
        ),
      ]),
    );
  }
}
