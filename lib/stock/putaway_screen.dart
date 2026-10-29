import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import 'move_stock_screen.dart' show stockJob;
import 'stock_env.dart';
import 'stock_kit.dart';
import '../ui/i18n.dart';

/// Figma "Putaway" (Receiving → Purchase → Putaway → Shelf labels): a received delivery's goods go into the places they are kept. A
/// posted receipt has put each product in one place (the shelf, unless receiving chose another); here the person splits it across
/// places ("Shelf A-01: 12, Backroom B-01: 10") and the app posts that as one stock move titled "Putaway" and the receipt number. The store's total
/// never changes: putaway only decides where the units sit.
class PutawayScreen extends StatefulWidget {
  const PutawayScreen({super.key, required this.env, this.receiptId});
  final StockEnv env;

  /// A receipt to start on (as from the receiving screen right after posting).
  final String? receiptId;
  @override
  State<PutawayScreen> createState() => _PutawayScreenState();
}

/// One destination of a product: a place and how many go there.
class _Slot {
  _Slot(this.binId, this.qty);
  String binId;
  num qty;
}

/// One product of the receipt: where it landed, how many were accepted, and where they go.
class _Line {
  _Line(this.facts, this.landed, this.accepted) : slots = [_Slot(landed, accepted)];
  final Facts facts;
  final String landed;
  final num accepted;
  final List<_Slot> slots;

  /// How many of this product each place holds now (the received units are already in [landed]).
  Map<String, num> here = const {};

  /// What a place holds after the putaway: the landed place keeps only its share; the others gain theirs.
  num after(_Slot s) => (here[s.binId] ?? 0) + (s.binId == landed ? s.qty - accepted : s.qty);
  num get assigned => slots.fold<num>(0, (n, s) => n + s.qty);
  String get name => facts.m('item').s('name');
  String get unit => facts.m('item').s('unit').isEmpty ? 'units' : facts.m('item').s('unit');
}

class _PutawayScreenState extends State<PutawayScreen> {
  InventoryApi get api => widget.env.api;
  List<Facts>? _receipts;
  Set<String> _done = const {}; // receipt numbers already put away
  List<Facts> _bins = const [];
  String? _error;
  String _tab = 'todo'; // todo | done
  InvDocument? _doc;
  List<_Line> _lines = const [];
  bool _busy = false;
  String? _key; // one key per "Assign locations" / "Save putaway plan" intent

  static String titleFor(String receiptNo) => 'Putaway $receiptNo';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final o = await api.options();
      final receipts = await api.documents('receipt', statuses: const ['posted'], limit: 20);
      final moves = await api.documents('transfer', statuses: const ['posted', 'draft'], q: 'Putaway', limit: 50);
      if (!mounted) return;
      setState(() {
        _bins = o.l('bins').where((b) => b.s('zone') != 'quarantine').toList();
        _receipts = receipts;
        _done = {for (final m in moves) if (m.s('title').startsWith('Putaway ')) m.s('title').substring(8)};
        _error = null;
      });
      final start = widget.receiptId;
      if (start != null && _doc == null) await _open(start);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _open(String id) async {
    setState(() => _busy = true);
    await stockJob(context, () async {
      final d = await api.document(id);
      final home = _bins.where((b) => b.s('zone') == 'shelf').map((b) => b.s('id')).firstOrNull ?? _bins.firstOrNull?.s('id') ?? '';
      final lines = [
        for (final l in d.lines)
          if (l.n('qty') - l.n('rejected_qty') > 0) _Line(l, l.mo('to_bin')?.s('id') ?? home, l.n('qty') - l.n('rejected_qty')),
      ];
      for (final l in lines) {
        try {
          final s = await api.stockDetail(l.facts.m('item').s('id'));
          l.here = {for (final b in s.l('bins')) b.s('id'): b.n('on_hand')};
        } catch (_) {} // the counts are a preview; the move still works without them
      }
      if (!mounted) return;
      setState(() {
        _doc = d;
        _lines = lines;
        _key = null;
      });
    });
    if (mounted) setState(() => _busy = false);
  }

  String _binName(String id) => _bins.where((b) => b.s('id') == id).map((b) => b.s('name')).firstOrNull ?? 'Shelf';

  Future<void> _pickBin(_Line line, _Slot slot) async {
    final taken = {for (final s in line.slots) if (s != slot) s.binId};
    final v = await pickOne<String>(context, 'Put ${line.name} in', [
      for (final b in _bins.where((b) => !taken.contains(b.s('id')))) (b.s('id'), b.s('name'), b.s('zone') == 'shelf' ? 'On display, ready to sell' : 'Kept aside'),
    ], current: slot.binId);
    if (v != null) {
      setState(() {
        slot.binId = v;
        _key = null;
      });
    }
  }

  void _addSlot(_Line line) {
    final free = _bins.where((b) => !line.slots.any((s) => s.binId == b.s('id'))).firstOrNull;
    if (free == null) return showToast(context, 'Every place is already in the list.');
    // the new place takes half of what is in the first one, so the total stays right
    final first = line.slots.first;
    final half = (first.qty / 2).floor();
    setState(() {
      first.qty -= half;
      line.slots.add(_Slot(free.s('id'), half));
      _key = null;
    });
  }

  String? _problem() {
    if (_lines.isEmpty) return 'Nothing on this delivery was accepted, so there is nothing to put away.';
    for (final l in _lines) {
      if (l.assigned != l.accepted) return '${l.name}: ${l.assigned > l.accepted ? 'more than the' : 'place all'} ${qty(l.accepted)} ${l.unit} received.';
    }
    return null;
  }

  /// Every unit leaving the place it landed in, as one move per product and place.
  List<DraftLine> _moves() => [
        for (final l in _lines)
          for (final s in l.slots)
            if (s.binId != l.landed && s.qty > 0)
              DraftLine(
                itemId: l.facts.m('item').s('id'),
                itemName: l.name,
                sku: l.facts.m('item').s('sku'),
                lotId: l.facts.mo('lot')?.s('id'),
                lotCode: l.facts.so('lot_code') ?? l.facts.mo('lot')?.so('lot_code'),
                fromBinId: l.landed,
                toBinId: s.binId,
                qty: s.qty,
              ),
      ];

  Future<void> _save({required bool now}) async {
    final p = _problem();
    if (p != null) return showToast(context, p);
    final d = _doc!;
    final moves = _moves();
    if (moves.isEmpty) {
      showToast(context, 'Everything stays where it was received. Nothing to move.');
      return;
    }
    setState(() => _busy = true);
    final ok = await stockJob(context, () async {
      _key ??= InventoryApi.newKey();
      var t = await api.createDraft('transfer', fields: {'title': titleFor(d.number), 'reason': 'Putaway after receiving'}, lines: moves, key: _key!);
      _key = null;
      if (now) t = await api.act(t.id, 'post', version: t.version);
    }, done: now ? 'Put away. ${d.number} is in its places now.' : 'Putaway plan saved as a draft. Assign it when the goods are in place.');
    if (ok && mounted) {
      setState(() {
        _doc = null;
        _lines = const [];
        if (now) _tab = 'done';
      });
      await _load();
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => StockScaffold(
        env: widget.env,
        title: tr('Putaway'),
        line: tr('Put received goods into the places you keep them.'),
        onRefresh: _load,
        children: [
          if (_error != null && _receipts == null)
            StockEmpty(tr('Could not load'), _error!, icon: LucideIcons.cloudOff, action: tr('Try again'), onAction: _load)
          else if (_receipts == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else if (_doc != null)
            ..._plan(_doc!)
          else
            ..._list(),
        ],
      );

  // ---------------------------------------------------------------- the deliveries
  List<Widget> _list() {
    final todo = _receipts!.where((r) => !_done.contains(r.s('doc_no'))).toList();
    final done = _receipts!.where((r) => _done.contains(r.s('doc_no'))).toList();
    final shown = _tab == 'todo' ? todo : done;
    return [
      InvChips(active: _tab, onTap: (t) => setState(() => _tab = t), items: [('todo', 'To put away', todo.length), ('done', 'Done', done.length)]),
      if (shown.isEmpty)
        StockEmpty(_tab == 'todo' ? 'Nothing to put away' : 'Nothing put away yet', _tab == 'todo' ? 'Deliveries show here once they are received.' : 'Deliveries you put away show here.',
            icon: LucideIcons.packageCheck)
      else
        for (final r in shown)
          InvCard(
            key: ValueKey('putaway-receipt-${r.s('id')}'),
            onTap: _busy ? null : () => _open(r.s('id')),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text([r.s('doc_no'), if (r.s('supplier_name').isNotEmpty) r.s('supplier_name')].join(' · '), style: inter(14.5, 700)),
                  Text(
                    [
                      if (r.s('first_item').isNotEmpty) r.s('first_item'),
                      '${qty(r.m('totals').n('received') - r.m('totals').n('rejected'))} accepted',
                      if (r.t('posted_at') != null) 'received ${dayMonth(r.t('posted_at')!)}',
                    ].join(' · '),
                    style: inter(12.5, 400, color: kMuted),
                  ),
                ]),
              ),
              _done.contains(r.s('doc_no')) ? const InvDotChip('Put away', bg: kMintBg, fg: kPostedText) : const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
            ]),
          ),
    ];
  }

  // ---------------------------------------------------------------- one delivery's plan
  List<Widget> _plan(InvDocument d) {
    final assigned = _lines.fold<num>(0, (n, l) => n + l.assigned), accepted = _lines.fold<num>(0, (n, l) => n + l.accepted);
    return [
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text([d.number, if (d.s('supplier_name').isNotEmpty) d.s('supplier_name')].join(' · '), style: inter(15.5, 700))),
          _done.contains(d.number) ? const InvDotChip('Put away', bg: kMintBg, fg: kPostedText) : const InvDotChip('To put away', bg: kAmberBgH, fg: kAmberText),
        ]),
        const SizedBox(height: 6),
        StockRow(tr('Accepted to put away'), '${qty(accepted)} units'),
        if (d.lines.any((l) => l.n('rejected_qty') > 0))
          StockRow(tr('Rejected (not put away)'), '${qty(d.lines.fold<num>(0, (n, l) => n + l.n('rejected_qty')))} units', color: kRedText),
        if (_lines.isEmpty) InvNote(tr('Nothing on this delivery was accepted.')),
      ])),
      for (final l in _lines) _lineCard(l),
      if (_lines.isNotEmpty) ...[
        Row(children: [
          Expanded(child: _count(qty(assigned), 'Assigned', kInk)),
          const SizedBox(width: 10),
          Expanded(child: _count(qty(accepted - assigned), 'Not placed', accepted == assigned ? kMuted : kRedText)),
        ]),
        const SizedBox(height: 10),
        InvNote(tr('The store\'s total stays the same: putaway only changes where the units sit.')),
        const SizedBox(height: 10),
        InvPrimary(tr('Assign locations'), key: const ValueKey('putaway-assign'), busy: _busy, onPressed: _busy ? null : () => _save(now: true)),
        const SizedBox(height: 10),
        InvSecondary(tr('Save putaway plan'), key: const ValueKey('putaway-save'), onPressed: _busy ? null : () => _save(now: false)),
      ],
      const SizedBox(height: 10),
      InvSecondary(tr('Back to deliveries'), onPressed: _busy ? null : () => setState(() => _doc = null)),
      if (_done.contains(d.number)) ...[
        const SizedBox(height: 10),
        InvSecondary(tr('Print shelf labels'), onPressed: () => widget.env.open(context, StockPage.shelfLabels)),
      ],
    ];
  }

  Widget _lineCard(_Line l) {
    final lot = l.facts.so('lot_code') ?? l.facts.mo('lot')?.so('lot_code');
    return InvCard(
      key: ValueKey('putaway-line-${l.facts.s('id')}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.name, style: inter(15, 700)),
        Text(['${qty(l.accepted)} ${l.unit} accepted', if (lot != null) 'batch $lot', 'received into ${_binName(l.landed)}'].join(' · '), style: inter(12.5, 400, color: kMuted)),
        const SizedBox(height: 8),
        for (final s in l.slots) ...[
          Row(children: [
            Expanded(child: InvPickBox(value: _binName(s.binId), semantic: 'Place for ${l.name}', onTap: () => _pickBin(l, s))),
            const SizedBox(width: 8),
            _Qty(
              value: s.qty,
              label: '${l.name} in ${_binName(s.binId)}',
              onChanged: (v) => setState(() {
                s.qty = v < 0 ? 0 : v;
                _key = null;
              }),
            ),
            if (l.slots.length > 1)
              IconButton(
                tooltip: tr('Remove this place'),
                onPressed: () => setState(() {
                  l.slots.remove(s);
                  l.slots.first.qty += s.qty;
                  _key = null;
                }),
                icon: const Icon(LucideIcons.x, size: 18, color: kMuted),
              ),
          ]),
          if (l.here.isNotEmpty) StockRow('${_binName(s.binId)}: now → after', '${qty(l.here[s.binId] ?? 0)} → ${qty(l.after(s))} ${l.unit}'),
          const SizedBox(height: 8),
        ],
        Row(children: [
          TextButton.icon(
            key: ValueKey('putaway-add-${l.facts.s('id')}'),
            onPressed: () => _addSlot(l),
            icon: const Icon(LucideIcons.plus, size: 15, color: kLink),
            label: Text(tr('Another place'), style: inter(13, 700, color: kLink)),
          ),
          const Spacer(),
          Text(l.assigned == l.accepted ? 'All placed' : '${qty(l.accepted - l.assigned)} left', style: inter(12.5, 700, color: l.assigned == l.accepted ? kPostedText : kRedText)),
        ]),
      ]),
    );
  }

  Widget _count(String n, String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: kCardLine)),
        child: Column(children: [
          Text(n, style: inter(20, 800, color: color)),
          Text(label, style: inter(12, 500, color: kMuted)),
        ]),
      );
}

/// A compact "– 12 +" that fits beside a place picker on a phone.
class _Qty extends StatelessWidget {
  const _Qty({required this.value, required this.label, required this.onChanged});
  final num value;
  final String label;
  final ValueChanged<num> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget step(String sign, String what, VoidCallback? tap) => Semantics(
          button: true,
          label: '$what $label',
          excludeSemantics: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: tap,
            child: SizedBox(width: 34, height: 44, child: Center(child: Text(sign, style: inter(17, 600, color: tap == null ? kMuted : kInk)))),
          ),
        );
    return Container(
      height: 46,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFD9DBD5))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        step('–', 'Decrease', value <= 0 ? null : () => onChanged(value - 1)),
        SizedBox(width: 40, child: Text(qty(value), textAlign: TextAlign.center, style: inter(15, 700))),
        step('+', 'Increase', () => onChanged(value + 1)),
      ]),
    );
  }
}
