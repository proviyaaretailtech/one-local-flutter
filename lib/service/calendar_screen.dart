import 'package:flutter/material.dart';

import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'booking_screen.dart';
import 'service_api.dart';
import 'service_widgets.dart';

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Figma "Appointment Calendar": week strip, the day's counts and the day's appointments. Every label and count is the server's.
class ServiceCalendarScreen extends StatefulWidget {
  const ServiceCalendarScreen({super.key, this.api, this.onNavigate, this.initialDate, this.initials});
  final ServiceApi? api;
  final ValueChanged<String>? onNavigate;
  final DateTime? initialDate;
  final String? initials;
  @override
  State<ServiceCalendarScreen> createState() => _ServiceCalendarScreenState();
}

class _ServiceCalendarScreenState extends State<ServiceCalendarScreen> {
  late final ServiceApi _api = widget.api ?? ServiceApi();
  late DateTime _date = widget.initialDate ?? DateTime.now();
  String _view = 'day';
  String? _staffId;
  CalendarData? _data;
  String? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mine = ++_seq;
    setState(() => _error = null);
    try {
      final d = await _api.calendar(date: _iso(_date), view: _view, staffId: _staffId);
      if (!mounted || mine != _seq) return;
      setState(() => _data = d);
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _pickProvider() async {
    final d = _data;
    if (d == null) return;
    final picked = await showOrderSheet<String>(context, title: 'Providers', body: (ctx) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(contentPadding: EdgeInsets.zero, title: Text('All providers', style: inter(15, _staffId == null ? 700 : 400)), onTap: () => Navigator.pop(ctx, '')),
        for (final p in d.providers)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${p['name']}', style: inter(15, p['staff_id'] == _staffId ? 700 : 400)),
            subtitle: (p['title'] ?? '').toString().isEmpty ? null : Text('${p['title']}', style: inter(12.5, 400, color: kMuted)),
            onTap: () => Navigator.pop(ctx, '${p['staff_id']}'),
          ),
      ]);
    });
    if (picked == null) return;
    _staffId = picked.isEmpty ? null : picked;
    _load();
  }

  Future<void> _book() async {
    final booked = await Navigator.of(context).push<AppointmentView>(MaterialPageRoute(builder: (_) => ServiceBookingScreen(api: _api, date: _date, business: _data?.business ?? '', location: _data?.locationName ?? '', initials: widget.initials)));
    if (booked != null && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final subtitle = d == null ? '' : [d.dateLabel, if (d.locationName.isNotEmpty) d.locationName].join(' · ');
    final staffName = d?.providers.where((p) => p['staff_id'] == _staffId).map((p) => '${p['name']}').firstOrNull;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        ServiceTopBar(business: d == null ? '' : [d.business, if (d.city.isNotEmpty) d.city].where((e) => e.isNotEmpty).join(' · '), initials: widget.initials, onBack: Navigator.canPop(context) ? () => Navigator.maybePop(context) : null),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 16), children: [
              Text('Appointment Calendar', style: inter(30, 700, height: 1.15)),
              const SizedBox(height: 8),
              Text(subtitle, style: inter(14, 400, color: kMuted)),
              const SizedBox(height: 16),
              Row(children: [
                ModeChip('Day', selected: _view == 'day', onTap: () {
                  _view = 'day';
                  _load();
                }),
                const SizedBox(width: 8),
                ModeChip('Week', selected: _view == 'week', onTap: () {
                  _view = 'week';
                  _load();
                }),
                const SizedBox(width: 8),
                ModeChip(staffName ?? 'All providers', selected: _staffId != null, onTap: _pickProvider),
              ]),
              const SizedBox(height: 16),
              if (d != null) _weekStrip(d),
              if (_error != null) ...[
                const SizedBox(height: 16),
                OrderCardBox(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_error!, style: inter(13.5, 500)),
                  const SizedBox(height: 8),
                  SmallPill('Try again', onTap: _load),
                ])),
              ] else if (d == null)
                const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kGreenText)))
              else ...[
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(child: _tile('Appointments', '${d.appointments}', _view == 'day' ? 'Today' : 'This week', kLink)),
                  const SizedBox(width: 12),
                  Expanded(child: _tile('Available slots', '${d.availableSlots}', '${d.providerCount} ${d.providerCount == 1 ? 'provider' : 'providers'}', kLink)),
                ]),
                const SizedBox(height: 24),
                Row(children: [
                  Expanded(child: Text(_view == 'day' ? 'Today’s appointments' : 'This week’s appointments', style: inter(18, 700))),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: kLine)),
                    child: Text('${d.items.length} scheduled', style: inter(13, 500, color: kMuted)),
                  ),
                ]),
                const SizedBox(height: 14),
                if (d.items.isEmpty) OrderCardBox(child: Text('No appointments yet. Tap Book appointment to add one.', style: inter(14, 400, color: kMuted))),
                for (final a in d.items) ...[
                  _card(a),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 6),
                DarkCta(label: '+ Book appointment', onPressed: _book),
              ],
            ]),
          ),
        ),
        PosBottomNav(active: 'bill', onTap: (id) => id == 'bill' ? null : (widget.onNavigate ?? (_) => showToast(context, 'That part of the app is not built yet.'))(id)),
      ]),
    );
  }

  Widget _weekStrip(CalendarData d) => Row(children: [
        for (final w in d.week) ...[
          Expanded(
            child: Semantics(
              button: true,
              selected: w['selected'] == true,
              label: '${w['weekday']} ${w['day']}',
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  _date = DateTime.parse('${w['date']}');
                  _load();
                },
                child: ExcludeSemantics(
                  child: Container(
                    height: 70,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(color: w['selected'] == true ? kPrimary : Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Text('${w['weekday']}', style: inter(12, 400, color: w['selected'] == true ? kLime : kMuted)),
                      const SizedBox(height: 6),
                      Text('${w['day']}', style: inter(20, 700, color: w['selected'] == true ? Colors.white : kInk)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ],
      ]);

  Widget _tile(String label, String value, String note, Color noteColor) => OrderCardBox(
        radius: 16,
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: inter(13, 400, color: kMuted)),
          const SizedBox(height: 8),
          Text(value, style: inter(28, 700)),
          const SizedBox(height: 6),
          Text(note, style: inter(12.5, 400, color: noteColor)),
        ]),
      );

  Widget _card(AppointmentView a) => InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => showToast(context, 'Appointment details come in a later release.'),
        child: OrderCardBox(
          radius: 18,
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${a.timeLabel} · ${a.title}', style: inter(16, 700)),
            const SizedBox(height: 10),
            ApptStatusChip(label: a.statusLabel, tone: a.tone),
            const SizedBox(height: 12),
            _row('Customer', a.customer),
            _row('Provider', a.resource == null ? a.provider : '${a.provider} · ${a.resource}'),
          ]),
        ),
      );

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 110, child: Text(k, style: inter(14, 400, color: kMuted))),
          Expanded(child: Text(v, style: inter(14.5, 600))),
        ]),
      );
}
