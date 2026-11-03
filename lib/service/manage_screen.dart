import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_nav.dart';
import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'availability_screen.dart';
import 'bookings_screen.dart' show bookingLength;
import 'service_api.dart';
import 'service_widgets.dart';

// The Manage tab, Service management (founder's sketch, 2 Nov 2026), the same for every kind of service: pick a weekday and see its slot
// table (Time · Slot · Length · how many people work it), worked out from the opening hours, the slot length and who works when. The
// opening hours and the slot length are changed here; the word for the people (Technicians, Cleaners, Staff...) comes from the kind of
// service chosen at sign-up. Every slot, count and word is the server's (svc_slot_table).

const _dayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
String _clock(TimeOfDay t) => '${t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod}:${t.minute.toString().padLeft(2, '0')} ${t.period == DayPeriod.am ? 'AM' : 'PM'}';
TimeOfDay? _time(String? hhmm) {
  final p = (hhmm ?? '').split(':');
  return p.length < 2 ? null : TimeOfDay(hour: int.tryParse(p[0]) ?? 0, minute: int.tryParse(p[1]) ?? 0);
}

String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class ManageScreen extends StatefulWidget {
  const ManageScreen({super.key, this.api, this.onNavigate, this.weekday});
  final ServiceApi? api;
  final ValueChanged<String>? onNavigate;

  /// The weekday to open on (1 = Monday); today when null.
  final int? weekday;
  @override
  State<ManageScreen> createState() => _ManageScreenState();
}

class _ManageScreenState extends State<ManageScreen> {
  late final ServiceApi _api = widget.api ?? ServiceApi();
  late int? _weekday = widget.weekday;
  SlotTableData? _data;
  String? _error;
  bool _busy = false;
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
      final d = await _api.slotTable(weekday: _weekday);
      if (!mounted || mine != _seq) return;
      setState(() {
        _data = d;
        _weekday = d.weekday;
      });
    } on ServiceApiException catch (e) {
      if (mounted && mine == _seq) setState(() => _error = e.message);
    } catch (_) {
      if (mounted && mine == _seq) setState(() => _error = 'Could not load the schedule. Check the connection and try again.');
    }
  }

  /// Saves part of the schedule (slot length or the week's hours), then reloads the table.
  Future<void> _save(Map<String, Object?> fields, String done) async {
    final d = _data;
    if (d == null || _busy) return;
    setState(() => _busy = true);
    try {
      await _api.saveSchedule({'location_id': d.locationId, ...fields}, key: ServiceApi.newKey());
      if (!mounted) return;
      showToast(context, done);
      await _load();
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not save. Check the connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The whole week's opening hours as the server saves them, with [weekday] replaced by [day] (null = closed that day).
  List<Map<String, Object?>> _weekWith(int weekday, Map<String, Object?>? day) => [
        for (final x in _data!.days)
          if (x.i('weekday') == weekday)
            ?day
          else if (x.b('open'))
            {'weekday': x.i('weekday'), 'open': x.s('open_time'), 'close': x.s('close_time'), if (x.so('break_start') != null) 'break_start': x.s('break_start'), if (x.so('break_end') != null) 'break_end': x.s('break_end')},
      ];

  Future<void> _editHours() async {
    final d = _data!;
    final day = d.days.firstWhere((x) => x.i('weekday') == d.weekday);
    final result = await showOrderSheet<Map<String, Object?>>(context, title: 'Hours on ${_dayNames[d.weekday - 1]}', body: (ctx) => _HoursForm(day: day));
    if (result == null || !mounted) return;
    final closed = result['closed'] == true;
    await _save({'hours': _weekWith(d.weekday, closed ? null : {...result, 'weekday': d.weekday})},
        closed ? 'Closed on ${_dayNames[d.weekday - 1]}s.' : 'Hours saved.');
  }

  Future<void> _showNames(SvcData slot) => showOrderSheet<void>(context, title: 'Slot ${slot.i('no')} · ${slot.s('time_label')}', body: (ctx) {
        final names = slot.ls('names');
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (names.isEmpty) Text('Nobody works all of this slot.', style: inter(14, 400, color: kMuted)),
          for (final n in names) Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(n, style: inter(15, 600))),
        ]);
      });

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return ServicePage(
      title: 'Service management',
      subtitle: d == null ? '' : '${d.locationName} · slots and hours',
      business: d?.raw['business']?.toString() ?? '',
      onMenu: HomeNav.openMenu == null ? null : () => HomeNav.openMenu!(context),
      onRefresh: _load,
      error: _error,
      onRetry: _load,
      body: d == null ? null : _body(d),
    );
  }

  // Compact (founder, 2 Nov 2026: "optimize the manage section"): the week as one row of round letters; the day's hours and the slot length
  // in one card; the slots as a grid of small tiles (not a long table); who works that day as short rows.
  List<Widget> _body(SlotTableData d) {
    final day = _dayNames[d.weekday - 1];
    final slots = d.slots;
    final empty = slots.where((s) => s.i('workers') == 0).length;
    return [
      _week(d),
      const SizedBox(height: 10),
      SvcCard(
        title: day,
        trailing: d.canEdit ? SmallPill('Edit hours', key: const ValueKey('edit-hours'), onTap: _busy ? () {} : _editHours) : null,
        children: [
          if (d.closed)
            Text('Closed on this day.', style: inter(14, 600, color: kBadText))
          else
            Wrap(spacing: 14, runSpacing: 4, children: [
              _fact(LucideIcons.clock, d.hours.s('label')),
              _fact(LucideIcons.coffee, d.hours.so('break_label') == null ? 'No break' : 'Break ${d.hours.s('break_label')}'),
            ]),
          const Divider(height: 18),
          Text('Slot length', style: inter(13, 600)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final m in d.slotChoices)
              ModeChip(bookingLength(m), key: ValueKey('slot-$m'), selected: m == d.slotMinutes,
                  onTap: () => !d.canEdit || m == d.slotMinutes || _busy ? null : _save({'slot_minutes': m}, 'Slots are now ${bookingLength(m)}.')),
          ]),
        ],
      ),
      SvcSectionHead('Slots on $day', count: '${slots.length} ${slots.length == 1 ? 'slot' : 'slots'}'),
      if (slots.isEmpty)
        OrderCardBox(child: Text(d.closed ? 'Closed on this day, so there are no slots.' : 'No slot fits the opening hours.', style: inter(14, 400, color: kMuted)))
      else ...[
        Text(empty == 0 ? 'Every slot has someone. Tap a slot to see who.' : '$empty with nobody (in red). Tap a slot to see who works it.',
            style: inter(12, 500, color: empty == 0 ? kMuted : kBadText)),
        const SizedBox(height: 8),
        LayoutBuilder(builder: (context, c) {
          final w = (c.maxWidth - 16) / 3; // three to a row
          return Wrap(spacing: 8, runSpacing: 8, children: [for (final s in slots) SizedBox(width: w, child: _slotTile(s, d))]);
        }),
      ],
      const SizedBox(height: 12),
      SvcCard(
        title: '${d.workerMany} on $day',
        trailing: d.canEdit
            ? SmallPill('Edit', key: const ValueKey('edit-staff-hours'), onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AvailabilityScreen(api: _api, onNavigate: widget.onNavigate)));
                if (mounted) _load();
              })
            : null,
        children: [
          if (d.staff.isEmpty) Text('No one takes bookings yet.', style: inter(14, 400, color: kMuted)),
          for (final p in d.staff)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Container(width: 7, height: 7, decoration: BoxDecoration(color: p.so('hours') == null ? kLine : kGreenText, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Expanded(child: Text(p.s('name'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13.5, 600))),
                Text(p.so('hours') ?? 'Off', style: inter(12.5, 500, color: p.so('hours') == null ? kMuted : kInk)),
              ]),
            ),
        ],
      ),
    ];
  }

  Widget _fact(IconData icon, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: kMuted),
        const SizedBox(width: 5),
        Text(text, style: inter(13, 600)),
      ]);

  /// The week as one row of round letters (as the Bookings week strip): filled when chosen, faded with a line through when closed.
  Widget _week(SlotTableData d) => Row(children: [
        for (final x in d.days)
          Expanded(
            child: Semantics(
              button: true,
              selected: x.i('weekday') == d.weekday,
              label: x.b('open') ? x.s('label') : '${x.s('label')} · Closed',
              child: InkWell(
                key: ValueKey('weekday-${x.i('weekday')}'),
                customBorder: const CircleBorder(),
                onTap: () {
                  _weekday = x.i('weekday');
                  _load();
                },
                child: Column(children: [
                  Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: x.i('weekday') == d.weekday ? kInk : Colors.white,
                      border: Border.all(color: x.i('weekday') == d.weekday ? kInk : kLine),
                    ),
                    child: Text(x.s('label').isEmpty ? '' : x.s('label')[0],
                        style: inter(14, 700, color: x.i('weekday') == d.weekday ? Colors.white : x.b('open') ? kInk : kMuted)
                            .copyWith(decoration: x.b('open') ? null : TextDecoration.lineThrough)),
                  ),
                  const SizedBox(height: 3),
                  Text(x.b('open') ? '' : 'Closed', style: inter(9.5, 600, color: kMuted)),
                ]),
              ),
            ),
          ),
      ]);

  /// One slot: its start, its end and length, and how many work it (red when nobody does). A tap shows who.
  Widget _slotTile(SvcData s, SlotTableData d) {
    final n = s.i('workers');
    final start = _time(s.so('start')), end = _time(s.so('end'));
    return Material(
      color: n == 0 ? kBadBg : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: n == 0 ? kBadText.withValues(alpha: 0.3) : kLine)),
      child: InkWell(
        key: ValueKey('slot-row-${s.i('no')}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showNames(s),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(9, 8, 9, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(start == null ? s.s('time_label') : _clock(start), maxLines: 1, style: inter(13.5, 800)),
            Text('${end == null ? '' : 'to ${_clock(end)} · '}${bookingLength(s.i('length_min'))}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(10.5, 500, color: kMuted)),
            const SizedBox(height: 4),
            Text('$n ${n == 1 ? d.workerOne : d.workerMany}', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: inter(11.5, 700, color: n == 0 ? kBadText : kGreenText)),
          ]),
        ),
      ),
    );
  }
}

/// One day's opening hours: open or closed, opening and closing time, an optional break. Pops the values the server saves.
class _HoursForm extends StatefulWidget {
  const _HoursForm({required this.day});
  final SvcData day;
  @override
  State<_HoursForm> createState() => _HoursFormState();
}

class _HoursFormState extends State<_HoursForm> {
  late bool _open = widget.day.b('open');
  late TimeOfDay _from = _time(widget.day.so('open_time')) ?? const TimeOfDay(hour: 10, minute: 0);
  late TimeOfDay _to = _time(widget.day.so('close_time')) ?? const TimeOfDay(hour: 20, minute: 0);
  late bool _break = widget.day.so('break_start') != null;
  late TimeOfDay _breakFrom = _time(widget.day.so('break_start')) ?? const TimeOfDay(hour: 14, minute: 0);
  late TimeOfDay _breakTo = _time(widget.day.so('break_end')) ?? const TimeOfDay(hour: 15, minute: 0);

  int _m(TimeOfDay t) => t.hour * 60 + t.minute;

  Future<void> _pick(TimeOfDay current, ValueChanged<TimeOfDay> set) async {
    final t = await showTimePicker(context: context, initialTime: current);
    if (t != null) setState(() => set(t));
  }

  Widget _timeField(String label, TimeOfDay t, ValueChanged<TimeOfDay> set, String key) => Expanded(
        child: InkWell(
          key: ValueKey(key),
          borderRadius: BorderRadius.circular(12),
          onTap: () => _pick(t, set),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: inter(12, 400, color: kMuted)),
              const SizedBox(height: 2),
              Text(_clock(t), style: inter(15, 600)),
            ]),
          ),
        ),
      );

  void _done() {
    if (!_open) return Navigator.pop(context, <String, Object?>{'closed': true});
    if (_m(_to) <= _m(_from)) return showToast(context, 'Closing time must be after opening time.');
    if (_break && (_m(_breakFrom) < _m(_from) || _m(_breakTo) > _m(_to) || _m(_breakTo) <= _m(_breakFrom))) {
      return showToast(context, 'The break must be inside the opening hours.');
    }
    Navigator.pop(context, <String, Object?>{
      'open': _hhmm(_from),
      'close': _hhmm(_to),
      if (_break) 'break_start': _hhmm(_breakFrom),
      if (_break) 'break_end': _hhmm(_breakTo),
    });
  }

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SwitchListTile(key: const ValueKey('day-open'), contentPadding: EdgeInsets.zero, title: Text('Open on this day', style: inter(15, 600)), value: _open, onChanged: (v) => setState(() => _open = v)),
        if (_open) ...[
          Row(children: [_timeField('Opens', _from, (t) => _from = t, 'opens'), const SizedBox(width: 10), _timeField('Closes', _to, (t) => _to = t, 'closes')]),
          SwitchListTile(key: const ValueKey('day-break'), contentPadding: EdgeInsets.zero, title: Text('Break', style: inter(15, 600)), value: _break, onChanged: (v) => setState(() => _break = v)),
          if (_break) Row(children: [_timeField('From', _breakFrom, (t) => _breakFrom = t, 'break-from'), const SizedBox(width: 10), _timeField('To', _breakTo, (t) => _breakTo = t, 'break-to')]),
        ],
        const SizedBox(height: 10),
        DarkCta(label: 'Save hours', onPressed: _done),
      ]);
}
