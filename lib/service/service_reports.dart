import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import '../ui/xlsx.dart';
import 'service_api.dart';
import 'service_widgets.dart';

// Service reports (founder, 4 Nov 2026: "copy the report section of restaurant ... make it service relevant"): the restaurant's Reports —
// groups of reports, each with a period, figures, lists and Excel — counted and worded for a service business: services instead of dishes,
// bookings, no-shows and staff instead of tables and kitchens. Every figure is the database's (svc_report); the app only draws it.

/// Hands an .xlsx over (tests replace it): a save dialog on a phone or computer, a download in the browser.
Future<void> Function(Uint8List bytes, String name) saveReportFile = (bytes, name) async {
  await FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', type: FileType.custom,
      allowedExtensions: const ['xlsx']);
};

const _reports = <(String group, List<(String kind, String name, String line, IconData icon)>)>[
  ('SALES', [
    ('sales', 'Sales summary', 'Gross, net, GST, discounts, refunds, bills', LucideIcons.chartColumn),
    ('services', 'Service-wise sales', 'Every service: how many, revenue, share, top and slowest', LucideIcons.scissors),
    ('categories', 'Category-wise sales', 'Your service categories and what sold in each', LucideIcons.layoutGrid),
  ]),
  ('BOOKINGS', [
    ('bookings', 'Bookings & no-shows', 'Completed, upcoming, cancelled, no-shows, online and offline', LucideIcons.calendarCheck),
    ('staff', 'Staff performance', 'Each person: bookings, hours, revenue, no-shows', LucideIcons.users),
  ]),
  ('PAYMENTS', [
    ('payments', 'Payment mode', 'Cash, UPI, card, and refunds', LucideIcons.wallet),
    ('dues', 'Customers who owe', 'Bills still to be paid, oldest first', LucideIcons.hourglass),
  ]),
  ('AUDIT', [
    ('discounts', 'Discounts', 'Every bill with a discount, and how much', LucideIcons.badgePercent),
    ('cancellations', 'Cancellations & refunds', 'Cancelled bookings, no-shows with reasons, refunds', LucideIcons.circleX),
  ]),
];

String _title(String kind) => [for (final (_, rows) in _reports) ...rows].firstWhere((r) => r.$1 == kind).$2;
String _rs(Object? minor) => svcRupees(((minor as num?) ?? 0) / 100);
const _methods = {'cash': 'Cash', 'upi': 'UPI', 'card': 'Card', 'wallet': 'Wallet', 'online': 'Online', 'other': 'Other'};

/// The Reports page: the groups of reports, each a row with an outline icon.
class ServiceReportsScreen extends StatelessWidget {
  const ServiceReportsScreen({super.key, this.api, this.today});
  final ServiceApi? api;

  /// Tests fix "today".
  final DateTime? today;

  @override
  Widget build(BuildContext context) {
    void open(String kind) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServiceReportScreen(kind: kind, api: api, today: today)));
    return ServicePage(
      title: 'Reports',
      subtitle: 'Sales, bookings, payments and audit, for any period',
      body: [
        for (final (group, rows) in _reports)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(padding: const EdgeInsets.only(left: 4, bottom: 8), child: Text(group, style: inter(12.5, 800, color: kMuted).copyWith(letterSpacing: 1.1))),
              Material(
                color: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: kLine)),
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  for (final (i, (kind, name, line, icon)) in rows.indexed) ...[
                    if (i > 0) const Divider(height: 1, color: kLine),
                    ListTile(
                      key: ValueKey('reports-open-$kind'),
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(color: kBg, shape: BoxShape.circle, border: Border.all(color: kLine)),
                        child: Icon(icon, size: 18, color: kInk),
                      ),
                      title: Text(name, style: inter(15, 700)),
                      subtitle: Text(line, style: inter(12.5, 500, color: kMuted)),
                      trailing: const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
                      onTap: () => open(kind),
                    ),
                  ],
                ]),
              ),
            ]),
          ),
      ],
    );
  }
}

/// One report: the period (Today, Yesterday, 7 days, This month, Last month), its figures and lists, and Excel.
class ServiceReportScreen extends StatefulWidget {
  const ServiceReportScreen({super.key, required this.kind, this.api, this.today});
  final String kind;
  final ServiceApi? api;
  final DateTime? today;
  @override
  State<ServiceReportScreen> createState() => _ServiceReportScreenState();
}

class _ServiceReportScreenState extends State<ServiceReportScreen> {
  late final ServiceApi _api = widget.api ?? ServiceApi();
  late final DateTime _today = DateUtils.dateOnly(widget.today ?? DateTime.now());
  String _period = 'month';
  SvcData? _d;
  String? _error;
  int _seq = 0;

  static const _periods = [('today', 'Today'), ('yesterday', 'Yesterday'), ('week', '7 days'), ('month', 'This month'), ('last', 'Last month')];

  (DateTime, DateTime) get _range => switch (_period) {
        'today' => (_today, _today),
        'yesterday' => (_today.subtract(const Duration(days: 1)), _today.subtract(const Duration(days: 1))),
        'week' => (_today.subtract(const Duration(days: 6)), _today),
        'last' => (DateTime(_today.year, _today.month - 1, 1), DateTime(_today.year, _today.month, 0)),
        _ => (DateTime(_today.year, _today.month, 1), _today),
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mine = ++_seq;
    final (from, to) = _range;
    try {
      final d = await _api.report(widget.kind, from: from, to: to);
      if (mounted && mine == _seq) {
        setState(() {
          _d = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && mine == _seq) setState(() => _error = e is ServiceApiException ? e.message : e.toString());
    }
  }

  // ---------------------------------------------------------------------------------------------------------------- Excel
  List<List<Object?>> _table(SvcData d) => switch (widget.kind) {
        'sales' => [
            ['Bill', 'Customer', 'When', 'Total (₹)', 'Paid by'],
            for (final b in d.l('bills')) [b.s('no'), b.s('customer'), b.s('when'), b.n('total_minor') / 100, b.s('methods')],
          ],
        'services' => [
            ['Service', 'Category', 'Sold', 'Revenue (₹)', 'Bills', 'Share %'],
            for (final s in d.l('services')) [s.s('name'), s.s('category'), s.n('qty'), s.n('revenue_minor') / 100, s.n('bills'), s.n('share_pct')],
          ],
        'categories' => [
            ['Category', 'Sold', 'Revenue (₹)', 'Bills', 'Share %'],
            for (final c in d.l('categories')) [c.s('name'), c.n('qty'), c.n('revenue_minor') / 100, c.n('bills'), c.n('share_pct')],
          ],
        'bookings' => [
            ['Day', 'Booked', 'Completed', 'Cancelled', 'No-show'],
            for (final x in d.l('days')) [x.s('day'), x.n('booked'), x.n('completed'), x.n('cancelled'), x.n('no_show')],
          ],
        'staff' => [
            ['Person', 'Title', 'Bookings', 'Completed', 'Hours', 'Revenue (₹)', 'No-shows', 'Cancelled'],
            for (final p in d.l('staff'))
              [p.s('name'), p.s('title'), p.n('bookings'), p.n('completed'), (p.n('minutes') / 60).toStringAsFixed(1), p.n('revenue_minor') / 100, p.n('no_show'), p.n('cancelled')],
          ],
        'payments' => [
            ['Method', 'Payments', 'Amount (₹)'],
            for (final m in d.l('methods')) [_methods[m.s('method')] ?? m.s('method'), m.n('count'), m.n('amount_minor') / 100],
          ],
        'dues' => [
            ['Bill', 'Customer', 'Phone', 'Since', 'Days', 'Due (₹)'],
            for (final b in d.l('list')) [b.s('no'), b.s('customer'), b.s('phone'), b.s('since'), b.n('days'), b.n('due_minor') / 100],
          ],
        'discounts' => [
            ['Bill', 'Customer', 'When', 'Bill (₹)', 'Discount (₹)', '%'],
            for (final b in d.l('list')) [b.s('no'), b.s('customer'), b.s('when'), b.n('gross_minor') / 100, b.n('discount_minor') / 100, b.n('pct')],
          ],
        _ => [
            ['Booking', 'Customer', 'When', 'State', 'Reason', 'Advance kept'],
            for (final b in d.l('bookings')) [b.s('no'), b.s('customer'), b.s('when'), b.s('state'), b.s('reason'), b.b('deposit_kept') ? 'Yes' : 'No'],
          ],
      };

  Future<void> _export() async {
    final d = _d;
    if (d == null) return;
    final (from, to) = _range;
    final name = '${_title(widget.kind).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}-${_dayOf(from)}-to-${_dayOf(to)}.xlsx';
    await saveReportFile(buildXlsx(_title(widget.kind), _table(d)), name);
    if (mounted) showToast(context, 'Exported.');
  }

  // ---------------------------------------------------------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    final d = _d;
    return ServicePage(
      title: _title(widget.kind),
      subtitle: d == null ? '' : '${_niceDay(d.s('from'))} to ${_niceDay(d.s('to'))}',
      onRefresh: _load,
      error: _error,
      onRetry: _load,
      body: [
        // every period in view (they wrap on a phone), then Excel
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final (k, label) in _periods)
            ModeChip(label, key: ValueKey('period-$k'), selected: _period == k, onTap: () {
              setState(() => _period = k);
              _load();
            }),
          SmallPill('Excel', key: const ValueKey('report-export'), onTap: d == null ? null : _export),
        ]),
        const SizedBox(height: 12),
        if (d == null && _error == null) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kGreenText))),
        if (d != null) ..._content(d),
      ],
    );
  }

  static String _niceDay(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${m[d.month - 1]}';
  }

  /// Figure tiles: two to a row on a phone, four on a wide screen.
  Widget _tiles(List<(String label, String value, String? note)> tiles) => LayoutBuilder(builder: (context, box) {
        final cols = box.maxWidth >= 640 ? 4 : 2;
        final w = (box.maxWidth - (cols - 1) * 10) / cols;
        return Wrap(spacing: 10, runSpacing: 10, children: [
          for (final (label, value, note) in tiles)
            SizedBox(
              width: w,
              child: OrderCardBox(
                radius: 16,
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: inter(12, 600, color: kMuted)),
                  const SizedBox(height: 4),
                  Text(value, key: ValueKey('tile-$label'), style: inter(18, 800)),
                  if (note != null) Text(note, style: inter(11.5, 500, color: kMuted)),
                ]),
              ),
            ),
        ]);
      });

  /// A list row: a name and a line, a figure on the right, and a share bar under it when there is one.
  Widget _row(String name, String line, String figure, {num? share, Key? key}) => Container(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: kLine))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: inter(14.5, 700)),
                if (line.isNotEmpty) Text(line, style: inter(12.5, 400, color: kMuted)),
              ]),
            ),
            Text(figure, style: inter(14.5, 800)),
          ]),
          if (share != null) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(value: (share / 100).clamp(0, 1).toDouble(), minHeight: 5, color: kGreenText, backgroundColor: const Color(0xFFE6EFE0)),
            ),
          ],
        ]),
      );

  Widget _card(String title, List<Widget> rows, {String empty = 'Nothing in this period.'}) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: OrderCardBox(
          radius: 16,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: inter(15, 800)),
            if (rows.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(empty, style: inter(13.5, 400, color: kMuted))) else ...rows,
          ]),
        ),
      );

  /// Day-by-day bars (net sales or bookings).
  Widget _bars(List<SvcData> days, num Function(SvcData) value, String Function(num) label) {
    final max = days.fold<num>(0, (m, x) => value(x) > m ? value(x) : m);
    if (days.length < 2 || max == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: OrderCardBox(
        radius: 16,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('Day by day', style: inter(15, 800))),
            Text('Best: ${label(max)}', style: inter(12, 600, color: kMuted)),
          ]),
          const SizedBox(height: 10),
          SizedBox(
            height: 90,
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              for (final x in days)
                Expanded(
                  child: Tooltip(
                    message: '${_niceDay(x.s('day'))}: ${label(value(x))}',
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      height: 4 + 86 * (value(x) / max).toDouble(),
                      decoration: BoxDecoration(color: value(x) == 0 ? kLine : kGreenText, borderRadius: BorderRadius.circular(3)),
                    ),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
  }

  String _change(num now, num before) {
    if (before == 0) return now == 0 ? 'Same as before' : 'New this period';
    final pct = ((now - before) * 100 / before).round();
    return pct == 0 ? 'Same as the period before' : '${pct > 0 ? '↑' : '↓'} ${pct.abs()}% on the period before';
  }

  List<Widget> _content(SvcData d) {
    switch (widget.kind) {
      case 'sales':
        final t = d.m('totals');
        return [
          Entrance(index: 0, child: _tiles([
            ('Net sales', _rs(t.n('net_minor')), _change(t.n('net_minor'), d.m('previous').n('net_minor'))),
            ('Bills', '${t.i('bills')}', _change(t.n('bills'), d.m('previous').n('bills'))),
            ('Average bill', _rs(t.n('average_minor')), null),
            ('Collected', _rs(t.n('collected_minor')), 'Payments taken'),
            ('Gross', _rs(t.n('gross_minor')), null),
            ('Discounts', _rs(t.n('discount_minor')), null),
            ('GST', _rs(t.n('gst_minor')), null),
            ('Refunds', _rs(t.n('refunds_minor')), '${t.i('refunds')} ${t.i('refunds') == 1 ? 'refund' : 'refunds'}'),
          ])),
          Entrance(index: 1, child: _bars(d.l('days'), (x) => x.n('net_minor'), _rs)),
          Entrance(index: 2, child: _card('Bills', [
            for (final b in d.l('bills')) _row('${b.s('no')} · ${b.s('customer').isEmpty ? 'Walk-in' : b.s('customer')}', '${b.s('when')} · ${b.s('methods').toUpperCase()}', _rs(b.n('total_minor'))),
          ])),
        ];
      case 'services':
        final top = d.l('services').where((s) => s.n('qty') > 0).toList();
        return [
          Entrance(index: 0, child: _tiles([
            ('Revenue', _rs(d.n('total_minor')), null),
            ('Services sold', '${d.n('qty')}', '${top.length} different ${top.length == 1 ? 'service' : 'services'}'),
          ])),
          Entrance(index: 1, child: _card('Every service', [
            for (final s in d.l('services'))
              _row(s.s('name'), '${s.s('category')} · ${s.n('qty')} sold · ${s.n('bills')} ${s.n('bills') == 1 ? 'bill' : 'bills'}', _rs(s.n('revenue_minor')),
                  share: s.n('share_pct'), key: ValueKey('svc-row-${s.s('name')}')),
          ])),
          if (d.l('unsold').isNotEmpty)
            Entrance(index: 2, child: _card('Not sold in this period', [for (final u in d.l('unsold')) _row(u.s('name'), u.s('category'), '0')])),
        ];
      case 'categories':
        return [
          Entrance(index: 0, child: _tiles([('Revenue', _rs(d.n('total_minor')), null), ('Categories', '${d.l('categories').length}', null)])),
          Entrance(index: 1, child: _card('By category', [
            for (final c in d.l('categories'))
              _row(c.s('name'), [for (final s in c.l('services')) '${s.s('name')} ${s.n('qty')}'].join(' · '), _rs(c.n('revenue_minor')), share: c.n('share_pct')),
          ])),
          if (d.ls('unsold').isNotEmpty) Entrance(index: 2, child: _card('Nothing sold', [for (final u in d.ls('unsold')) _row(u, '', '0')])),
        ];
      case 'bookings':
        return [
          Entrance(index: 0, child: _tiles([
            ('Bookings', '${d.i('total')}', '${d.i('online')} online · ${d.i('offline')} offline'),
            ('Completed', '${d.i('completed')}', null),
            ('Upcoming', '${d.i('upcoming')}', null),
            ('Cancelled', '${d.i('cancelled')}', null),
            ('No-shows', '${d.i('no_show')}', '${d.n('no_show_pct')}% of visits due'),
            ('Job visits', '${d.i('job_visits')}', 'At customers\' places'),
          ])),
          Entrance(index: 1, child: _bars(d.l('days'), (x) => x.n('booked'), (v) => '${v.round()} booked')),
        ];
      case 'staff':
        return [
          Entrance(index: 0, child: _card('Each person', empty: 'No service providers yet.', [
            for (final p in d.l('staff'))
              _row(p.s('title').isEmpty ? p.s('name') : '${p.s('name')} · ${p.s('title')}',
                  '${p.i('bookings')} bookings · ${p.i('completed')} completed · ${(p.n('minutes') / 60).toStringAsFixed(1)} hrs · ${p.i('no_show')} no-shows · ${p.i('cancelled')} cancelled',
                  _rs(p.n('revenue_minor')), key: ValueKey('staff-row-${p.s('name')}')),
          ])),
        ];
      case 'payments':
        final total = d.n('total_minor');
        return [
          Entrance(index: 0, child: _tiles([('Collected', _rs(total), null), ('Refunds', _rs(d.n('refunds_minor')), '${d.i('refunds')} ${d.i('refunds') == 1 ? 'refund' : 'refunds'}')])),
          Entrance(index: 1, child: _card('By method', [
            for (final m in d.l('methods'))
              _row(_methods[m.s('method')] ?? m.s('method'), '${m.i('count')} ${m.i('count') == 1 ? 'payment' : 'payments'}', _rs(m.n('amount_minor')),
                  share: total == 0 ? 0 : m.n('amount_minor') * 100 / total),
          ])),
        ];
      case 'dues':
        return [
          Entrance(index: 0, child: _tiles([('Owed to you', _rs(d.n('total_minor')), null), ('Bills', '${d.i('bills')}', 'All open bills, not just this period')])),
          Entrance(index: 1, child: _card('Oldest first', empty: 'Nobody owes you anything.', [
            for (final b in d.l('list'))
              _row('${b.s('customer').isEmpty ? 'Walk-in' : b.s('customer')} · ${b.s('no')}',
                  '${b.s('phone').isEmpty ? '' : '${svcPhone(b.s('phone'))} · '}since ${b.s('since')} · ${b.i('days')} ${b.i('days') == 1 ? 'day' : 'days'}', _rs(b.n('due_minor'))),
          ])),
        ];
      case 'discounts':
        return [
          Entrance(index: 0, child: _tiles([('Discounts given', _rs(d.n('total_minor')), null), ('Bills', '${d.i('bills')}', 'with a discount')])),
          Entrance(index: 1, child: _card('Every discount', [
            for (final b in d.l('list'))
              _row('${b.s('no')} · ${b.s('customer').isEmpty ? 'Walk-in' : b.s('customer')}', '${b.s('when')} · ${b.n('pct')}% off ${_rs(b.n('gross_minor'))}', _rs(b.n('discount_minor'))),
          ])),
        ];
      default:
        final refunds = d.l('refunds');
        return [
          Entrance(index: 0, child: _tiles([
            ('Cancelled or no-show', '${d.l('bookings').length}', 'bookings'),
            ('Bills cancelled', '${d.i('bills_cancelled')}', null),
            ('Refunds', _rs(refunds.fold<num>(0, (s, r) => s + r.n('amount_minor'))), '${refunds.length} ${refunds.length == 1 ? 'refund' : 'refunds'}'),
          ])),
          Entrance(index: 1, child: _card('Bookings', [
            for (final b in d.l('bookings'))
              _row('${b.s('customer')} · ${b.s('no')}', '${b.s('when')}${b.s('reason').isEmpty ? '' : ' · ${b.s('reason')}'}${b.b('deposit_kept') ? ' · advance kept' : ''}', b.s('state')),
          ])),
          Entrance(index: 2, child: _card('Refunds', [
            for (final r in refunds) _row(r.s('reason').isEmpty ? 'Refund' : r.s('reason'), '${r.s('when')} · ${(_methods[r.s('method')] ?? r.s('method'))}', _rs(r.n('amount_minor'))),
          ])),
        ];
    }
  }
}

/// A day as the report file name wants it (YYYY-MM-DD).
String _dayOf(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
