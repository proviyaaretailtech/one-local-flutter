import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart';
import '../ui/theme.dart';
import '../shift/refund_blocked_screen.dart';
import 'sell_api.dart';
import 'sell_env.dart';
import 'sell_widgets.dart';

/// Figma "Returns & Refunds" (All, Customer Returns, Supplier Returns): a customer brings items back, a manager approves or rejects it,
/// and an approved return is refunded through the counter refund (manager only, capped to the money taken, idempotent). The refund value is
/// the items' share of the bill, worked out by the database. Supplier returns come with goods receiving and are not built here.
class ReturnsScreen extends StatefulWidget {
  const ReturnsScreen({super.key, required this.env});
  final SellEnv env;
  @override
  State<ReturnsScreen> createState() => _ReturnsScreenState();
}

class _ReturnsScreenState extends State<ReturnsScreen> {
  SellEnv get env => widget.env;
  final _q = TextEditingController();
  Timer? _debounce;
  String _kind = 'all', _status = 'all';
  List<ReturnRecord>? _rows;
  String? _error;
  final _open = <String>{};
  bool _busy = false;
  int _seq = 0;

  static const _statuses = [('all', 'All statuses'), ('requested', 'Requested'), ('approved', 'Approved'), ('rejected', 'Rejected'), ('refunded', 'Refunded')];
  static const _reasons = ['Damaged seal', 'Wrong item', 'Quality issue', 'Customer changed mind', 'Other'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final mine = ++_seq;
    setState(() => _error = null);
    try {
      final r = await env.sell.returns(status: _status, q: _q.text);
      if (mounted && mine == _seq) setState(() => _rows = r);
    } catch (e) {
      if (mounted && mine == _seq) setState(() => _error = sellErrorText(e));
    }
  }

  Future<void> _act(Future<void> Function() job, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await job();
      if (mounted) showToast(context, done);
      await _load();
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e)); // "only a manager can ...", "more than was taken" and the rest come from the database
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject(ReturnRecord r) async {
    final note = TextEditingController();
    final ok = await showOrderSheet<bool>(
      context,
      title: 'Reject ${r.returnNo}',
      body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: note, autofocus: true, decoration: const InputDecoration(hintText: 'Why is it rejected?')),
        const SizedBox(height: 14),
        DarkCta(label: 'Reject return', onPressed: () => Navigator.pop(ctx, true)),
      ]),
    );
    if (ok == true) await _act(() => env.sell.decideReturn(r.id, approve: false, note: note.text.trim()), '${r.returnNo} rejected.');
  }

  Future<void> _refund(ReturnRecord r) async {
    final method = await showOrderSheet<String>(
      context,
      title: 'Refund ${rupees(r.amount)}',
      body: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        Text('How does the money go back to ${r.customer}?', style: inter(13, 400, color: kMuted)),
        for (final (id, l) in const [('cash', 'Cash'), ('upi', 'UPI'), ('card', 'Card'), ('other', 'Other')]) ListTile(contentPadding: EdgeInsets.zero, title: Text(l, style: inter(15, 600)), onTap: () => Navigator.pop(ctx, id)),
      ]),
    );
    if (method != null) await _act(() => env.sell.refundReturn(r.id, method: method, key: OrdersApi.newKey()), '${rupees(r.amount)} refunded.');
  }

  Future<void> _newReturn() async {
    final done = await showOrderSheet<bool>(context, title: 'New customer return', body: (ctx) => _NewReturn(env: env));
    if (done == true) {
      if (mounted) showToast(context, 'Return recorded. A manager approves it next.');
      _load();
    }
  }

  Future<void> _pickStatus() async {
    final s = await showOrderSheet<String>(context, title: 'Status', body: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [for (final (id, l) in _statuses) ListTile(contentPadding: EdgeInsets.zero, title: Text(l, style: inter(15, id == _status ? 800 : 500)), onTap: () => Navigator.pop(ctx, id))]));
    if (s != null) {
      _status = s;
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _kind == 'supplier' ? const <ReturnRecord>[] : (_rows ?? const <ReturnRecord>[]);
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        SellTopBar(title: 'Returns & refunds', initials: env.initials),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 16), children: [
            Row(children: [
              Expanded(child: SellTitle('Returns & Refunds', sub: env.storeLine)),
              Material(color: kDark, shape: const StadiumBorder(), child: InkWell(customBorder: const StadiumBorder(), onTap: _newReturn, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), child: Text('+ Return', style: inter(14, 700, color: kLime))))),
            ]),
            const SizedBox(height: 12),
            SellSearchField(controller: _q, hint: 'Return ID, order/invoice, customer, supplier or product', onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 300), _load);
            }),
            const SizedBox(height: 10),
            FilterPills(options: const [('all', 'All'), ('customer', 'Customer Returns'), ('supplier', 'Supplier Returns')], selected: _kind, onSelect: (v) => setState(() => _kind = v)),
            const SizedBox(height: 10),
            Material(
              color: Colors.white,
              shape: const StadiumBorder(side: BorderSide(color: Color(0xFFDADCD5))),
              child: InkWell(customBorder: const StadiumBorder(), onTap: _pickStatus, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14), child: Row(children: [Expanded(child: Text(_statuses.firstWhere((s) => s.$1 == _status).$2, style: inter(14, 600, color: kMuted))), const Icon(LucideIcons.chevronDown, size: 16, color: kMuted)]))),
            ),
            const SizedBox(height: 12),
            if (_kind == 'supplier') const StateCard(icon: LucideIcons.truck, title: 'Supplier returns come later', body: 'Sending goods back to a supplier is part of goods receiving, a later section of the app.'),
            if (_kind != 'supplier' && _error != null) StateCard(icon: LucideIcons.database, danger: true, title: 'Returns could not load', body: _error!, primary: 'Retry', onPrimary: _load),
            if (_kind != 'supplier' && _error == null && _rows == null) const SkeletonRows(),
            if (_kind != 'supplier' && _rows != null && rows.isEmpty) const StateCard(icon: LucideIcons.undo2, title: 'No returns', body: 'No customer return matches these filters.'),
            for (final r in rows) ...[_card(r), const SizedBox(height: 12)],
          ]),
        ),
        PosBottomNav(active: 'bill', onTap: (id) => env.tab(context, id)),
      ]),
    );
  }

  Widget _card(ReturnRecord r) {
    final open = _open.contains(r.id);
    final (bg, fg) = switch (r.status) { 'requested' => (kWarnBg, kWarnText), 'rejected' => (kBadBg, kBadText), _ => (kChipGreen, kGreenText) };
    return OrderCardBox(
      radius: 24,
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Text('#${r.returnNo}', style: inter(16, 800)), const Spacer(), Text(r.date, style: inter(14, 400, color: kMuted))]),
        const SizedBox(height: 4),
        Row(children: [Expanded(child: Text(r.customer, style: inter(21, 800))), TagChip(r.statusLabel, bg: bg, fg: fg)]),
        Text('Customer order #${r.orderNo}', style: inter(15, 400, color: kMuted)),
        const SizedBox(height: 8),
        for (final l in r.lines) ItemLine(name: '${l['name']}', sub: '', amount: 0, qtyBadge: '${l['qty']}×'),
        const SizedBox(height: 6),
        Text('Reason: ${r.reason}', style: inter(16, 700)),
        if (r.note != null && r.note!.isNotEmpty) Text(r.note!, style: inter(14, 400, color: kMuted)),
        const Divider(height: 22, color: kLine),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Customer refund · TO customer', style: inter(16, 800)), Text(r.statusNote, style: inter(14, 400, color: kMuted))])),
          Text(rupees(r.amount), style: inter(26, 800, color: const Color(0xFF3DB800))),
        ]),
        const SizedBox(height: 8),
        Semantics(
          button: true,
          label: 'View details ${r.returnNo}',
          child: InkWell(onTap: () => setState(() => open ? _open.remove(r.id) : _open.add(r.id)), child: Row(children: [Text('View details', style: inter(17, 700)), const Spacer(), Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 18)])),
        ),
        if (open) ...[
          const Divider(height: 20, color: kLine),
          for (final l in r.lines) KeyValue('${l['qty']} × ${l['name']}${l['restock'] == false ? ' · damaged' : ''}', rupees((l['amount'] as num?) ?? 0), bold: false),
          KeyValue('Bill', '#${r.orderNo}', bold: false),
          const SizedBox(height: 8),
          if (r.status == 'requested') Row(children: [
            Expanded(child: LightCta(label: 'Reject', onPressed: _busy ? null : () => _reject(r))),
            const SizedBox(width: 10),
            Expanded(child: DarkCta(label: 'Approve', onPressed: _busy ? null : () => _act(() => env.sell.decideReturn(r.id, approve: true), '${r.returnNo} approved.'))),
          ]),
          if (r.status == 'approved') DarkCta(label: 'Issue refund ${rupees(r.amount)}', onPressed: _busy ? null : () => _refund(r)),
          if (r.status == 'requested' || r.status == 'approved') Padding(padding: const EdgeInsets.only(top: 6), child: Text('Approving and refunding is for managers.', style: inter(12, 400, color: kMuted))),
        ],
      ]),
    );
  }
}

/// Sheet: choose the bill, the items and quantities, the reason.
class _NewReturn extends StatefulWidget {
  const _NewReturn({required this.env});
  final SellEnv env;
  @override
  State<_NewReturn> createState() => _NewReturnState();
}

class _NewReturnState extends State<_NewReturn> {
  final _q = TextEditingController(), _note = TextEditingController();
  Timer? _debounce;
  List<Receipt>? _bills;
  Receipt? _bill;
  final _qty = <String, int>{};
  final _damaged = <String>{}; // items that come back broken: refunded, but not put back in stock
  String _reason = _ReturnsScreenState._reasons.first;
  String? _error;
  bool _busy = false;
  String? _key;

  @override
  void initState() {
    super.initState();
    _find();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    try {
      final r = await widget.env.sell.receipts(q: _q.text, status: 'paid');
      if (mounted) setState(() => _bills = r);
    } catch (e) {
      if (mounted) setState(() => _error = sellErrorText(e));
    }
  }

  /// S6.5: before items are chosen, ask the database whether this bill can take a return at all (return days, paid in full, already
  /// refunded, role). If not, show why instead of the item list. pos_return_create checks again.
  Future<void> _choose(Receipt b) async {
    try {
      final c = await widget.env.shift.refundCheck(b.id, purpose: 'return');
      if (!mounted) return;
      if (!c.allowed) {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => RefundBlockedScreen(check: c, initials: widget.env.initials)));
        return;
      }
    } catch (_) {/* the check could not be read: the return itself is still checked by the database */}
    if (mounted) setState(() => _bill = b);
  }

  Future<void> _submit() async {
    final lines = [for (final e in _qty.entries.where((e) => e.value > 0)) {'order_item_id': e.key, 'qty': e.value, if (_damaged.contains(e.key)) 'restock': false}];
    if (lines.isEmpty) {
      setState(() => _error = 'Choose the items being returned.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    _key ??= OrdersApi.newKey();
    try {
      await widget.env.sell.createReturn(orderId: _bill!.id, lines: lines, reason: _reason, note: _note.text.trim(), key: _key!);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = sellErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bill == null) {
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SellSearchField(controller: _q, hint: 'Bill number or customer', onChanged: (_) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 300), _find);
        }),
        const SizedBox(height: 8),
        if (_error != null) Text(_error!, style: inter(13, 400, color: kBadText)),
        if (_bills == null && _error == null) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(color: kGreenText))),
        if (_bills != null && _bills!.isEmpty) Padding(padding: const EdgeInsets.all(12), child: Text('No paid bill found.', style: inter(13, 400, color: kMuted))),
        if (_bills != null)
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
            child: ListView(shrinkWrap: true, children: [
              for (final b in _bills!) ListTile(contentPadding: EdgeInsets.zero, title: Text('${b.displayNo} · ${b.customer}', style: inter(14, 600)), subtitle: Text('${b.when} · ${b.counts}', style: inter(12, 400, color: kMuted)), trailing: Text(rupees(b.total), style: inter(14, 700)), onTap: () => _choose(b)),
            ]),
          ),
      ]);
    }
    return SingleChildScrollView(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${_bill!.displayNo} · ${_bill!.customer}', style: inter(15, 700)),
        const SizedBox(height: 8),
        for (final i in _bill!.items)
          Row(children: [
            Expanded(child: Text('${i['name']} (sold ${i['qty']})', style: inter(14, 500))),
            if ((_qty[i['order_item_id']] ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: FilterChip(label: const Text('Damaged'), selected: _damaged.contains(i['order_item_id']), onSelected: (v) => setState(() => v ? _damaged.add('${i['order_item_id']}') : _damaged.remove('${i['order_item_id']}'))),
              ),
            IconButton(tooltip: 'One less ${i['name']}', onPressed: (_qty[i['order_item_id']] ?? 0) > 0 ? () => setState(() => _qty[i['order_item_id']] = _qty[i['order_item_id']]! - 1) : null, icon: const Icon(LucideIcons.minus, size: 16)),
            Text('${_qty[i['order_item_id']] ?? 0}', style: inter(15, 700)),
            IconButton(tooltip: 'One more ${i['name']}', onPressed: (_qty[i['order_item_id']] ?? 0) < (i['qty'] as num) ? () => setState(() => _qty[i['order_item_id']] = (_qty[i['order_item_id']] ?? 0) + 1) : null, icon: const Icon(LucideIcons.plus, size: 16)),
          ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [for (final r in _ReturnsScreenState._reasons) ChoiceChip(label: Text(r), selected: _reason == r, selectedColor: const Color(0xFFA5FF2D), onSelected: (_) => setState(() => _reason = r))]),
        const SizedBox(height: 10),
        TextField(controller: _note, decoration: const InputDecoration(hintText: 'Note (optional)')),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: inter(13, 400, color: kBadText))),
        const SizedBox(height: 14),
        DarkCta(label: 'Record return', busy: _busy, onPressed: _submit),
        TextButton(onPressed: () => setState(() => _bill = null), child: const Text('Choose another bill')),
      ]),
    );
  }
}
