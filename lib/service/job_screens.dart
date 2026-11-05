import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'bills_screen.dart';
import 'service_api.dart';
import 'service_widgets.dart';
import 'step_form.dart';

// Jobs (New job, 2 Nov 2026), the same for every kind of service: work with several services, a team, a date and start / end time (or
// "schedule later"), an arrival window and repeating visits. The job's bill is one ordinary bill in the Bill tab. Every amount, label and
// action is the server's (svc_job_save, svc_job_view, svc_job_act).

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
String _clock(TimeOfDay t) => '${t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod}:${t.minute.toString().padLeft(2, '0')} ${t.period == DayPeriod.am ? 'AM' : 'PM'}';
String _day(DateTime d) => '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]} ${d.year}';

/// The arrival window choices (minutes) and repeat choices, as the form shows them.
const kArrivalWindows = <(int, String)>[(0, 'None'), (30, '30 min'), (60, '1 hr'), (120, '2 hr')];
const kRepeats = <(String, String)>[('none', 'Does not repeat'), ('weekly', 'Every week'), ('fortnightly', 'Every 2 weeks'), ('monthly', 'Every month')];

/// New job: the customer and where, what the job is, services with quantities, a discount, when (or schedule later), arrival window,
/// repeating, the team, and the reminder to bill on closing. Pops the saved job.
class NewJobScreen extends StatefulWidget {
  const NewJobScreen({super.key, required this.api, this.date, this.today});
  final ServiceApi api;

  /// The day to start on (the Bookings tab's chosen day); [today] is the clock (tests pass a fixed one).
  final DateTime? date;
  final DateTime Function()? today;
  @override
  State<NewJobScreen> createState() => _NewJobScreenState();
}

class _NewJobScreenState extends State<NewJobScreen> {
  final _name = TextEditingController(), _phone = TextEditingController(), _address = TextEditingController();
  final _title = TextEditingController(), _instructions = TextEditingController(), _discount = TextEditingController();
  late DateTime _now = (widget.today ?? DateTime.now)();
  late DateTime _date = () {
    final d = widget.date ?? _now;
    final day = DateTime(d.year, d.month, d.day);
    return day.isBefore(DateTime(_now.year, _now.month, _now.day)) ? DateTime(_now.year, _now.month, _now.day) : day;
  }();
  TimeOfDay _start = const TimeOfDay(hour: 10, minute: 0), _end = const TimeOfDay(hour: 11, minute: 0);
  bool _later = false, _percent = false, _remind = true, _busy = false;
  int _window = 0, _count = 4, _step = 0; // _step: the step shown
  String _repeat = 'none';
  final _team = <String>{};
  final _qty = <String, int>{};
  Catalogue? _catalogue;
  String? _error, _key;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _address, _title, _instructions, _discount]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final c = await widget.api.catalogue();
      if (mounted) setState(() => (_catalogue = c, _error = null));
    } on ServiceApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load your services. Check the connection and try again.');
    }
  }

  List<ServiceOption> get _services => _catalogue?.services ?? const [];
  num get _gross => _services.fold<num>(0, (s, o) => s + o.price * (_qty[o.id] ?? 0));
  num get _off {
    final v = num.tryParse(_discount.text.trim()) ?? 0;
    return _percent ? (_gross * v / 100) : v;
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(_now.year, _now.month, _now.day), lastDate: _now.add(const Duration(days: 365)));
    if (d != null) setState(() => _date = d);
  }

  Future<void> _pickTime(bool start) async {
    final t = await showTimePicker(context: context, initialTime: start ? _start : _end);
    if (t == null) return;
    setState(() {
      if (start) {
        final length = (_end.hour * 60 + _end.minute) - (_start.hour * 60 + _start.minute);
        _start = t;
        final m = (t.hour * 60 + t.minute + (length > 0 ? length : 60)).clamp(0, 23 * 60 + 59);
        _end = TimeOfDay(hour: m ~/ 60, minute: m % 60); // the end moves with the start, keeping the length
      } else {
        _end = t;
      }
    });
  }

  /// The steps (founder, 4 Nov 2026: every Service POS form in steps).
  static const _steps = ['Customer', 'Services', 'Schedule', 'Team and billing'];

  /// Back to the step with what is missing, then say what it is.
  void _stop(int step, String message) {
    setState(() => _step = step);
    showToast(context, message);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return _stop(0, 'Enter the customer\'s name.');
    final phone = _phone.text.replaceAll(RegExp(r'\D'), '');
    if (phone.isNotEmpty && phone.length < 10) return _stop(0, 'Enter a 10-digit mobile number.');
    final lines = [for (final o in _services) if ((_qty[o.id] ?? 0) > 0) {'menu_item_id': o.id, 'qty': _qty[o.id]}];
    if (lines.isEmpty) return _stop(1, 'Add at least one service.');
    final d = num.tryParse(_discount.text.trim());
    if (_discount.text.trim().isNotEmpty && (d == null || d < 0 || (_percent && d > 100))) return _stop(1, 'Check the discount.');
    if (_off > _gross) return _stop(1, 'The discount is more than the bill.');
    if (!_later && (_end.hour * 60 + _end.minute) <= (_start.hour * 60 + _start.minute)) return _stop(2, 'The end time must be after the start time.');
    setState(() => _busy = true);
    _key ??= ServiceApi.newKey();
    try {
      final j = await widget.api.saveJob(
        key: _key!,
        customerName: name,
        customerPhone: phone,
        address: _address.text,
        title: _title.text,
        instructions: _instructions.text,
        lines: lines,
        discount: !_percent && (d ?? 0) > 0 ? d : null,
        discountPct: _percent && (d ?? 0) > 0 ? d : null,
        team: _team.toList(),
        scheduleLater: _later,
        date: _iso(_date),
        start: _hhmm(_start),
        end: _hhmm(_end),
        arrivalWindowMin: _window,
        repeat: _repeat,
        repeatCount: _count,
        remindInvoice: _remind,
      );
      if (mounted) Navigator.of(context).pop(j);
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
      if (e.status < 500) _key = null;
    } catch (_) {
      if (mounted) showToast(context, 'Could not reach the server. Try again: the job will not be made twice.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(String label, TextEditingController c, String key, {TextInputType? keyboard, int lines = 1, String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          key: ValueKey(key),
          controller: c,
          keyboardType: keyboard,
          inputFormatters: numberOnly(keyboard),
          minLines: lines,
          maxLines: lines,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: label, hintText: hint, filled: true, fillColor: Colors.white, isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kLine))),
        ),
      );

  /// A label with an on / off switch (a plain row: a ListTile's ink would be hidden by the white card).
  Widget _switch(String label, bool value, ValueChanged<bool> onChanged, String key) => Row(children: [
        Expanded(child: Text(label, style: inter(14.5, 600))),
        Switch(key: ValueKey(key), value: value, onChanged: onChanged),
      ]);

  Widget _box(String label, String value, String key, VoidCallback onTap, {IconData? icon}) => Expanded(
        child: InkWell(
          key: ValueKey(key),
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
            child: Row(children: [
              if (icon != null) ...[Icon(icon, size: 18, color: kMuted), const SizedBox(width: 8)],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: inter(12, 400, color: kMuted)),
                  const SizedBox(height: 2),
                  Text(value, style: inter(15, 600)),
                ]),
              ),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = _catalogue;
    // loading and a failed load keep the plain page; the steps start once the services are in (4 Nov 2026)
    if (c == null) return ServicePage(title: 'New job', subtitle: 'Work with one or more services, a team and a time', error: _error, onRetry: _load);
    return StepFormPage(
      title: 'New job',
      keyPrefix: 'job',
      steps: _steps,
      step: _step,
      onStep: (i) => setState(() => _step = i),
      lastLine: 'Last step: save the job',
      body: _stepBody(c),
      finish: DarkCta(label: 'Save job', busy: _busy, onPressed: _busy ? null : _save),
    );
  }

  List<Widget> _stepBody(Catalogue c) => switch (_step) {
        0 => [
            SvcCard(title: 'Customer', children: [
              _field('Customer name', _name, 'job-name'),
              _field('Mobile number', _phone, 'job-phone', keyboard: TextInputType.phone),
              _field('Address (where the work is)', _address, 'job-address', hint: 'Leave empty when the work is at your place'),
            ]),
            SvcCard(title: 'Job', children: [
              _field('Job title (optional)', _title, 'job-title', hint: 'e.g. AC repair and service'),
              _field('Instructions (optional)', _instructions, 'job-instructions', lines: 3, hint: 'e.g. Call before coming. Lift on the left.'),
            ]),
          ],
        1 => [
            SvcCard(children: [
              if (_services.isEmpty) Text('Add services in Catalogue first.', style: inter(14, 400, color: kMuted)),
              for (final o in _services) _serviceRow(o),
              const SizedBox(height: 10),
              Wrap(spacing: 8, children: [
                ModeChip('₹ off', key: const ValueKey('job-disc-rupees'), selected: !_percent, onTap: () => setState(() => _percent = false)),
                ModeChip('% off', key: const ValueKey('job-disc-percent'), selected: _percent, onTap: () => setState(() => _percent = true)),
              ]),
              const SizedBox(height: 10),
              _field(_percent ? 'Discount (%)' : 'Discount (₹)', _discount, 'job-discount', keyboard: TextInputType.number),
              KeyValue('Services', svcRupees(_gross), size: 14),
              if (_off > 0) KeyValue('Discount', '−${svcRupees(_off)}', size: 14, valueColor: kLink),
              KeyValue('Before tax', svcRupees((_gross - _off).clamp(0, double.infinity)), size: 15),
            ]),
          ],
        2 => [
            SvcCard(children: [
              _switch('Schedule later', _later, (v) => setState(() => _later = v), 'job-later'),
              if (!_later) ...[
                Row(children: [_box('Date', _day(_date), 'job-date', _pickDate, icon: LucideIcons.calendarDays)]),
                const SizedBox(height: 10),
                Row(children: [
                  _box('Start time', _clock(_start), 'job-start', () => _pickTime(true), icon: LucideIcons.clock),
                  const SizedBox(width: 10),
                  _box('End time', _clock(_end), 'job-end', () => _pickTime(false)),
                ]),
                const SizedBox(height: 10),
                Text('Arrival window', style: inter(14, 600)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final (m, l) in kArrivalWindows) ModeChip(l, key: ValueKey('window-$m'), selected: _window == m, onTap: () => setState(() => _window = m)),
                ]),
                const SizedBox(height: 10),
                Text('Repeating', style: inter(14, 600)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final (v, l) in kRepeats) ModeChip(l, key: ValueKey('repeat-$v'), selected: _repeat == v, onTap: () => setState(() => _repeat = v)),
                ]),
                if (_repeat != 'none')
                  Row(children: [
                    Expanded(child: Text('Number of visits', style: inter(14, 500))),
                    IconButton(key: const ValueKey('visits-less'), onPressed: _count <= 2 ? null : () => setState(() => _count--), icon: const Icon(LucideIcons.minus, size: 18)),
                    Text('$_count', style: inter(15, 700)),
                    IconButton(key: const ValueKey('visits-more'), onPressed: _count >= 12 ? null : () => setState(() => _count++), icon: const Icon(LucideIcons.plus, size: 18)),
                  ]),
              ],
            ]),
          ],
        _ => [
            SvcCard(title: 'Team', children: [
              if (c.providers.isEmpty) Text('Add staff in Team management first.', style: inter(14, 400, color: kMuted)),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final p in c.providers)
                  ModeChip(p.name, key: ValueKey('team-${p.id}'), selected: _team.contains(p.id), onTap: () => setState(() => _team.contains(p.id) ? _team.remove(p.id) : _team.add(p.id))),
              ]),
            ]),
            SvcCard(title: 'Billing', children: [
              _switch('Remind me to bill when I close the job', _remind, (v) => setState(() => _remind = v), 'job-remind'),
            ]),
          ],
      };

  Widget _serviceRow(ServiceOption o) {
    final q = _qty[o.id] ?? 0;
    return Container(
      key: ValueKey('jsvc-${o.id}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(o.name, style: inter(14.5, 600)),
            Text(svcRupees(o.price), style: inter(13, 400, color: kMuted)),
          ]),
        ),
        IconButton(key: ValueKey('jless-${o.id}'), onPressed: q == 0 ? null : () => setState(() => _qty[o.id] = q - 1), icon: const Icon(LucideIcons.minus, size: 18)),
        SizedBox(width: 24, child: Text('$q', textAlign: TextAlign.center, style: inter(15, 700))),
        IconButton(key: ValueKey('jmore-${o.id}'), onPressed: q >= 99 ? null : () => setState(() => _qty[o.id] = q + 1), icon: const Icon(LucideIcons.plus, size: 18)),
      ]),
    );
  }
}

/// One job: who, where, what, the team, every visit with Start / Complete, the bill, Close job and Cancel job.
class JobDetailScreen extends StatefulWidget {
  const JobDetailScreen({super.key, required this.api, required this.id, this.onNavigate});
  final ServiceApi api;
  final String id;
  final ValueChanged<String>? onNavigate;
  @override
  State<JobDetailScreen> createState() => _JobDetailScreenState();
}

class _JobDetailScreenState extends State<JobDetailScreen> {
  JobView? _j;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final j = await widget.api.job(widget.id);
      if (mounted) setState(() => (_j = j, _error = null));
    } on ServiceApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load the job. Check the connection and try again.');
    }
  }

  Future<void> _act(String action, {String? visitId}) async {
    if (_busy) return;
    if (action == 'cancel') {
      final sure = await showOrderSheet<bool>(context, title: 'Cancel this job?', body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Its visits and its bill are cancelled too.', style: inter(14, 400, color: kMuted)),
            const SizedBox(height: 10),
            DarkCta(label: 'Cancel job', onPressed: () => Navigator.pop(ctx, true)),
            const SizedBox(height: 8),
            LightCta(label: 'Keep it', onPressed: () => Navigator.pop(ctx, false)),
          ]));
      if (sure != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final j = await widget.api.jobAct(_j!.id, action, visitId: visitId, key: ServiceApi.newKey());
      if (!mounted) return;
      setState(() => _j = j);
      if (action == 'close') {
        showToast(context, j.visitsCancelled > 0 ? 'Job closed. ${j.visitsCancelled} later ${j.visitsCancelled == 1 ? 'visit was' : 'visits were'} cancelled.' : 'Job closed.');
        if (j.billNow) await _billNow(j);
      }
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
      if (e.stale) _load();
    } catch (_) {
      if (mounted) showToast(context, 'Could not reach the server. Check the connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "Remind me to bill when I close the job": offer the bill right away.
  Future<void> _billNow(JobView j) async {
    final go = await showOrderSheet<bool>(context, title: 'Bill ${j.customer} now?', body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${svcRupees(j.bill.due)} is due on this job.', style: inter(14, 400, color: kMuted)),
          const SizedBox(height: 10),
          DarkCta(label: 'Open the bill', onPressed: () => Navigator.pop(ctx, true)),
          const SizedBox(height: 8),
          LightCta(label: 'Later', onPressed: () => Navigator.pop(ctx, false)),
        ]));
    if (go == true && mounted) await _openBill();
  }

  Future<void> _openBill() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => BillDetailScreen(api: widget.api, id: _j!.bill.id, onNavigate: widget.onNavigate)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final j = _j;
    return ServicePage(
      title: j == null ? 'Job' : 'Job ${j.displayNo}',
      subtitle: j == null ? '' : '${j.repeatLabel} · ${j.visits.length} ${j.visits.length == 1 ? 'visit' : 'visits'}',
      error: _error,
      onRetry: _load,
      onRefresh: _load,
      body: j == null ? null : _body(j),
    );
  }

  List<Widget> _body(JobView j) => [
        OrderCardBox(
          radius: 20,
          padding: const EdgeInsets.all(18),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(j.title, style: inter(18, 700)),
                const SizedBox(height: 4),
                Text([j.customer, if (j.customerPhone.isNotEmpty) svcPhone(j.customerPhone)].join(' · '), style: inter(13.5, 400, color: kMuted)),
                if (j.address.isNotEmpty) ...[const SizedBox(height: 2), Text(j.address, style: inter(13.5, 400, color: kMuted))],
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              ApptStatusChip(label: j.statusLabel, tone: j.tone),
              const SizedBox(height: 6),
              SourceTag(online: j.online),
            ]),
          ]),
        ),
        const SizedBox(height: 10),
        if (j.instructions.isNotEmpty) SvcCard(title: 'Instructions', children: [Text(j.instructions, style: inter(14, 400))]),
        SvcCard(title: 'Team', children: [
          if (j.team.isEmpty) Text('No one is on this job yet.', style: inter(14, 400, color: kMuted)),
          for (final p in j.team) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text(p.s('name'), style: inter(14.5, 600))),
        ]),
        SvcSectionHead('Visits', count: '${j.visits.length}'),
        if (j.visits.isEmpty) OrderCardBox(child: Text('Not scheduled yet.', style: inter(14, 400, color: kMuted))),
        for (final v in j.visits)
          SvcCard(
            key: ValueKey('visit-${v.s('id')}'),
            title: 'Visit ${v.i('no')} · ${v.s('date_label')}',
            trailing: ApptStatusChip(label: v.s('status_label'), tone: switch (v.s('status')) { 'completed' => 'good', 'cancelled' => 'bad', 'in_progress' => 'info', _ => 'good' }),
            children: [
              SvcKV('Time', v.s('time_label')),
              if (v.so('arrival_label') != null) SvcKV('Arrival', v.s('arrival_label')),
              if (v.ls('actions').contains('start')) ...[
                const SizedBox(height: 8),
                SmallPill('Start visit', key: ValueKey('start-${v.s('id')}'), onTap: () => _act('start', visitId: v.s('id'))),
              ],
              if (v.ls('actions').contains('complete')) ...[
                const SizedBox(height: 8),
                SmallPill('Complete visit', key: ValueKey('complete-${v.s('id')}'), onTap: () => _act('complete', visitId: v.s('id'))),
              ],
            ],
          ),
        SvcCard(
          title: 'Bill ${j.bill.displayNo}',
          trailing: ApptStatusChip(label: j.bill.statusLabel, tone: j.bill.tone),
          onTap: _openBill,
          children: [
            for (final l in j.bill.lines) SvcLine(l.s('name'), qty: '${l.n('qty')}×', amount: svcRupees(l.n('amount'))),
            const Divider(height: 18, color: kLine),
            KeyValue('Total', svcRupees(j.bill.total), size: 14),
            KeyValue('Due', svcRupees(j.bill.due), size: 14, valueColor: j.bill.due > 0 ? kBadText : kInk),
          ],
        ),
        if (j.can('close')) DarkCta(label: 'Close job', busy: _busy, onPressed: _busy ? null : () => _act('close')),
        if (j.can('cancel')) ...[
          const SizedBox(height: 10),
          LightCta(key: const ValueKey('cancel-job'), label: 'Cancel job', onPressed: () => _act('cancel')),
        ],
      ];
}
