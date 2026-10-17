import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'service_api.dart';
import 'service_widgets.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _monthsLong = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
String _clock(DateTime t) => '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
String _dayTime(DateTime t) => '${t.day} ${_months[t.month - 1]}, ${_clock(t)}';
DateTime? _at(Object? v) => DateTime.tryParse('${v ?? ''}')?.toLocal();
String _typeTag(String f) => switch (f) { 'on_location' => 'On-location', 'event' => 'Event', 'on_demand' => 'On-demand', _ => 'Appointment' };
String _methodLabel(String m) => switch (m) { 'upi' => 'UPI', 'card' => 'Card', 'cash' => 'Cash', _ => m };

/// The header card of the visit frames: number + title, the people, and the fulfilment tag.
class _VisitHeader extends StatelessWidget {
  const _VisitHeader({required this.title, required this.sub, required this.tag});
  final String title, sub, tag;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: OrderCardBox(
          radius: 20,
          padding: const EdgeInsets.all(18),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: inter(18, 700)),
                const SizedBox(height: 4),
                Text(sub, style: inter(13.5, 400, color: kMuted)),
              ]),
            ),
            TagChip(tag),
          ]),
        ),
      );
}

Widget _chipLine(String label, String tone) => Padding(padding: const EdgeInsets.only(bottom: 14), child: Align(alignment: Alignment.centerLeft, child: svcStatus(label, tone)));

String _err(Object e) => e is ServiceApiException ? e.message : e.toString();

/// Figma 92 "Appointment Detail": who, when, where, the bill so far, notes, the booking history and the next step. The actions shown are
/// the ones the server allows now.
class AppointmentDetailScreen extends StatefulWidget {
  const AppointmentDetailScreen({super.key, required this.api, required this.id, this.business = '', this.onNavigate});
  final ServiceApi api;
  final String id, business;
  final ValueChanged<String>? onNavigate;
  @override
  State<AppointmentDetailScreen> createState() => _AppointmentDetailScreenState();
}

class _AppointmentDetailScreenState extends State<AppointmentDetailScreen> {
  AppointmentView? _a;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final a = await widget.api.get(widget.id);
      if (mounted) setState(() { _a = a; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = _err(e));
    }
  }

  Future<void> _act(String action, [Map<String, Object?> extra = const {}]) async {
    final a = _a!;
    setState(() => _busy = true);
    try {
      final r = await widget.api.act(a.id, action, version: a.version, extra: extra);
      if (mounted) setState(() => _a = r);
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
      if (e.stale) _load();
    } catch (e) {
      if (mounted) showToast(context, _err(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  Future<void> _primary() async {
    final a = _a!;
    if (a.can('pay_deposit')) {
      final pay = await pickPayment(context, title: 'Advance ${svcRupees(a.billData.n('deposit'))}', amount: a.billData.n('deposit'));
      if (pay != null) await _act('pay_deposit', {'method': pay.$1, 'tendered': pay.$2});
    } else if (a.can('check_in')) {
      if (a.onLocation) return _push(ServiceCheckInScreen(api: widget.api, appointment: a, business: widget.business, onNavigate: widget.onNavigate));
      await _act('check_in');
    } else if (a.can('start')) {
      await _act('start');
      if (mounted && _a?.status == 'in_service') return _push(ServiceExecutionScreen(api: widget.api, id: a.id, business: widget.business, onNavigate: widget.onNavigate));
    } else if (a.status == 'in_service') {
      return _push(ServiceExecutionScreen(api: widget.api, id: a.id, business: widget.business, onNavigate: widget.onNavigate));
    }
  }

  String? get _primaryLabel {
    final a = _a!;
    if (a.can('pay_deposit')) return 'Collect advance ${svcRupees(a.billData.n('deposit'))}';
    if (a.can('check_in')) return 'Check in customer';
    if (a.can('start')) return 'Start service';
    if (a.status == 'in_service') return 'Continue job';
    return null;
  }

  Future<void> _reschedule() async {
    final a = _a!;
    final service = a.lines.where((l) => l.s('kind') == 'service').firstOrNull;
    if (service == null) return;
    var day = DateTime.now().add(const Duration(days: 1));
    final picked = await showDatePicker(context: context, initialDate: day, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 120)));
    if (picked == null || !mounted) return;
    day = picked;
    final iso = '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    final slot = await showOrderSheet<Map<String, dynamic>>(context, title: 'New time', body: (ctx) => _Slots(
          api: widget.api,
          date: iso,
          serviceId: service.s('menu_item_id'),
          addonIds: [for (final l in a.lines) if (l.s('kind') == 'addon') l.s('menu_item_id')],
          staffId: a.m('provider').s('staff_id'),
        ));
    if (slot == null) return;
    await _act('reschedule', {'starts_at': slot['starts_at']});
    if (mounted && _a?.version != a.version) showToast(context, 'Moved to ${slot['range_label'] ?? slot['label']}.');
  }

  Future<void> _cancel() async {
    final a = _a!;
    final reason = await askText(context, 'Cancel ${a.displayNo}', hint: 'Reason (customer asked, ...)', action: 'Cancel appointment');
    if (reason == null || reason.length < 3) return;
    await _act('cancel', {'reason': reason});
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    return ServicePage(
      title: 'Appointment Detail',
      subtitle: a == null ? '' : '${a.displayNo} · ${a.onLocation ? 'Provider visits the customer' : 'Customer visits business'}',
      business: widget.business,
      onNavigate: widget.onNavigate,
      error: _error,
      onRetry: _load,
      onRefresh: _load,
      body: a == null ? null : _body(a),
    );
  }

  List<Widget> _body(AppointmentView a) {
    final b = a.billData;
    final deposits = a.payments;
    final first = deposits.firstOrNull;
    final label = _primaryLabel;
    return [
      _VisitHeader(title: a.displayNo, sub: [a.customer, if (a.customerPhone.isNotEmpty) svcPhone(a.customerPhone)].join(' · '), tag: _typeTag(a.fulfilment)),
      _chipLine(a.statusLabel, a.tone),
      SvcCard(title: a.title, children: [
        SvcKV('Provider', a.resource == null ? a.provider : '${a.provider} · ${a.resource}'),
        SvcKV('Schedule', '${a.dateLabel} · ${a.timeLabel}'),
        if (a.onLocation) SvcKV('Address', a.s('service_address')) else SvcKV('Location', a.location),
        SvcKV('Duration', '${a.durationMin} min${a.bufferMin > 0 ? ' · ${a.bufferMin} min buffer' : ''}'),
      ]),
      SvcCard(title: 'Payment', children: [
        SvcKV('Services', svcRupees(b.n('subtotal'))),
        if (b.n('discount') > 0) SvcKV('Discount', '−${svcRupees(b.n('discount'))}${a.credits.isNotEmpty ? ' · ${a.credits.first.s('plan')}' : ''}'),
        SvcKV('GST · ${b.n('gst_pct').toStringAsFixed(b.n('gst_pct') % 1 == 0 ? 0 : 1)}%', svcRupees(b.n('gst_amount'))),
        if (first != null) SvcKV(a.status == 'completed' ? 'Paid' : 'Deposit paid', '${svcRupees(b.n('paid'))} · ${_methodLabel(first.s('method'))} · ${_dayTime(_at(first.raw['at']) ?? DateTime.now())}'),
        if (b.n('refunded') > 0) SvcKV('Refunded', svcRupees(b.n('refunded'))),
        if (a.status != 'cancelled' && a.status != 'no_show') SvcKV('Balance due', '${svcRupees(b.n('due'))}${b.n('due') > 0 ? ' · Pay ${a.onLocation ? 'on completion' : 'at studio'}' : ''}'),
        const Divider(height: 22, color: kLine),
        Row(children: [Expanded(child: Text('Booking total', style: inter(18, 700))), Text(svcRupees(b.n('total')), style: inter(28, 800))]),
      ]),
      if (a.s('notes').isNotEmpty) SvcCard(title: 'Customer notes', children: [Text(a.s('notes'), style: inter(15, 400, height: 1.45))]),
      SvcCard(title: 'Booking history', children: [..._history(a)]),
      if (a.can('reschedule')) ...[LightCta(label: 'Reschedule appointment', onPressed: _busy ? null : _reschedule), const SizedBox(height: 12)],
      if (label != null) DarkCta(label: label, busy: _busy, onPressed: _busy ? null : _primary),
      if (a.status == 'in_service') ...[
        const SizedBox(height: 12),
        LightCta(
            label: 'Go to billing',
            onPressed: () => _push(ServiceBillingScreen(api: widget.api, id: a.id, business: widget.business, onNavigate: widget.onNavigate))),
      ],
      if (a.can('cancel') || a.can('no_show'))
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Wrap(alignment: WrapAlignment.center, spacing: 16, children: [
            if (a.can('cancel')) UnderLink('Cancel appointment', onTap: _busy ? null : _cancel),
            if (a.can('no_show')) UnderLink('Mark no-show', onTap: _busy ? null : () => _act('no_show')),
          ]),
        ),
    ];
  }

  Iterable<Widget> _history(AppointmentView a) sync* {
    const titles = {
      'appointment_booked': 'Booking created',
      'entitlement_redeemed': 'Package applied',
      'part_paid': 'Payment received',
      'paid': 'Paid in full',
      'appointment_pay_deposit': 'Deposit received',
      'appointment_reschedule': 'Rescheduled',
      'arrival_confirmation_requested': 'Confirmation requested',
      'appointment_check_in': 'Customer checked in',
      'appointment_start': 'Service started',
      'extra_added': 'Extra charge added',
      'appointment_completed': 'Completed and billed',
      'appointment_cancel': 'Cancelled',
      'appointment_no_show': 'No-show',
      'advance_retained': 'Advance kept',
      'refunded': 'Refunded',
    };
    for (final e in a.events) {
      final t = titles[e.s('kind')];
      if (t == null) continue;
      final at = _at(e.raw['at']);
      final who = e.s('actor');
      yield _step(t, [if (at != null) _dayTime(at), if (who.isNotEmpty) who else if (e.s('kind') == 'appointment_booked') a.customer].join(' · '), done: true);
    }
    final start = _at(a.raw['starts_at']);
    if (a.status == 'confirmed' && start != null) yield _step('Customer check-in', 'Expected ${_dayTime(start)}', done: false);
    if (a.status == 'checked_in') yield _step('Service start', 'Next', done: false);
  }

  Widget _step(String title, String sub, {required bool done}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: done ? kChipGreen : const Color(0xFFF3F4F1), shape: BoxShape.circle, border: Border.all(color: done ? kChipGreen : kLine)),
            child: Icon(done ? LucideIcons.check : LucideIcons.circle, size: 16, color: done ? kLink : kMuted),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: inter(15.5, 600)),
              const SizedBox(height: 2),
              Text(sub, style: inter(13, 400, color: kMuted)),
            ]),
          ),
        ]),
      );
}

/// Free start times for a reschedule (same service, add-ons and provider).
class _Slots extends StatefulWidget {
  const _Slots({required this.api, required this.date, required this.serviceId, required this.addonIds, required this.staffId});
  final ServiceApi api;
  final String date, serviceId, staffId;
  final List<String> addonIds;
  @override
  State<_Slots> createState() => _SlotsState();
}

class _SlotsState extends State<_Slots> {
  List<Map<String, dynamic>>? _slots;
  String? _error;
  @override
  void initState() {
    super.initState();
    widget.api.slots(date: widget.date, serviceId: widget.serviceId, addonIds: widget.addonIds, staffId: widget.staffId).then((d) {
      if (mounted) setState(() => _slots = d.expand((p) => p.slots).toList());
    }).catchError((Object e) {
      if (mounted) setState(() => _error = _err(e));
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Text(_error!, style: inter(14, 400, color: kMuted));
    final s = _slots;
    if (s == null) return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(color: kGreenText)));
    if (s.isEmpty) return Text('No free time that day. Try another date.', style: inter(14, 400, color: kMuted));
    return Wrap(spacing: 8, runSpacing: 8, children: [for (final x in s) SmallPill('${x['label']}', onTap: () => Navigator.pop(context, x))]);
  }
}

/// Four boxes for the 4-digit arrival code.
class _CodeBoxes extends StatelessWidget {
  const _CodeBoxes({required this.controller});
  final TextEditingController controller;
  @override
  Widget build(BuildContext context) => Stack(alignment: Alignment.center, children: [
        ValueListenableBuilder(
          valueListenable: controller,
          builder: (_, v, _) => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < 4; i++)
              Container(
                width: 64,
                height: 64,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                alignment: Alignment.center,
                decoration: BoxDecoration(color: const Color(0xFFF1F1EC), borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
                child: Text(i < v.text.length ? v.text[i] : '', style: inter(28, 700)),
              ),
          ]),
        ),
        Positioned.fill(
          child: Opacity(
            opacity: 0.01,
            child: TextField(
              key: const ValueKey('arrival-code'),
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
              decoration: const InputDecoration(border: InputBorder.none, counterText: ''),
            ),
          ),
        ),
      ]);
}

/// Figma 103 "Service Check-In": an on-location job's arrival is verified with the customer's 4-digit code, or with the customer's
/// confirmation after a request; then the job starts.
class ServiceCheckInScreen extends StatefulWidget {
  const ServiceCheckInScreen({super.key, required this.api, required this.appointment, this.business = '', this.onNavigate, this.now});
  final ServiceApi api;
  final AppointmentView appointment;
  final String business;
  final ValueChanged<String>? onNavigate;
  final DateTime? now;
  @override
  State<ServiceCheckInScreen> createState() => _ServiceCheckInScreenState();
}

class _ServiceCheckInScreenState extends State<ServiceCheckInScreen> {
  late AppointmentView _a = widget.appointment;
  String _mode = 'otp';
  final _code = TextEditingController();
  bool _busy = false;
  bool _requested = false;

  DateTime get _now => widget.now ?? DateTime.now();

  String get _arrival {
    final s = _at(_a.raw['starts_at']), e = _at(_a.raw['ends_at']);
    if (s == null || e == null) return _clock(_now);
    final within = !_now.isBefore(s.subtract(const Duration(minutes: 15))) && !_now.isAfter(e);
    final late = _now.difference(s).inMinutes;
    return '${_clock(_now)} · ${within ? 'Within booked slot' : (late > 0 ? '$late min late' : 'Early')}';
  }

  Future<void> _request() async {
    setState(() => _busy = true);
    try {
      _a = await widget.api.jobUpdate(_a.id, version: _a.version, key: ServiceApi.newKey(), requestConfirmation: true);
      if (!mounted) return;
      setState(() { _requested = true; _mode = 'confirmation'; });
      showToast(context, 'Confirmation request recorded. Ask ${_a.customer} to confirm in person.');
    } catch (e) {
      if (mounted) showToast(context, _err(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    if (_mode == 'otp' && _code.text.length != 4) {
      showToast(context, 'Enter the 4-digit code.');
      return;
    }
    setState(() => _busy = true);
    try {
      var a = await widget.api.act(_a.id, 'check_in', version: _a.version, extra: _mode == 'otp' ? {'verification': 'otp', 'code': _code.text} : {'verification': 'confirmation'});
      a = await widget.api.act(a.id, 'start', version: a.version);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ServiceExecutionScreen(api: widget.api, id: a.id, business: widget.business, onNavigate: widget.onNavigate)));
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (e) {
      if (mounted) showToast(context, _err(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    final first = a.customer.split(' ').first;
    return ServicePage(
      title: 'Service Check-In',
      subtitle: 'Arrival verification · ${_now.day} ${_months[_now.month - 1]} ${_now.year}, ${_clock(_now)}',
      business: widget.business,
      onNavigate: widget.onNavigate,
      body: [
        _VisitHeader(title: '${a.displayNo} · ${a.title}', sub: '${a.provider} · ${a.customer}', tag: _typeTag(a.fulfilment)),
        _chipLine('Arrived · Verification needed', 'warn'),
        SvcCard(title: 'Customer location', children: [
          SvcKV('Address', a.s('service_address')),
          if (a.s('access_note').isNotEmpty) SvcKV('Access', a.s('access_note')),
          SvcKV('Arrival', _arrival),
        ]),
        SvcChips(options: const [('otp', 'Customer OTP'), ('confirmation', 'Customer confirmation')], selected: _mode, onSelect: (v) => setState(() => _mode = v)),
        if (_mode == 'otp')
          SvcCard(title: 'Enter the customer’s arrival OTP', children: [
            Text('Ask $first for the 4-digit code shared at booking${a.customerPhone.isEmpty ? '' : ' (${svcPhone(a.customerPhone)})'}. This confirms arrival, not payment.',
                style: inter(14.5, 400, color: kMuted, height: 1.45)),
            const SizedBox(height: 16),
            _CodeBoxes(controller: _code),
          ])
        else
          SvcCard(title: 'Customer confirmation', children: [
            Text(_requested ? '$first has been asked to confirm. Verify once they confirm in person.' : 'Request $first’s confirmation first, then verify.', style: inter(14.5, 400, color: kMuted, height: 1.45)),
          ]),
        SvcInfo(title: 'Customer confirmation is supported', text: 'If OTP is unavailable, send $first an arrival confirmation request.'),
        LightCta(label: 'Request customer confirmation', onPressed: _busy ? null : _request),
        const SizedBox(height: 12),
        DarkCta(label: 'Verify arrival & start job', busy: _busy, onPressed: _busy ? null : _verify),
      ],
    );
  }
}

/// Figma 104 "Service Execution": the job checklist, materials and extra charges the customer approved, the provider's notes; then billing.
class ServiceExecutionScreen extends StatefulWidget {
  const ServiceExecutionScreen({super.key, required this.api, required this.id, this.business = '', this.onNavigate});
  final ServiceApi api;
  final String id, business;
  final ValueChanged<String>? onNavigate;
  @override
  State<ServiceExecutionScreen> createState() => _ServiceExecutionScreenState();
}

class _ServiceExecutionScreenState extends State<ServiceExecutionScreen> {
  AppointmentView? _a;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final a = await widget.api.get(widget.id);
      if (mounted) setState(() { _a = a; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = _err(e));
    }
  }

  Future<void> _update({List<String>? done, String? notes, List<Map<String, Object?>>? extras}) async {
    final a = _a!;
    setState(() => _busy = true);
    try {
      final r = await widget.api.jobUpdate(a.id, version: a.version, key: ServiceApi.newKey(), done: done, providerNotes: notes, extras: extras);
      if (mounted) setState(() => _a = r);
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
      if (e.stale) _load();
    } catch (e) {
      if (mounted) showToast(context, _err(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addExtra() async {
    Catalogue c;
    try {
      c = await widget.api.catalogue();
    } catch (e) {
      if (mounted) showToast(context, _err(e));
      return;
    }
    if (!mounted) return;
    final extra = await showOrderSheet<Map<String, Object?>>(context, title: 'Add material or charge', body: (ctx) => _ExtraForm(items: c.extras, customer: _a!.customer.split(' ').first));
    if (extra != null) await _update(extras: [extra]);
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    final started = a == null ? null : _at(a.raw['started_at']);
    return ServicePage(
      title: 'Service Execution',
      subtitle: a == null ? '' : '${a.displayNo} · ${a.provider}${started == null ? '' : ' · Started at ${_clock(started)}'}',
      business: widget.business,
      onNavigate: widget.onNavigate,
      error: _error,
      onRetry: _load,
      onRefresh: _load,
      body: a == null ? null : _body(a),
    );
  }

  List<Widget> _body(AppointmentView a) {
    final checks = a.checklist;
    final done = checks.where((c) => c.b('done')).length;
    final checkedIn = _at(a.raw['checked_in_at']);
    final materials = a.extras.where((x) => x.s('kind') == 'material').toList();
    final addons = a.lines.where((l) => l.s('kind') == 'addon').toList();
    final labour = a.extras.where((x) => x.s('kind') != 'material').toList();
    final open = checks.where((c) => !c.b('done')).firstOrNull;
    final first = a.customer.split(' ').first;
    num sum(List<SvcData> xs) => xs.fold<num>(0, (s, x) => s + x.n('amount'));
    return [
      _VisitHeader(
          title: a.title,
          sub: [a.customer, if (a.onLocation && a.s('service_address').isNotEmpty) a.s('service_address').split(',').last.trim().split(' ').first,
            if (checkedIn != null) a.s('arrival_verified_by') == 'otp' ? 'OTP verified ${_clock(checkedIn)}' : 'Checked in ${_clock(checkedIn)}'].join(' · '),
          tag: _typeTag(a.fulfilment)),
      _chipLine(a.status == 'in_service' ? 'In progress' : a.statusLabel, a.status == 'in_service' ? 'good' : a.tone),
      if (checks.isNotEmpty)
        SvcCard(title: 'Job checklist · $done of ${checks.length} done', children: [
          for (final c in checks)
            InkWell(
              key: ValueKey('check-${c.s('label')}'),
              onTap: c.b('done') || _busy ? null : () => _update(done: [c.s('label')]),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Row(children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(color: c.b('done') ? kCheck : Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: c.b('done') ? kCheck : kMuted)),
                    child: c.b('done') ? const Icon(LucideIcons.check, size: 15, color: kInk) : null,
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: Text(c.s('label'), style: inter(15, 400))),
                ]),
              ),
            ),
        ]),
      SvcCard(title: 'Before / after photos', children: [
        Text('No photos attached. Photo upload is not available in this release.', style: inter(14, 400, color: kMuted)),
      ]),
      SvcCard(title: 'Materials used', children: [
        if (materials.isEmpty) Text('None added.', style: inter(14, 400, color: kMuted)),
        for (final m in materials) SvcLine(m.s('name'), qty: '${m.i('qty')}×', amount: svcRupees(m.n('amount'))),
      ]),
      SvcCard(title: 'Extra charges', children: [
        SvcKV('Materials', materials.isEmpty ? '₹0 · None added' : '${svcRupees(sum(materials))} · Approved by $first at ${_clock(_at(materials.last.raw['approved_at']) ?? DateTime.now())}'),
        for (final ad in addons) SvcKV(ad.s('name'), '${svcRupees(ad.n('amount'))} · Selected at booking'),
        SvcKV('Labour extras', labour.isEmpty ? '₹0 · None added' : '${svcRupees(sum(labour))} · Approved by $first'),
        if (a.status == 'in_service') Align(alignment: Alignment.centerLeft, child: UnderLink('+ Add material or charge', onTap: _busy ? null : _addExtra)),
      ]),
      Text('Provider notes', style: inter(18, 700)),
      const SizedBox(height: 10),
      InkWell(
        key: const ValueKey('provider-notes'),
        onTap: a.status != 'in_service' || _busy
            ? null
            : () async {
                final t = await askText(context, 'Provider notes', initial: a.s('provider_notes'), lines: 3);
                if (t != null) await _update(notes: t);
              },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          margin: const EdgeInsets.only(bottom: 18),
          decoration: BoxDecoration(color: const Color(0xFFF1F1EC), borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
          child: Text(a.s('provider_notes').isEmpty ? 'Tap to add notes for the service record.' : a.s('provider_notes'), style: inter(15, 400, color: a.s('provider_notes').isEmpty ? kMuted : kInk)),
        ),
      ),
      if (open != null) SvcInfo(title: 'Complete: ${open.s('label')}', text: 'Finish the checklist and confirm with the customer before closure.'),
      DarkCta(
        label: 'Review job & complete',
        onPressed: a.status != 'in_service'
            ? null
            : () async {
                if (open != null) {
                  showToast(context, 'Finish the job checklist first (${checks.length - done} left).');
                  return;
                }
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServiceBillingScreen(api: widget.api, id: a.id, business: widget.business, onNavigate: widget.onNavigate)));
                if (mounted) _load();
              },
      ),
    ];
  }
}

class _ExtraForm extends StatefulWidget {
  const _ExtraForm({required this.items, required this.customer});
  final List<SvcData> items;
  final String customer;
  @override
  State<_ExtraForm> createState() => _ExtraFormState();
}

class _ExtraFormState extends State<_ExtraForm> {
  SvcData? _item;
  int _qty = 1;
  String _kind = 'material';
  bool _approved = false;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (widget.items.isEmpty) Text('Add materials to your catalogue first (Items).', style: inter(14, 400, color: kMuted)),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final it in widget.items) ModeChip('${it.s('name')} · ${svcRupees(it.n('price'))}', selected: _item?.s('id') == it.s('id'), onTap: () => setState(() => _item = it)),
          ]),
          const SizedBox(height: 12),
          SvcChips(options: const [('material', 'Material'), ('travel', 'Travel'), ('labour', 'Labour'), ('other', 'Other')], selected: _kind, onSelect: (v) => setState(() => _kind = v)),
          Row(children: [
            Expanded(child: Text('Quantity', style: inter(14.5, 500))),
            QtyStepper(name: _item?.s('name') ?? 'item', qty: _qty, onMinus: () => setState(() => _qty = (_qty - 1).clamp(1, 99)), onPlus: () => setState(() => _qty = (_qty + 1).clamp(1, 99))),
          ]),
          CheckboxListTile(
            key: const ValueKey('approved'),
            contentPadding: EdgeInsets.zero,
            value: _approved,
            onChanged: (v) => setState(() => _approved = v ?? false),
            title: Text('${widget.customer} approved this charge', style: inter(14.5, 500)),
          ),
          DarkCta(
            label: 'Add to the bill',
            onPressed: _item == null || !_approved ? null : () => Navigator.pop(context, {'menu_item_id': _item!.s('id'), 'qty': _qty, 'kind': _kind, 'approved_by_customer': true}),
          ),
        ]),
      );
}

/// Figma 105 "Service Billing": every charge, the final bill with GST and any package or membership discount, what was paid, the balance,
/// the tax split and GSTIN; then the payment through the same order and payment records as every sale.
class ServiceBillingScreen extends StatefulWidget {
  const ServiceBillingScreen({super.key, required this.api, required this.id, this.business = '', this.onNavigate});
  final ServiceApi api;
  final String id, business;
  final ValueChanged<String>? onNavigate;
  @override
  State<ServiceBillingScreen> createState() => _ServiceBillingScreenState();
}

class _ServiceBillingScreenState extends State<ServiceBillingScreen> {
  AppointmentView? _a;
  String? _error, _key;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final a = await widget.api.get(widget.id);
      if (mounted) setState(() { _a = a; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = _err(e));
    }
  }

  Future<void> _pay() async {
    final a = _a!;
    final due = a.billData.n('due');
    (String, num?)? pay;
    if (due > 0) {
      pay = await pickPayment(context, title: 'Collect ${svcRupees(due)}', amount: due);
      if (pay == null) return;
    }
    setState(() => _busy = true);
    _key ??= ServiceApi.newKey();
    try {
      final r = await widget.api.bill(a.id, method: pay?.$1, tendered: pay?.$2, version: a.version, key: _key!);
      if (!mounted) return;
      showToast(context, '${r.displayNo} completed${due > 0 ? ' · ${svcRupees(due)} collected' : ''}.');
      setState(() => _a = r);
      Navigator.of(context).pop(r);
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
      if (e.status < 500) _key = null;
      if (e.stale) _load();
    } catch (e) {
      if (mounted) showToast(context, _err(e)); // keep the key: the retry must not charge twice
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    final today = DateTime.now();
    return ServicePage(
      title: 'Service Billing',
      subtitle: a == null ? '' : 'Invoice ${a.m('order').s('display_no')} · ${today.day} ${_monthsLong[today.month - 1]} ${today.year}',
      business: widget.business,
      onNavigate: widget.onNavigate,
      error: _error,
      onRetry: _load,
      body: a == null ? null : _body(a),
    );
  }

  List<Widget> _body(AppointmentView a) {
    final b = a.billData;
    final due = b.n('due');
    final pct = b.n('gst_pct').toStringAsFixed(b.n('gst_pct') % 1 == 0 ? 0 : 1);
    final materials = a.extras.where((x) => x.s('kind') == 'material').toList();
    final plan = a.credits.firstOrNull?.s('plan');
    return [
      _VisitHeader(title: '${a.displayNo} · ${a.title.split(' + ').first}', sub: '${a.customer} · Provider: ${a.provider}', tag: _typeTag(a.fulfilment)),
      _chipLine(a.status == 'in_service' ? 'Ready for billing' : a.statusLabel, a.status == 'in_service' ? 'good' : a.tone),
      SvcCard(title: 'Service charges', children: [
        for (final l in a.lines) SvcLine(l.s('name'), qty: '${l.i('qty')}×', amount: l.b('covered') ? 'Prepaid' : svcRupees(l.n('amount'))),
        for (final x in a.extras) SvcLine(x.s('name'), qty: '${x.i('qty')}×', amount: svcRupees(x.n('amount'))),
      ]),
      SvcCard(children: [
        const Kick('Final bill'),
        const SizedBox(height: 8),
        KeyValue('Charges subtotal', svcRupees(b.n('subtotal')), size: 14),
        KeyValue('GST ($pct% on ${svcRupees(b.n('taxable'))})', svcRupees(b.n('gst_amount')), size: 14),
        if (b.n('service_charge') > 0) KeyValue('Service charge', svcRupees(b.n('service_charge')), size: 14),
        if (b.n('discount') > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2.5),
            child: Row(children: [
              Text('Discount', style: inter(14, 400, color: kLink)),
              if (plan != null) ...[const SizedBox(width: 8), TagChip(plan.toUpperCase())],
              const Spacer(),
              Text('−${svcRupees(b.n('discount'))}', style: inter(14, 600, color: kLink)),
            ]),
          ),
        const Divider(height: 20, color: kLine),
        Row(children: [Expanded(child: Text('Final total', style: inter(16, 700))), Text(svcRupees(b.n('total')), style: inter(26, 800, color: kLink))]),
        const SizedBox(height: 10),
        TenderBlock(
          label: b.n('paid') > 0 ? 'Paid to date · ${a.payments.length > 1 ? 'Advance + partial' : 'Advance'}' : 'Paid to date',
          amountText: svcRupees(b.n('paid')),
          chips: const [],
          changeLabel: 'Balance due',
          changeChip: 'FINAL',
          changeValue: svcRupees(due),
        ),
      ]),
      SvcCard(title: 'Approval & tax details', children: [
        if (materials.isNotEmpty)
          SvcKV('Materials', '${svcRupees(materials.fold<num>(0, (s, x) => s + x.n('amount')))} approved at ${_clock(_at(materials.last.raw['approved_at']) ?? DateTime.now())}', labelWidth: 120),
        if (b.n('discount') > 0) SvcKV('Discount', plan == null ? 'Applied at booking' : '$plan · Prepaid plan', labelWidth: 120),
        SvcKV('Tax split', 'CGST ${svcRupees(b.n('cgst'))} + SGST ${svcRupees(b.n('sgst'))}', labelWidth: 120),
        if (b.s('gstin').isNotEmpty) SvcKV('GSTIN', b.s('gstin'), labelWidth: 120),
      ]),
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Text(
            due > 0
                ? 'The final bill includes ${materials.isEmpty ? 'every charge' : 'approved materials'}. Share the invoice before collecting the remaining ${svcRupees(due)}.'
                : 'Nothing is left to pay. Completing closes the visit and its order.',
            style: inter(15, 400, color: kMuted, height: 1.45)),
      ),
      if (a.can('bill')) DarkCta(label: due > 0 ? 'Continue to payment · ${svcRupees(due)}' : 'Complete visit', busy: _busy, onPressed: _busy ? null : _pay),
    ];
  }
}
