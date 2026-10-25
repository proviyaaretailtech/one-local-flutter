import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import 'prices_common.dart';
import 'stock_env.dart';
import 'stock_kit.dart';

/// Figma "Replenishment", simplified: what to buy again and how much. The suggestions come from the stock dashboard; each item's
/// recent daily sales and what is already on the way come from its 7-day forecast. The quantities are the person's own to change;
/// "Create purchase order" opens the purchase order screen (the order itself is made there).
class ReorderScreen extends StatefulWidget {
  const ReorderScreen({super.key, required this.env, this.itemId});
  final StockEnv env;
  final String? itemId;
  @override
  State<ReorderScreen> createState() => _ReorderScreenState();
}

class _Line {
  _Line(this.id, this.name, this.unit, this.urgent, num suggest) : qty = TextEditingController(text: suggest > 0 ? qty0(suggest) : '');
  final String id, name, unit;
  final bool urgent;
  final TextEditingController qty;
  Facts? forecast;
  Facts? stock;
  static String qty0(num v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';
}

class _ReorderScreenState extends State<ReorderScreen> {
  List<_Line>? _lines;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final l in _lines ?? const <_Line>[]) {
      l.qty.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final api = widget.env.api;
      final dash = await api.dashboard();
      final stock = await loadAllStock(api);
      final byId = {for (final s in stock.items) s.s('id'): s};
      final lines = [
        for (final r in dash.l('replenishment')) _Line(r.s('id'), r.s('name'), r.s('unit'), r.b('urgent'), r.n('suggest')),
      ];
      // opened for one item that is not suggested: add it, so its numbers can still be checked
      final one = widget.itemId;
      if (one != null && !lines.any((l) => l.id == one) && byId[one] != null) {
        final s = byId[one]!;
        lines.insert(0, _Line(one, s.s('name'), s.s('unit'), false, 0));
      }
      for (final l in lines) {
        l.stock = byId[l.id];
      }
      await Future.wait([
        for (final l in lines)
          api.forecast(l.id).then((f) => l.forecast = f).catchError((Object _) => Facts(const {})),
      ]);
      for (final l in lines) {
        final s = l.forecast?.no('suggest_qty');
        if (l.qty.text.isEmpty && s != null && s > 0) l.qty.text = _Line.qty0(s);
      }
      if (!mounted) return;
      for (final l in _lines ?? const <_Line>[]) {
        l.qty.dispose();
      }
      setState(() => _lines = lines);
    } catch (e) {
      if (mounted) setState(() => _error = stockError(e));
    }
  }

  num _total(List<_Line> lines) => lines.fold<num>(0, (s, l) => s + (num.tryParse(l.qty.text.trim()) ?? 0));

  void _purchase() {
    final open = widget.env.onOpenPurchase;
    if (open != null) return open(context);
    showToast(context, 'Purchase orders open from the Purchase section in the side menu.');
  }

  @override
  Widget build(BuildContext context) => StockScaffold(
        env: widget.env,
        title: 'Reorder',
        line: 'What to buy again and how much. Change any quantity, then create the purchase order.',
        onRefresh: _load,
        children: [
          InvLoad<List<_Line>>(
            data: _lines,
            error: _error,
            onRetry: _load,
            builder: (lines) {
              final picked = lines.where((l) => (num.tryParse(l.qty.text.trim()) ?? 0) > 0).toList();
              return [
                const InvInfoBanner(
                  title: 'These are suggestions',
                  body: 'They use recent sales and what is already on the way. Nothing is ordered until you create the purchase order.',
                ),
                const SizedBox(height: 12),
                if (lines.isEmpty)
                  const StockEmpty('Nothing to reorder', 'Every item has enough stock for the next few days.', icon: LucideIcons.packageCheck)
                else
                  for (final l in lines) _card(l),
                if (lines.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  InvCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text('Order summary', style: inter(16, 700)),
                      const SizedBox(height: 6),
                      StockRow('Items to order', '${picked.length}'),
                      StockRow('Total quantity', qty(_total(lines)), strong: true),
                      for (final l in picked) StockRow(l.name, '${l.qty.text.trim()} ${l.unit.isEmpty ? 'units' : l.unit}'),
                    ]),
                  ),
                ],
                const SizedBox(height: 6),
                InvPrimary(picked.isEmpty ? 'Create purchase order' : 'Create purchase order · ${qty(_total(lines))} units', onPressed: _purchase),
                const SizedBox(height: 8),
                InvNote('Note the quantities above: the purchase order screen opens next, where you pick the supplier and add them.'),
              ];
            },
          ),
        ],
      );

  Widget _card(_Line l) {
    final env = widget.env;
    final f = l.forecast;
    final s = l.stock;
    final unit = l.unit.isEmpty ? 'units' : l.unit;
    final perDay = f?.no('demand_per_day');
    return InvCard(
      key: ValueKey('reorder-${l.id}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: () => env.open(context, StockPage.item, itemId: l.id),
          child: InvCardHead(
            l.name,
            subtitle: s == null || s.s('sku').isEmpty ? null : 'System Code: ${s.s('sku')}',
            chip: StockStatusChip(l.urgent ? 'critical' : 'low', label: l.urgent ? 'Urgent' : 'Soon'),
          ),
        ),
        const SizedBox(height: 8),
        if (s != null) StockRow('Available now', unitsOf(s, 'available'), color: s.n('available') <= 0 ? kRedText : null),
        StockRow('On the way', '${qty(f?.n('inbound_total') ?? s?.n('in_transit') ?? 0)} $unit'),
        StockRow('Sells per day', perDay == null || perDay == 0 ? 'No recent sales' : '${perDay.toStringAsFixed(perDay < 10 ? 1 : 0)} $unit'),
        if (f != null && f.has('end_stock')) StockRow('Left after 7 days', '${qty(f.n('end_stock'))} $unit', color: f.n('end_stock') < 0 ? kRedText : null),
        const SizedBox(height: 10),
        InvLabel('Order quantity ($unit)'),
        const SizedBox(height: 6),
        InvInput(key: ValueKey('reorder-qty-${l.id}'), controller: l.qty, number: true, label: 'Order quantity ($unit)', hint: '0', onChanged: (_) => setState(() {})),
      ]),
    );
  }
}
