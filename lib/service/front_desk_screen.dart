import 'dart:async';

import 'package:flutter/material.dart';

import '../home/home_nav.dart';
import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'bills_screen.dart';
import 'job_screens.dart';
import 'service_api.dart';
import 'service_widgets.dart';
import 'visit_screens.dart';

// The Bill tab's first screen (5 Nov 2026): today's bookings in a tab per listing type, so people can be checked in from one place, with the
// bills in the last tab. Only the types this business offers show. Bookings and what can be done next are the server's (svc_front_desk).
// Events and activities count who is in at each time: +1 / -1 for walk-ins with no names, and each booking whole or part of a group.
// Play shows each court: who is on it, the time left and who is next.

const _kinds = [('events', 'Events'), ('activities', 'Activities'), ('play', 'Play'), ('service', 'Service'), ('stay', 'Stay')];

/// The queue's sections, in the order they are worked through.
const _sections = [
  ('Waiting', ['deposit_pending', 'confirmed', 'checked_in']),
  ('In progress', ['in_service']),
  ('Done', ['completed']),
  ('Cancelled', ['cancelled', 'no_show']),
];

class FrontDeskScreen extends StatefulWidget {
  const FrontDeskScreen({super.key, this.api, this.onNavigate, this.now});
  final ServiceApi? api;
  final ValueChanged<String>? onNavigate;

  /// The clock (tests pass a fixed one).
  final DateTime Function()? now;
  @override
  State<FrontDeskScreen> createState() => _FrontDeskScreenState();
}

class _FrontDeskScreenState extends State<FrontDeskScreen> {
  late final ServiceApi _api = widget.api ?? ServiceApi();
  String _tab = 'all';
  String _q = '';
  FrontDeskData? _data;
  String? _error, _busy;
  int _seq = 0, _billsRefresh = 0;

  /// Taps on + and - not yet answered, per session: the count moves at once however fast the door is.
  final _pending = <String, int>{};

  /// Moves the time left on the courts along.
  Timer? _tick;

  DateTime get _now => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _load();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _tab == 'play') setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final mine = ++_seq;
    setState(() => _error = null);
    try {
      final d = await _api.frontDesk();
      if (mounted && mine == _seq) setState(() => _data = d);
    } on ServiceApiException catch (e) {
      if (mounted && mine == _seq) setState(() => _error = e.message);
    } catch (_) {
      if (mounted && mine == _seq) setState(() => _error = 'Could not load today\'s bookings. Check the connection and try again.');
    }
  }

  Future<void> _refresh() async {
    setState(() => _billsRefresh++);
    await _load();
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  String get _business => _data?.business ?? '';

  /// A booking opens its details; a job visit opens its job.
  Future<void> _open(AppointmentView a) => _push(a.s('kind') == 'job'
      ? JobDetailScreen(api: _api, id: a.s('job_id'), onNavigate: widget.onNavigate)
      : AppointmentDetailScreen(api: _api, id: a.id, business: _business, onNavigate: widget.onNavigate));

  /// What the row's button says; null when there is nothing to do next.
  String? _actionLabel(AppointmentView a) {
    if (a.s('kind') == 'job') return a.status == 'confirmed' || a.status == 'in_service' ? 'Open' : null;
    if (a.can('pay_deposit')) return 'Advance';
    if (a.can('check_in')) return 'Check in';
    if (a.can('start')) return 'Start';
    if (a.can('finish')) return a.category == 'play' ? 'Finish' : 'Complete';
    return null;
  }

  Future<void> _act(AppointmentView a) async {
    if (a.s('kind') == 'job' || a.can('pay_deposit')) return _open(a);
    if (a.can('finish')) return _push(ServiceExecutionScreen(api: _api, id: a.id, business: _business, onNavigate: widget.onNavigate));
    setState(() => _busy = a.id);
    try {
      if (a.can('check_in') && a.onLocation) {
        // work at the customer's place keeps its arrival code
        final full = await _api.get(a.id);
        if (!mounted) return;
        await _push(ServiceCheckInScreen(api: _api, appointment: full, business: _business, onNavigate: widget.onNavigate));
        return;
      }
      await _api.act(a.id, a.can('check_in') ? 'check_in' : 'start', version: a.version);
      await _load();
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
      if (e.stale) _load();
    } catch (_) {
      if (mounted) showToast(context, 'Could not save that. Check the connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// One walk-in on or off; the answer is the whole day, newest answer wins.
  Future<void> _count(SvcData session, int delta) async {
    final key = session.s('key');
    setState(() => _pending[key] = (_pending[key] ?? 0) + delta);
    final mine = ++_seq;
    try {
      final d = await _api.countWalkIn(session.s('service_id'), startsAt: session.s('starts_at'), delta: delta);
      if (mounted && mine == _seq) _data = d;
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
      if (mounted && mine == _seq) await _load();
    } catch (_) {
      if (mounted) showToast(context, 'Could not save that. Check the connection and try again.');
    } finally {
      if (mounted) setState(() => _pending[key] = (_pending[key] ?? 0) - delta);
    }
  }

  /// Starts a count for a listing, at the time now.
  Future<void> _startCount(String serviceId) async {
    final mine = ++_seq;
    try {
      final d = await _api.countWalkIn(serviceId);
      if (mounted && mine == _seq) setState(() => _data = d);
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not save that. Check the connection and try again.');
    }
  }

  /// How many on a booking are in.
  Future<void> _admit(AppointmentView a, int n) async {
    setState(() => _busy = a.id);
    final mine = ++_seq;
    try {
      final d = await _api.admit(a.id, n, version: a.version);
      if (mounted && mine == _seq) _data = d;
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
      if (e.stale) _load();
    } catch (_) {
      if (mounted) showToast(context, 'Could not save that. Check the connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  bool _matches(AppointmentView a) {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return true;
    return a.customer.toLowerCase().contains(q) || a.customerPhone.contains(q) || a.displayNo.toLowerCase().contains(q) || a.title.toLowerCase().contains(q);
  }

  Widget _tabs(FrontDeskData d) {
    int open(String? kind) => d.items.where((a) => a.status != 'cancelled' && a.status != 'no_show' && (kind == null || a.category == kind)).length;
    String label(String name, int n) => n == 0 ? name : '$name $n';
    final tabs = <(String, String)>[
      ('all', label('All', open(null))),
      for (final (id, name) in _kinds)
        if (d.kinds.contains(id) || open(id) > 0) (id, label(name, open(id))),
    ];
    Widget chip(String id, String text) => ModeChip(text, key: ValueKey('desk-tab-$id'), selected: _tab == id, onTap: () => setState(() => _tab = id));
    // the types scroll; Bills stays in sight on the right
    return Row(children: [
      Expanded(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final (id, text) in tabs) Padding(padding: const EdgeInsets.only(right: 6), child: chip(id, text)),
          ]),
        ),
      ),
      const SizedBox(width: 2),
      chip('bills', 'Bills'),
    ]);
  }

  List<Widget> _queue(FrontDeskData d) {
    final shown = d.items.where((a) => (_tab == 'all' || a.category == _tab) && _matches(a)).toList();
    return [
      SvcSearch(hint: 'Search name, phone or booking', fieldKey: const ValueKey('desk-search'), onChanged: (v) => setState(() => _q = v)),
      const SizedBox(height: 10),
      if (shown.isEmpty)
        OrderCardBox(child: Text(_q.trim().isEmpty ? 'No bookings here today.' : 'No booking matches that.', style: inter(14, 400, color: kMuted))),
      for (final (name, statuses) in _sections) ...() {
        final rows = shown.where((a) => statuses.contains(a.status)).toList();
        if (rows.isEmpty) return const <Widget>[];
        return <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 6),
            child: Text('$name · ${rows.length}', key: ValueKey('desk-section-$name'), style: inter(13.5, 700)),
          ),
          for (final a in rows) _row(a),
        ];
      }(),
    ];
  }

  /// Events and activities: a count for each time, its bookings under it, and a way to start counting when no one has booked.
  List<Widget> _door(FrontDeskData d) {
    final sessions = d.sessions.where((x) => x.s('category') == _tab).toList();
    final listings = d.groupListings.where((x) => x.s('category') == _tab).toList();
    final searching = _q.trim().isNotEmpty;
    final cards = <Widget>[
      for (final x in sessions)
        if (!searching || d.items.any((a) => a.s('session_key') == x.s('key') && _matches(a))) _session(d, x),
    ];
    return [
      SvcSearch(hint: 'Search name, phone or booking', fieldKey: const ValueKey('desk-search'), onChanged: (v) => setState(() => _q = v)),
      const SizedBox(height: 10),
      if (cards.isEmpty)
        OrderCardBox(child: Text(searching ? 'No booking matches that.' : 'No one is booked here today. Start a count below when people arrive.', style: inter(14, 400, color: kMuted))),
      ...cards,
      if (listings.isNotEmpty) ...[
        Padding(padding: const EdgeInsets.only(top: 4, bottom: 6), child: Text('Start a count now', style: inter(13.5, 700))),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final l in listings)
            ActionChip(
              key: ValueKey('desk-start-${l.s('service_id')}'),
              avatar: const Icon(Icons.add, size: 16, color: kGreenText),
              label: Text(l.s('name'), style: inter(13, 600)),
              backgroundColor: Colors.white,
              side: const BorderSide(color: kLine),
              onPressed: () => _startCount(l.s('service_id')),
            ),
        ]),
      ],
    ];
  }

  Widget _session(FrontDeskData d, SvcData x) {
    final key = x.s('key');
    final pending = _pending[key] ?? 0;
    final walkIns = x.i('walk_ins') + pending;
    final admitted = x.i('admitted') + pending;
    final capacity = x.raw['capacity'] == null ? null : x.i('capacity');
    final free = capacity == null ? null : x.i('free') - pending;
    final notes = [
      '$walkIns walk-in${walkIns == 1 ? '' : 's'}',
      if (x.i('to_come') > 0) '${x.i('to_come')} booked to come',
      if (free != null) free <= 0 ? 'Full' : '$free free',
    ].join(' · ');
    final rows = d.items.where((a) => a.s('session_key') == key && a.status != 'cancelled' && a.status != 'no_show' && _matches(a)).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        key: ValueKey('desk-session-$key'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(x.s('title'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14.5, 700)),
          Text(x.s('time_label'), style: inter(12, 400, color: kMuted)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(capacity == null ? '$admitted admitted' : '$admitted of $capacity admitted', key: ValueKey('desk-count-$key'), style: inter(18, 800)),
                if (capacity != null) ...[
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(value: (admitted / capacity).clamp(0.0, 1.0), minHeight: 7, backgroundColor: kInfoGreyBg, color: kGreenText),
                  ),
                ],
                const SizedBox(height: 4),
                Text(notes, style: inter(11.5, 400, color: kMuted)),
              ]),
            ),
            const SizedBox(width: 10),
            _CountButton('−1', key: ValueKey('desk-minus-$key'), filled: false, onTap: walkIns > 0 ? () => _count(x, -1) : null),
            const SizedBox(width: 6),
            _CountButton('+1', key: ValueKey('desk-plus-$key'), filled: true, onTap: free != null && free <= 0 ? null : () => _count(x, 1)),
          ]),
          if (rows.isNotEmpty) const Padding(padding: EdgeInsets.only(top: 10), child: Divider(height: 1, color: kLine)),
          for (final a in rows) _guest(a),
        ]),
      ),
    );
  }

  /// One booking under its count: Admit for one person, - 2 of 4 + for a group.
  Widget _guest(AppointmentView a) {
    final places = a.i('places') < 1 ? 1 : a.i('places');
    final inNow = a.i('admitted');
    final due = a.amount - a.paid;
    final open = a.status == 'confirmed' || a.status == 'checked_in';
    final busy = _busy == a.id;
    return InkWell(
      key: ValueKey('desk-row-${a.id}'),
      onTap: () => _open(a),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13.5, 700)),
              Text('${a.displayNo} · $places ${places == 1 ? 'person' : 'people'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 400, color: kMuted)),
              if (due > 0) Text('Due ${svcRupees(due)}', style: inter(11.5, 700, color: const Color(0xFFB45309))),
            ]),
          ),
          const SizedBox(width: 8),
          if (a.can('pay_deposit'))
            _DeskButton('Advance', key: ValueKey('desk-act-${a.id}'), busy: false, onTap: () => _open(a))
          else if (!open)
            ApptStatusChip(label: a.statusLabel, tone: a.tone)
          else if (places == 1)
            inNow == 0
                ? _DeskButton('Admit', key: ValueKey('desk-admit-${a.id}'), busy: busy, onTap: _busy == null ? () => _admit(a, 1) : null)
                : _CountButton('Undo', key: ValueKey('desk-undo-${a.id}'), filled: false, onTap: _busy == null ? () => _admit(a, 0) : null)
          else ...[
            _CountButton('−', key: ValueKey('desk-less-${a.id}'), filled: false, small: true, onTap: inNow > 0 && _busy == null ? () => _admit(a, inNow - 1) : null),
            SizedBox(width: 52, child: Text('$inNow of $places', key: ValueKey('desk-in-${a.id}'), textAlign: TextAlign.center, style: inter(12.5, 700))),
            _CountButton('+', key: ValueKey('desk-more-${a.id}'), filled: true, small: true, onTap: inNow < places && _busy == null ? () => _admit(a, inNow + 1) : null),
            // always there, so + and - never move under a finger at a busy door
            const SizedBox(width: 6),
            _CountButton('All', key: ValueKey('desk-all-${a.id}'), filled: false, small: true, onTap: inNow < places && _busy == null ? () => _admit(a, places) : null),
          ],
        ]),
      ),
    );
  }

  /// Play: each listing's courts, then any booking that has no court.
  List<Widget> _courts(FrontDeskData d) {
    final searching = _q.trim().isNotEmpty;
    final plays = d.items.where((a) => a.category == 'play').toList();
    final known = {for (final x in d.courts) for (final u in x.l('units')) '${x.s('service_id')}|${u.s('name')}'};
    final others = plays.where((a) => !known.contains('${a.s('service_id')}|${a.s('unit')}') && a.status != 'cancelled' && a.status != 'no_show' && _matches(a)).toList();
    final listings = <Widget>[];
    for (final x in d.courts) {
      final cards = <Widget>[];
      for (final u in x.l('units')) {
        final rows = plays.where((a) => a.s('service_id') == x.s('service_id') && a.s('unit') == u.s('name')).toList();
        if (!searching || rows.any(_matches)) cards.add(_court(x, u, rows));
      }
      if (cards.isEmpty) continue;
      listings.add(Padding(padding: const EdgeInsets.only(top: 2, bottom: 6), child: Text(x.s('title'), style: inter(13.5, 700))));
      listings.addAll(cards);
    }
    return [
      SvcSearch(hint: 'Search name, phone or booking', fieldKey: const ValueKey('desk-search'), onChanged: (v) => setState(() => _q = v)),
      const SizedBox(height: 10),
      if (listings.isEmpty && others.isEmpty) OrderCardBox(child: Text(searching ? 'No booking matches that.' : 'No bookings here today.', style: inter(14, 400, color: kMuted))),
      ...listings,
      if (others.isNotEmpty) ...[
        Padding(padding: const EdgeInsets.only(top: 2, bottom: 6), child: Text('Other bookings · ${others.length}', style: inter(13.5, 700))),
        for (final a in others) _row(a),
      ],
    ];
  }

  /// One court. A court booked in parts shows each part on its own line.
  Widget _court(SvcData x, SvcData unit, List<AppointmentView> rows) {
    final key = '${x.s('service_id')}|${unit.s('name')}';
    final open = rows.where((a) => a.status != 'cancelled' && a.status != 'no_show' && a.status != 'completed').toList()..sort((a, b) => a.s('starts_at').compareTo(b.s('starts_at')));
    final done = rows.where((a) => a.status == 'completed').length;
    final parts = open.map((a) => a.s('part')).toSet();
    final split = parts.any((p) => p.isNotEmpty);
    final surface = unit.s('surface');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        key: ValueKey('desk-court-$key'),
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text.rich(TextSpan(children: [
            TextSpan(text: unit.s('name'), style: inter(14.5, 700)),
            if (surface.isNotEmpty) TextSpan(text: ' · $surface', style: inter(11.5, 400, color: kMuted)),
          ]), maxLines: 1, overflow: TextOverflow.ellipsis),
          if (!split)
            _lane(key, null, open)
          else
            for (final p in (parts.toList()..sort()))
              _lane('$key|$p', p.isEmpty ? 'Full ${x.s('unit_word').toLowerCase()}' : p, open.where((a) => a.s('part') == p).toList()),
          if (done > 0) Padding(padding: const EdgeInsets.only(top: 4), child: Text('$done done today', style: inter(11.5, 400, color: kMuted))),
        ]),
      ),
    );
  }

  /// A court or part now: Playing with the time left, Waiting, or Free; then who is next and who has not come.
  Widget _lane(String key, String? part, List<AppointmentView> open) {
    final now = _now;
    DateTime ends(AppointmentView a) => DateTime.tryParse(a.s('ends_at'))?.toLocal() ?? now;
    final playing = open.where((a) => a.status == 'in_service').firstOrNull;
    final here = open.where((a) => a.status == 'checked_in').firstOrNull;
    final ahead = open.where((a) => (a.status == 'confirmed' || a.status == 'deposit_pending') && ends(a).isAfter(now)).toList();
    final missed = open.where((a) => (a.status == 'confirmed' || a.status == 'deposit_pending') && !ends(a).isAfter(now)).toList();
    final first = playing ?? here ?? ahead.firstOrNull;
    final next = playing == null && here == null ? (ahead.length > 1 ? ahead[1] : null) : ahead.firstOrNull;
    final started = first != null && first.startsAt != null && !first.startsAt!.isAfter(now);
    final (status, bg, fg) = playing != null
        ? ('Playing', kChipGreen, kGreenText)
        : here != null || started
            ? ('Waiting', const Color(0xFFFFF1D6), const Color(0xFF7A4E00))
            : ('Free now', const Color(0xFFF1F2F4), kMuted);
    String? line, when;
    Color whenColor = kMuted;
    if (first != null) {
      final people = first.raw['people'] == null ? '' : ' · ${first.i('people')} ${first.i('people') == 1 ? 'person' : 'people'}';
      line = status == 'Free now' ? 'Next: ${first.customer}$people' : '${first.customer}$people';
      if (playing != null) {
        final left = ends(playing).difference(now).inMinutes;
        when = left >= 0 ? '${_length(left)} left' : '${_length(-left)} over';
        if (left < 0) whenColor = const Color(0xFFB45309);
      } else {
        final late = first.startsAt == null ? 0 : now.difference(first.startsAt!).inMinutes;
        when = here == null && late > 0 ? '$late min late' : 'at ${_clockOf(first.startsAt)}';
      }
    }
    final due = first == null ? 0 : first.amount - first.paid;
    final action = first == null ? null : _actionLabel(first);
    final body = Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (part != null) Flexible(child: Padding(padding: const EdgeInsets.only(right: 6), child: Text(part, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 700)))),
            Container(
              key: ValueKey('desk-state-$key'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
              child: Text(status, style: inter(11, 700, color: fg)),
            ),
          ]),
          const SizedBox(height: 3),
          if (line != null) Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13, 600)) else Text('Nothing more booked today', style: inter(12, 400, color: kMuted)),
          if (when != null) Text(when, key: ValueKey('desk-when-$key'), style: inter(12, 600, color: whenColor)),
          if (due > 0) Text('Due ${svcRupees(due)}', style: inter(11.5, 700, color: const Color(0xFFB45309))),
          if (next != null) Text('Next: ${next.customer} at ${_clockOf(next.startsAt)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 400, color: kMuted)),
        ]),
      ),
      if (action != null) ...[
        const SizedBox(width: 8),
        _DeskButton(action, key: ValueKey('desk-act-${first!.id}'), busy: _busy == first.id, onTap: _busy == null ? () => _act(first) : null),
      ],
    ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 6),
      first == null ? body : InkWell(key: ValueKey('desk-row-${first.id}'), onTap: () => _open(first), child: body),
      for (final a in missed)
        InkWell(
          key: ValueKey('desk-missed-${a.id}'),
          onTap: () => _open(a),
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Did not come: ${a.customer} at ${_clockOf(a.startsAt)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 500, color: const Color(0xFFB45309))),
          ),
        ),
    ]);
  }

  Widget _row(AppointmentView a) {
    final due = a.amount - a.paid;
    final action = _actionLabel(a);
    final cancelled = a.status == 'cancelled' || a.status == 'no_show';
    final meta = [
      if (a.status == 'checked_in') a.statusLabel,
      // a court's name is often in the booking's title already
      if (a.s('unit').isNotEmpty && !a.title.contains(a.s('unit'))) a.s('unit'),
      if (a.s('part').isNotEmpty && !a.title.contains(a.s('part'))) a.s('part'),
      if (a.raw['people'] != null) '${a.i('people')} ${a.i('people') == 1 ? 'person' : 'people'}',
      if (a.s('unit').isEmpty && a.provider.isNotEmpty) a.provider,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: kLine)),
        child: InkWell(
          key: ValueKey('desk-row-${a.id}'),
          onTap: () => _open(a),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14.5, 700)),
                  const SizedBox(height: 2),
                  Text('${a.timeLabel} · ${a.title}', maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(12.5, 400, color: kMuted)),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 400, color: kMuted)),
                  ],
                  if (due > 0 && !cancelled) ...[
                    const SizedBox(height: 3),
                    Text('Due ${svcRupees(due)}', style: inter(12, 700, color: const Color(0xFFB45309))),
                  ],
                ]),
              ),
              const SizedBox(width: 8),
              if (action != null)
                _DeskButton(action, key: ValueKey('desk-act-${a.id}'), busy: _busy == a.id, onTap: _busy == null ? () => _act(a) : null)
              else
                ApptStatusChip(label: a.statusLabel, tone: a.tone),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final n = d?.items.where((a) => a.status != 'cancelled' && a.status != 'no_show').length ?? 0;
    return ServicePage(
      title: 'Today',
      subtitle: d == null ? '' : '${d.dateLabel} · $n ${n == 1 ? 'booking' : 'bookings'}',
      onMenu: HomeNav.openMenu == null ? null : () => HomeNav.openMenu!(context),
      onNavigate: widget.onNavigate,
      onRefresh: _refresh,
      error: _error,
      onRetry: _load,
      body: d == null
          ? null
          : [
              _tabs(d),
              const SizedBox(height: 10),
              if (_tab == 'bills')
                BillsScreen(key: ValueKey('desk-bills-$_billsRefresh'), api: _api, onNavigate: widget.onNavigate, embedded: true)
              else
                ...(_tab == 'events' || _tab == 'activities' ? _door(d) : _tab == 'play' && d.courts.isNotEmpty ? _courts(d) : _queue(d)),
            ],
    );
  }
}

/// 25 min · 1 hr · 1 hr 20 min
String _length(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? '$h hr' : '$h hr $m min';
}

String _clockOf(DateTime? t) => t == null ? '' : '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';

/// The door's buttons: large enough to hit without looking.
class _CountButton extends StatelessWidget {
  const _CountButton(this.label, {super.key, required this.filled, required this.onTap, this.small = false});
  final String label;
  final bool filled, small;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final on = onTap != null;
    final size = small ? 34.0 : 50.0;
    return Material(
      color: !filled ? Colors.white : on ? kGreenText : kInfoGreyBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: filled ? BorderSide.none : BorderSide(color: on ? kGreenText : kLine)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: size, minHeight: size),
          child: Center(
            widthFactor: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(label, style: inter(small ? 14 : 16, 800, color: !on ? kMuted : filled ? Colors.white : kGreenText)),
            ),
          ),
        ),
      ),
    );
  }
}

class _DeskButton extends StatelessWidget {
  const _DeskButton(this.label, {super.key, required this.busy, required this.onTap});
  final String label;
  final bool busy;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: kGreenText,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 78, minHeight: 38),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            child: busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text(label, style: inter(13, 700, color: Colors.white)),
          ),
        ),
      );
}
