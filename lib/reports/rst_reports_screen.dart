import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/live_sync.dart';
import '../inventory/inventory_api.dart' show Facts;
import '../money/money_style.dart' show kMoneyLime, kMoneyDeep;
import '../money/store_money.dart' show rs, dayMonth;
import '../outlets/outlet_scope.dart';
import '../stock/closing_stock_screen.dart' show saveSpreadsheet;
import '../tables/bill_api.dart';
import '../tables/table_widgets.dart' show sayError;
import '../ui/app_header.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import '../ui/xlsx.dart';
import 'rst_reports_api.dart';

/// Restaurant reports V1 (founder, 30 Oct 2026, from the "Mini Restaurant Reporting Blueprint"): Sales (Summary, Items, Categories),
/// Payments (Payment mode, Cashier & day close), Audit (Discounts, Leakage). Every figure comes from the database (migration 0636) for the
/// signed-in business and the outlet the app is showing; nothing is worked out or made up here.
class RstReportsScreen extends StatelessWidget {
  const RstReportsScreen({super.key, this.api, this.bill, this.today, this.openFeed});
  final RstReportsApi? api;
  final BillApi? bill;

  /// Tests fix "today".
  final DateTime? today;

  /// The owner's sales feed (the earlier Reports page), kept one tap away.
  final VoidCallback? openFeed;

  static Route<void> route({VoidCallback? openFeed}) => MaterialPageRoute(builder: (_) => RstReportsScreen(openFeed: openFeed));

  @override
  Widget build(BuildContext context) {
    void open(String kind) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => RstReportScreen(kind: kind, api: api, bill: bill, today: today)));
    Widget group(String title, List<(String, String, String, IconData)> rows) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(padding: const EdgeInsets.only(left: 4, bottom: 8), child: Text(title, style: inter(12.5, 800, color: kMuted).copyWith(letterSpacing: 1.1))),
            Material(
              color: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: kLine)),
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                for (final (i, (kind, name, sub, icon)) in rows.indexed) ...[
                  if (i > 0) const Divider(height: 1, color: kLine),
                  ListTile(
                    key: ValueKey('reports-open-$kind'),
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(color: kMoneyDeep, borderRadius: BorderRadius.circular(12)),
                      child: Icon(icon, size: 19, color: kMoneyLime),
                    ),
                    title: Text(name, style: inter(15.5, 700)),
                    subtitle: Text(sub, style: inter(12.5, 500, color: kMuted)),
                    trailing: const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
                    onTap: () => open(kind),
                  ),
                ],
              ]),
            ),
          ]),
        );
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(title: 'Reports', onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
            Entrance(index: 0, child: group('SALES', const [
              ('sales', 'Sales summary', 'Gross, net, tax, discounts, refunds, bills', LucideIcons.chartColumn),
              ('items', 'Item-wise sales', 'Every dish: quantity, revenue, share, top and slowest', LucideIcons.utensils),
              ('categories', 'Category-wise sales', 'Menu sections and their dishes', LucideIcons.layoutGrid),
            ])),
            Entrance(index: 1, child: group('PAYMENTS', const [
              ('payments', 'Payment mode', 'Cash, UPI, card, split bills, refunds, reconciliation', LucideIcons.wallet),
              ('cashiers', 'Cashier & day close', 'Who took what, and the cash count of each day', LucideIcons.userCheck),
            ])),
            Entrance(index: 2, child: group('AUDIT', const [
              ('discounts', 'Discounts', 'Coupons, service charge waived, free dishes', LucideIcons.badgePercent),
              ('audit', 'Leakage audit', 'Cancelled and unpaid bills, reprints, changes after the bill', LucideIcons.shieldAlert),
            ])),
            if (openFeed != null)
              TextButton.icon(
                key: const ValueKey('reports-feed'),
                onPressed: openFeed,
                icon: const Icon(LucideIcons.activity, size: 17, color: kInk),
                label: Text('Open the sales feed', style: inter(14, 700)),
              ),
          ]),
        ),
      ]),
    );
  }
}

const _titles = {
  'sales': 'Sales summary', 'items': 'Item-wise sales', 'categories': 'Category-wise sales', 'payments': 'Payment mode',
  'cashiers': 'Cashier & day close', 'discounts': 'Discounts', 'audit': 'Leakage audit',
};
const _methods = {'cash': 'Cash', 'upi': 'UPI', 'card': 'Card', 'wallet': 'Wallet', 'due': 'On credit', 'online': 'Online', 'other': 'Other'};
const _channels = {'dine_in': 'Dine-in', 'pickup': 'Takeaway', 'delivery': 'Own delivery', 'online': 'OneLocal', 'swiggy': 'Swiggy', 'zomato': 'Zomato', 'other': 'Other'};

/// One report: the period (Today, Yesterday, 7 days, This month, Custom), its figures, totals and lists; a tap on a bill opens it;
/// Excel exports the main table. It reads again when bills change (live) and when the app comes back.
class RstReportScreen extends StatefulWidget {
  const RstReportScreen({super.key, required this.kind, this.api, this.bill, this.today});
  final String kind;
  final RstReportsApi? api;
  final BillApi? bill;
  final DateTime? today;
  @override
  State<RstReportScreen> createState() => _RstReportScreenState();
}

class _RstReportScreenState extends State<RstReportScreen> with WidgetsBindingObserver {
  late final RstReportsApi _api = widget.api ?? RstReportsApi();
  late final DateTime _today = DateUtils.dateOnly(widget.today ?? DateTime.now());
  late DateTime _from = _today, _to = _today;
  String _period = 'today';
  Facts? _r;
  String? _error;
  int _seq = 0;
  VoidCallback? _unwatch;
  final _openCategories = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _unwatch = LiveSync.watch({'orders', 'kitchen'}, _load); // new bills, payments, discounts and cancellations
    OutletScope.selected.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unwatch?.call();
    OutletScope.selected.removeListener(_load);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final mine = ++_seq;
    try {
      final r = await _api.report(widget.kind, from: _from, to: _to, locationId: OutletScope.selected.value);
      if (!mounted || mine != _seq) return;
      setState(() {
        _r = r;
        _error = null;
      });
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() => _error = sayError(e));
    }
  }

  Future<void> _pick(String period) async {
    var from = _from, to = _to;
    switch (period) {
      case 'today':
        from = to = _today;
      case 'yesterday':
        from = to = _today.subtract(const Duration(days: 1));
      case '7days':
        from = _today.subtract(const Duration(days: 6));
        to = _today;
      case 'month':
        from = DateTime(_today.year, _today.month);
        to = _today;
      case 'custom':
        final picked = await showDateRangePicker(
          context: context,
          firstDate: _today.subtract(const Duration(days: 730)),
          lastDate: _today,
          initialDateRange: DateTimeRange(start: _from, end: _to),
        );
        if (picked == null) return;
        if (picked.end.difference(picked.start).inDays > 365) {
          if (mounted) showToast(context, 'Choose at most one year.');
          return;
        }
        from = picked.start;
        to = picked.end;
    }
    setState(() {
      _period = period;
      _from = from;
      _to = to;
      _r = null;
    });
    await _load();
  }

  String get _periodText => _from == _to ? dayMonth(RstReportsApi.day(_from)) : '${dayMonth(RstReportsApi.day(_from))} – ${dayMonth(RstReportsApi.day(_to))}';

  // ---------------------------------------------------------------------------------------------------------------- drill-down
  Future<void> _openBill(String? orderId) async {
    if (orderId == null || orderId.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SizedBox(height: MediaQuery.sizeOf(context).height * 0.75, child: _BillSheet(api: widget.bill ?? BillApi(), orderId: orderId)),
    );
  }

  Future<void> _openDish(Facts d) async {
    final id = d.so('menu_item_id');
    if (id == null) return;
    Facts? r;
    try {
      r = await _api.report('items', from: _from, to: _to, locationId: OutletScope.selected.value, menuItemId: id);
    } catch (e) {
      if (mounted) showToast(context, sayError(e));
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
          Text('Bills with ${d.s('name')}', style: inter(19, 800)),
          Text(_periodText, style: inter(13, 500, color: kMuted)),
          const SizedBox(height: 10),
          for (final b in r!.l('bills')) _billRow(b, onTap: () => _openBill(b.s('order_id'))),
        ]),
      ),
    );
  }

  // ---------------------------------------------------------------------------------------------------------------- export
  Future<void> _export() async {
    final r = _r;
    if (r == null) return;
    final rows = switch (widget.kind) {
      'sales' => [
          ['Bill', 'Paid at', 'Type', 'Cashier', 'Gross (Rs)', 'Discount (Rs)', 'Total (Rs)'],
          for (final b in r.l('bills')) [b.s('bill'), b.s('at'), _channels[b.s('channel')] ?? b.s('channel'), b.s('cashier'), b.n('gross_minor') / 100, b.n('discount_minor') / 100, b.n('total_minor') / 100],
        ],
      'items' => [
          ['Dish', 'Size', 'Category', 'Qty', 'Revenue (Rs)', 'Share %', 'Bills'],
          for (final i in r.l('items')) [i.s('name'), i.s('variant'), i.s('category'), i.n('qty'), i.n('revenue_minor') / 100, i.n('share_pct'), i.n('bills')],
        ],
      'categories' => [
          ['Category', 'Dish', 'Qty', 'Revenue (Rs)', 'Share %'],
          for (final c in r.l('categories')) ...[
            [c.s('name'), '', c.n('qty'), c.n('revenue_minor') / 100, c.n('share_pct')],
            for (final d in c.l('dishes')) ['', d.s('name'), d.n('qty'), d.n('revenue_minor') / 100, ''],
          ],
        ],
      'payments' => [
          ['Method', 'Payments', 'Collected (Rs)', 'Refunds (Rs)'],
          for (final m in r.l('methods')) [_methods[m.s('method')] ?? m.s('method'), m.n('count'), m.n('amount_minor') / 100, m.n('refunds_minor') / 100],
        ],
      'cashiers' => [
          ['Day', 'Opening (Rs)', 'Cash sales (Rs)', 'Refunds (Rs)', 'Paid out (Rs)', 'Expected (Rs)', 'Counted (Rs)', 'Difference (Rs)', 'Closed by'],
          for (final d in r.l('days'))
            [d.s('day'), d.n('opening_minor') / 100, d.n('cash_sales_minor') / 100, d.n('refunds_minor') / 100, d.n('paid_out_minor') / 100, d.n('expected_minor') / 100,
             d.no('counted_minor') == null ? '' : d.n('counted_minor') / 100, d.no('difference_minor') == null ? '' : d.n('difference_minor') / 100, d.s('closed_by')],
        ],
      'discounts' => [
          ['Bill', 'At', 'Gross (Rs)', 'Coupon', 'Discount (Rs)', 'Applied by', 'Service charge waived (Rs)', 'Reason', 'Waived by'],
          for (final b in r.l('bills'))
            [b.s('bill'), b.s('at'), b.n('gross_minor') / 100, b.s('coupon'), b.n('discount_minor') / 100, b.s('coupon_by'), b.n('waived_minor') / 100, b.s('waive_reason'), b.s('waived_by')],
        ],
      _ => [
          ['What', 'Bill', 'At', 'Amount (Rs)', 'By', 'Reason / detail'],
          for (final c in r.m('cancelled').l('list')) ['Cancelled', c.s('bill'), c.s('at'), c.n('value_minor') / 100, c.s('by'), c.s('reason')],
          for (final u in r.m('unpaid').l('list')) ['Not paid', u.s('bill'), u.s('at'), u.n('total_minor') / 100, u.s('cashier'), ''],
          for (final p in r.m('reprints').l('list')) ['Reprint', p.s('bill'), p.s('at'), '', p.s('by'), p.s('what')],
          for (final a in r.m('after_bill').l('list')) ['After the bill', a.s('bill'), a.s('at'), '', a.s('by'), a.s('what')],
          for (final f in r.m('refunds').l('list')) ['Refund', f.s('bill'), f.s('at'), f.n('amount_minor') / 100, f.s('by'), f.s('reason')],
        ],
    };
    final name = '${widget.kind}-${RstReportsApi.day(_from)}${_from == _to ? '' : '-to-${RstReportsApi.day(_to)}'}.xlsx';
    await saveSpreadsheet(buildXlsx(_titles[widget.kind]!, rows), name);
    if (mounted) showToast(context, 'Saved $name');
  }

  // ---------------------------------------------------------------------------------------------------------------- building blocks
  Widget _card(String? title, List<Widget> children, {Key? key}) => Container(
        key: key,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: kLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (title != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(title, style: inter(12.5, 800, color: kMuted).copyWith(letterSpacing: 1))),
          ...children,
        ]),
      );

  Widget _line(String label, String value, {String? key, bool bold = false, Color? color, String? sub, VoidCallback? onTap}) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: inter(14.5, bold ? 800 : 500)),
                if (sub != null && sub.isNotEmpty) Text(sub, style: inter(12, 500, color: kMuted)),
              ]),
            ),
            const SizedBox(width: 8),
            Text(value, key: key == null ? null : ValueKey(key), style: inter(14.5, bold ? 800 : 700, color: color ?? kInk)),
            if (onTap != null) const Padding(padding: EdgeInsets.only(left: 4, top: 2), child: Icon(LucideIcons.chevronRight, size: 15, color: kMuted)),
          ]),
        ),
      );

  /// The headline figures, two a row; each tile as tall as its text (a long comparison wraps instead of overflowing).
  Widget _kpis(List<(String, String, String, String?)> items) => LayoutBuilder(
        builder: (context, box) => Wrap(spacing: 10, runSpacing: 10, children: [
          for (final (i, (key, label, value, change)) in items.indexed)
            Container(
              width: (box.maxWidth - 10) / 2,
              constraints: const BoxConstraints(minHeight: 92),
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
              decoration: BoxDecoration(color: i == 0 ? kMoneyDeep : Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: i == 0 ? kMoneyDeep : kLine)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(label, style: inter(12, 700, color: i == 0 ? const Color(0xFFB8BCC4) : kMuted)),
                FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, key: ValueKey('rep-$key'), style: inter(22, 800, color: i == 0 ? Colors.white : kInk))),
                if (change != null) Text(change, style: inter(11.5, 600, color: i == 0 ? kMoneyLime : kMuted)),
              ]),
            ),
        ]),
      );

  /// The change against the same number of days just before.
  String? _change(num now, num before) {
    if (before == 0) return now == 0 ? null : 'none in the period before';
    final pct = (now - before) * 100 / before;
    return '${pct >= 0 ? '▲' : '▼'} ${pct.abs().toStringAsFixed(pct.abs() < 10 ? 1 : 0)}% against the period before';
  }

  Widget _billRow(Facts b, {VoidCallback? onTap, String? value, String? sub}) => _line(
        'Bill ${b.s('bill')}',
        value ?? rs(b.n('total_minor')),
        key: 'rep-bill-${b.s('order_id')}',
        sub: sub ?? [_time(b.s('at')), _channels[b.s('channel')] ?? '', if (b.s('table').isNotEmpty) 'Table ${b.s('table')}', b.s('cashier')].where((s) => s.isNotEmpty).join(' · '),
        onTap: onTap ?? () => _openBill(b.s('order_id')),
      );

  String _time(String iso) {
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return '';
    return '${dayMonth(RstReportsApi.day(t))} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Widget _empty(String text) => Padding(
        key: const ValueKey('rep-empty'),
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Column(children: [
          const Icon(LucideIcons.inbox, size: 30, color: kMuted),
          const SizedBox(height: 8),
          Text(text, textAlign: TextAlign.center, style: inter(14.5, 500, color: kMuted)),
        ]),
      );

  Widget _note(String text) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0xFFFFF7E6), borderRadius: BorderRadius.circular(14)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(LucideIcons.info, size: 16, color: Color(0xFFB45309)),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: inter(12.5, 500, color: const Color(0xFF92400E), height: 1.35))),
        ]),
      );

  // ---------------------------------------------------------------------------------------------------------------- the reports
  List<Widget> _sales(Facts r) {
    final t = r.m('totals'), p = r.m('previous');
    if (t.n('bills') == 0 && r.m('cancelled').n('bills') == 0 && t.n('refunds') == 0) return [_empty('No bills were paid in this period.')];
    return [
      _kpis([
        ('net', 'Net sales', rs(t.n('net_minor')), _change(t.n('net_minor'), p.n('net_minor'))),
        ('bills', 'Completed bills', '${t.n('bills')}', _change(t.n('bills'), p.n('bills'))),
        ('average', 'Average bill', rs(t.n('average_minor')), _change(t.n('average_minor'), p.n('average_minor'))),
        ('collected', 'Collected', rs(t.n('collected_minor')), null),
      ]),
      const SizedBox(height: 12),
      _card('HOW IT ADDS UP', [
        _line('Gross sales', rs(t.n('gross_minor')), key: 'rep-gross', sub: 'Dishes with add-ons, before discount and tax'),
        _line('Discounts', '−${rs(t.n('discount_minor'))}', key: 'rep-discounts'),
        _line('Net sales', rs(t.n('net_minor')), bold: true),
        _line('Service charge', rs(t.n('service_charge_minor')), key: 'rep-service'),
        _line('GST', rs(t.n('gst_minor')), key: 'rep-gst'),
        if (t.n('round_off_minor') != 0) _line('Round off', rs(t.n('round_off_minor'))),
        _line('Bill total', rs(t.n('total_minor')), bold: true, key: 'rep-total'),
        const Divider(height: 14, color: kLine),
        _line('Refunds', '−${rs(t.n('refunds_minor'))}', key: 'rep-refunds', sub: '${t.n('refunds')} refund${t.n('refunds') == 1 ? '' : 's'}'),
        _line('Net after refunds', rs(t.n('net_after_refunds_minor')), bold: true),
        _line('Guests', '${t.n('guests')}'),
        _line('Cancelled bills', '${r.m('cancelled').n('bills')} · ${rs(r.m('cancelled').n('value_minor'))}', key: 'rep-cancelled', color: kError),
      ]),
      if (r.l('days').length > 1)
        _card('DAY BY DAY', [for (final d in r.l('days')) _line(dayMonth(d.s('day')), rs(d.n('net_minor')), sub: '${d.n('bills')} bills')]),
      _card('BILLS (${t.n('bills')})', [
        for (final b in r.l('bills')) _billRow(b),
        if (t.n('bills') > r.n('bills_shown_max')) Text('The newest ${r.n('bills_shown_max')} are listed; Excel has them all.', style: inter(12, 500, color: kMuted)),
      ]),
    ];
  }

  List<Widget> _items(Facts r) {
    final items = r.l('items'), sold = items.where((i) => i.n('qty') > 0).toList();
    if (sold.isEmpty) return [_empty('No dishes were sold in this period.')];
    Widget dish(Facts i, String list) => _line(
          '${i.s('name')}${i.s('variant').isEmpty ? '' : ' (${i.s('variant')})'}',
          rs(i.n('revenue_minor')),
          key: 'rep-dish-$list-${i.s('name')}',
          sub: '${_qty(i.n('qty'))} sold · ${i.n('share_pct')}%${i.s('category').isEmpty ? '' : ' · ${i.s('category')}'}',
          onTap: i.n('qty') > 0 ? () => _openDish(i) : null,
        );
    return [
      _kpis([
        ('items-total', 'Item revenue', rs(r.n('total_minor')), 'before bill discounts'),
        ('items-qty', 'Dishes sold', _qty(r.n('qty')), '${sold.length} different'),
      ]),
      const SizedBox(height: 12),
      _card('TOP 5', [for (final i in r.l('top')) dish(i, 'top')], key: const ValueKey('rep-top')),
      _card('SLOWEST 5', [for (final i in r.l('slowest')) dish(i, 'slowest')], key: const ValueKey('rep-slowest')),
      _card('EVERY DISH (${items.length})', [for (final i in items) dish(i, 'all')]),
    ];
  }

  String _qty(num q) => q == q.roundToDouble() ? '${q.round()}' : q.toStringAsFixed(2);

  List<Widget> _categories(Facts r) {
    final cats = r.l('categories');
    if (cats.isEmpty) return [_empty('No dishes were sold in this period.')];
    return [
      _kpis([('cat-total', 'Category revenue', rs(r.n('total_minor')), '${cats.length} categories sold')]),
      const SizedBox(height: 12),
      _card('BY CATEGORY', [
        for (final c in cats) ...[
          InkWell(
            key: ValueKey('rep-cat-${c.s('name')}'),
            onTap: () => setState(() => _openCategories.contains(c.s('name')) ? _openCategories.remove(c.s('name')) : _openCategories.add(c.s('name'))),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text(c.s('name'), style: inter(15, 700))),
                  Text(rs(c.n('revenue_minor')), key: ValueKey('rep-cat-value-${c.s('name')}'), style: inter(15, 800)),
                  Icon(_openCategories.contains(c.s('name')) ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 16, color: kMuted),
                ]),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(value: (c.n('share_pct') / 100).clamp(0, 1).toDouble(), minHeight: 6, backgroundColor: kLine, color: kMoneyDeep),
                ),
                const SizedBox(height: 3),
                Text('${c.n('share_pct')}% · ${_qty(c.n('qty'))} sold · ${c.n('bills')} ${c.n('bills') == 1 ? 'bill' : 'bills'}', style: inter(12, 500, color: kMuted)),
              ]),
            ),
          ),
          if (_openCategories.contains(c.s('name')))
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 6),
              child: Column(children: [
                for (final d in c.l('dishes')) _line(d.s('name'), rs(d.n('revenue_minor')), sub: '${_qty(d.n('qty'))} sold', onTap: () => _openDish(d)),
              ]),
            ),
        ],
      ]),
      if (r.ls('unsold').isNotEmpty) _card('NOTHING SOLD', [Text(r.ls('unsold').join(', '), style: inter(13.5, 500, color: kMuted))]),
    ];
  }

  List<Widget> _payments(Facts r) {
    final methods = r.l('methods'), rec = r.m('reconcile');
    if (methods.isEmpty && rec.n('bills_minor') == 0) return [_empty('No payments in this period.')];
    return [
      _kpis([
        ('collected', 'Collected', rs(r.n('collected_minor')), '${r.n('payments')} payments'),
        ('refunds', 'Refunds', rs(r.m('refunds').n('amount_minor')), '${r.m('refunds').n('count')} refunds'),
      ]),
      const SizedBox(height: 12),
      _card('BY METHOD', [
        for (final m in methods)
          _line(_methods[m.s('method')] ?? m.s('method'), rs(m.n('amount_minor')), key: 'rep-method-${m.s('method')}',
              sub: '${m.n('count')} payments${m.n('refunds_minor') > 0 ? ' · refunds ${rs(m.n('refunds_minor'))}' : ''}'),
      ]),
      _card('RECONCILIATION', [
        _line('Bills paid in the period', rs(rec.n('bills_minor'))),
        _line('Paid for those bills', rs(rec.n('paid_minor'))),
        if (rec.n('on_credit_minor') > 0) _line('Put on credit', rs(rec.n('on_credit_minor'))),
        _line(rec.n('difference_minor') == 0 ? 'Fully reconciled' : 'Not reconciled', rs(rec.n('difference_minor')),
            bold: true, key: 'rep-difference', color: rec.n('difference_minor') == 0 ? const Color(0xFF15803D) : kError),
      ]),
      if (r.l('channels').isNotEmpty)
        _card('BY ORDER SOURCE', [for (final c in r.l('channels')) _line(_channels[c.s('channel')] ?? c.s('channel'), rs(c.n('amount_minor')), sub: '${c.n('bills')} bills')]),
      _card('SPLIT BILLS (${r.m('split').n('bills')})', [
        if (r.m('split').l('list').isEmpty) Text('No bill was paid with more than one method.', style: inter(13, 500, color: kMuted)),
        for (final s in r.m('split').l('list'))
          _line('Bill ${s.s('bill')}', rs(s.n('amount_minor')), sub: s.s('methods').split(' + ').map((m) => _methods[m] ?? m).join(' + '), onTap: () => _openBill(s.s('order_id'))),
      ]),
    ];
  }

  List<Widget> _cashiers(Facts r) {
    final people = r.l('cashiers'), days = r.l('days');
    return [
      _card('WHO TOOK THE MONEY', [
        if (people.isEmpty) Text('No payments in this period.', style: inter(13.5, 500, color: kMuted)),
        for (final c in people)
          _line(c.s('name'), rs(c.n('amount_minor')), key: 'rep-cashier-${c.s('name')}',
              sub: '${c.n('bills')} bills · ${(c.raw['methods'] as Map? ?? const {}).entries.map((e) => '${_methods[e.key] ?? e.key} ${rs(e.value as num?)}').join(' · ')}'),
      ]),
      _note('The restaurant closes by day: each day\'s cash count is below. Shifts are not used for restaurant billing.'),
      _card('DAY CLOSE', [
        for (final d in days)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text(dayMonth(d.s('day')), style: inter(15, 800))),
                if (d.no('counted_minor') == null)
                  Text('Not closed', style: inter(12.5, 700, color: kMuted))
                else
                  Text(d.n('difference_minor') == 0 ? 'Matched' : (d.n('difference_minor') < 0 ? 'Short ${rs(-d.n('difference_minor'))}' : 'Extra ${rs(d.n('difference_minor'))}'),
                      key: ValueKey('rep-close-${d.s('day')}'), style: inter(13, 800, color: d.n('difference_minor') < 0 ? kError : const Color(0xFF15803D))),
              ]),
              Text('Opening ${rs(d.n('opening_minor'))} · cash sales ${rs(d.n('cash_sales_minor'))} · refunds ${rs(d.n('refunds_minor'))} · paid out ${rs(d.n('paid_out_minor'))}',
                  style: inter(12, 500, color: kMuted)),
              Text('Expected ${rs(d.n('expected_minor'))}${d.no('counted_minor') == null ? '' : ' · counted ${rs(d.n('counted_minor'))}${d.s('closed_by').isEmpty ? '' : ' by ${d.s('closed_by')}'}'}',
                  style: inter(12, 600)),
            ]),
          ),
        if (days.length < (_to.difference(_from).inDays + 1)) Text('The newest ${days.length} days are shown.', style: inter(12, 500, color: kMuted)),
      ]),
    ];
  }

  List<Widget> _discounts(Facts r) {
    final t = r.m('totals');
    final share = t.n('gross_minor') == 0 ? 0 : t.n('discount_minor') * 100 / t.n('gross_minor');
    return [
      _kpis([
        ('disc-total', 'Discounts', rs(t.n('discount_minor')), '${share.toStringAsFixed(1)}% of gross sales'),
        ('waived', 'Service charge waived', rs(t.n('waived_minor')), null),
        ('disc-bills', 'Bills with a discount', '${t.n('bills')}', 'of ${t.n('all_bills')} bills'),
        ('free', 'Free dishes', '${t.n('free_dishes')}', null),
      ]),
      const SizedBox(height: 12),
      _note('The POS records coupon discounts and service charge waivers. Manual discounts and approvals are not recorded yet.'),
      if (r.l('coupons').isNotEmpty) _card('BY COUPON', [for (final c in r.l('coupons')) _line(c.s('code'), rs(c.n('amount_minor')), sub: '${c.n('bills')} bills')]),
      _card('BILLS', [
        if (r.l('bills').isEmpty) _empty('No discounts in this period.'),
        for (final b in r.l('bills'))
          _line('Bill ${b.s('bill')}', b.n('discount_minor') > 0 ? '−${rs(b.n('discount_minor'))}' : '−${rs(b.n('waived_minor'))}', key: 'rep-disc-${b.s('order_id')}',
              sub: [
                _time(b.s('at')),
                if (b.s('coupon').isNotEmpty) 'Coupon ${b.s('coupon')}${b.s('coupon_by').isEmpty ? '' : ' by ${b.s('coupon_by')}'}',
                if (b.n('waived_minor') > 0 || b.s('waive_reason').isNotEmpty)
                  'Service charge ${rs(b.n('waived_minor'))} waived${b.s('waived_by').isEmpty ? '' : ' by ${b.s('waived_by')}'}${b.s('waive_reason').isEmpty ? '' : ': ${b.s('waive_reason')}'}',
              ].join(' · '),
              onTap: () => _openBill(b.s('order_id'))),
      ]),
      if (r.l('free').isNotEmpty)
        _card('FREE DISHES', [for (final f in r.l('free')) _line(f.s('name'), '× ${_qty(f.n('qty'))}', sub: 'Bill ${f.s('bill')}', onTap: () => _openBill(f.s('order_id')))]),
    ];
  }

  List<Widget> _audit(Facts r) {
    final c = r.m('cancelled'), u = r.m('unpaid'), p = r.m('reprints'), a = r.m('after_bill'), f = r.m('refunds');
    final nothing = c.n('bills') == 0 && u.n('bills') == 0 && p.n('count') == 0 && a.n('count') == 0 && f.n('count') == 0;
    Widget event(Facts e) => _line('Bill ${e.s('bill')}', _time(e.s('at')), sub: '${e.s('what')}${e.s('by').isEmpty ? '' : ' · ${e.s('by')}'}', onTap: () => _openBill(e.s('order_id')));
    return [
      _kpis([
        ('audit-cancelled', 'Cancelled bills', '${c.n('bills')}', rs(c.n('value_minor'))),
        ('audit-unpaid', 'Billed, not paid', '${u.n('bills')}', rs(u.n('value_minor'))),
        ('audit-reprints', 'Reprints', '${p.n('count')}', null),
        ('audit-after', 'Changed after the bill', '${a.n('count')}', null),
      ]),
      const SizedBox(height: 12),
      if (nothing) _empty('Nothing unusual in this period.'),
      if (c.n('bills') > 0)
        _card('CANCELLED BILLS', [
          for (final x in c.l('list'))
            _line('Bill ${x.s('bill')}', rs(x.n('value_minor')), color: kError,
                sub: [_time(x.s('at')), if (x.b('kot_sent')) 'after the kitchen got it', if (x.s('by').isNotEmpty) 'by ${x.s('by')}', if (x.s('reason').isNotEmpty) x.s('reason')].join(' · '),
                onTap: () => _openBill(x.s('order_id'))),
        ]),
      if (u.n('bills') > 0) _card('BILLED, NOT PAID BY THE END OF THE DAY', [for (final b in u.l('list')) _billRow(b)]),
      if (f.n('count') > 0)
        _card('REFUNDS', [
          for (final x in f.l('list'))
            _line('Bill ${x.s('bill')}', rs(x.n('amount_minor')), sub: [_time(x.s('at')), _methods[x.s('method')] ?? x.s('method'), if (x.s('by').isNotEmpty) 'by ${x.s('by')}', x.s('reason')].join(' · '),
                onTap: () => _openBill(x.s('order_id'))),
        ]),
      if (a.n('count') > 0) _card('CHANGED AFTER THE BILL', [for (final e in a.l('list')) event(e)]),
      if (p.n('count') > 0) _card('REPRINTS', [for (final e in p.l('list')) event(e)]),
      _note('Removing a single dish and editing a price are not possible in the POS, so they cannot happen unseen.'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    const periods = [('today', 'Today'), ('yesterday', 'Yesterday'), ('7days', '7 days'), ('month', 'This month'), ('custom', 'Custom')];
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(
          title: _titles[widget.kind]!,
          onBack: () => Navigator.of(context).maybePop(),
          under: Row(children: [
            Expanded(child: Text(_periodText, key: const ValueKey('rep-period'), style: inter(14, 600, color: kMuted))),
            IconButton(key: const ValueKey('rep-export'), tooltip: 'Export Excel', onPressed: r == null ? null : _export, icon: const Icon(LucideIcons.fileSpreadsheet, size: 20)),
          ]),
        ),
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
            for (final (id, label) in periods)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  key: ValueKey('rep-period-$id'),
                  label: Text(label, style: inter(13, 700, color: _period == id ? kMoneyLime : kInk)),
                  selected: _period == id,
                  showCheckmark: false,
                  selectedColor: kMoneyDeep,
                  backgroundColor: Colors.white,
                  onSelected: (_) => _pick(id),
                ),
              ),
          ]),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            // the whole report is built at once (lists are capped by the database), so every row is there to read and export
            child: SingleChildScrollView(
              key: ValueKey('rep-${widget.kind}'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(children: [
                    Text(_error!, key: const ValueKey('rep-error'), textAlign: TextAlign.center, style: inter(14.5, 500, color: kMuted)),
                    TextButton(onPressed: _load, child: const Text('Try again')),
                  ]),
                )
              else if (r == null)
                const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kInk)))
              else
                ...switch (widget.kind) {
                  'sales' => _sales(r),
                  'items' => _items(r),
                  'categories' => _categories(r),
                  'payments' => _payments(r),
                  'cashiers' => _cashiers(r),
                  'discounts' => _discounts(r),
                  _ => _audit(r),
                },
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// One bill as the database keeps it (rst_receipt_view): number, status, dishes, the money and payments. Read only.
class _BillSheet extends StatefulWidget {
  const _BillSheet({required this.api, required this.orderId});
  final BillApi api;
  final String orderId;
  @override
  State<_BillSheet> createState() => _BillSheetState();
}

class _BillSheetState extends State<_BillSheet> {
  Facts? _b;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api.receipt(widget.orderId).then((b) {
      if (mounted) setState(() => _b = b);
    }, onError: (Object e) {
      if (mounted) setState(() => _error = sayError(e));
    });
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    Widget line(String l, String v, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [Expanded(child: Text(l, style: inter(14, bold ? 800 : 500))), Text(v, style: inter(14, bold ? 800 : 600))]),
        );
    return ListView(key: const ValueKey('rep-bill-sheet'), padding: const EdgeInsets.fromLTRB(18, 16, 18, 24), children: [
      if (_error != null) Text(_error!, style: inter(14, 500, color: kMuted)),
      if (b == null && _error == null) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator(color: kInk))),
      if (b != null) ...[
        Text('Bill ${b.s('display_no')}', style: inter(20, 800)),
        Text([b.s('status').replaceAll('_', ' '), if (b.s('table_label').isNotEmpty) 'Table ${b.s('table_label')}', if (b.s('customer_name').isNotEmpty) b.s('customer_name')].join(' · '),
            style: inter(13, 500, color: kMuted)),
        const Divider(height: 22, color: kLine),
        for (final i in billItems(b)) line('${i.n('qty')} × ${i.s('name')}${i.s('variant').isEmpty ? '' : ' (${i.s('variant')})'}', money(i.n('line_total'))),
        const Divider(height: 22, color: kLine),
        line('Subtotal', money(b.n('subtotal'))),
        if (b.n('discount') != 0) line('Discount${b.s('coupon_code').isEmpty ? '' : ' (${b.s('coupon_code')})'}', '−${money(b.n('discount'))}'),
        if (b.n('service_charge') != 0) line('Service charge', money(b.n('service_charge'))),
        if (b.n('gst_amount') != 0) line('GST', money(b.n('gst_amount'))),
        if (b.n('round_off') != 0) line('Round off', money(b.n('round_off'))),
        line('Total', money(b.n('total')), bold: true),
        line('Paid', money(b.n('paid'))),
        if (b.n('due') > 0) line('Due', money(b.n('due')), bold: true),
      ],
    ]);
  }
}
