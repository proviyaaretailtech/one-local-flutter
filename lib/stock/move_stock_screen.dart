import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import 'stock_env.dart';
import 'stock_kit.dart';
import '../ui/i18n.dart';

/// Runs one stock save or action: a refusal from the server shows as a toast with its own words. Returns whether it worked.
Future<bool> stockJob(BuildContext context, Future<void> Function() job, {String? done}) async {
  try {
    await job();
    if (done != null && context.mounted) showToast(context, done);
    return true;
  } on PartnerApiException catch (e) {
    if (context.mounted) showToast(context, e.message);
  } catch (_) {
    if (context.mounted) showToast(context, 'Could not reach the server. Check your connection and try again.');
  }
  return false;
}

/// "Move stock" (Figma "Stock Transfer", made simple): move units of one product from one place to another in this store (backroom to
/// shelf), or send them to another store of the business. Within the store the store's total never changes.
class MoveStockScreen extends StatefulWidget {
  const MoveStockScreen({super.key, required this.env, this.itemId});
  final StockEnv env;
  final String? itemId;
  @override
  State<MoveStockScreen> createState() => _MoveStockScreenState();
}

class _MoveStockScreenState extends State<MoveStockScreen> {
  InventoryApi get api => widget.env.api;
  Facts? _options;
  Facts? _detail; // the chosen product's stock by place and batch
  String? _error;
  String _tab = 'here'; // here | other
  String? _fromBin, _toBin, _toStore, _lotId, _reason;
  num _qty = 1;
  bool _busy = false;
  String? _key; // one key per "Move stock" / "Save as draft" intent
  List<Facts> _open = const [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final o = await api.options();
      final open = await api.documents('transfer', statuses: const ['draft', 'in_transit'], limit: 20);
      final d = widget.itemId == null || _detail != null ? _detail : await api.stockDetail(widget.itemId!);
      if (!mounted) return;
      setState(() {
        _options = o;
        _open = open;
        _error = null;
        if (d != null) _adoptItem(d);
      });
    } on PartnerApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load. Check your connection.');
    }
  }

  void _adoptItem(Facts d) {
    _detail = d;
    final from = _fromBins(d);
    _fromBin = from.isEmpty ? null : from.reduce((a, b) => a.n('on_hand') >= b.n('on_hand') ? a : b).s('id');
    _lotId = null;
    _toBin = _toBins().where((b) => b.s('id') != _fromBin).map((b) => b.s('id')).firstOrNull;
    _qty = 1;
  }

  List<Facts> _fromBins(Facts d) => d.l('bins').where((b) => b.s('zone') != 'quarantine' && b.n('on_hand') > 0).toList();
  List<Facts> _toBins() => (_options?.l('bins') ?? const <Facts>[]).where((b) => b.s('zone') != 'quarantine').toList();
  List<Facts> _otherStores() {
    final here = _options?.m('location').s('id');
    return (_options?.l('locations') ?? const <Facts>[]).where((l) => l.s('id') != here).toList();
  }

  num _onHand(String? binId) => _detail?.l('bins').where((b) => b.s('id') == binId).firstOrNull?.n('on_hand') ?? 0;
  List<Facts> _lotsIn(String? binId) => _detail?.l('lots').where((l) => l.s('bin_id') == binId && l.n('on_hand') > 0).toList() ?? const [];
  num get _max {
    if (_lotId != null) return _lotsIn(_fromBin).where((l) => l.s('id') == _lotId).firstOrNull?.n('on_hand') ?? 0;
    return _onHand(_fromBin);
  }

  String _binName(String? id) => (_options?.l('bins') ?? const <Facts>[]).where((b) => b.s('id') == id).firstOrNull?.s('name') ?? '—';
  String _storeName(String? id) => _otherStores().where((l) => l.s('id') == id).firstOrNull?.s('name') ?? '—';
  String get _unit => _detail?.m('item').s('unit').isNotEmpty == true ? _detail!.m('item').s('unit') : 'units';

  Future<void> _pickProduct() async {
    final it = await pickItem(context, api);
    if (it == null || !mounted) return;
    setState(() => _busy = true);
    await stockJob(context, () async {
      final d = await api.stockDetail(it.s('id'));
      _adoptItem(d);
      _key = null;
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickFrom() async {
    final v = await pickOne<String>(context, 'Take from', [for (final b in _fromBins(_detail!)) (b.s('id'), b.s('name'), '${qty(b.n('on_hand'))} $_unit here')], current: _fromBin);
    if (v == null) return;
    setState(() {
      _fromBin = v;
      _lotId = null;
      if (_toBin == v) _toBin = _toBins().where((b) => b.s('id') != v).map((b) => b.s('id')).firstOrNull;
      _qty = _qty.clamp(1, _max == 0 ? 1 : _max);
      _key = null;
    });
  }

  Future<void> _pickTo() async {
    final v = await pickOne<String>(context, 'Put in', [
      for (final b in _toBins().where((b) => b.s('id') != _fromBin)) (b.s('id'), b.s('name'), '${qty(_onHand(b.s('id')))} $_unit here now'),
    ], current: _toBin);
    if (v != null) {
      setState(() {
        _toBin = v;
        _key = null;
      });
    }
  }

  Future<void> _pickStore() async {
    final v = await pickOne<String>(context, 'Send to', [for (final l in _otherStores()) (l.s('id'), l.s('name'), null)], current: _toStore);
    if (v != null) {
      setState(() {
        _toStore = v;
        _key = null;
      });
    }
  }

  Future<void> _pickLot() async {
    final lots = _lotsIn(_fromBin);
    final v = await pickOne<String>(context, 'Which batch?', [
      ('', 'Any batch (oldest first)', null),
      for (final l in lots) (l.s('id'), l.s('lot_code').isEmpty ? 'Batch without a code' : 'Batch ${l.s('lot_code')}', '${qty(l.n('on_hand'))} $_unit${l.t('expiry_date') == null ? '' : ' · expires ${dayMonth(l.t('expiry_date')!)}'}'),
    ], current: _lotId ?? '');
    if (v != null) {
      setState(() {
        _lotId = v.isEmpty ? null : v;
        _key = null;
      });
    }
  }

  Future<void> _pickReason() async {
    final list = _options?.m('reasons').ls('transfer') ?? const <String>[];
    final v = await pickOne<String>(context, 'Why are you moving it?', [for (final r in list) (r, r, null)], current: _reason);
    if (v != null) setState(() => _reason = v);
  }

  String? _problem() {
    if (_detail == null) return 'Choose a product first.';
    if (_fromBin == null) return 'There is no stock of this product to move.';
    if (_tab == 'here' && _toBin == null) return 'Choose where to put it.';
    if (_tab == 'other' && _toStore == null) return 'Choose the store to send it to.';
    if (_qty <= 0) return 'Choose how many to move.';
    if (_qty > _max) return 'Only ${qty(_max)} $_unit are there to move.';
    return null;
  }

  Future<void> _go({required bool now}) async {
    final p = _problem();
    if (p != null) return showToast(context, p);
    final item = _detail!.m('item');
    final other = _tab == 'other';
    final reason = _reason ?? (other ? 'Rebalance between stores' : 'Refill sales shelf');
    final lot = _lotsIn(_fromBin).where((l) => l.s('id') == _lotId).firstOrNull;
    setState(() => _busy = true);
    final moved = _qty;
    final ok = await stockJob(context, () async {
      _key ??= InventoryApi.newKey();
      var d = await api.createDraft('transfer',
          fields: {'title': 'Move ${item.s('name')}', 'reason': reason, if (other) 'to_location_id': _toStore},
          lines: [DraftLine(itemId: item.s('id'), itemName: item.s('name'), sku: item.s('sku'), fromBinId: _fromBin, toBinId: other ? null : _toBin, lotId: lot?.s('id'), lotCode: lot?.so('lot_code'), qty: _qty)],
          key: _key!);
      _key = null;
      if (now) d = await api.act(d.id, other ? 'dispatch' : 'post', version: d.version);
      if (!mounted) return;
      showToast(context, !now
          ? 'Saved as draft ${d.number}. Move it from the list below when ready.'
          : other
              ? '${qty(moved)} $_unit are on the way to ${_storeName(_toStore)}. They are added there when that store receives them.'
              : 'Moved ${qty(moved)} $_unit to ${_binName(_toBin)}.');
    });
    if (ok) {
      try {
        _adoptItem(await api.stockDetail(item.s('id')));
      } catch (_) {}
      await _init();
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _finishOpen(Facts row) async {
    setState(() => _busy = true);
    await stockJob(context, () async {
      final d = await api.document(row.s('id'));
      final action = d.can('post') ? 'post' : d.can('dispatch') ? 'dispatch' : d.can('receive') ? 'receive' : null;
      if (action == null) throw const PartnerApiException(409, 'This move cannot be finished from here.');
      await api.act(d.id, action, version: d.version);
    }, done: row.s('status') == 'in_transit' ? 'Received. The stock is added to this store.' : 'Stock moved.');
    await _init();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _cancelOpen(Facts row) async {
    setState(() => _busy = true);
    await stockJob(context, () async {
      final d = await api.document(row.s('id'));
      await api.act(d.id, 'cancel', version: d.version);
    }, done: 'Draft removed.');
    await _init();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => StockScaffold(
        env: widget.env,
        title: tr('Transfer stock'),
        line: tr('Move units from one place to another, like backroom to shelf. Moving inside the store never changes its total.'),
        onRefresh: _init,
        children: [
          InvLoad<Facts>(data: _options, error: _error, onRetry: _init, builder: (_) => _body()),
        ],
      );

  List<Widget> _body() {
    final d = _detail;
    final other = _tab == 'other';
    final stores = _otherStores();
    final lots = _lotsIn(_fromBin);
    final from = _onHand(_fromBin), to = _onHand(_toBin);
    return [
      InvChips(active: _tab, onTap: (t) => setState(() {
            _tab = t;
            _key = null;
          }), items: const [('here', 'Within this store', null), ('other', 'To another store', null)]),
      const SizedBox(height: 12),
      if (other && stores.isEmpty)
        StockEmpty(tr('Only one store'), 'Your business has one store. Add another store to send stock between them.', icon: LucideIcons.store)
      else ...[
        InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InvLabel(tr('Product')),
          InvPickBox(value: d?.m('item').s('name') ?? 'Choose a product', onTap: _busy ? null : _pickProduct),
          if (d != null) ...[
            if (_fromBins(d).isEmpty)
              InvNote(tr('There is no stock of this product in the store to move.'), color: kRedText)
            else ...[
              InvLabel(tr('Take from')),
              InvPickBox(value: '${_binName(_fromBin)} · ${qty(from)} $_unit', onTap: _pickFrom),
              if (lots.isNotEmpty) ...[
                InvLabel(tr('Batch')),
                InvPickBox(value: _lotId == null ? 'Any batch (oldest first)' : 'Batch ${lots.where((l) => l.s('id') == _lotId).firstOrNull?.s('lot_code') ?? ''}', onTap: _pickLot),
              ],
              InvLabel(other ? 'Send to' : 'Put in'),
              other
                  ? InvPickBox(value: _toStore == null ? 'Choose a store' : _storeName(_toStore), onTap: _pickStore)
                  : InvPickBox(value: _toBin == null ? 'Choose a place' : '${_binName(_toBin)} · ${qty(to)} $_unit now', onTap: _pickTo),
              InvLabel(tr('How many?')),
              InvStepper(value: _qty, min: 1, label: 'units to move', onChanged: (v) => setState(() {
                _qty = v > _max ? _max : v;
                _key = null;
              })),
              InvNote('Up to ${qty(_max)} $_unit can be moved from here.'),
              InvLabel(tr('Reason')),
              InvPickBox(value: _reason ?? (other ? 'Rebalance between stores' : 'Refill sales shelf'), onTap: _pickReason),
            ],
          ],
        ])),
        if (d != null && _fromBin != null && (other ? _toStore != null : _toBin != null))
          InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            InvCardHead(tr('After the move'), subtitle: tr('Before → after')),
            StockRow(_binName(_fromBin), '${qty(from)} − ${qty(_qty)} → ${qty(from - _qty)}'),
            if (!other) StockRow(_binName(_toBin), '${qty(to)} + ${qty(_qty)} → ${qty(to + _qty)}'),
            if (other) StockRow(tr('This store, ready to sell'), '${qty(d.n('available'))} → ${qty(d.n('available') - _qty)}'),
            if (other) StockRow(_storeName(_toStore), '+${qty(_qty)} when received'),
            if (!other) StockRow(tr('Store total'), '${qty(d.n('available'))} · no change', strong: true),
          ])),
        InvPrimary(other ? 'Send stock' : 'Move stock', busy: _busy, onPressed: () => _go(now: true)),
        const SizedBox(height: 10),
        InvSecondary(tr('Save as draft'), onPressed: _busy ? null : () => _go(now: false)),
      ],
      if (_open.isNotEmpty) ...[
        const SizedBox(height: 18),
        Text(tr('Drafts and stock on the way'), style: inter(16, 700)),
        const SizedBox(height: 8),
        for (final r in _open) _openRow(r),
      ],
      InvFootnote(at: _options?.t('snapshot_at')),
    ];
  }

  Widget _openRow(Facts r) {
    final onTheWay = r.s('status') == 'in_transit';
    return InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(r.s('first_item').isEmpty ? r.s('doc_no') : r.s('first_item'), style: inter(15, 700))),
        onTheWay ? const InvDotChip('On the way', bg: kAmberBgH, fg: kAmberText) : const InvDotChip('Draft', bg: kGreyBg, fg: kMuted),
      ]),
      const SizedBox(height: 4),
      Text([r.s('doc_no'), r.s('reason'), if (r.m('to_location').s('name').isNotEmpty) 'to ${r.m('to_location').s('name')}'].where((s) => s.isNotEmpty).join(' · '),
          style: inter(12.5, 400, color: kMuted)),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: InvSecondary(onTheWay ? 'Mark received' : 'Move now', onPressed: _busy ? null : () => _finishOpen(r))),
        if (!onTheWay) ...[const SizedBox(width: 10), Expanded(child: InvSecondary(tr('Remove'), color: kRedText, onPressed: _busy ? null : () => _cancelOpen(r)))],
      ]),
    ]));
  }
}
