import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart' show rupees;
import '../ui/theme.dart';
import 'sell_api.dart';
import 'sell_env.dart';
import 'sell_widgets.dart';

/// Figma "Invoices & Receipts": the bills of a date range with search and status, several can be ticked and downloaded together.
/// Sales only: purchase invoices come from goods receiving (a later section). "Download" puts the receipt text on the clipboard;
/// a PDF or a printer needs a device plugin that is not in this build.
class ReceiptsScreen extends StatefulWidget {
  const ReceiptsScreen({super.key, required this.env});
  final SellEnv env;
  @override
  State<ReceiptsScreen> createState() => _ReceiptsScreenState();
}

class _ReceiptsScreenState extends State<ReceiptsScreen> {
  SellEnv get env => widget.env;
  final _q = TextEditingController();
  Timer? _debounce;
  String _kind = 'all', _status = 'all';
  late DateTimeRange _range = DateTimeRange(start: DateTime(DateTime.now().year, DateTime.now().month, 1), end: DateTime.now());
  List<Receipt>? _rows;
  String? _error;
  final _picked = <String>{};
  int _seq = 0;

  static const _statuses = [('all', 'All statuses'), ('paid', 'Paid'), ('part_paid', 'Partially paid'), ('unpaid', 'Unpaid'), ('refunded', 'Refunded'), ('cancelled', 'Cancelled')];

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
      final r = await env.sell.receipts(q: _q.text, status: _status, from: isoDay(_range.start), to: isoDay(_range.end));
      if (mounted && mine == _seq) setState(() => _rows = r);
    } catch (e) {
      if (mounted && mine == _seq) setState(() => _error = sellErrorText(e));
    }
  }

  String get _rangeLabel => _range.start.year == _range.end.year && _range.start.month == _range.end.month
      ? '${_range.start.day}–${fmtDay(_range.end)}'
      : '${fmtDay(_range.start)} – ${fmtDay(_range.end)}';

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime.now(), initialDateRange: _range);
    if (r != null) {
      _range = r;
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

  void _download(List<Receipt> list) {
    Clipboard.setData(ClipboardData(text: list.map((r) => r.receiptText).join('\n\n----------\n\n')));
    showToast(context, list.length == 1 ? 'Receipt text copied. PDF download is not in this release.' : '${list.length} receipts copied. PDF download is not in this release.');
  }

  @override
  Widget build(BuildContext context) {
    final rows = _kind == 'purchases' ? const <Receipt>[] : (_rows ?? const <Receipt>[]);
    final picked = rows.where((r) => _picked.contains(r.id)).toList();
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        SellTopBar(title: 'Invoices & receipts', initials: env.initials),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 12), children: [
            SellTitle('Invoices & Receipts', sub: env.storeLine),
            const SizedBox(height: 12),
            SellSearchField(controller: _q, hint: 'Invoice/receipt number, customer or supplier', onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 300), _load);
            }),
            const SizedBox(height: 10),
            FilterPills(options: const [('all', 'All'), ('sales', 'Sales'), ('purchases', 'Purchases')], selected: _kind, onSelect: (v) => setState(() => _kind = v)),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _drop(_rangeLabel, _pickRange)),
              const SizedBox(width: 10),
              Expanded(child: _drop(_statuses.firstWhere((s) => s.$1 == _status).$2, _pickStatus)),
            ]),
            const SizedBox(height: 12),
            if (_error != null) StateCard(icon: LucideIcons.database, danger: true, title: 'Receipts could not load', body: _error!, primary: 'Retry', onPrimary: _load),
            if (_error == null && _rows == null) const SkeletonRows(),
            if (_kind == 'purchases') const StateCard(icon: LucideIcons.truck, title: 'No purchase invoices here yet', body: 'Supplier invoices come from goods receiving, which is a later part of the app.'),
            if (_error == null && _rows != null && _kind != 'purchases' && rows.isEmpty) const StateCard(icon: LucideIcons.receiptText, title: 'No records', body: 'No bills match these filters.'),
            for (final r in rows) ...[_card(r), const SizedBox(height: 10)],
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${picked.length} selected · ${rows.length} records', style: inter(13, 700, color: kGreenText)),
            const SizedBox(height: 6),
            DarkCta(label: 'Download Selected (${picked.length})', onPressed: picked.isEmpty ? null : () => _download(picked)),
          ]),
        ),
        PosBottomNav(active: 'bill', onTap: (id) => env.tab(context, id)),
      ]),
    );
  }

  Widget _drop(String label, VoidCallback onTap) => Material(
        color: Colors.white,
        shape: StadiumBorder(side: BorderSide(color: const Color(0xFFDADCD5))),
        child: InkWell(customBorder: const StadiumBorder(), onTap: onTap, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13), child: Row(children: [Expanded(child: Text(label, style: inter(14, 600, color: kMuted), overflow: TextOverflow.ellipsis)), const Icon(LucideIcons.chevronDown, size: 16, color: kMuted)]))),
      );

  Widget _card(Receipt r) {
    final on = _picked.contains(r.id);
    final warn = r.status == 'part_paid' || r.status == 'unpaid';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22), border: Border.all(color: on ? const Color(0xFF3DB800) : const Color(0xFFECEDE8), width: on ? 1.5 : 1)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text.rich(TextSpan(children: [
            TextSpan(text: r.displayNo, style: inter(14, 800)),
            TextSpan(text: ' · ${r.balanceDue > 0 ? '${rupees(r.balanceDue)} balance due' : (r.paidAtLabel ?? r.statusLabel)}', style: inter(14, 400, color: kMuted)),
          ]))),
          Semantics(
            checked: on,
            label: 'Select ${r.displayNo}',
            child: InkWell(
              onTap: () => setState(() => on ? _picked.remove(r.id) : _picked.add(r.id)),
              child: Container(width: 26, height: 26, decoration: BoxDecoration(color: on ? const Color(0xFF8BE800) : Colors.white, borderRadius: BorderRadius.circular(7), border: Border.all(color: on ? const Color(0xFF3DB800) : const Color(0xFFDADCD5))), child: on ? const Icon(LucideIcons.check, size: 16) : null),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Row(children: [Expanded(child: Text(r.customer, style: inter(19, 800))), Text(rupees(r.total), style: inter(22, 800, color: const Color(0xFF3DB800)))]),
        Text('${r.when.split(' · ').first} · ${r.units} ${r.units == 1 ? 'item' : 'items'} · ${r.kindLabel}', style: inter(13, 400, color: kMuted)),
        const Divider(height: 20, color: kLine),
        Row(children: [
          DotChip(r.statusLabel, bg: warn ? kWarnBg : kChipGreen, fg: warn ? kWarnText : kGreenText),
          const Spacer(),
          InkWell(onTap: () => _download([r]), child: Row(children: [Text('Download', style: inter(15, 700)), const SizedBox(width: 6), const Icon(LucideIcons.download, size: 18)])),
        ]),
      ]),
    );
  }
}
