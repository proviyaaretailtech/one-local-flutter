import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'document_flow.dart';
import 'inventory_api.dart';
import 'inventory_dashboard.dart';
import 'inventory_widgets.dart';

const _types = [
  ('decrease', 'Decrease available stock'),
  ('increase', 'Increase available stock'),
  ('quarantine', 'Move to quarantine (damaged)'),
  ('write_off', 'Write off quarantined stock'),
];

/// Figma "Adjustment": document a stock correction with evidence and approval. A draft changes nothing; only an approver posting it does.
class AdjustmentScreen extends StatefulWidget {
  const AdjustmentScreen({super.key, required this.env, this.documentId});
  final InvEnv env;
  final String? documentId;
  @override
  State<AdjustmentScreen> createState() => _AdjustmentScreenState();
}

class _AdjustmentScreenState extends State<AdjustmentScreen> {
  InvEnv get env => widget.env;
  late final DocFlow _f = DocFlow(env, 'adjustment');
  final _qty = TextEditingController();
  final _note = TextEditingController();
  DraftLine? _line;
  Facts? _stock; // the chosen item's bins and lots
  String _reason = '';
  String _tab = 'draft';
  bool _loaded = false;
  bool _banner = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _f.load(id: widget.documentId, open: const ['draft', 'awaiting_approval']);
    if (!mounted) return;
    await _adopt();
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _adopt() async {
    final d = _f.doc;
    if (d == null) return;
    _reason = d.s('reason');
    _note.text = d.s('note');
    _tab = switch (d.status) { 'awaiting_approval' => 'awaiting', 'posted' => 'posted', _ => 'draft' };
    _line = d.lines.isEmpty ? null : DraftLine.from(d.lines.first);
    _qty.text = _line?.qty == null ? '' : qty(_line!.qty).replaceAll(',', '');
    if (_line != null) {
      try {
        _stock = await env.api.stockDetail(_line!.itemId);
      } catch (_) {}
    }
  }

  bool get _editable => _f.doc == null || _f.doc!.status == 'draft';

  Future<void> _pickProduct() async {
    final it = await pickItem(context, env.api);
    if (it == null) return;
    final s = await env.api.stockDetail(it.s('id'));
    if (!mounted) return;
    setState(() {
      _stock = s;
      _line = DraftLine(itemId: it.s('id'), itemName: it.s('name'), sku: it.s('sku'), adjustType: _line?.adjustType ?? 'decrease');
    });
  }

  Future<void> _pickPlace() async {
    final s = _stock;
    if (s == null || _line == null) return showToast(context, 'Choose a product first.');
    final lots = s.l('lots');
    final bins = s.l('bins');
    final opts = <((String?, String?), String, String?)>[
      for (final l in lots) ((l.s('bin_id'), l.s('id')), '${l.s('bin_name')} / ${l.s('lot_code')}', '${units(l.n('on_hand'), s.m('item').s('unit'))}${l.no('days_left') == null ? '' : ' · ${l.n('days_left').toInt()} days'}'),
      for (final b in bins.where((b) => !lots.any((l) => l.s('bin_id') == b.s('id')))) ((b.s('id'), null), b.s('name'), units(b.n('on_hand'), s.m('item').s('unit'))),
    ];
    final v = await pickOne<(String?, String?)>(context, 'Location / lot', opts);
    if (v == null) return;
    setState(() {
      _line!.fromBinId = v.$1;
      _line!.lotId = v.$2;
    });
  }

  Future<void> _pickType() async {
    final v = await pickOne<String>(context, 'Adjustment type', [for (final (id, label) in _types) (id, label, null)], current: _line?.adjustType);
    if (v != null && _line != null) setState(() => _line!.adjustType = v);
  }

  Future<void> _pickReason() async {
    final reasons = _f.options?.m('reasons').ls('adjustment') ?? const <String>[];
    final v = await pickOne<String>(context, 'Reason', [for (final r in reasons) (r, r, null)], current: _reason);
    if (v != null) setState(() => _reason = v);
  }

  DraftLine? _built() {
    final l = _line;
    if (l == null) return null;
    l.qty = num.tryParse(_qty.text);
    if (l.adjustType == 'increase') {
      l.fromBinId = null;
    } else if (l.adjustType == 'quarantine' || l.adjustType == 'decrease') {
      // free stock only
    }
    return l;
  }

  Map<String, Object?> get _fields => {'reason': _reason, 'note': _note.text.trim(), if (_f.doc == null) 'title': _title()};

  String _title() => switch (_line?.adjustType) { 'increase' => 'Stock increase', 'quarantine' => 'Damaged stock', 'write_off' => 'Write-off', _ => 'Stock shortage' };

  Future<bool> _save({String? done, bool submit = false}) {
    final l = _built();
    if (l == null) {
      showToast(context, 'Choose a product first.');
      return Future.value(false);
    }
    return _f.run(context, () => setState(() {}), () async {
      await _f.save(fields: _fields, lines: [l]);
      if (submit) await _f.act('submit');
      await _adopt();
    }, done: done);
  }

  @override
  Widget build(BuildContext context) => InvScaffold(env: env, onRefresh: _init, children: [
        const InvTitle('Stock Adjustment', subtitle: 'Document a stock correction with evidence and approval'),
        InvChips(active: _tab, onTap: _setTab, items: const [('draft', 'Draft', null), ('awaiting', 'Awaiting approval', null), ('posted', 'Posted', null)]),
        if (!_loaded && _f.error == null) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kInk))),
        if (_f.error != null) ...[InvCard(child: Text(_f.error!, style: inter(13.5, 400, color: kRedText))), InvSecondary('Try again', onPressed: _init)],
        if (_loaded && _f.error == null) ..._body(),
      ]);

  Future<void> _setTab(String id) async {
    final status = switch (id) { 'awaiting' => 'awaiting_approval', 'posted' => 'posted', _ => 'draft' };
    final row = _f.history.where((h) => h.s('status') == status).firstOrNull;
    if (row == null) {
      setState(() {
        _tab = id;
        if (id == 'draft') {
          _f.startNew();
          _line = null;
          _stock = null;
          _qty.clear();
          _note.clear();
          _reason = '';
        } else {
          _f.doc = null;
        }
      });
      return;
    }
    await _f.run(context, () => setState(() {}), () async {
      await _f.open(row.s('id'));
      await _adopt();
    });
  }

  List<Widget> _body() {
    final d = _f.doc;
    final l = _line;
    final sys = _stock?.no('available') ?? d?.lines.firstOrNull?.mo('position')?.no('available');
    final q = num.tryParse(_qty.text) ?? l?.qty ?? 0;
    final sign = (l?.adjustType == 'increase') ? 1 : (l?.adjustType == 'decrease' || l?.adjustType == 'quarantine') ? -1 : 0;
    final correction = sign * q;
    final bin = l?.fromBinId == null ? null : _stock?.l('bins').where((b) => b.s('id') == l!.fromBinId).firstOrNull;
    final linked = d?.mo('linked');
    final me = _f.options?.m('me');
    final approvers = _f.options?.l('approvers') ?? const <Facts>[];
    if (d == null && l == null) {
      return docEmpty(_tab == 'draft' ? 'No adjustment draft is open.' : 'Nothing here yet.', action: _tab == 'draft' ? 'New adjustment' : null, onAction: _pickProduct);
    }
    return [
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${d?.number ?? 'New'} · ${d?.s('title').isNotEmpty == true ? d!.s('title') : _title()}', style: inter(16.5, 700)),
              if (linked != null) Text('Linked to ${linked.s('doc_no')}', style: inter(12.5, 400, color: kMuted)),
            ]),
          ),
          InvDotChip.doc('adjustment', d?.status ?? 'draft'),
        ]),
        const InvLabel('Product'),
        InvPickBox(value: l == null ? 'Choose a product' : '${l.itemName} · ${l.sku}', chevron: false, onTap: _editable ? _pickProduct : null, semantic: 'Product'),
        const InvLabel('Location / lot'),
        InvPickBox(
            value: l?.fromBinId == null && l?.adjustType != 'increase' ? 'Choose a place' : _place(l),
            onTap: _editable && l?.adjustType != 'increase' ? _pickPlace : null,
            semantic: 'Location and lot'),
        const InvLabel('Adjustment type'),
        InvPickBox(value: _types.firstWhere((t) => t.$1 == (l?.adjustType ?? 'decrease')).$2, onTap: _editable ? _pickType : null, semantic: 'Adjustment type'),
        const InvLabel('Quantity (units)'),
        _editable ? InvInput(controller: _qty, number: true, onChanged: (_) => setState(() {})) : InvPickBox(value: qty(q), chevron: false),
        const InvLabel('Reason'),
        InvPickBox(value: _reason.isEmpty ? 'Choose a reason' : _reason, onTap: _editable ? _pickReason : null, semantic: 'Reason'),
      ])),
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const InvCardHead('Proposed balance change'),
        InvTiles([
          InvStatTile(qty(sys), 'System · units'),
          InvStatTile(sign == 0 ? '0' : signed(correction), 'Correction · units'),
          InvStatTile(qty((sys ?? 0) + (l?.adjustType == 'write_off' ? 0 : correction)), 'Proposed · units'),
        ]),
        const SizedBox(height: 8),
        if (bin != null && sign != 0)
          InvKV('${bin.s('name')} available', '${qty(bin.n('on_hand'))} ${sign < 0 ? '−' : '+'} ${qty(q)} = ${qty(bin.n('on_hand') + correction)} units'),
        for (final b in (_stock?.l('bins') ?? const <Facts>[]).where((b) => b.s('zone') != 'quarantine' && b.s('id') != l?.fromBinId))
          InvKV('${b.s('name')} available', '${qty(b.n('on_hand'))} • unchanged'),
        if (_stock != null) InvKV('Reserved / damaged', '${qty(_stock!.n('reserved'))} / ${qty(_stock!.n('damaged'))} • unchanged'),
        InvNote(switch (l?.adjustType) {
          'quarantine' => 'This moves free stock into quarantine. It is held apart and no longer sellable.',
          'write_off' => 'This removes quarantined stock for good.',
          'increase' => 'This is a surplus correction. No stock has been added yet.',
          _ => 'This is a shortage correction, not a damage quarantine or write-off. No stock has been removed yet.',
        }),
      ])),
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const InvCardHead('Evidence and approval'),
        if (linked != null) InvKV('Recount evidence', '${linked.s('doc_no')} · counted'),
        const InvLabel('Operator note'),
        _editable ? InvInput(controller: _note, hint: 'What happened?') : InvPickBox(value: _note.text.isEmpty ? '–' : _note.text, chevron: false),
        const SizedBox(height: 4),
        InvKV('Requested by', d?.mo('created_by')?.s('name') ?? me?.s('name') ?? ''),
        InvKV('Required approver', approvers.isEmpty ? 'Owner' : approvers.first.s('name') + ((approvers.first.s('role')) == 'org_owner' ? ' · Owner' : '')),
        if (d != null && d.mo('approved_by') != null) InvKV('Approved by', d.m('approved_by').s('name')),
      ])),
      if (_banner && (d == null || d.status != 'posted'))
        InvInfoBanner(
          title: 'Current availability stays ${qty(sys)}',
          body: 'Only approval posts a ${signed(correction)} movement${sign == 0 ? '' : ' and sets available stock to ${qty((sys ?? 0) + correction)}'}. Other draft operations are not combined.',
          onClose: () => setState(() => _banner = false),
        ),
      if (d != null && d.status == 'awaiting_approval') ...[
        if (d.can('approve'))
          InvPrimary('Approve and Post', busy: _f.busy, onPressed: () => _f.run(context, () => setState(() {}), () async {
                await _f.act('approve');
                await _adopt();
              }, done: 'Adjustment posted.')),
        if (d.can('reject'))
          InvSecondary('Send Back', onPressed: () async {
            final n = await askNote(context, 'Send back to draft', hint: 'Why?', action: 'Send back');
            if (n == null || !mounted) return;
            await _f.run(context, () => setState(() {}), () async {
              await _f.act('reject', note: n);
              await _adopt();
            });
          }),
        if (!d.can('approve')) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Waiting for ${approvers.isEmpty ? 'an approver' : approvers.first.s('name')} to approve.', style: inter(13.5, 400, color: kMuted))),
      ],
      if (_editable) ...[
        InvPrimary('Submit for Approval', busy: _f.busy, onPressed: () => _save(submit: true, done: 'Submitted for approval. Stock has not changed yet.')),
        InvSecondary('Save Draft', onPressed: () => _save(done: 'Draft saved.')),
      ],
      InvFootnote(at: DateTime.now()),
    ];
  }

  String _place(DraftLine? l) {
    if (l == null) return '';
    final s = _stock;
    final bin = s?.l('bins').where((b) => b.s('id') == l.fromBinId).firstOrNull;
    final lot = s?.l('lots').where((x) => x.s('id') == l.lotId).firstOrNull;
    if (l.adjustType == 'increase') return 'Main shelf';
    return '${bin?.s('name') ?? l.fromBinId ?? ''}${lot == null ? '' : ' / ${lot.s('lot_code')}'}';
  }
}
