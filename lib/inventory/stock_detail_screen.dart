import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'forecast_screen.dart';
import 'inventory_api.dart';
import 'inventory_dashboard.dart';
import 'inventory_widgets.dart';
import 'movement_screen.dart';
import 'transfer_screen.dart';

/// Figma "Stock Detail": one item's position, where it sits (bins), its batches and its movements. Tabs: Overview, Lots, Movements.
class StockDetailScreen extends StatefulWidget {
  const StockDetailScreen({super.key, required this.env, required this.itemId, this.tab = 'overview'});
  final InvEnv env;
  final String itemId;
  final String tab;
  @override
  State<StockDetailScreen> createState() => _StockDetailScreenState();
}

class _StockDetailScreenState extends State<StockDetailScreen> {
  InvEnv get env => widget.env;
  late String _tab = widget.tab;
  Facts? _d;
  List<Facts>? _moves;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await env.api.stockDetail(widget.itemId);
      final m = await env.api.movements(itemId: widget.itemId);
      if (!mounted) return;
      setState(() {
        _d = d;
        _moves = m;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => InvScaffold(env: env, onRefresh: _load, children: [
        InvTitle('Stock Detail', crumb: 'Inventory / ${_d?.m('item').s('name') ?? ''}'),
        InvLoad<Facts>(data: _d, error: _error, onRetry: _load, builder: _body),
      ]);

  List<Widget> _body(Facts d) {
    final item = d.m('item');
    final unit = item.s('unit');
    final latest = d.mo('latest_movement');
    return [
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(item.s('name'), style: inter(19, 700))),
          _Health(d.s('status')),
        ]),
        Text('SKU: ${item.s('sku')}${item.s('category').isEmpty ? '' : ' | ${item.s('category')}'}', style: inter(13, 400, color: kMuted)),
        const SizedBox(height: 12),
        InvTiles([
          InvStatTile(qty(d.n('available')), unit == 'unit' ? 'Available units' : 'Available $unit'),
          InvStatTile(d.no('stock_days') == null ? '–' : qty(d.n('stock_days')), 'Stock days'),
        ]),
        const SizedBox(height: 8),
        InvKV('Reserved (Active Carts)', units(d.n('reserved'), unit)),
        InvKV('In Transit (From Warehouse)', units(d.n('in_transit'), unit)),
        InvKV('Damaged / Quarantine', units(d.n('damaged'), unit), valueColor: d.n('damaged') > 0 ? kRedText : kInk),
        InvNote('${qty(d.n('available'))} is already free to sell. Reserved and damaged quantities are held separately.'),
      ])),
      InvChips(active: _tab, onTap: (id) => setState(() => _tab = id), items: const [('overview', 'Overview', null), ('lots', 'Lots', null), ('movements', 'Movements', null)]),
      if (_tab == 'overview') ..._overview(d, latest),
      if (_tab == 'lots') ..._lots(d),
      if (_tab == 'movements') ..._movements(),
      InvPrimary('View Movements', onPressed: () => setState(() => _tab = 'movements')),
      InvSecondary('View Lots', onPressed: () => setState(() => _tab = 'lots')),
      InvSecondary('Transfer Stock', onPressed: () => env.push(context, TransferScreen(env: env, startItem: d.m('item'))).then((_) => mounted ? _load() : null)),
      InvSecondary('Forecast', onPressed: () => env.push(context, ForecastScreen(env: env, itemId: item.s('id')))),
      InvFootnote(at: d.t('snapshot_at')),
    ];
  }

  List<Widget> _overview(Facts d, Facts? latest) {
    final bins = d.l('bins');
    final lots = d.l('lots').where((l) => l.s('zone') != 'quarantine').toList();
    final unit = d.m('item').s('unit');
    final sellable = bins.where((b) => b.s('zone') != 'quarantine').fold<num>(0, (a, b) => a + b.n('on_hand'));
    return [
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InvCardHead('Available by location', subtitle: '${d.m('location').s('name')} • allocations total ${units(sellable, unit)}'),
        for (final b in bins.where((b) => b.s('zone') != 'quarantine')) ...[
          Row(children: [Expanded(child: Text(b.s('name'), style: inter(14, 400, color: kMuted))), Text(units(b.n('on_hand'), unit), style: inter(14, 600))]),
          InvBar(fraction: sellable <= 0 ? 0 : b.n('on_hand') / sellable, color: b.s('zone') == 'shelf' ? kLimeH : kNavyH),
          const SizedBox(height: 4),
        ],
        for (final b in bins.where((b) => b.s('zone') == 'quarantine'))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              Expanded(child: Text('${b.s('name')} (excluded)', style: inter(14, 400, color: kMuted))),
              Text('${qty(b.n('on_hand'))} damaged units', style: inter(14, 600, color: kRedText)),
            ]),
          ),
        if (bins.isEmpty) Text('No stock placed yet.', style: inter(13.5, 400, color: kMuted)),
      ])),
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const InvCardHead('Batch and expiry', subtitle: 'Pick oldest eligible batch first'),
        for (final l in lots)
          InvKV('${l.s('lot_code')} · ${l.s('bin_name')}', '${qty(l.n('on_hand'))} available${l.no('days_left') == null ? '' : ' • ${l.n('days_left').toInt()} days'}'),
        if (lots.isEmpty) Text('No batches recorded.', style: inter(13.5, 400, color: kMuted)),
        if (d.n('reserved') > 0) InvKV('Reserved allocations', units(d.n('reserved'), unit)),
      ])),
      if (latest != null)
        InvCard(
          onTap: () => env.push(context, MovementScreen(env: env, movementId: latest.n('id').toInt())),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            InvCardHead('Latest posted movement',
                subtitle: '${latest.m('reference').s('label')} • ${latest.s('kind').replaceAll('_', ' ')} • ${stamp(latest.t('created_at')!).replaceFirst(RegExp(r' \d{4},'), ',')}'),
            InvKV('Available balance', '${qty(latest.n('before'))} ${latest.n('delta') < 0 ? '−' : '+'} ${qty(latest.n('delta').abs())} = ${units(latest.n('after'), unit)}'),
            InvKV('Operator / reference', [latest.m('reference').mo('recorded_by')?.s('name'), latest.m('reference').s('label')].whereType<String>().where((s) => s.isNotEmpty).join(' / ')),
          ]),
        ),
    ];
  }

  List<Widget> _lots(Facts d) {
    final lots = d.l('lots');
    final unit = d.m('item').s('unit');
    return [
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const InvCardHead('Lots', subtitle: 'Earliest expiry first'),
        for (final l in lots)
          InvKV('${l.s('lot_code')} · ${l.s('bin_name')}',
              '${units(l.n('on_hand'), unit)}${l.no('days_left') == null ? '' : ' • ${l.n('days_left') < 0 ? 'expired' : '${l.n('days_left').toInt()} days'}'}',
              valueColor: l.s('zone') == 'quarantine' ? kRedText : kInk),
        if (lots.isEmpty) Text('No batches recorded.', style: inter(13.5, 400, color: kMuted)),
      ])),
    ];
  }

  List<Widget> _movements() {
    final m = _moves ?? const <Facts>[];
    return [
      InvCard(padding: const EdgeInsets.fromLTRB(16, 12, 16, 6), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const InvCardHead('Movements', subtitle: 'Newest first · posted only'),
        for (final x in m)
          InvKV('${x.m('ref').s('label')} · ${x.s('kind').replaceAll('_', ' ')} · ${stamp(x.t('created_at')!)}', signed(x.n('delta')),
              valueColor: x.n('delta') < 0 ? kRedText : kInk, onTap: () => env.push(context, MovementScreen(env: env, movementId: x.n('id').toInt()))),
        if (m.isEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('No movements yet.', style: inter(13.5, 400, color: kMuted))),
      ])),
    ];
  }
}

class _Health extends StatelessWidget {
  const _Health(this.status);
  final String status;
  @override
  Widget build(BuildContext context) {
    final (t, bg, fg) = statusLook(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: status == 'healthy' ? kGreenIconBg : bg, borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: status == 'healthy' ? kLink : fg, shape: BoxShape.circle)),
        const SizedBox(width: 7),
        Text(t == 'Out of Stock' ? 'Out of stock' : t, style: inter(13.5, 600, color: status == 'healthy' ? kPostedText : fg)),
      ]),
    );
  }
}
