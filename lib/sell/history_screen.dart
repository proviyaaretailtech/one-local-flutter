import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart';
import '../ui/theme.dart';
import 'sell_api.dart';
import 'sell_env.dart';
import 'sell_widgets.dart';

/// Figma "Transaction History": the bills that took money on one day, newest first; "View card" opens the lines and the sum.
/// A manager can refund from an opened bill (capped to the money taken; the database refuses anyone else and any excess).
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.env, this.day});
  final SellEnv env;
  final DateTime? day;
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  SellEnv get env => widget.env;
  late DateTime _day = widget.day ?? DateTime.now();
  List<Receipt>? _rows;
  String? _error;
  final _open = <String>{};
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _isToday {
    final n = DateTime.now();
    return n.year == _day.year && n.month == _day.month && n.day == _day.day;
  }

  Future<void> _load() async {
    final mine = ++_seq;
    setState(() {
      _error = null;
      _rows = null;
    });
    try {
      final all = await env.sell.receipts(from: isoDay(_day), to: isoDay(_day));
      if (!mounted || mine != _seq) return;
      setState(() => _rows = all.where((r) => r.paid > 0).toList()); // bills that took money; held and cancelled bills are not transactions
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() => _error = sellErrorText(e));
    }
  }

  void _step(int days) {
    _day = _day.add(Duration(days: days));
    _load();
  }

  Future<void> _refund(Receipt r) async {
    final amount = TextEditingController(), reason = TextEditingController();
    var method = 'cash', kind = 'goodwill';
    final go = await showOrderSheet<bool>(
      context,
      title: 'Refund ${r.displayNo}',
      body: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Taken ${rupees(r.paid)}${r.refunded > 0 ? ' · already refunded ${rupees(r.refunded)}' : ''}. A refund can never be more than what is left.', style: inter(13, 400, color: kMuted)),
            const SizedBox(height: 12),
            TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))], decoration: const InputDecoration(prefixText: '₹ ', hintText: 'Amount to refund')),
            const SizedBox(height: 10),
            Wrap(spacing: 8, children: [for (final m in const ['cash', 'upi', 'card', 'other']) ChoiceChip(label: Text(m == 'upi' ? 'UPI' : '${m[0].toUpperCase()}${m.substring(1)}'), selected: method == m, selectedColor: const Color(0xFFA5FF2D), onSelected: (_) => set(() => method = m))]),
            const SizedBox(height: 10),
            Wrap(spacing: 8, children: [
              ChoiceChip(label: const Text('Goodwill / sale refund'), selected: kind == 'goodwill', selectedColor: const Color(0xFFA5FF2D), onSelected: (_) => set(() => kind = 'goodwill')),
              ChoiceChip(label: const Text('Cancellation (part-paid bill)'), selected: kind == 'cancel', selectedColor: const Color(0xFFA5FF2D), onSelected: (_) => set(() => kind = 'cancel')),
            ]),
            const SizedBox(height: 10),
            TextField(controller: reason, decoration: const InputDecoration(hintText: 'Reason')),
            const SizedBox(height: 16),
            DarkCta(label: 'Give refund', onPressed: () => Navigator.pop(ctx, true)),
          ]),
        ),
      ),
    );
    if (go != true || !mounted) return;
    final value = num.tryParse(amount.text.trim());
    if (value == null || value <= 0) {
      showToast(context, 'Enter the amount to refund.');
      return;
    }
    try {
      await env.sell.refundOrder(r.id, amount: value, method: method, kind: kind, reason: reason.text.trim(), key: OrdersApi.newKey());
      if (mounted) showToast(context, '${rupees(value)} refunded on ${r.displayNo}.');
      await _load();
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e)); // e.g. only a manager, or more than was taken
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        SellTopBar(onMenu: () => env.menu(context), initials: env.initials),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 16), children: [
            SellTitle('Transaction History', sub: env.storeLine),
            const SizedBox(height: 10),
            Row(children: [
              IconButton(tooltip: 'Previous day', onPressed: () => _step(-1), icon: const Icon(LucideIcons.chevronLeft, size: 18)),
              Text('${_isToday ? 'Today · ' : ''}${fmtDay(_day)}', style: inter(15, 700, color: kMuted)),
              IconButton(tooltip: 'Next day', onPressed: _isToday ? null : () => _step(1), icon: const Icon(LucideIcons.chevronRight, size: 18)),
              const Spacer(),
              Text(rows == null ? '' : '${rows.length} ${rows.length == 1 ? 'transaction' : 'transactions'}', style: inter(14, 400, color: kMuted)),
            ]),
            const SizedBox(height: 6),
            if (_error != null) StateCard(icon: LucideIcons.database, danger: true, title: 'History could not load', body: _error!, primary: 'Retry', onPrimary: _load),
            if (_error == null && rows == null) const SkeletonRows(),
            if (rows != null && rows.isEmpty) const StateCard(icon: LucideIcons.history, title: 'No transactions', body: 'No bill took money on this day.'),
            if (rows != null) for (final r in rows) ...[_card(r), const SizedBox(height: 12)],
          ]),
        ),
        PosBottomNav(active: 'bill', onTap: (id) => env.tab(context, id)),
      ]),
    );
  }

  Widget _card(Receipt r) {
    final open = _open.contains(r.id);
    return OrderCardBox(
      radius: 24,
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(r.customer, style: inter(19, 800)), Text('Order ${r.displayNo}', style: inter(14, 400, color: kMuted))])),
          Text(rupees(r.total), style: inter(24, 800, color: const Color(0xFF3DB800))),
        ]),
        const SizedBox(height: 10),
        Row(children: [DotChip(r.statusLabel == 'Paid' ? 'Paid' : r.statusLabel, bg: kChipGreen, fg: kGreenText), const Spacer(), Text(r.paidAtLabel ?? '', style: inter(14, 400, color: kMuted))]),
        const Divider(height: 22, color: kLine),
        Semantics(
          button: true,
          label: 'View card ${r.displayNo}',
          child: InkWell(
            onTap: () => setState(() => open ? _open.remove(r.id) : _open.add(r.id)),
            child: Row(children: [Text('View card', style: inter(17, 700)), const Spacer(), Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 18)]),
          ),
        ),
        if (open) ...[
          const Divider(height: 22, color: kLine),
          Row(children: [Kick('Ordered items'), const Spacer(), Text(r.counts, style: inter(12, 400, color: kMuted))]),
          const SizedBox(height: 6),
          for (final i in r.items) ItemLine(name: '${i['name']}', sub: '', amount: (i['amount'] as num?) ?? 0, qtyBadge: '${i['qty']}×'),
          const Divider(height: 18, color: kLine),
          KeyValue('Subtotal', rupees(r.subtotal), bold: false),
          if (r.taxAndCharges > 0) KeyValue('GST + service charge', rupees(r.taxAndCharges), bold: false),
          if (r.discount > 0) KeyValue('Discount${r.couponCode == null ? '' : ' · ${r.couponCode}'}', '−${rupees(r.discount)}', valueColor: kGreenText, keyColor: kGreenText, bold: false),
          if (r.refunded > 0) KeyValue('Refunded', '−${rupees(r.refunded)}', valueColor: kBadText, keyColor: kBadText, bold: false),
          const Divider(height: 18, color: kLine),
          Row(children: [Text('Total Amount', style: inter(17, 800)), const Spacer(), Text(rupees(r.total), style: inter(22, 800, color: const Color(0xFF3DB800)))]),
          const SizedBox(height: 8),
          Row(children: [
            TextButton(onPressed: () {
              Clipboard.setData(ClipboardData(text: r.receiptText));
              showToast(context, 'Receipt text copied.');
            }, child: const Text('Copy receipt')),
            const Spacer(),
            if (r.paid > r.refunded) TextButton(onPressed: () => _refund(r), child: const Text('Refund this bill')),
          ]),
        ],
      ]),
    );
  }
}
