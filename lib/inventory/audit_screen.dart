import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'adjustment_screen.dart';
import 'document_flow.dart';
import 'inventory_api.dart';
import 'inventory_dashboard.dart';
import 'inventory_widgets.dart';

/// Figma "Stock Audit": count the usable, unreserved units, review the variances, then draft an adjustment. Counts are evidence, never a balance.
class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key, required this.env, this.documentId});
  final InvEnv env;
  final String? documentId;
  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  InvEnv get env => widget.env;
  late final DocFlow _f = DocFlow(env, 'audit');
  final _counts = <String, TextEditingController>{}; // item id -> counted
  final _note = TextEditingController();
  List<DraftLine> _lines = [];
  Map<String, num> _system = {};
  String _tab = 'progress';
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _f.load(id: widget.documentId, open: const ['draft', 'review']);
    if (!mounted) return;
    _adopt();
    setState(() => _loaded = true);
  }

  void _adopt() {
    final d = _f.doc;
    if (d == null) return;
    _lines = d.lines.map(DraftLine.from).toList();
    _system = {for (final l in d.lines) l.m('item').s('id'): l.n('system_qty')};
    for (final l in _lines) {
      _counts.putIfAbsent(l.itemId, TextEditingController.new).text = l.countedQty == null ? '' : qty(l.countedQty).replaceAll(',', '');
    }
    _note.text = d.s('note');
    _tab = d.status == 'completed' ? 'completed' : 'progress';
  }

  bool get _editable => _f.doc == null || _f.doc!.status == 'draft';

  List<DraftLine> _collect() {
    for (final l in _lines) {
      l.countedQty = num.tryParse(_counts[l.itemId]?.text ?? '');
    }
    return _lines;
  }

  Future<bool> _save({String? action, String? done}) => _f.run(context, () => setState(() {}), () async {
        await _f.save(fields: {'title': 'Morning cycle count', 'note': _note.text.trim()}, lines: _collect());
        if (action != null) await _f.act(action);
        _adopt();
      }, done: done);

  Future<void> _addItem() async {
    final it = await pickItem(context, env.api);
    if (it == null) return;
    if (!mounted) return;
    if (_lines.any((l) => l.itemId == it.s('id'))) return showToast(context, 'That item is already in this count.');
    setState(() {
      _lines.add(DraftLine(itemId: it.s('id'), itemName: it.s('name'), sku: it.s('sku')));
      _counts[it.s('id')] = TextEditingController();
    });
    // the server takes the system figure when the item joins the count
    await _save();
  }

  @override
  Widget build(BuildContext context) => InvScaffold(env: env, onRefresh: _init, children: [
        const InvTitle('Stock Audit', subtitle: 'Count physical stock and review variances before posting'),
        InvChips(active: _tab, onTap: _setTab, items: const [('progress', 'In progress', null), ('completed', 'Completed', null)]),
        if (!_loaded && _f.error == null) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kInk))),
        if (_f.error != null) ...[InvCard(child: Text(_f.error!, style: inter(13.5, 400, color: kRedText))), InvSecondary('Try again', onPressed: _init)],
        if (_loaded && _f.error == null) ..._body(),
      ]);

  Future<void> _setTab(String id) async {
    final want = id == 'completed' ? ['completed'] : ['draft', 'review'];
    final row = _f.history.where((h) => want.contains(h.s('status'))).firstOrNull;
    if (row == null) {
      setState(() {
        _tab = id;
        _f.doc = null;
        _lines = [];
      });
      return;
    }
    if (!mounted) return;
    await _f.run(context, () => setState(() {}), () async {
      await _f.open(row.s('id'));
      _adopt();
    });
  }

  List<Widget> _body() {
    final d = _f.doc;
    if (d == null) {
      return docEmpty(_tab == 'completed' ? 'No completed counts yet.' : 'No count is in progress.',
          action: _tab == 'completed' ? null : 'Start Stock Audit', onAction: () async {
        _f.startNew();
        _lines = [];
        await _addItem();
      });
    }
    _collect();
    final counted = _lines.where((l) => l.countedQty != null).length;
    final sys = _lines.fold<num>(0, (a, l) => a + (_system[l.itemId] ?? 0));
    final cnt = _lines.fold<num>(0, (a, l) => a + (l.countedQty ?? 0));
    final net = _lines.where((l) => l.countedQty != null).fold<num>(0, (a, l) => a + (l.countedQty! - (_system[l.itemId] ?? 0)));
    final firstVariance = _lines.where((l) => l.countedQty != null && l.countedQty != _system[l.itemId]).firstOrNull;
    return [
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${d.number} · ${d.s('title').isEmpty ? 'Stock count' : d.s('title')}', style: inter(16.5, 700)),
              Text('${d.m('location').s('code')} • available-stock scope', style: inter(12.5, 400, color: kMuted)),
            ]),
          ),
          InvDotChip.doc('audit', d.status),
        ]),
        const SizedBox(height: 8),
        InvKV('System snapshot', d.t('created_at') == null ? '' : '${dayMonth(d.t('created_at')!)}, ${hm(d.t('created_at')!)}'),
        InvKV('Counter / approver', '${d.mo('created_by')?.s('name') ?? ''}${(_f.options?.l('approvers') ?? const <Facts>[]).isEmpty ? '' : ' / ${_f.options!.l('approvers').first.s('name')}'}'),
        InvKV('Count progress', '$counted of ${_lines.length} SKUs counted'),
        InvBar(fraction: _lines.isEmpty ? 0 : counted / _lines.length),
        const SizedBox(height: 4),
        InvNote('Count only unreserved usable units. Reserved, damaged and incoming staging are counted separately, not included here.'),
      ])),
      for (final l in _lines) _item(d, l),
      if (_editable) InvSecondary('Add Item to Count', onPressed: _addItem),
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const InvCardHead('Audit summary'),
        InvKV('System / counted usable', '${qty(sys)} / ${qty(cnt)} units'),
        InvKV('Net variance', '${signed(net)} units', valueColor: net == 0 ? kInk : kRedText),
        const InvLabel('Variance explanation'),
        _editable ? InvInput(controller: _note, hint: 'e.g. Shelf shortage · recount confirmed') : InvPickBox(value: d.s('note').isEmpty ? '–' : d.s('note'), chevron: false),
        InvNote('Count evidence is not a posted balance.${firstVariance == null ? '' : ' ${firstVariance.itemName.split(' ').first} remains ${qty(_system[firstVariance.itemId])} available until a linked adjustment is approved.'}'),
      ])),
      if (d.status == 'draft')
        InvPrimary('Send for Review', busy: _f.busy, onPressed: () {
          if (counted < _lines.length) return showToast(context, 'Count every item before review.');
          _save(action: 'submit', done: 'Count sent for review.');
        }),
      if (d.status == 'review' && d.can('complete'))
        InvSecondary('Complete Audit', onPressed: () => _f.run(context, () => setState(() {}), () async {
              await _f.act('complete');
              _adopt();
            }, done: 'Audit completed.')),
      if (d.status == 'review' && d.can('reopen'))
        InvSecondary('Reopen Count', onPressed: () => _f.run(context, () => setState(() {}), () async {
              await _f.act('reopen');
              _adopt();
            })),
      if (d.b('can_draft_adjustment'))
        InvPrimary('Create Adjustment Draft', busy: _f.busy, onPressed: () async {
          InvDocument? adj;
          final ok = await _f.run(context, () => setState(() {}), () async {
            adj = await env.api.adjustmentFromAudit(d.id);
          });
          if (ok && adj != null && mounted) {
            await env.push(context, AdjustmentScreen(env: env, documentId: adj!.id));
            if (mounted) _init();
          }
        })
      else if (d.mo('linked_from') == null && d.raw['linked_from'] is List && (d.raw['linked_from'] as List).isNotEmpty)
        InvSecondary('Open ${(d.raw['linked_from'] as List).first['doc_no']}', onPressed: () async {
          await env.push(context, AdjustmentScreen(env: env, documentId: (d.raw['linked_from'] as List).first['id'] as String));
          if (mounted) _init();
        }),
      if (_editable) InvSecondary('Save Audit', onPressed: () => _save(done: 'Count saved.')),
      InvFootnote(at: DateTime.now()),
    ];
  }

  Widget _item(InvDocument d, DraftLine l) {
    final sysQ = _system[l.itemId] ?? 0;
    final cnt = l.countedQty;
    final variance = cnt == null ? null : cnt - sysQ;
    final line = d.lines.where((x) => x.m('item').s('id') == l.itemId).firstOrNull;
    final bins = line?.l('bins').where((b) => b.s('zone') != 'quarantine').toList() ?? const <Facts>[];
    final matched = variance == 0;
    return InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.itemName, style: inter(16, 700)),
            Text(l.sku, style: inter(12.5, 400, color: kMuted)),
          ]),
        ),
        if (variance != null) matched ? const InvDotChip('Matched', bg: kGreenIconBg, fg: kPostedText) : InvDotChip('${signed(variance)} units', bg: kRedBgH, fg: kRedText),
      ]),
      const SizedBox(height: 6),
      if (matched && !_editable)
        InvKV('System / counted / variance', '${qty(sysQ)} / ${qty(cnt)} / 0 units')
      else ...[
        InvKV('System available', units(sysQ)),
        if (bins.isNotEmpty) InvKV('Location count · ${bins.map((b) => b.s('code')).join(' / ')}', '${bins.map((b) => qty(b.n('on_hand'))).join(' / ')} units'),
        const InvLabel('Counted available (units)'),
        _editable ? InvInput(controller: _counts[l.itemId]!, number: true, onChanged: (_) => setState(() {})) : InvPickBox(value: qty(cnt), chevron: false),
        const SizedBox(height: 4),
        InvKV('Variance = counted − system', variance == null ? '–' : '${qty(cnt)} − ${qty(sysQ)} = ${signed(variance)} units', valueColor: variance == null || variance == 0 ? kInk : kRedText),
        if (_editable) InvSecondary('Recount Item · ${l.itemName.split(' ').first}', onPressed: () => setState(() => _counts[l.itemId]!.clear())),
      ],
    ]));
  }
}
