import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'document_flow.dart';
import 'inventory_api.dart';
import 'inventory_dashboard.dart';
import 'inventory_widgets.dart';

/// Figma "Transfer": move stock between places in a store (internal) or to another store (inter-facility), without changing the store's total
/// for an internal move. Draft → post; inter-facility: dispatch, then the other store receives.
class TransferScreen extends StatefulWidget {
  const TransferScreen({super.key, required this.env, this.documentId, this.startItem});
  final InvEnv env;
  final String? documentId;

  /// Item facts (id, name, sku) to start a new transfer with (from Stock Detail "Transfer Stock").
  final Facts? startItem;
  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  InvEnv get env => widget.env;
  late final DocFlow _f = DocFlow(env, 'transfer');
  final _qty = TextEditingController();
  DraftLine? _line;
  Facts? _stock;
  String _kind = 'internal';
  String? _toLocationId, _reason, _operatorId;
  bool _loaded = false;
  bool _banner = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _f.load(id: widget.documentId, open: const ['draft', 'in_transit']);
    if (!mounted) return;
    if (_f.doc != null) {
      await _adopt();
    } else if (widget.startItem != null && _line == null) {
      await _setItem(widget.startItem!);
    }
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _adopt() async {
    final d = _f.doc;
    if (d == null) return;
    _reason = d.s('reason').isEmpty ? null : d.s('reason');
    _toLocationId = d.mo('to_location')?.s('id');
    _kind = _toLocationId == null ? 'internal' : 'inter';
    _operatorId = d.mo('operator')?.s('id');
    _line = d.lines.isEmpty ? null : DraftLine.from(d.lines.first);
    _qty.text = _line?.qty == null ? '' : qty(_line!.qty).replaceAll(',', '');
    if (_line != null) {
      try {
        _stock = await env.api.stockDetail(_line!.itemId);
      } catch (_) {}
    }
  }

  bool get _editable => _f.doc == null || _f.doc!.status == 'draft';

  Future<void> _setItem(Facts item) async {
    final id = item.has('item') ? item.m('item').s('id') : item.s('id');
    final s = await env.api.stockDetail(id);
    final bins = s.l('bins').where((b) => b.s('zone') != 'quarantine').toList();
    final from = bins.where((b) => b.s('zone') == 'backroom' && b.n('on_hand') > 0).firstOrNull ?? bins.where((b) => b.n('on_hand') > 0).firstOrNull;
    final to = bins.where((b) => b.s('zone') == 'shelf' && b.s('id') != from?.s('id')).firstOrNull;
    if (!mounted) return;
    setState(() {
      _stock = s;
      _line = DraftLine(itemId: id, itemName: s.m('item').s('name'), sku: s.m('item').s('sku'), fromBinId: from?.s('id'), toBinId: to?.s('id'));
    });
  }

  List<((String, String?), String, String?)> _binOptions({required bool from}) {
    final s = _stock;
    final opts = _f.options;
    if (s == null) return const [];
    final all = (opts?.l('bins') ?? const <Facts>[]).where((b) => b.s('zone') != 'quarantine');
    return [
      for (final b in all)
        ((b.s('id'), null), b.s('name'), '${units(s.l('bins').where((x) => x.s('id') == b.s('id')).firstOrNull?.n('on_hand') ?? 0, s.m('item').s('unit'))} available')
    ];
  }

  Future<void> _pickBin(bool from) async {
    if (_line == null) return showToast(context, 'Choose a product first.');
    final v = await pickOne<(String, String?)>(context, from ? 'From location' : 'To location', _binOptions(from: from));
    if (v == null) return;
    setState(() => from ? _line!.fromBinId = v.$1 : _line!.toBinId = v.$1);
  }

  String _binName(String? id) => (_f.options?.l('bins') ?? const <Facts>[]).where((b) => b.s('id') == id).firstOrNull?.s('name') ?? 'Choose a place';

  num _onHand(String? binId) => _stock?.l('bins').where((b) => b.s('id') == binId).firstOrNull?.n('on_hand') ?? 0;

  DraftLine? _built() {
    final l = _line;
    if (l == null) return null;
    l.qty = num.tryParse(_qty.text);
    if (_kind == 'inter') l.toBinId = null;
    return l;
  }

  Map<String, Object?> get _fields => {
        'title': 'Shelf replenishment',
        'reason': _reason ?? '',
        'to_location_id': _kind == 'inter' ? _toLocationId : null,
        'operator_id': _operatorId,
      };

  Future<bool> _go({String? action, String? done}) {
    final l = _built();
    if (l == null) {
      showToast(context, 'Choose a product first.');
      return Future.value(false);
    }
    return _f.run(context, () => setState(() {}), () async {
      await _f.save(fields: _fields, lines: [l]);
      if (action != null) await _f.act(action);
      await _adopt();
    }, done: done);
  }

  @override
  Widget build(BuildContext context) => InvScaffold(env: env, onRefresh: _init, children: [
        const InvTitle('Transfer', subtitle: "Move stock between locations without changing store totals"),
        InvChips(active: _kind, onTap: (id) => setState(() => _kind = id), items: const [('internal', 'Internal transfer', null), ('inter', 'Inter-facility', null)]),
        if (!_loaded && _f.error == null) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kInk))),
        if (_f.error != null) ...[InvCard(child: Text(_f.error!, style: inter(13.5, 400, color: kRedText))), InvSecondary('Try again', onPressed: _init)],
        if (_loaded && _f.error == null) ..._body(),
      ]);

  List<Widget> _body() {
    final d = _f.doc;
    final l = _line;
    if (d == null && l == null) {
      return docEmpty('No transfer is open.', action: 'New transfer', onAction: () async {
        final it = await pickItem(context, env.api);
        if (it != null) await _setItem(it);
      });
    }
    final unit = _stock?.m('item').s('unit') ?? 'unit';
    final q = num.tryParse(_qty.text) ?? l?.qty ?? 0;
    final fromId = l?.fromBinId, toId = l?.toBinId;
    final cross = _kind == 'inter';
    final locations = (_f.options?.l('locations') ?? const <Facts>[]).where((x) => x.s('id') != _f.options?.m('location').s('id')).toList();
    final staff = _f.options?.l('staff') ?? const <Facts>[];
    final toCap = (_f.options?.l('bins') ?? const <Facts>[]).where((b) => b.s('id') == toId).firstOrNull?.no('capacity_units');
    return [
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${d?.number ?? 'New'} · ${d?.s('title').isNotEmpty == true ? d!.s('title') : 'Shelf replenishment'}', style: inter(16.5, 700)),
              Text('${_f.options?.m('location').s('name') ?? ''} • ${d == null ? 'proposed movement' : 'movement'}', style: inter(12.5, 400, color: kMuted)),
            ]),
          ),
          InvDotChip.doc('transfer', d?.status ?? 'draft'),
        ]),
        const InvLabel('Product / lot'),
        InvPickBox(
            value: l == null ? 'Choose a product' : '${l.itemName}${l.sku.isEmpty ? '' : ' · ${l.sku}'}',
            onTap: _editable ? () async {
              final it = await pickItem(context, env.api);
              if (it != null) await _setItem(it);
            } : null,
            semantic: 'Product'),
        const InvLabel('From location'),
        InvPickBox(value: fromId == null ? 'Choose a place' : '${_binName(fromId)} · ${qty(_onHand(fromId))} available', onTap: _editable ? () => _pickBin(true) : null, semantic: 'From location'),
        const InvLabel('To location'),
        if (cross)
          InvPickBox(
              value: locations.where((x) => x.s('id') == _toLocationId).firstOrNull?.s('name') ?? 'Choose a store',
              onTap: _editable ? () async {
                final v = await pickOne<String>(context, 'To store', [for (final x in locations) (x.s('id'), x.s('name'), x.s('code'))], current: _toLocationId);
                if (v != null) setState(() => _toLocationId = v);
              } : null,
              semantic: 'To store')
        else
          InvPickBox(value: toId == null ? 'Choose a place' : '${_binName(toId)} · ${qty(_onHand(toId))} available', onTap: _editable ? () => _pickBin(false) : null, semantic: 'To location'),
        const InvLabel('Transfer quantity (units)'),
        _editable ? InvInput(controller: _qty, number: true, onChanged: (_) => setState(() {})) : InvPickBox(value: qty(q), chevron: false),
        if (!cross && toCap != null) ...[
          const SizedBox(height: 8),
          InvKV('Destination capacity', '${qty(toCap)} bottle positions'),
        ],
      ])),
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const InvCardHead('Balance preview', subtitle: 'Before → after if confirmed'),
        if (fromId != null) InvKV(_binName(fromId), '${qty(_onHand(fromId))} − ${qty(q)} = ${qty(_onHand(fromId) - q)} available'),
        if (!cross && toId != null) InvKV(_binName(toId), '${qty(_onHand(toId))} + ${qty(q)} = ${qty(_onHand(toId) + q)} available'),
        InvKV(cross ? 'This store' : 'Store-wide available', cross ? '${qty(_stock?.n('available'))} → ${qty((_stock?.n('available') ?? 0) - q)} units' : '${qty(_stock?.n('available'))} → ${units(_stock?.n('available'), unit)}'),
        if (_stock != null) InvKV('Reserved / damaged', '${qty(_stock!.n('reserved'))} / ${qty(_stock!.n('damaged'))} • unchanged'),
        InvNote(cross ? 'The stock leaves this store when dispatched and joins the other store when it is received there. The batch keeps its expiry date.' :
            'Move free stock only. The batch keeps its expiry date and traceability; no receipt or sale is created.'),
      ])),
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const InvCardHead('Handling checks'),
        _check('Quantity fits ${cross ? 'what is in the place' : 'destination capacity'}', toCap == null || q <= toCap || cross),
        _check((cross || fromId == null) ? 'Storage' : 'Ambient → Ambient · compatible', true),
        _check('No reserved units selected', true),
        const InvLabel('Reason'),
        InvPickBox(
            value: _reason ?? 'Choose a reason',
            onTap: _editable ? () async {
              final r = _f.options?.m('reasons').ls('transfer') ?? const <String>[];
              final v = await pickOne<String>(context, 'Reason', [for (final x in r) (x, x, null)], current: _reason);
              if (v != null) setState(() => _reason = v);
            } : null,
            semantic: 'Reason'),
        const InvLabel('Assigned operator'),
        InvPickBox(
            value: staff.where((s) => s.s('id') == _operatorId).firstOrNull?.s('name') ?? 'Choose an operator',
            onTap: _editable ? () async {
              final v = await pickOne<String>(context, 'Assigned operator', [for (final s in staff) (s.s('id'), s.s('name'), null)], current: _operatorId);
              if (v != null) setState(() => _operatorId = v);
            } : null,
            semantic: 'Assigned operator'),
      ])),
      if (_banner && (d == null || d.status == 'draft'))
        InvInfoBanner(title: 'Independent draft', body: "This transfer uses today's snapshot of ${qty(_stock?.n('available'))} units, not any proposed receipt.", onClose: () => setState(() => _banner = false)),
      if (d != null && d.can('receive')) InvPrimary('Receive Transfer', busy: _f.busy, onPressed: () => _f.run(context, () => setState(() {}), () async {
            await _f.act('receive');
            await _adopt();
          }, done: 'Transfer received.')),
      if (_editable) ...[
        InvPrimary(cross ? 'Dispatch Transfer' : 'Review Transfer', busy: _f.busy, onPressed: () => _confirm(cross, q)),
        InvSecondary('Save Draft', onPressed: () => _go(done: 'Draft saved.')),
      ],
      InvFootnote(at: DateTime.now()),
    ];
  }

  Future<void> _confirm(bool cross, num q) async {
    final l = _built();
    if (l == null) return showToast(context, 'Choose a product first.');
    if (cross && _toLocationId == null) return showToast(context, 'Choose the store to send to.');
    if (!cross && (l.toBinId == null || l.toBinId == l.fromBinId)) return showToast(context, 'Choose a different place to move it to.');
    if ((l.qty ?? 0) <= 0) return showToast(context, 'Enter a quantity above zero.');
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(cross ? 'Dispatch transfer?' : 'Post transfer?', style: inter(18, 700)),
            const SizedBox(height: 8),
            Text('${l.itemName}: ${qty(q)} from ${_binName(l.fromBinId)}${cross ? '' : ' to ${_binName(l.toBinId)}'}. This changes posted stock.', style: inter(14, 400, color: kMuted, height: 1.45)),
            const SizedBox(height: 14),
            InvPrimary(cross ? 'Dispatch' : 'Post transfer', onPressed: () => Navigator.pop(ctx, true)),
            InvSecondary('Cancel', onPressed: () => Navigator.pop(ctx, false)),
          ]),
        ),
      ),
    );
    if (ok == true) await _go(action: cross ? 'dispatch' : 'post', done: cross ? 'Dispatched. The other store can now receive it.' : 'Transfer posted.');
  }

  Widget _check(String text, bool ok) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(ok ? Icons.check : Icons.close, size: 16, color: ok ? kInk : kRedText),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: inter(14, 400, color: ok ? kInk : kRedText))),
        ]),
      );
}
