import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'service_api.dart';
import 'service_menu.dart';
import 'service_widgets.dart';

const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
final _hhmm = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

/// Figma 89 "Availability & Scheduling": the location's week and lunch break, each provider's week, the slot rules and the blocked times and
/// holidays. Changes are collected on the page and sent together with "Save schedule"; confirmed bookings are never moved by them.
class AvailabilityScreen extends StatefulWidget {
  const AvailabilityScreen({super.key, required this.api, this.business = '', this.onNavigate});
  final ServiceApi api;
  final String business;
  final ValueChanged<String>? onNavigate;
  @override
  State<AvailabilityScreen> createState() => _AvailabilityScreenState();
}

class _AvailabilityScreenState extends State<AvailabilityScreen> {
  ScheduleData? _d;
  String? _error, _locationId;
  String _tab = 'hours';
  // pending changes
  List<Map<String, Object?>>? _hours;
  final _providers = <String, List<Map<String, Object?>>>{};
  final _closuresAdd = <Map<String, Object?>>[], _timeOffAdd = <Map<String, Object?>>[];
  final _closuresRemove = <String>{}, _timeOffRemove = <String>{};
  String? _key;
  bool _busy = false;

  bool get _dirty => _hours != null || _providers.isNotEmpty || _closuresAdd.isNotEmpty || _timeOffAdd.isNotEmpty || _closuresRemove.isNotEmpty || _timeOffRemove.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.schedule(locationId: _locationId);
      if (mounted) setState(() { _d = d; _error = null; _locationId = d.locationId; });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _reset() {
    _hours = null;
    _providers.clear();
    _closuresAdd.clear();
    _timeOffAdd.clear();
    _closuresRemove.clear();
    _timeOffRemove.clear();
    _key = null;
  }

  Future<void> _save() async {
    final d = _d;
    if (d == null) return;
    if (!_dirty) {
      showToast(context, 'Nothing to save yet. Tap a block to change it.');
      return;
    }
    setState(() => _busy = true);
    _key ??= ServiceApi.newKey();
    try {
      final saved = await widget.api.saveSchedule({
        'location_id': d.locationId,
        'hours': ?_hours,
        if (_providers.isNotEmpty) 'providers': [for (final e in _providers.entries) {'staff_id': e.key, 'hours': e.value}],
        if (_closuresAdd.isNotEmpty) 'closures_add': _closuresAdd,
        if (_closuresRemove.isNotEmpty) 'closures_remove': _closuresRemove.toList(),
        if (_timeOffAdd.isNotEmpty) 'time_off_add': _timeOffAdd,
        if (_timeOffRemove.isNotEmpty) 'time_off_remove': _timeOffRemove.toList(),
      }, key: _key!);
      if (!mounted) return;
      setState(() {
        _d = saved;
        _reset();
      });
      showToast(context, 'Schedule saved. Confirmed bookings are unchanged.');
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
      if (e.status < 500) _key = null;
    } catch (e) {
      if (mounted) showToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickLocation() async {
    final d = _d;
    if (d == null || d.l('locations').length < 2) return;
    final pick = await showOrderSheet<String>(context, title: 'Location', body: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
          for (final l in d.l('locations')) ListTile(contentPadding: EdgeInsets.zero, title: Text(l.s('name'), style: inter(15, 500)), onTap: () => Navigator.pop(ctx, l.s('id'))),
        ]));
    if (pick == null || pick == _locationId) return;
    setState(() {
      _locationId = pick;
      _d = null;
      _reset();
    });
    _load();
  }

  Future<void> _editWeek() async {
    final d = _d!;
    final cur = {for (final h in _hours ?? d.hours.map((e) => e.raw).toList()) (h['weekday'] as num).toInt(): h};
    final rows = await showOrderSheet<List<Map<String, Object?>>>(context, title: 'Weekly working hours', body: (ctx) => _WeekEditor(initial: cur, withBreak: true));
    if (rows != null) {
      setState(() {
        _hours = rows;
        _key = null;
      });
    }
  }

  Future<void> _editProvider(SvcData p) async {
    final cur = {for (final h in _providers[p.s('staff_id')] ?? p.l('hours').map((e) => e.raw).toList()) (h['weekday'] as num).toInt(): {'open': h['start'], 'close': h['end']}};
    final rows = await showOrderSheet<List<Map<String, Object?>>>(context, title: p.s('name'), body: (ctx) => _WeekEditor(initial: cur, withBreak: false));
    if (rows != null) {
      setState(() {
        _providers[p.s('staff_id')] = [for (final r in rows) {'weekday': r['weekday'], 'start': r['open'], 'end': r['close']}];
        _key = null;
      });
    }
  }

  Future<void> _addException() async {
    final d = _d!;
    final res = await showOrderSheet<Map<String, Object?>>(context, title: 'Add exception', body: (ctx) => _ExceptionForm(providers: d.providers));
    if (res == null) return;
    setState(() {
      (res['kind'] == 'holiday' ? _closuresAdd : _timeOffAdd).add(res..remove('kind'));
      _key = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return ServicePage(
      title: 'Availability & Scheduling',
      subtitle: d == null ? '' : '${d.locationName} · Appointment availability',
      business: widget.business,
      onMenu: () => showServiceMenu(context, widget.api, business: widget.business, onNavigate: widget.onNavigate, current: 'availability'),
      onNavigate: widget.onNavigate,
      error: _error,
      onRetry: _load,
      body: d == null
          ? null
          : [
              SvcChips(options: const [('hours', 'Working hours'), ('providers', 'Providers'), ('exceptions', 'Exceptions')], selected: _tab, onSelect: (v) => setState(() => _tab = v)),
              if (_tab == 'hours') ...[
                Text('Location', style: inter(18, 700)),
                const SizedBox(height: 10),
                InkWell(
                  key: const ValueKey('location-box'),
                  onTap: _pickLocation,
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(color: const Color(0xFFF1F1EC), borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
                    child: Text(d.locationName, style: inter(16, 400)),
                  ),
                ),
                SvcCard(
                  title: 'Weekly working hours',
                  onTap: d.canEdit ? _editWeek : null,
                  trailing: _hours != null ? const TagChip('Not saved', bg: Color(0xFFFFF9E3), fg: Color(0xFFA23F00)) : null,
                  children: [
                    if (_hours != null)
                      for (final h in _hours!) SvcKV(_dayNames[(h['weekday'] as int) - 1], '${h['open']} – ${h['close']}${h['break_start'] != null ? ' · break ${h['break_start']}–${h['break_end']}' : ''}', labelWidth: 120)
                    else if (d.hoursRows.isEmpty)
                      Text('Open whenever a provider works. Tap to set the location\'s hours.', style: inter(14, 400, color: kMuted))
                    else
                      for (final r in d.hoursRows) SvcKV(r.s('label'), r.s('value'), labelWidth: 120),
                  ],
                ),
              ],
              if (_tab == 'hours' || _tab == 'providers')
                SvcCard(title: 'Provider availability', children: [
                  Align(alignment: Alignment.centerLeft, child: svcStatus('${d.availableToday} available today', d.availableToday > 0 ? 'good' : 'info')),
                  const SizedBox(height: 8),
                  if (d.providers.isEmpty) Text('No providers at this location yet.', style: inter(14, 400, color: kMuted)),
                  for (final p in d.providers)
                    InkWell(
                      key: ValueKey('provider-${p.s('staff_id')}'),
                      onTap: d.canEdit ? () => _editProvider(p) : null,
                      child: SvcKV(p.s('name'),
                          _providers.containsKey(p.s('staff_id')) ? '${_providers[p.s('staff_id')]!.length} days · not saved' : p.s('label'), labelWidth: 120),
                    ),
                ]),
              if (_tab == 'hours')
                SvcCard(title: 'Slot configuration', children: [
                  SvcKV('Slot interval', '${d.slot.i('slot_minutes')} minutes'),
                  if (d.slot.s('service').isNotEmpty) SvcKV('Service duration', '${d.slot.i('duration_min')} min · ${d.slot.s('service')}'),
                  SvcKV('Capacity', '${d.slot.i('capacity')} customer per provider'),
                  SvcKV('Buffer before', '${d.slot.i('buffer_before')} minutes'),
                  SvcKV('Buffer after', '${d.slot.i('buffer_after')} minutes'),
                ]),
              if (_tab == 'hours' || _tab == 'exceptions') ...[
                SvcSectionHead('Blocked time & holidays', count: '${d.exceptions.length - _closuresRemove.length - _timeOffRemove.length + _closuresAdd.length + _timeOffAdd.length} exceptions'),
                for (final x in d.exceptions)
                  if (!_closuresRemove.contains(x.s('id')) && !_timeOffRemove.contains(x.s('id'))) _exception(x),
                for (final c in _closuresAdd) SvcCard(title: '${c['day']}', trailing: const TagChip('Not saved'), children: [SvcKV('Reason', '${c['reason']}', labelWidth: 120)]),
                for (final t in _timeOffAdd) SvcCard(title: '${t['label']}', trailing: const TagChip('Not saved'), children: [SvcKV('Provider', '${t['provider']} · ${t['reason']}', labelWidth: 120)]),
                if (d.canEdit) Padding(padding: const EdgeInsets.only(bottom: 12), child: LightCta(label: 'Add exception', icon: LucideIcons.plus, onPressed: _addException)),
              ],
              const SvcInfo(title: 'Existing bookings are protected', text: 'Schedule changes apply to new slots, not confirmed appointments.'),
              if (d.canEdit) DarkCta(label: 'Save schedule', busy: _busy, onPressed: _busy ? null : _save),
            ],
    );
  }

  Widget _exception(SvcData x) {
    final holiday = x.s('kind') == 'holiday';
    return SvcCard(
      title: x.s('date_label'),
      onTap: _d?.canEdit == true
          ? () async {
              final rm = await showOrderSheet<bool>(context, title: x.s('date_label'), body: (ctx) => DarkCta(label: 'Remove this exception', onPressed: () => Navigator.pop(ctx, true)));
              if (rm == true) setState(() => (holiday ? _closuresRemove : _timeOffRemove).add(x.s('id')));
            }
          : null,
      children: [
        Align(alignment: Alignment.centerLeft, child: svcStatus(holiday ? 'Holiday' : 'Blocked', holiday ? 'info' : 'warn')),
        const SizedBox(height: 8),
        if (holiday)
          SvcKV('Reason', x.s('reason'), labelWidth: 120)
        else ...[
          SvcKV('Time', x.s('time_label'), labelWidth: 120),
          SvcKV('Provider', x.s('reason').isEmpty ? x.s('provider') : '${x.s('provider')} · ${x.s('reason')}', labelWidth: 120),
        ],
      ],
    );
  }
}

/// Seven days with open / close (and an optional break): returns the open days as rows.
class _WeekEditor extends StatefulWidget {
  const _WeekEditor({required this.initial, required this.withBreak});
  final Map<int, Map<String, Object?>> initial;
  final bool withBreak;
  @override
  State<_WeekEditor> createState() => _WeekEditorState();
}

class _WeekEditorState extends State<_WeekEditor> {
  late final _open = {for (var d = 1; d <= 7; d++) d: widget.initial.containsKey(d)};
  late final _from = {for (var d = 1; d <= 7; d++) d: TextEditingController(text: '${widget.initial[d]?['open'] ?? '10:00'}')};
  late final _to = {for (var d = 1; d <= 7; d++) d: TextEditingController(text: '${widget.initial[d]?['close'] ?? '19:00'}')};
  late final _bs = TextEditingController(text: '${widget.initial.values.map((e) => e['break_start']).firstWhere((e) => e != null, orElse: () => '')}');
  late final _be = TextEditingController(text: '${widget.initial.values.map((e) => e['break_end']).firstWhere((e) => e != null, orElse: () => '')}');

  void _done() {
    final rows = <Map<String, Object?>>[];
    for (var d = 1; d <= 7; d++) {
      if (!_open[d]!) continue;
      final a = _from[d]!.text.trim(), b = _to[d]!.text.trim();
      if (!_hhmm.hasMatch(a) || !_hhmm.hasMatch(b)) {
        showToast(context, 'Use 24-hour times like 09:30 for ${_dayNames[d - 1]}.');
        return;
      }
      rows.add({'weekday': d, 'open': a, 'close': b, if (widget.withBreak && _bs.text.trim().isNotEmpty) 'break_start': _bs.text.trim(), if (widget.withBreak && _be.text.trim().isNotEmpty) 'break_end': _be.text.trim()});
    }
    Navigator.pop(context, rows);
  }

  Widget _t(TextEditingController c, String key) => SizedBox(width: 74, child: TextField(key: ValueKey(key), controller: c, textAlign: TextAlign.center, decoration: const InputDecoration(isDense: true)));

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var d = 1; d <= 7; d++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                SizedBox(width: 48, child: Text(_dayNames[d - 1], style: inter(14, 600))),
                Switch(key: ValueKey('day-$d'), value: _open[d]!, onChanged: (v) => setState(() => _open[d] = v)),
                const Spacer(),
                if (_open[d]!) ...[_t(_from[d]!, 'from-$d'), const Text('  –  '), _t(_to[d]!, 'to-$d')] else Text('Closed', style: inter(14, 400, color: kMuted)),
              ]),
            ),
          if (widget.withBreak) ...[
            const SizedBox(height: 8),
            Row(children: [Expanded(child: Text('Lunch break (optional)', style: inter(14, 500))), _t(_bs, 'break-start'), const Text('  –  '), _t(_be, 'break-end')]),
          ],
          const SizedBox(height: 14),
          DarkCta(label: 'Done', onPressed: _done),
        ]),
      );
}

/// A holiday (whole location, one day) or a provider's blocked time.
class _ExceptionForm extends StatefulWidget {
  const _ExceptionForm({required this.providers});
  final List<SvcData> providers;
  @override
  State<_ExceptionForm> createState() => _ExceptionFormState();
}

class _ExceptionFormState extends State<_ExceptionForm> {
  String _kind = 'holiday';
  String? _staff;
  final _day = TextEditingController(), _from = TextEditingController(text: '15:00'), _to = TextEditingController(text: '16:00'), _reason = TextEditingController();

  void _done() {
    final day = DateTime.tryParse(_day.text.trim());
    if (day == null || _reason.text.trim().length < 2) {
      showToast(context, 'Enter the date (YYYY-MM-DD) and a reason.');
      return;
    }
    final iso = _day.text.trim();
    if (_kind == 'holiday') {
      Navigator.pop(context, {'kind': 'holiday', 'day': iso, 'reason': _reason.text.trim()});
      return;
    }
    if (_staff == null || !_hhmm.hasMatch(_from.text.trim()) || !_hhmm.hasMatch(_to.text.trim())) {
      showToast(context, 'Choose the provider and 24-hour times like 15:00.');
      return;
    }
    final p = widget.providers.firstWhere((x) => x.s('staff_id') == _staff);
    // the studio's time zone (India) — the server checks the range again
    Navigator.pop(context, {
      'kind': 'blocked',
      'staff_id': _staff,
      'starts_at': '${iso}T${_from.text.trim()}:00+05:30',
      'ends_at': '${iso}T${_to.text.trim()}:00+05:30',
      'reason': _reason.text.trim(),
      'label': '$iso ${_from.text.trim()}–${_to.text.trim()}',
      'provider': p.s('name'),
    });
  }

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SvcChips(options: const [('holiday', 'Holiday (studio closed)'), ('blocked', 'Blocked time')], selected: _kind, onSelect: (v) => setState(() => _kind = v)),
        TextField(key: const ValueKey('exception-day'), controller: _day, decoration: const InputDecoration(hintText: 'Date, e.g. 2026-10-20')),
        const SizedBox(height: 10),
        if (_kind == 'blocked') ...[
          Wrap(spacing: 8, runSpacing: 8, children: [for (final p in widget.providers) ModeChip(p.s('name'), selected: _staff == p.s('staff_id'), onTap: () => setState(() => _staff = p.s('staff_id')))]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: TextField(controller: _from, decoration: const InputDecoration(hintText: 'From 15:00'))),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: _to, decoration: const InputDecoration(hintText: 'To 16:00'))),
          ]),
          const SizedBox(height: 10),
        ],
        TextField(key: const ValueKey('exception-reason'), controller: _reason, decoration: const InputDecoration(hintText: 'Reason (Dasara · Studio closed all day)')),
        const SizedBox(height: 14),
        DarkCta(label: 'Add', onPressed: _done),
      ]);
}
