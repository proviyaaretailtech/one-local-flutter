import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'floor_screen.dart';
import 'reserve_screen.dart';
import 'table_widgets.dart';
import 'take_order_screens.dart';

/// Reservations (0642, founder 3 Nov 2026): the bookings of a day at this outlet, by status (Upcoming, Seated, Cancelled, No-show, All),
/// each with its time, guest, party size, table, phone and notes; late ones are marked. Seat (at the booked table or another free one),
/// No-show and Cancel ask first. Which actions show comes from the server (`can`); the database checks again.

const _amber = Color(0xFFB45309), _red = Color(0xFFB91C1C), _green = Color(0xFF15803D);

String _two(int n) => n.toString().padLeft(2, '0');
String _day(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "7:30 PM" from the store's "19:30".
String clock12(String hm) {
  final p = hm.split(':');
  final h = int.tryParse(p.first) ?? 0, m = p.length > 1 ? p[1] : '00';
  return '${h % 12 == 0 ? 12 : h % 12}:$m ${h < 12 ? 'AM' : 'PM'}';
}

const _statusLook = {
  'confirmed': ('Booked', Color(0xFF2563EB), Color(0xFFE0EAFF)),
  'seated': ('Seated', _green, Color(0xFFDCFCE7)),
  'cancelled': ('Cancelled', Color(0xFF6B7280), Color(0xFFF1F2EE)),
  'no_show': ('No-show', _red, Color(0xFFFFE1E3)),
};

/// Seat, No-show or Cancel one booking, asking first. Seat can choose another free table, and then offers to take the order.
/// Answers true when the booking changed.
Future<bool> reservationAction(BuildContext context, TablesEnv env, Facts r, String action) async {
  final who = '${r.s('guest_name')} (${r.n('guests').toInt()})';
  final table = r.so('table_label');
  String? tableId;
  String? reason;
  if (action == 'seat') {
    final pick = await showOlDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Seat $who?', style: inter(18, 700)),
        content: Text(table == null ? 'Choose the table for them.' : 'At table $table, as booked, or at another free table.', style: inter(15, 400, color: kMuted)),
        actions: [
          TextButton(key: const ValueKey('rsv-seat-no'), onPressed: () => Navigator.pop(c), child: const Text('No')),
          TextButton(key: const ValueKey('rsv-seat-other'), onPressed: () => Navigator.pop(c, 'other'), child: const Text('Another table')),
          if (table != null) TextButton(key: const ValueKey('rsv-seat-yes'), onPressed: () => Navigator.pop(c, 'booked'), child: Text('Yes, at $table')),
        ],
      ),
    );
    if (pick == null || !context.mounted) return false;
    if (pick == 'other') {
      final t = await Navigator.of(context).push<Facts>(MaterialPageRoute(
          builder: (_) => FloorScreen(env: env, pickFor: r.so('table_id') ?? '', pickTitle: 'Seat ${r.s('guest_name')} at')));
      if (t == null || !context.mounted) return false;
      tableId = t.s('id');
    }
  } else {
    final noShow = action == 'no_show';
    // the reason, or null for No
    reason = await showOlDialog<String>(
      context: context,
      builder: (d) => _ReasonDialog(
        title: noShow ? 'Mark $who as a no-show?' : 'Cancel the booking of $who?',
        body: '${clock12(r.s('local_time'))}${table == null ? '' : ' · Table $table'}. The table is free again.',
        hint: noShow ? 'Did not answer the phone' : 'Guest called to cancel',
        yes: noShow ? 'Yes, no-show' : 'Yes, cancel',
      ),
    );
    if (reason == null || !context.mounted) return false;
  }
  try {
    if (action == 'seat') {
      final res = await env.api.seatReservation(r.s('id'), tableId: tableId);
      if (!context.mounted) return true;
      final t = res.m('table');
      final order = await showOlDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('${r.s('guest_name')} seated at ${t.s('label')}', style: inter(18, 700)),
          content: Text('Take their order now?', style: inter(15, 400, color: kMuted)),
          actions: [
            TextButton(key: const ValueKey('rsv-order-later'), onPressed: () => Navigator.pop(c, false), child: const Text('Later')),
            TextButton(key: const ValueKey('rsv-order-now'), onPressed: () => Navigator.pop(c, true), child: const Text('Take order')),
          ],
        ),
      );
      if (order == true && context.mounted) {
        final start = env.onStartOrder;
        if (start != null) {
          start(context, t);
        } else {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AddDishesScreen(env: env, tableId: t.s('id'), tableLabel: 'Table ${t.s('label')}')));
        }
      }
    } else {
      await env.api.cancelReservation(r.s('id'), outcome: action == 'no_show' ? 'no_show' : 'cancelled', reason: reason);
      if (context.mounted) showToast(context, action == 'no_show' ? '$who marked as a no-show.' : 'Booking of $who cancelled.');
    }
    return true;
  } catch (e) {
    if (context.mounted) showToast(context, sayError(e));
    return true; // read again: the booking may have changed on another device
  }
}

/// "Are you sure?" with an optional reason: answers the reason ('' when none), or null for No.
class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({required this.title, required this.body, required this.hint, required this.yes});
  final String title, body, hint, yes;
  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title, style: inter(18, 700)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.body, style: inter(15, 400, color: kMuted)),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('rsv-reason'),
            controller: _c,
            maxLength: 200,
            decoration: InputDecoration(labelText: 'Reason (optional)', hintText: widget.hint, border: const OutlineInputBorder()),
          ),
        ]),
        actions: [
          TextButton(key: const ValueKey('rsv-no'), onPressed: () => Navigator.pop(context), child: const Text('No')),
          TextButton(key: const ValueKey('rsv-yes'), onPressed: () => Navigator.pop(context, _c.text), child: Text(widget.yes)),
        ],
      );
}

/// One booking: time, guest, party, table, phone, notes, status; Seat / No-show / Cancel as the server allows.
class ReservationCard extends StatelessWidget {
  const ReservationCard({super.key, required this.r, required this.onAction, this.busy = false, this.showTable = true});
  final Facts r;
  final ValueChanged<String> onAction;
  final bool busy, showTable;

  @override
  Widget build(BuildContext context) {
    final id = r.s('id');
    final can = r.m('can');
    final (word, ink, tint) = _statusLook[r.s('status')] ?? (r.s('status'), kMuted, const Color(0xFFF1F2EE));
    final late = r.b('late');
    final notes = (r.so('notes') ?? '').trim(), why = (r.so('outcome_reason') ?? '').trim();
    return Container(
      key: ValueKey('rsv-$id'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: late ? const Color(0xFFFCA5A5) : const Color(0xFFE5E7EB), width: late ? 1.4 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 92,
            child: Text(clock12(r.s('local_time')), key: ValueKey('rsv-time-$id'), style: inter(17, 800, color: late ? _red : kInk)),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.s('guest_name'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(16, 800)),
              const SizedBox(height: 2),
              Text(
                [
                  '${r.n('guests').toInt()} ${r.n('guests') == 1 ? 'guest' : 'guests'}',
                  if (showTable && (r.so('table_label') ?? '').isNotEmpty) 'Table ${r.s('table_label')}',
                  if ((r.so('phone') ?? '').isNotEmpty) r.s('phone'),
                ].join(' · '),
                style: inter(13, 500, color: kMuted),
              ),
            ]),
          ),
          Container(
            key: ValueKey('rsv-status-$id'),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(color: late ? const Color(0xFFFFE1E3) : tint, borderRadius: BorderRadius.circular(20)),
            child: Text(late ? 'Late' : word, style: inter(12, 800, color: late ? _red : ink)),
          ),
        ]),
        if (notes.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6, left: 92), child: Text('“$notes”', style: inter(13, 500, color: _amber))),
        if (why.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4, left: 92), child: Text(why, style: inter(13, 500, color: kMuted))),
        if (can.b('seat') || can.b('no_show') || can.b('cancel')) ...[
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (can.b('cancel'))
              TextButton(key: ValueKey('rsv-cancel-$id'), onPressed: busy ? null : () => onAction('cancel'), child: Text('Cancel', style: inter(14, 700, color: kMuted))),
            if (can.b('no_show'))
              TextButton(key: ValueKey('rsv-noshow-$id'), onPressed: busy ? null : () => onAction('no_show'), child: Text('No-show', style: inter(14, 700, color: _red))),
            if (can.b('seat')) ...[
              const SizedBox(width: 4),
              FilledButton.icon(
                key: ValueKey('rsv-seat-$id'),
                style: FilledButton.styleFrom(backgroundColor: kInk, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                onPressed: busy ? null : () => onAction('seat'),
                icon: const Icon(LucideIcons.armchair, size: 16, color: kLimeBtn),
                label: Text('Seat', style: inter(14, 800, color: kLimeBtn)),
              ),
            ],
          ]),
        ],
      ]),
    );
  }
}

class ReservationsScreen extends StatefulWidget {
  const ReservationsScreen({super.key, required this.env, this.today});
  final TablesEnv env;

  /// The store's today (tests pass their own; else the server's answer decides).
  final DateTime? today;

  static Route<void> route(TablesEnv env) => MaterialPageRoute(builder: (_) => ReservationsScreen(env: env));

  @override
  State<ReservationsScreen> createState() => _ReservationsScreenState();
}

class _ReservationsScreenState extends State<ReservationsScreen> {
  Facts? _d;
  String? _error, _date;
  String _status = 'upcoming';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.env.api.reservations(date: _date, status: _status);
      if (mounted) {
        setState(() {
          _d = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = sayError(e));
    }
  }

  DateTime get _today => widget.today ?? DateTime.tryParse(_d?.so('today') ?? '') ?? DateTime.now();
  DateTime get _shown => DateTime.tryParse(_date ?? _d?.so('date') ?? '') ?? _today;

  void _goTo(DateTime d) {
    setState(() {
      _date = _day(d);
      _d = null;
    });
    _load();
  }

  Future<void> _act(Facts r, String action) async {
    setState(() => _busy = true);
    final changed = await reservationAction(context, widget.env, r, action);
    if (mounted) setState(() => _busy = false);
    if (changed) await _load();
  }

  Future<void> _new() async {
    final t = await Navigator.of(context).push<Facts>(MaterialPageRoute(builder: (_) => FloorScreen(env: widget.env, pickFor: '', pickTitle: 'Reserve which table?')));
    if (t == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReserveScreen(env: widget.env, table: t)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final counts = d?.m('counts');
    final shown = _shown, today = _today;
    final isToday = _day(shown) == _day(today), isTomorrow = _day(shown) == _day(today.add(const Duration(days: 1)));
    final label = isToday ? 'Today' : isTomorrow ? 'Tomorrow' : '${_weekdays[shown.weekday - 1]} ${shown.day} ${_months[shown.month - 1]}';
    final list = d?.l('reservations') ?? const <Facts>[];
    return TablesPage(
      env: widget.env,
      title: 'Reservations',
      subtitle: counts == null ? ' ' : '$label · ${counts.n('upcoming').toInt()} upcoming · ${counts.n('guests').toInt()} guests',
      back: true,
      onRefresh: _load,
      nav: false,
      footer: d?.b('can_reserve') == true
          ? Padding(padding: const EdgeInsets.fromLTRB(14, 8, 14, 10), child: LimeButton('New reservation', key: const ValueKey('rsv-new'), icon: LucideIcons.calendarPlus, onPressed: _new))
          : null,
      children: [
        // the day: back, the day's name (tap for a calendar), forward
        Row(children: [
          IconButton(key: const ValueKey('rsv-prev'), onPressed: () => _goTo(shown.subtract(const Duration(days: 1))), icon: const Icon(LucideIcons.chevronLeft)),
          Expanded(
            child: TextButton.icon(
              key: const ValueKey('rsv-day'),
              onPressed: () async {
                final picked = await showDatePicker(context: context, initialDate: shown, firstDate: today.subtract(const Duration(days: 60)), lastDate: today.add(const Duration(days: 90)));
                if (picked != null) _goTo(picked);
              },
              icon: const Icon(LucideIcons.calendar, size: 18, color: kInk),
              label: Text(label, style: inter(16, 800)),
            ),
          ),
          IconButton(key: const ValueKey('rsv-next'), onPressed: () => _goTo(shown.add(const Duration(days: 1))), icon: const Icon(LucideIcons.chevronRight)),
        ]),
        SizedBox(
          height: 44,
          child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
            for (final (k, name) in const [('upcoming', 'Upcoming'), ('seated', 'Seated'), ('no_show', 'No-show'), ('cancelled', 'Cancelled'), ('all', 'All')])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  key: ValueKey('rsv-filter-$k'),
                  label: Text('$name${counts == null ? '' : ' ${counts.n(k).toInt()}'}', style: inter(13.5, 700, color: _status == k ? kLimeBtn : kInk)),
                  selected: _status == k,
                  showCheckmark: false,
                  selectedColor: kInk,
                  backgroundColor: Colors.white,
                  onSelected: (_) {
                    setState(() => _status = k);
                    _load();
                  },
                ),
              ),
          ])),
        ),
        const SizedBox(height: 10),
        if ((counts?.n('late') ?? 0) > 0 && _status == 'upcoming')
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text('${counts!.n('late').toInt()} late: seat them, or mark a no-show.', key: const ValueKey('rsv-late'), style: inter(13.5, 700, color: _red)),
          ),
        if (d == null && _error == null) tablesLoading(),
        if (_error != null) TablesError(_error!, onRetry: _load),
        if (d != null && list.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(child: Text(_status == 'upcoming' ? 'No bookings to come on this day.' : 'Nothing here on this day.', style: inter(15, 500, color: kMuted))),
          ),
        for (final r in list) ReservationCard(r: r, busy: _busy, onAction: (a) => _act(r, a)),
      ],
    );
  }
}
