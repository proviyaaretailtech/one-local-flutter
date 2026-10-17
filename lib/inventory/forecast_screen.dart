import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'inventory_api.dart';
import 'inventory_dashboard.dart';
import 'inventory_widgets.dart';

/// Figma "Inventory Forecast": estimated demand and usable stock for one item. Planning only — it never writes a balance.
class ForecastScreen extends StatefulWidget {
  const ForecastScreen({super.key, required this.env, this.itemId});
  final InvEnv env;
  final String? itemId;
  @override
  State<ForecastScreen> createState() => _ForecastScreenState();
}

class _ForecastScreenState extends State<ForecastScreen> {
  InvEnv get env => widget.env;
  String? _itemId;
  String _itemLabel = '';
  int _days = 7;
  num? _demand; // a what-if demand per day typed in "Edit Assumptions"
  Facts? _d;
  String? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _itemId = widget.itemId;
    _load();
  }

  Future<void> _load() async {
    final id = _itemId;
    if (id == null) {
      // no item named: use the one that runs out first, else the first listed
      try {
        final s = await env.api.stock(pageSize: 1);
        final it = s.l('items').firstOrNull;
        if (it == null) return setState(() => _error = 'No items yet.');
        _itemId = it.s('id');
      } catch (e) {
        if (mounted) setState(() => _error = e.toString());
        return;
      }
    }
    final mine = ++_seq;
    try {
      final d = await env.api.forecast(_itemId!, days: _days, demandPerDay: _demand);
      if (!mounted || mine != _seq) return;
      setState(() {
        _d = d;
        _itemLabel = '${d.m('item').s('name')} · ${d.m('item').s('sku')}';
        _error = null;
      });
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _pick() async {
    final it = await pickItem(context, env.api);
    if (it == null) return;
    _itemId = it.s('id');
    _demand = null;
    _load();
  }

  Future<void> _edit() async {
    final c = TextEditingController(text: _demand == null ? qty(_d?.n('demand_per_day')).replaceAll(',', '') : qty(_demand).replaceAll(',', ''));
    final v = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Edit assumptions', style: inter(18, 700)),
          const SizedBox(height: 4),
          Text('Try a different daily demand. This is a what-if; nothing is saved.', style: inter(13, 400, color: kMuted)),
          const InvLabel('Demand (units per day)'),
          InvInput(controller: c, number: true),
          const SizedBox(height: 12),
          InvPrimary('Apply', onPressed: () => Navigator.pop(ctx, c.text.trim())),
          InvSecondary('Use sales history', onPressed: () => Navigator.pop(ctx, '')),
        ]),
      ),
    );
    if (v == null) return;
    _demand = v.isEmpty ? null : num.tryParse(v);
    _load();
  }

  @override
  Widget build(BuildContext context) => InvScaffold(env: env, onRefresh: _load, children: [
        const InvTitle('Inventory Forecast', subtitle: 'Estimated demand and usable stock • planning, not live balances'),
        InvChips(active: '$_days', onTap: (id) {
          _days = int.parse(id);
          _load();
        }, items: const [('7', '7 days', null), ('14', '14 days', null), ('30', '30 days', null)]),
        const InvLabel('Product'),
        InvPickBox(value: _itemLabel.isEmpty ? 'Choose a product' : _itemLabel, onTap: _pick, semantic: 'Product'),
        const SizedBox(height: 10),
        InvLoad<Facts>(data: _d, error: _error, onRetry: _load, builder: _body),
      ]);

  List<Widget> _body(Facts d) {
    final unit = d.m('item').s('unit') == 'unit' ? 'u' : d.m('item').s('unit');
    final days = d.n('days').toInt();
    final inbound = d.l('inbound');
    final sens = d.l('sensitivity');
    final short = d.n('end_stock') < 0;
    final per = d.n('demand_per_day');
    return [
      InvTiles([
        InvStatTile('${qty(d.n('demand_total'))} $unit', '$days-day demand estimate', big: true),
        InvStatTile('${qty(d.n('end_stock'))} $unit', 'End stock estimate', color: short ? kRedText : kInk),
      ]),
      const SizedBox(height: 10),
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InvCardHead('Projected available stock', subtitle: '${dayMonth(d.t('baseline_date')!)} baseline; day-end estimates · units'),
        SizedBox(
          height: 230,
          child: Semantics(
            label: 'Chart of projected stock: ${d.l('series').map((p) => qty(p.n('value'))).join(', ')}',
            child: CustomPaint(painter: _ForecastPainter(d.l('series'), inbound, d.n('safety_buffer')), size: Size.infinite),
          ),
        ),
        const SizedBox(height: 8),
        InvNote('Navy = estimated free stock.${inbound.isEmpty ? '' : ' Marker = ${inbound.first.s('doc_no')}\'s ${qty(inbound.first.n('qty'))} accepted units released on ${dayMonth(inbound.first.t('date')!)}, conditional on approval.'}'),
      ])),
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const InvCardHead('Assumptions'),
        InvKV('Opening available', units(d.n('opening'))),
        InvKV('Demand model', '${qty(per)} units/day × $days days'),
        InvKV('Inbound scenario', inbound.isEmpty ? 'none expected' : '${qty(d.n('inbound_total'))} usable on day ${inbound.first.n('day').toInt()}'),
        InvKV('Rejected delivery units', '${qty(d.n('rejected_excluded'))} · excluded'),
        InvKV('Projection', '${qty(d.n('opening'))}${d.n('inbound_total') == 0 ? '' : ' + ${qty(d.n('inbound_total'))}'} − ${qty(d.n('demand_total'))} = ${qty(d.n('end_stock'))} units'),
        InvNote(d.b('demand_from_history')
            ? 'Demand is the average of the last ${d.n('history_days').toInt()} days of sales; no new reservations, losses or other receipts. Current inbound stays in transit until the receipt is posted; this estimate uses only the accepted units.'
            : 'Demand is the figure you typed in; it is a what-if and is not saved.'),
      ])),
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InvCardHead('Sensitivity · next $days days'),
        for (final s in sens)
          InvKV(s.n('pct') == 0 ? 'Base · ${qty(s.n('per_day'))}/day' : 'Demand ${s.n('pct') < 0 ? '−' : '+'}${s.n('pct').abs().toInt()}% · ${qty(s.n('per_day'))}/day',
              s.n('end') < 0 ? '${qty(s.n('end').abs())}-unit shortfall' : '${qty(s.n('end'))} units remaining', valueColor: s.n('end') < 0 ? kRedText : kInk),
        const SizedBox(height: 4),
        if (d.no('buffer_breach_day') != null)
          Text('Base coverage falls below the ${qty(d.n('safety_buffer'))}-unit one-day safety buffer on day ${d.n('buffer_breach_day').toInt()}. Suggest ${qty(d.n('suggest_qty'))} more units, subject to lead time.',
              style: inter(13.5, 500, height: 1.45))
        else
          Text('Base coverage stays above the one-day safety buffer for all $days days.', style: inter(13.5, 500, height: 1.45)),
      ])),
      InvPrimary('Review Scenario', onPressed: () => showOrderlessSheetLike(context, d)),
      InvSecondary('Edit Assumptions', onPressed: _edit),
      InvFootnote(at: DateTime.now()),
    ];
  }

  /// A plain summary of the scenario (the Figma frame leaves "Review Scenario" undefined; this shows the numbers in one place).
  void showOrderlessSheetLike(BuildContext context, Facts d) {
    final sens = d.l('sensitivity');
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Scenario summary', style: inter(18, 700)),
            const SizedBox(height: 8),
            InvKV('Item', d.m('item').s('name')),
            InvKV('Horizon', '${d.n('days').toInt()} days'),
            InvKV('End stock', units(d.n('end_stock'))),
            for (final s in sens) InvKV('Demand ${s.n('pct') > 0 ? '+' : ''}${s.n('pct').toInt()}%', units(s.n('end'))),
            InvKV('Suggested extra units', qty(d.n('suggest_qty'))),
            InvNote('Raising a purchase suggestion happens in the back office.'),
            const SizedBox(height: 10),
            InvPrimary('Close', onPressed: () => Navigator.pop(ctx)),
          ]),
        ),
      ),
    );
  }
}

class _ForecastPainter extends CustomPainter {
  _ForecastPainter(this.series, this.inbound, this.buffer);
  final List<Facts> series, inbound;
  final num buffer;

  @override
  void paint(Canvas canvas, Size size) {
    if (series.length < 2) return;
    const left = 36.0, bottom = 22.0, top = 22.0;
    final w = size.width - left - 6, h = size.height - bottom - top;
    final vals = series.map((p) => p.n('value').toDouble()).toList();
    final maxV = math.max(vals.reduce(math.max), 1.0);
    final minV = math.min(vals.reduce(math.min), 0.0);
    final top0 = (maxV / 28).ceil() * 28.0;
    final yMax = math.max(top0, maxV);
    double x(int i) => left + w * i / (series.length - 1);
    double y(double v) => top + h * (1 - (v - minV) / (yMax - minV));
    final grid = Paint()..color = const Color(0xFFE5E7EB)..strokeWidth = 1;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    void text(String s, Offset o, {TextStyle? style, bool center = false}) {
      tp.text = TextSpan(text: s, style: style ?? inter(11, 400, color: kMuted));
      tp.layout();
      tp.paint(canvas, center ? o - Offset(tp.width / 2, 0) : o);
    }

    for (final g in [0.0, yMax / 3, yMax * 2 / 3, yMax]) {
      canvas.drawLine(Offset(left, y(g)), Offset(left + w, y(g)), grid);
      text(g.round().toString(), Offset(0, y(g) - 7));
    }
    final step = math.max(1, (series.length / 8).ceil());
    for (var i = 0; i < series.length; i += step) {
      final d = series[i].t('date');
      text(d == null ? '$i' : d.day.toString().padLeft(2, '0'), Offset(x(i), size.height - bottom + 6), center: true);
    }
    final line = Path()..moveTo(x(0), y(vals[0]));
    for (var i = 1; i < vals.length; i++) {
      line.lineTo(x(i), y(vals[i]));
    }
    canvas.drawPath(line, Paint()..color = kInk..style = PaintingStyle.stroke..strokeWidth = 2.2..strokeJoin = StrokeJoin.round);
    for (final b in inbound) {
      final i = b.n('day').toInt().clamp(0, series.length - 1);
      canvas.drawLine(Offset(x(i), top - 8), Offset(x(i), top + h), Paint()..color = const Color(0xFF16A34A)..strokeWidth = 1.5);
      text('+${qty(b.n('qty'))} accepted', Offset(x(i), 0), style: inter(11, 500, color: const Color(0xFF16A34A)), center: true);
    }
    final show = <int>{0, series.length - 1, ...inbound.map((b) => b.n('day').toInt().clamp(0, series.length - 1))};
    for (var i = 0; i < vals.length; i += math.max(1, (vals.length / 8).ceil())) {
      show.add(i);
    }
    for (final i in show) {
      text(vals[i].round().toString(), Offset(x(i) + 3, y(vals[i]) - 17), style: inter(11.5, 700));
    }
  }

  @override
  bool shouldRepaint(_ForecastPainter old) => old.series != series || old.inbound != inbound;
}
