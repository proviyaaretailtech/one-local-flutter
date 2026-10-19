import 'package:flutter/material.dart';

import '../inventory/inventory_api.dart';
import '../inventory/inventory_dashboard.dart';
import '../inventory/inventory_widgets.dart';
import '../ui/theme.dart';
import 'purchasing_api.dart';
import 'purchasing_widgets.dart';

/// Figma "Supplier Price Detail" with its three tabs: Overview & Trends (the active supplier selection and contract parameters), Alternative Bids
/// (the suppliers bidding for the ingredient, "Select supplier") and Quality Audit (the latest audit round, "Re-Audit"). Only what the database holds is
/// shown: a figure nobody recorded reads "—", never a made-up one.
class SupplierPriceScreen extends StatefulWidget {
  const SupplierPriceScreen({super.key, required this.env, required this.priceId, this.tab = 'overview'});
  final PurEnv env;
  final String priceId;
  final String tab;
  @override
  State<SupplierPriceScreen> createState() => _SupplierPriceScreenState();
}

class _SupplierPriceScreenState extends State<SupplierPriceScreen> {
  PurEnv get env => widget.env;
  Facts? _d;
  String? _error;
  late String _tab = widget.tab;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await env.api.price(widget.priceId);
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

  Future<void> _run(Future<Facts> Function() call) async {
    setState(() => _busy = true);
    try {
      final d = await call();
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) showToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _select(Facts bid) async {
    final name = bid.m('supplier').s('name');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Select $name?'),
        content: const Text('This supplier becomes the preferred one. The change is kept in the audit trail with your name and the time.'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Select supplier'))],
      ),
    );
    if (ok == true) await _run(() => env.api.selectSourcing(bid.s('price_id')));
  }

  Future<void> _audit(Facts d) async {
    final rows = <_CheckRow>[
      for (final c in d.m('audit').l('checks')) _CheckRow(c.s('name'), c.s('result'), c.s('detail')),
      if (d.m('audit').l('checks').isEmpty) _CheckRow('', 'pass', ''),
    ];
    final sent = await showModalBottomSheet<List<Map<String, String>>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => _AuditSheet(rows: rows),
    );
    if (sent != null) await _run(() => env.api.recordAudit(d.s('price_id'), sent));
  }

  @override
  Widget build(BuildContext context) => InvScaffold(env: env.inv, onRefresh: _load, children: [
        const InvTitle('Suppliers'),
        InvLoad<Facts>(data: _d, error: _error, onRetry: _load, builder: _body),
      ]);

  List<Widget> _body(Facts d) {
    final actions = d.ls('allowed_actions');
    final unit = d.s('unit');
    final src = d.s('source');
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text('${d.s('emoji')} ${d.s('ingredient_name')}'.trim(), style: inter(24, 700)),
      ),
      Text('Supplier: ${d.m('supplier').s('name')} · UOM: Per ${unit.toUpperCase()}${d.s('sku_id').isEmpty ? '' : ' · SKU ID: ${d.s('sku_id')}'}', style: inter(14.5, 400, color: kMuted, height: 1.4)),
      if (src.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Align(alignment: Alignment.centerLeft, child: PoChip(src, bg: kBlueIconBg, fg: kBlueIcon))),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: InvSecondary('Re-Audit', onPressed: actions.contains('re_audit') && !_busy ? () => _audit(d) : null)),
        const SizedBox(width: 10),
        Expanded(child: InvPrimary('Select Sourcing', onPressed: actions.contains('select_sourcing') && !_busy ? () => setState(() => _tab = 'bids') : null)),
      ]),
      _tabs(),
      ...switch (_tab) { 'bids' => _bids(d, actions, unit), 'audit' => _auditTab(d), _ => _overview(d, unit) },
    ];
  }

  Widget _tabs() => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(children: [
          for (final (id, label) in const [('overview', 'Overview & Trends'), ('bids', 'Alternative Bids'), ('audit', 'Quality Audit')])
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Semantics(
                  button: true,
                  selected: _tab == id,
                  child: InkWell(
                    key: ValueKey('tab-$id'),
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() => _tab = id),
                    child: Container(
                      height: 52,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(color: _tab == id ? const Color(0xFFEAF8DA) : Colors.white, borderRadius: BorderRadius.circular(14)),
                      child: Text(label, textAlign: TextAlign.center, style: inter(13.5, _tab == id ? 700 : 500)),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      );

  String _rate(Facts bid, String unit, {required bool preferred}) {
    final r = '${preferred ? 'Contract Rate' : 'Bid Rate'}: ${money(bid.n('rate_minor'))}/$unit';
    final rating = bid.m('supplier').no('rating');
    return rating == null || rating == 0 ? r : '$r · Rating: ${rating == rating.roundToDouble() ? rating.toInt() : rating}★';
  }

  String _lead(num? h) => h == null ? '—' : '$h Hours';
  String _moq(num? v, String unit) => v == null ? '—' : '${qty1(v).replaceFirst(RegExp(r'\.0$'), '')} $unit';
  String _avail(num? v) => v == null ? '—' : '${v == v.roundToDouble() ? v.toInt() : v}% Guaranteed';

  List<Widget> _overview(Facts d, String unit) {
    final bids = d.l('bids');
    final c = d.m('contract');
    return [
      const InvSection('Active Supplier Selection'),
      if (bids.isEmpty) InvCard(child: Text('No supplier prices recorded for this ingredient.', style: inter(14.5, 400, color: kMuted))),
      for (final b in bids) _bidSummary(b, unit),
      Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: const Color(0xFFF7EBDD), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFF5A623))),
        child: Text('Sourcing selection changes require kitchen controller audit trailing.', style: inter(14.5, 400, color: const Color(0xFFD98200), height: 1.4)),
      ),
      InvCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Sourcing Contract Parameters', style: inter(18, 700)),
          const SizedBox(height: 8),
          InvKV('Lead Time', _lead(c.no('lead_time_hours')), bold: false),
          InvKV('Minimum Order Qty (MOQ)', _moq(c.no('moq'), unit), bold: false),
          InvKV('Payment Terms', c.s('payment_terms').isEmpty ? '—' : c.s('payment_terms'), bold: false),
          InvKV('Supply Availability', _avail(c.no('availability_pct')), bold: false),
        ]),
      ),
    ];
  }

  Widget _dot(bool preferred) => Container(width: 22, height: 22, margin: const EdgeInsets.only(right: 10), decoration: BoxDecoration(color: preferred ? const Color(0xFF10B981) : const Color(0xFF6B7280), shape: BoxShape.circle));

  Widget _bidSummary(Facts b, String unit) {
    final pref = b.b('preferred');
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      _dot(pref),
      Expanded(
        child: InvCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${b.m('supplier').s('name')}${pref ? ' (Preferred)' : ''}', style: inter(18, 700)),
            const SizedBox(height: 6),
            Text(_rate(b, unit, preferred: pref), style: inter(14.5, 400)),
          ]),
        ),
      ),
    ]);
  }

  List<Widget> _bids(Facts d, List<String> actions, String unit) {
    final bids = d.l('bids');
    return [
      const InvSection('Available Supplier Bids'),
      Padding(padding: const EdgeInsets.only(bottom: 12), child: Text('${bids.length} ${bids.length == 1 ? 'supplier' : 'suppliers'} · Rates per ${unit.toUpperCase()}', style: inter(14.5, 400, color: kMuted))),
      for (final b in bids) ...[
        Padding(padding: const EdgeInsets.only(bottom: 6), child: _dot(b.b('preferred'))),
        InvCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${b.m('supplier').s('name')}${b.b('preferred') ? ' (Preferred)' : ''}', style: inter(18, 700)),
            const SizedBox(height: 8),
            Text(_rate(b, unit, preferred: b.b('preferred')), style: inter(14.5, 400)),
            const SizedBox(height: 4),
            Text('Lead Time: ${_lead(b.no('lead_time_hours'))}', style: inter(14.5, 400)),
            const SizedBox(height: 4),
            Text('Minimum Order Qty (MOQ): ${_moq(b.no('moq'), unit)}', style: inter(14.5, 400)),
            const SizedBox(height: 4),
            Text('Payment Terms: ${b.m('supplier').s('payment_terms').isEmpty ? '—' : b.m('supplier').s('payment_terms')}', style: inter(14.5, 400)),
            const SizedBox(height: 4),
            Text('Supply Availability: ${_avail(b.no('availability_pct'))}', style: inter(14.5, 400)),
            if (b.b('preferred')) ...[const SizedBox(height: 4), Text('Current preferred supplier', style: inter(14.5, 400))],
          ]),
        ),
        if (!b.b('preferred') && actions.contains('select_sourcing')) InvSecondary('Select supplier', onPressed: _busy ? null : () => _select(b)),
      ],
    ];
  }

  List<Widget> _auditTab(Facts d) {
    final a = d.m('audit');
    final checks = a.l('checks');
    final fail = a.n('fail').toInt(), warn = a.n('warning').toInt(), pass = a.n('pass').toInt();
    return [
      const InvSection('Key Quality Checks'),
      if (a.n('rounds') == 0)
        InvCard(child: Text('No audit recorded yet.', style: inter(14.5, 400, color: kMuted)))
      else ...[
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: fail > 0 ? kRedSoft : kMintBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: fail > 0 ? kRedText : kPostedText),
          ),
          child: Text('${fail > 0 ? 'Re-audit required · ' : ''}$pass Pass · $warn Warning · $fail Fail', style: inter(15, 500, color: fail > 0 ? kRedText : kPostedText)),
        ),
        for (final c in checks) _check(c),
      ],
    ];
  }

  Widget _check(Facts c) {
    final (label, bg, fg) = switch (c.s('result')) {
      'pass' => ('Pass', kMintBg, kPostedText),
      'warning' => ('Warning', kAmberBgH, kAmberText),
      _ => ('Fail', kRedBgH, kRedText),
    };
    return InvCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(c.s('name'), style: inter(18, 700)),
        if (c.s('detail').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(c.s('detail'), style: inter(14.5, 400, color: kMuted))),
        const SizedBox(height: 10),
        PoChip(label, bg: bg, fg: fg),
      ]),
    );
  }
}

class _CheckRow {
  _CheckRow(String name, this.result, String detail)
      : name = TextEditingController(text: name),
        detail = TextEditingController(text: detail);
  final TextEditingController name, detail;
  String result;
}

/// "Re-Audit": one row per check (name, pass / warning / fail, a short note). The previous round's names are filled in.
class _AuditSheet extends StatefulWidget {
  const _AuditSheet({required this.rows});
  final List<_CheckRow> rows;
  @override
  State<_AuditSheet> createState() => _AuditSheetState();
}

class _AuditSheetState extends State<_AuditSheet> {
  @override
  Widget build(BuildContext context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 12 + MediaQuery.viewInsetsOf(context).bottom),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Re-Audit', style: inter(18, 700)),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  for (final r in widget.rows) ...[
                    InvInput(controller: r.name, hint: 'Check name'),
                    const SizedBox(height: 6),
                    Row(children: [
                      for (final (id, label) in const [('pass', 'Pass'), ('warning', 'Warning'), ('fail', 'Fail')])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(label: Text(label), selected: r.result == id, onSelected: (_) => setState(() => r.result = id)),
                        ),
                    ]),
                    InvInput(controller: r.detail, hint: 'Note (optional)'),
                    const Divider(height: 24, color: kCardLine),
                  ],
                  InvSecondary('Add check', onPressed: () => setState(() => widget.rows.add(_CheckRow('', 'pass', '')))),
                ]),
              ),
              InvPrimary('Record audit', onPressed: () {
                final out = <Map<String, String>>[
                  for (final r in widget.rows)
                    if (r.name.text.trim().isNotEmpty) {'name': r.name.text.trim(), 'result': r.result, 'detail': r.detail.text.trim()},
                ];
                if (out.isEmpty) {
                  showToast(context, 'Name at least one check.');
                  return;
                }
                Navigator.pop(context, out);
              }),
            ]),
          ),
        ),
      );
}
