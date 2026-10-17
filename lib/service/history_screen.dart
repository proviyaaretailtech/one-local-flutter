import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'service_api.dart';
import 'service_menu.dart';
import 'service_widgets.dart';
import 'visit_screens.dart';

const _typeLabel = {'appointment': 'Appointment', 'event': 'Event tickets', 'on_location': 'On-location', 'on_demand': 'On-demand'};
const _statusOptions = [('all', 'All statuses'), ('upcoming', 'Upcoming'), ('completed', 'Completed'), ('cancelled', 'Cancelled')];

/// Figma 108 "Service History": every visit, filtered by type, period, status and provider, searchable; export as CSV.
class ServiceHistoryScreen extends StatefulWidget {
  const ServiceHistoryScreen({super.key, required this.api, this.business = '', this.onNavigate});
  final ServiceApi api;
  final String business;
  final ValueChanged<String>? onNavigate;
  @override
  State<ServiceHistoryScreen> createState() => _ServiceHistoryScreenState();
}

class _ServiceHistoryScreenState extends State<ServiceHistoryScreen> {
  HistoryData? _d;
  String? _error;
  String _q = '', _type = '', _status = 'all', _period = 'this_month';
  String? _staff;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mine = ++_seq;
    try {
      final d = await widget.api.history(filter: _status, q: _q, fulfilment: _type.isEmpty ? null : _type, staffId: _staff, period: _period);
      if (mounted && mine == _seq) setState(() { _d = d; _error = null; });
    } catch (e) {
      if (mounted && mine == _seq) setState(() => _error = e.toString());
    }
  }

  Future<void> _pick(String title, List<(String, String)> options, String current, ValueChanged<String> set) async {
    final v = await showOrderSheet<String>(context, title: title, body: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
          for (final (id, label) in options)
            ListTile(contentPadding: EdgeInsets.zero, title: Text(label, style: inter(15, id == current ? 700 : 500)), onTap: () => Navigator.pop(ctx, id)),
        ]));
    if (v == null) return;
    set(v);
    _load();
  }

  Future<void> _export() async {
    final d = _d;
    if (d == null || d.items.isEmpty) {
      showToast(context, 'Nothing to export.');
      return;
    }
    String q(String s) => '"${s.replaceAll('"', '""')}"';
    final rows = [
      'Booking,Service,Status,Customer,Provider,Date,Time,Total,Paid,Refunded,Order',
      for (final a in d.items)
        [a.displayNo, a.title, a.statusLabel, a.customer, a.provider, a.dateLabel, a.timeLabel, '${a.n('total')}', '${a.n('paid')}', '${a.n('refunded')}', a.s('order_no')].map(q).join(','),
    ];
    await Clipboard.setData(ClipboardData(text: rows.join('\n')));
    if (mounted) showToast(context, '${d.items.length} records copied as CSV. Paste them into a sheet or a message.');
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final staffName = d?.providers.where((p) => p.s('staff_id') == _staff).map((p) => p.s('name')).firstOrNull;
    return ServicePage(
      title: 'Service History',
      subtitle: d == null ? '' : 'All service activity · ${_period == 'this_month' ? d.monthLabel : 'All time'}',
      business: widget.business,
      onMenu: () => showServiceMenu(context, widget.api, business: widget.business, onNavigate: widget.onNavigate, current: 'history'),
      onNavigate: widget.onNavigate,
      onRefresh: _load,
      error: _error,
      onRetry: _load,
      body: d == null
          ? null
          : [
              SvcSearch(hint: 'Search customer, booking or service...', fieldKey: const ValueKey('history-search'), onChanged: (v) {
                _q = v;
                _load();
              }),
              const SizedBox(height: 14),
              SvcChips(options: const [('', 'All'), ('appointment', 'Appointment'), ('event', 'Event'), ('on_location', 'On-location')], selected: _type, onSelect: (v) {
                _type = v;
                _load();
              }),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  ModeChip(_period == 'this_month' ? 'This month' : 'All time', selected: true,
                      onTap: () => _pick('Period', const [('this_month', 'This month'), ('all', 'All time')], _period, (v) => _period = v)),
                  ModeChip(_statusOptions.firstWhere((s) => s.$1 == _status).$2, selected: _status != 'all', onTap: () => _pick('Status', _statusOptions, _status, (v) => _status = v)),
                  ModeChip(staffName ?? 'All providers', selected: _staff != null,
                      onTap: () => _pick('Provider', [('', 'All providers'), for (final p in d.providers) (p.s('staff_id'), p.s('name'))], _staff ?? '', (v) => _staff = v.isEmpty ? null : v)),
                ]),
              ),
              SvcSectionHead('Recent activity', count: '${d.total} ${d.total == 1 ? 'record' : 'records'}'),
              if (d.items.isEmpty) OrderCardBox(child: Text('No service activity matches.', style: inter(14, 400, color: kMuted))),
              for (final a in d.items) _card(a),
              DarkCta(label: 'Export service history', onPressed: _export),
            ],
    );
  }

  Widget _card(AppointmentView a) {
    final cancelled = a.status == 'cancelled' || a.status == 'no_show';
    final refunded = a.n('refunded') > 0;
    final at = DateTime.tryParse(a.s('refunded_at'))?.toLocal();
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return SvcCard(
      title: '${a.displayNo} · ${a.title}',
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AppointmentDetailScreen(api: widget.api, id: a.id, business: widget.business, onNavigate: widget.onNavigate)));
        if (mounted) _load();
      },
      children: [
        Align(alignment: Alignment.centerLeft, child: svcStatus('${a.statusLabel.split(' · ').first} · ${a.s('money_label')}', a.status == 'completed' ? 'good' : cancelled ? 'bad' : 'info')),
        const SizedBox(height: 8),
        SvcKV('Customer', a.customer, labelWidth: 140),
        SvcKV(a.fulfilment == 'event' ? 'Host' : 'Provider', a.provider, labelWidth: 140),
        if (cancelled && refunded) ...[
          SvcKV('Refund', '${svcRupees(a.n('refunded'))}${at == null ? '' : ' · ${at.day} ${months[at.month - 1]}'}', labelWidth: 140),
          SvcKV('Original session', '${a.dateLabel} · ${a.timeLabel}', labelWidth: 140),
        ] else ...[
          SvcKV('When', '${a.dateLabel} · ${a.timeLabel}', labelWidth: 140),
          SvcKV('Amount', '${svcRupees(a.n('total'))} · ${_typeLabel[a.fulfilment] ?? 'Appointment'}', labelWidth: 140),
        ],
      ],
    );
  }
}
