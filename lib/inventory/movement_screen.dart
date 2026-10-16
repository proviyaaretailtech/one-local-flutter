import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'inventory_api.dart';
import 'inventory_dashboard.dart';
import 'inventory_widgets.dart';
import 'stock_detail_screen.dart';

/// Figma "Movement Detail": one ledger row — before, delta, after, where it came from, the linked transaction and the audit trail.
class MovementScreen extends StatefulWidget {
  const MovementScreen({super.key, required this.env, required this.movementId});
  final InvEnv env;
  final int movementId;
  @override
  State<MovementScreen> createState() => _MovementScreenState();
}

class _MovementScreenState extends State<MovementScreen> {
  InvEnv get env => widget.env;
  Facts? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await env.api.movement(widget.movementId);
      if (!mounted) return;
      setState(() {
        _d = d;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  static String _kind(String k) => switch (k) {
        'sale' => 'Sale',
        'sale_reversal' => 'Sale reversal',
        'receipt' => 'Receipt',
        'adjustment' => 'Adjustment',
        'wastage' => 'Write-off',
        'transfer_in' => 'Transfer in',
        'transfer_out' => 'Transfer out',
        _ => k,
      };

  @override
  Widget build(BuildContext context) {
    final trackingId = _d?.mo('item')?.s('id');
    return InvScaffold(env: env, onRefresh: _load, children: [
      InvTitle('Movement Detail', crumb: 'Inventory Tracking / ${_d == null ? '' : _label(_d!)}'),
      InvLoad<Facts>(data: _d, error: _error, onRetry: _load, builder: (d) => _body(d, trackingId)),
    ]);
  }

  String _label(Facts d) => d.m('reference').s('label').isEmpty ? 'MOV-${d.s('id')}' : d.m('reference').s('label');

  List<Widget> _body(Facts d, String? itemId) {
    final item = d.m('item');
    final unit = item.s('unit');
    final ref = d.m('reference');
    final delta = d.n('delta');
    final allocs = d.l('allocations');
    final at = d.t('created_at')!;
    final unitWord = unit == 'unit' ? 'units' : unit;
    final verb = switch (d.s('kind')) { 'sale' => 'sold', 'receipt' => 'received', 'wastage' => 'written off', _ => delta < 0 ? 'removed' : 'added' };
    return [
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('MOV-${d.s('id')} · ${_kind(d.s('kind'))}', style: inter(18, 700))),
          const InvDotChip('Posted', bg: kGreenIconBg, fg: kPostedText),
        ]),
        Text(stamp(at), style: inter(13, 400, color: kMuted)),
        const SizedBox(height: 10),
        InvTiles([
          InvStatTile(qty(d.n('before')), 'Before · $unitWord'),
          InvStatTile(signed(delta), 'Delta · $unitWord'),
          InvStatTile(qty(d.n('after')), 'After · $unitWord'),
        ]),
        const SizedBox(height: 10),
        Text('${qty(d.n('before'))} available ${delta < 0 ? '−' : '+'} ${qty(delta.abs())} $verb = ${qty(d.n('after'))} available $unitWord.', style: inter(14, 400)),
      ])),
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(item.s('name'), style: inter(17, 700)),
        Text('${item.s('sku')}${item.s('category').isEmpty ? '' : ' | ${item.s('category')}'}', style: inter(12.5, 400, color: kMuted)),
        const SizedBox(height: 6),
        for (final a in allocs) ...[
          InvKV(allocs.length > 1 || a.m('bin').s('zone') != 'shelf' ? 'Location' : 'Source location', a.m('bin').s('name').replaceFirst('Shelf ', 'Shelf ')),
          if (a.mo('lot') != null) InvKV('Batch / lot', a.m('lot').s('lot_code')),
          InvKV('Available at ${a.m('bin').s('zone') == 'shelf' ? 'source' : 'place'}', '${qty(a.n('bin_before'))} → ${units(a.n('bin_after'), unit)}'),
        ],
        for (final u in d.l('unchanged_bins')) InvKV('${u.s('name')} (unchanged)', units(u.n('on_hand'), unit)),
        const Divider(height: 18, color: Color(0xFFEDEEE9)),
        InvKV('Reserved / damaged (unchanged)', '${qty(d.n('reserved_after'))} / ${qty(d.n('damaged_after'))} units'),
      ])),
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const InvCardHead('Transaction reference'),
        if (ref.s('label').isNotEmpty) InvKV(ref.s('type') == 'order' ? 'Bill' : 'Document', '${ref.s('label')}${ref.s('type') == 'order' || ref.s('type') == 'document' ? ' ›' : ''}',
            onTap: ref.s('type') == 'order' && env.onOpenOrder != null ? () => env.onOpenOrder!(context, ref.s('id')) : null),
        InvKV('${_kind(d.s('kind'))} quantity', units(d.n('quantity').abs(), unit)),
        if (ref.mo('recorded_by') != null) InvKV('Recorded by', ref.m('recorded_by').s('name')),
        if (ref.s('method').isNotEmpty) InvKV('Posting method', ref.s('method')),
      ])),
      const InvSection('Audit trail'),
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const InvCardHead('Committed to ledger'),
        for (final t in d.l('trail'))
          InvKV('${hm(t.t('at')!)} · ${t.s('label')}', t.so('actor') ?? '', bold: true),
        InvKV('${hm(at)} · Stock posted', 'MOV-${d.s('id')}'),
        InvNote('Posted records cannot be edited. Use a linked correction to maintain the audit trail.'),
      ])),
      if (ref.s('type') == 'order' && env.onOpenOrder != null) InvPrimary('Open Linked Transaction · ${ref.s('label')}', onPressed: () => env.onOpenOrder!(context, ref.s('id'))),
      if (itemId != null)
        InvSecondary('View Tracking · ${item.s('sku')}', onPressed: () => env.push(context, StockDetailScreen(env: env, itemId: itemId, tab: 'movements'))),
      InvFootnote(at: at),
    ];
  }
}
