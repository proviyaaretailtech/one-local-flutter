import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart';
import '../ui/theme.dart';
import '../shift/refund_blocked_screen.dart';
import 'sell_api.dart';
import 'sell_env.dart';
import 'sell_widgets.dart';
import '../ui/i18n.dart';

/// Order history (founder, 31 Oct 2026; was Transaction History): Bill → History lists the counter (offline) orders, the Online order
/// tab's Past orders lists the online ones. Today, Yesterday, Last week (7 days), Last month (30 days) or a chosen month; newest first,
/// 100 at a time. "View card" opens the lines and the sum; a manager can refund a counter bill (capped to the money taken; the database
/// refuses anyone else and any excess).
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.env, this.source = 'offline', this.onOpen, this.bottomNav, this.now});
  final SellEnv env;

  /// offline: counter bills; online: orders customers placed.
  final String source;

  /// Online: opens an order's own page (accept, pack, return…).
  final void Function(String orderId)? onOpen;

  /// The bottom bar of the section that opened it (the Bill's by default).
  final Widget? bottomNav;

  /// Tests set the clock.
  final DateTime Function()? now;
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  SellEnv get env => widget.env;
  bool get _online => widget.source == 'online';
  DateTime get _today {
    final n = (widget.now ?? DateTime.now)();
    return DateTime(n.year, n.month, n.day);
  }

  /// today | yesterday | week | month | pick (with [_month]).
  String _range = 'today';
  DateTime? _month;
  bool _more = false, _loadingMore = false;
  List<Receipt>? _rows;
  String? _error;
  final _open = <String>{};
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The first and last day of the chosen range.
  (DateTime, DateTime) get _span {
    final t = _today;
    return switch (_range) {
      'yesterday' => (t.subtract(const Duration(days: 1)), t.subtract(const Duration(days: 1))),
      'week' => (t.subtract(const Duration(days: 6)), t),
      'month' => (t.subtract(const Duration(days: 29)), t),
      'pick' => (_month!, DateTime(_month!.year, _month!.month + 1, 0)),
      _ => (t, t),
    };
  }

  String get _spanText {
    final (a, b) = _span;
    return a == b ? fmtDay(a) : '${a.day} ${_mon(a)}${a.year == b.year ? '' : ' ${a.year}'} – ${fmtDay(b)}';
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static String _mon(DateTime d) => _months[d.month - 1];
  static const _pageSize = 100;

  Future<void> _load() async {
    final mine = ++_seq;
    setState(() {
      _error = null;
      _rows = null;
      _more = false;
    });
    try {
      final (a, b) = _span;
      final all = await env.sell.receipts(from: isoDay(a), to: isoDay(b), source: widget.source, limit: _pageSize);
      if (!mounted || mine != _seq) return;
      setState(() {
        _rows = all;
        _more = all.length >= _pageSize;
      });
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() => _error = sellErrorText(e));
    }
  }

  /// The next 100, older than the last one shown.
  Future<void> _loadMore() async {
    final rows = _rows;
    if (rows == null || rows.isEmpty || _loadingMore) return;
    final mine = _seq;
    setState(() => _loadingMore = true);
    try {
      final (a, b) = _span;
      final next = await env.sell.receipts(from: isoDay(a), to: isoDay(b), source: widget.source, limit: _pageSize, before: rows.last.createdAt);
      if (!mounted || mine != _seq) return;
      setState(() {
        _rows = [...rows, ...next];
        _more = next.length >= _pageSize;
      });
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _pickRange(String r) {
    if (r == _range) return;
    setState(() => _range = r);
    _load();
  }

  /// Select month: the last 12 months, this one first.
  Future<void> _pickMonth() async {
    final t = _today;
    final months = [for (var i = 0; i < 12; i++) DateTime(t.year, t.month - i, 1)];
    final picked = await pickMonthSheet(context, months, current: _range == 'pick' ? _month : null);
    if (picked == null || !mounted) return;
    setState(() {
      _range = 'pick';
      _month = picked;
    });
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
            TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))], decoration: InputDecoration(prefixText: '₹ ', hintText: tr('Amount to refund'))),
            const SizedBox(height: 10),
            Wrap(spacing: 8, children: [for (final m in const ['cash', 'upi', 'card', 'other']) ChoiceChip(label: Text(m == 'upi' ? 'UPI' : '${m[0].toUpperCase()}${m.substring(1)}'), selected: method == m, selectedColor: const Color(0xFFA5FF2D), onSelected: (_) => set(() => method = m))]),
            const SizedBox(height: 10),
            Wrap(spacing: 8, children: [
              ChoiceChip(label: const Text('Goodwill / sale refund'), selected: kind == 'goodwill', selectedColor: const Color(0xFFA5FF2D), onSelected: (_) => set(() => kind = 'goodwill')),
              ChoiceChip(label: const Text('Cancellation (part-paid bill)'), selected: kind == 'cancel', selectedColor: const Color(0xFFA5FF2D), onSelected: (_) => set(() => kind = 'cancel')),
            ]),
            const SizedBox(height: 10),
            TextField(controller: reason, decoration: InputDecoration(hintText: tr('Reason'))),
            const SizedBox(height: 16),
            DarkCta(label: tr('Give refund'), onPressed: () => Navigator.pop(ctx, true)),
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
    if (await _blocked(r.id, value) || !mounted) return;
    try {
      await env.sell.refundOrder(r.id, amount: value, method: method, kind: kind, reason: reason.text.trim(), key: OrdersApi.newKey());
      if (mounted) showToast(context, '${rupees(value)} refunded on ${r.displayNo}.');
      await _load();
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e)); // e.g. only a manager, or more than was taken
    }
  }

  /// S6.5: asks the database whether this refund may be given and, if not, shows why. The refund call still decides; a check that
  /// cannot be read lets the refund call answer for itself.
  Future<bool> _blocked(String orderId, num amount) async {
    try {
      final c = await env.shift.refundCheck(orderId, purpose: 'refund', amount: amount);
      if (c.allowed || !mounted) return false;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => RefundBlockedScreen(check: c, initials: env.initials)));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        SellTopBar(title: tr(_online ? 'Past online orders' : 'Order history'), initials: env.initials),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 16), children: [
            SellTitle(_online ? 'Past online orders' : 'Order History', sub: env.storeLine),
            const SizedBox(height: 10),
            _ranges(),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: Text(_spanText, key: const ValueKey('hist-span'), style: inter(15, 700, color: kMuted))),
              if (rows != null)
                Text(
                  '${rows.length}${_more ? '+' : ''} ${rows.length == 1 ? 'order' : 'orders'} · ${rupees(rows.fold<num>(0, (s, r) => s + r.paid - r.refunded))}',
                  key: const ValueKey('hist-count'),
                  style: inter(14, 400, color: kMuted),
                ),
            ]),
            const SizedBox(height: 8),
            if (_error != null) StateCard(icon: LucideIcons.database, danger: true, title: tr('History could not load'), body: _error!, primary: 'Retry', onPrimary: _load),
            if (_error == null && rows == null) const SkeletonRows(),
            if (rows != null && rows.isEmpty)
              StateCard(icon: LucideIcons.history, title: tr('No orders'), body: tr(_online ? 'No online orders in this time.' : 'No counter orders in this time.')),
            if (rows != null) for (final r in rows) ...[_card(r), const SizedBox(height: 12)],
            if (_more)
              Center(
                child: TextButton(
                  key: const ValueKey('hist-more'),
                  onPressed: _loadingMore ? null : _loadMore,
                  child: Text(tr(_loadingMore ? 'Loading…' : 'Show older orders'), style: inter(14, 700, color: kLink)),
                ),
              ),
          ]),
        ),
        widget.bottomNav ?? PosBottomNav(active: 'bill', onTap: (id) => env.tab(context, id)),
      ]),
    );
  }

  /// Today · Yesterday · Last week · Last month · Select month.
  Widget _ranges() {
    Widget chip(String id, String label, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            key: ValueKey('hist-range-$id'),
            label: Text(label, style: inter(13, _range == id ? 700 : 500)),
            selected: _range == id,
            showCheckmark: false,
            selectedColor: const Color(0xFFA5FF2D),
            backgroundColor: Colors.white,
            side: BorderSide(color: _range == id ? const Color(0xFFA5FF2D) : kLine),
            onSelected: (_) => onTap(),
          ),
        );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        chip('today', tr('Today'), () => _pickRange('today')),
        chip('yesterday', tr('Yesterday'), () => _pickRange('yesterday')),
        chip('week', tr('Last week'), () => _pickRange('week')),
        chip('month', tr('Last month'), () => _pickRange('month')),
        chip('pick', _range == 'pick' && _month != null ? '${_mon(_month!)} ${_month!.year} ⌄' : '${tr('Select month')} ⌄', _pickMonth),
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
        Row(children: [
          DotChip(r.statusLabel, bg: r.paid > 0 ? kChipGreen : const Color(0xFFF1F2EE), fg: r.paid > 0 ? kGreenText : kMuted),
          const Spacer(),
          Text(r.paidAtLabel ?? r.when, style: inter(14, 400, color: kMuted)),
        ]),
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
          Row(children: [Text(tr('Total Amount'), style: inter(17, 800)), const Spacer(), Text(rupees(r.total), style: inter(22, 800, color: const Color(0xFF3DB800)))]),
          const SizedBox(height: 8),
          Row(children: [
            TextButton(onPressed: () {
              Clipboard.setData(ClipboardData(text: r.receiptText));
              showToast(context, 'Receipt text copied.');
            }, child: Text(tr('Copy receipt'))),
            const Spacer(),
            if (widget.onOpen != null) TextButton(key: ValueKey('hist-open-${r.id}'), onPressed: () => widget.onOpen!(r.id), child: Text(tr('Open order'))),
            if (!_online && r.paid > r.refunded) TextButton(onPressed: () => _refund(r), child: Text(tr('Refund this bill'))),
          ]),
        ],
      ]),
    );
  }
}

/// Select month: the months to pick from (newest first); answers the first day of the one picked.
Future<DateTime?> pickMonthSheet(BuildContext context, List<DateTime> months, {DateTime? current}) => showOrderSheet<DateTime>(
      context,
      title: tr('Select month'),
      body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final m in months)
          ListTile(
            key: ValueKey('hist-month-${m.year}-${m.month}'),
            contentPadding: EdgeInsets.zero,
            title: Text('${_HistoryScreenState._months[m.month - 1]} ${m.year}', style: inter(15, current == m ? 700 : 500)),
            trailing: current == m ? const Icon(LucideIcons.check, size: 18, color: kLink) : null,
            onTap: () => Navigator.pop(ctx, m),
          ),
      ]),
    );
