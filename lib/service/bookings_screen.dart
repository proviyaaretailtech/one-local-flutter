import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../home/home_nav.dart';
import '../orders/order_widgets.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'booking_screen.dart';
import 'job_screens.dart';
import 'map_preview.dart';
import 'service_api.dart';
import 'service_widgets.dart';
import 'visit_screens.dart';

// The Bookings tab (founder's sketch, 2 Nov 2026), the same for every kind of service: Calendar (day, week or month, with Today), a List of
// one day, a Board (Kanban by status) and a Map of the day's doorstep jobs. Below the calendar, the chosen day's bookings: time and length,
// what, who does it, the customer. Every count, label and amount is the server's (svc_calendar).

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
String _clock(DateTime t) => '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
String _dayLabel(DateTime d) => '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]}';

/// 45 min · 1 hr · 1 hr 30 min
String bookingLength(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? '$h hr' : '$h hr $m min';
}

/// Where the work happens, in plain words, for every kind of service.
String bookingKind(String fulfilment) => switch (fulfilment) {
      'on_location' => 'At customer\'s place',
      'event' => 'Group session',
      'on_demand' => 'Online',
      _ => 'At the shop',
    };

/// The Board's columns: which booking states each one holds.
const kBoardColumns = <(String, List<String>)>[
  ('Upcoming', ['deposit_pending', 'confirmed']),
  ('Checked in', ['checked_in']),
  ('In progress', ['in_service']),
  ('Done', ['completed']),
  ('Cancelled', ['cancelled', 'no_show']),
];

class BookingsScreen extends StatefulWidget {
  const BookingsScreen({super.key, this.api, this.onNavigate, this.now, this.openUrl, this.mode = 'calendar'});
  final ServiceApi? api;
  final ValueChanged<String>? onNavigate;

  /// The clock (tests pass a fixed one).
  final DateTime Function()? now;

  /// Opens a map link (tests pass a fake).
  final Future<bool> Function(Uri url)? openUrl;

  /// The view to open on: calendar, list, board or map (the dashboard's Visits tile opens the list, 2 Nov 2026).
  final String mode;
  @override
  State<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends State<BookingsScreen> {
  late final ServiceApi _api = widget.api ?? ServiceApi();
  DateTime get _now => (widget.now ?? DateTime.now)();
  late DateTime _date = DateTime(_now.year, _now.month, _now.day);
  late String _mode = widget.mode; // calendar | list | board | map
  String? _staffId;
  String? _source; // null: all; 'pos': logged offline; 'app': booked online (2 Nov 2026)
  bool _folded = false; // the month view's sheet pulled up: the month folds into the chosen week (2 Nov 2026)
  double _pull = 0; // how far the sheet's handle has been pulled (negative: up)
  int _monthStep = 1; // which way the month moved: a new month slides in from that side
  CalendarData? _data;
  String? _error;
  int _seq = 0;

  bool get _isToday => _iso(_date) == _iso(_now);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mine = ++_seq;
    setState(() => _error = null);
    try {
      final d = await _api.calendar(date: _iso(_date), view: _mode == 'calendar' ? 'month' : 'day', staffId: _staffId, withCancelled: true, source: _source);
      if (!mounted || mine != _seq) return;
      setState(() => _data = d);
    } on ServiceApiException catch (e) {
      if (mounted && mine == _seq) setState(() => _error = e.message);
    } catch (_) {
      if (mounted && mine == _seq) setState(() => _error = 'Could not load bookings. Check the connection and try again.');
    }
  }

  void _go(DateTime d, {bool reload = true}) {
    _date = DateTime(d.year, d.month, d.day);
    if (reload) {
      _load();
    } else {
      setState(() {});
    }
  }

  void _setMode(String m) {
    if (m == _mode) return;
    _mode = m;
    _load();
  }

  Future<void> _pickStaff() async {
    final d = _data;
    if (d == null) return;
    final picked = await showOrderSheet<String>(context, title: 'Staff', body: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(contentPadding: EdgeInsets.zero, title: Text('All staff', style: inter(15, _staffId == null ? 700 : 400)), onTap: () => Navigator.pop(ctx, '')),
          for (final p in d.providers)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${p['name']}', style: inter(15, p['staff_id'] == _staffId ? 700 : 400)),
              subtitle: '${p['title'] ?? ''}'.isEmpty ? null : Text('${p['title']}', style: inter(12.5, 400, color: kMuted)),
              onTap: () => Navigator.pop(ctx, '${p['staff_id']}'),
            ),
        ]));
    if (picked == null) return;
    _staffId = picked.isEmpty ? null : picked;
    _load();
  }

  /// A booking opens its visit; a job visit opens its job.
  Future<void> _open(AppointmentView a) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => a.s('kind') == 'job'
            ? JobDetailScreen(api: _api, id: a.s('job_id'), onNavigate: widget.onNavigate)
            : AppointmentDetailScreen(api: _api, id: a.id, business: _data?.business ?? '', onNavigate: widget.onNavigate)));
    if (mounted) _load();
  }

  Future<void> _newJob() async {
    final made = await Navigator.of(context).push<JobView>(MaterialPageRoute(builder: (_) => NewJobScreen(api: _api, date: _date, today: widget.now)));
    if (made == null || !mounted) return;
    _load();
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => JobDetailScreen(api: _api, id: made.id, onNavigate: widget.onNavigate)));
    if (mounted) _load();
  }

  Future<void> _book() async {
    final booked = await Navigator.of(context).push<AppointmentView>(
        MaterialPageRoute(builder: (_) => ServiceBookingScreen(api: _api, date: _date, business: _data?.business ?? '', location: _data?.locationName ?? '')));
    if (booked != null && mounted) _load();
  }

  /// The chosen day's bookings (the week and month answers hold more days).
  List<AppointmentView> get _dayItems => (_data?.items ?? const <AppointmentView>[]).where((a) => a.day.isEmpty || a.day == _iso(_date)).toList();

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final staffName = d?.providers.where((p) => p['staff_id'] == _staffId).map((p) => '${p['name']}').firstOrNull;
    return ServicePage(
      title: 'Bookings',
      subtitle: d == null ? '' : [_mode == 'calendar' ? d.monthLabel : d.dateLabel, if (d.locationName.isNotEmpty) d.locationName].join(' · '),
      business: d?.business ?? '',
      onMenu: HomeNav.openMenu == null ? null : () => HomeNav.openMenu!(context),
      onRefresh: _load,
      error: _error,
      onRetry: _load,
      body: [
        // create first, where it is seen without scrolling (founder, 2 Nov 2026); a job: several services, a team, a time of your choosing, repeating visits
        Row(children: [
          Expanded(child: SvcTopButton('+ New booking', key: const ValueKey('new-booking'), onTap: _book)),
          const SizedBox(width: 10),
          Expanded(child: SvcTopButton('+ New job', key: const ValueKey('new-job'), dark: false, onTap: _newJob)),
        ]),
        const SizedBox(height: 10),
        _modeTabs(),
        const SizedBox(height: 10),
        // one row of filters (founder, 2 Nov 2026: "decrease this mess"): where it was booked, and whose; no Day / Week / Month any more, the
        // calendar itself folds from the month to the week; Today sits in the calendar's own header
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (_data != null) ..._sourceChips(_data!),
          ModeChip(staffName ?? 'All staff', key: const ValueKey('staff-filter'), selected: _staffId != null, onTap: _pickStaff),
          if (_mode != 'calendar') ModeChip('Today', key: const ValueKey('today'), selected: _isToday, onTap: () => _go(_now)),
        ]),
        const SizedBox(height: 10),
        if (d == null)
          const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kGreenText)))
        else ...switch (_mode) {
          'list' => _list(d),
          'board' => _board(d),
          'map' => _map(d),
          _ => _calendar(d),
        },
      ],
    );
  }

  // ---- the four views

  /// All · Offline · Online (founder, 2 Nov 2026): every booking, only those logged in the POS, or only those booked in the customer app.
  /// Both kinds share the same time slots; the counts are for the days shown.
  List<Widget> _sourceChips(CalendarData d) => [
        for (final (v, l, n) in [(null, 'All', d.offlineCount + d.onlineCount), ('pos', 'Offline', d.offlineCount), ('app', 'Online', d.onlineCount)])
          ModeChip('$l $n', key: ValueKey('source-${v ?? 'all'}'), selected: _source == v, onTap: () {
            if (_source == v) return;
            _source = v;
            _load();
          }),
      ];

  static const _modes = [('calendar', 'Calendar'), ('list', 'List'), ('board', 'Board'), ('map', 'Map')];

  /// Calendar · List · Board · Map; the white highlight slides to the picked view (the store's segmented tabs, founder's reference video).
  Widget _modeTabs() => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: kInfoGreyBg, borderRadius: BorderRadius.circular(14)),
        child: SlidingTabs(
          count: _modes.length,
          height: 34,
          selected: _modes.indexWhere((m) => m.$1 == _mode),
          onSelect: (i) => _setMode(_modes[i].$1),
          keyOf: (i) => ValueKey('mode-${_modes[i].$1}'),
          highlight: Container(
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(10), boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 1))]),
          ),
          builder: (_, i, on) => Text(_modes[i].$2, style: inter(14, on ? 700 : 500, color: on ? kInk : kMuted)),
        ),
      );

  /// The calendar is the planner (founder, 2 Nov 2026): the month with the chosen day's bookings; pulled up, the week with the day by the hour.
  List<Widget> _calendar(CalendarData d) => [_monthGrid(d)];

  List<Widget> _list(CalendarData d) => [
        _weekStrip(d, arrows: true),
        const SizedBox(height: 10),
        SvcSectionHead(_isToday ? 'Today' : _dayLabel(_date), count: '${_dayItems.length} ${_dayItems.length == 1 ? 'booking' : 'bookings'}'),
        if (_dayItems.isEmpty) _empty(),
        for (final a in _dayItems) _card(a),
      ];

  List<Widget> _board(CalendarData d) => [
        _weekStrip(d, arrows: true),
        const SizedBox(height: 10),
        SizedBox(
          height: 340,
          // five columns: all built at once, so a card can be found in any column without scrolling to it
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final (name, states) in kBoardColumns) _column(name, _dayItems.where((a) => states.contains(a.status)).toList()),
            ]),
          ),
        ),
      ];

  List<Widget> _map(CalendarData d) {
    final jobs = _dayItems.where((a) => a.serviceAddress.isNotEmpty && a.status != 'cancelled').toList();
    return [
      _weekStrip(d, arrows: true),
      const SizedBox(height: 10),
      // a drawn example map until the app has a Google Maps key (founder, 2 Nov 2026); one pin per job, numbered as in the list below
      MapPreview(key: const ValueKey('map-preview'), pins: jobs.length),
      const SizedBox(height: 8),
      Text('Example map. The real map comes once the Maps key is added; until then, open each address in Maps.', style: inter(12.5, 400, color: kMuted)),
      const SizedBox(height: 8),
      SvcSectionHead('Jobs at the customer\'s place', count: '${jobs.length}'),
      if (jobs.isEmpty) OrderCardBox(child: Text('No jobs at a customer\'s place on this day.', style: inter(14, 400, color: kMuted))),
      for (final a in jobs)
        SvcCard(
          title: '${a.timeLabel} · ${a.title}',
          onTap: () => _open(a),
          children: [
            SvcKV('Customer', a.customer),
            Align(alignment: Alignment.centerLeft, child: SourceTag(online: a.online)),
            const SizedBox(height: 4),
            SvcKV('Address', a.serviceAddress),
            SvcKV('Staff', a.provider),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: SmallPill('Open in Maps', key: ValueKey('maps-${a.id}'), onTap: () => _openMaps(a.serviceAddress)),
            ),
          ],
        ),
    ];
  }

  Future<void> _openMaps(String address) async {
    final url = Uri.parse('https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}');
    final opened = await (widget.openUrl ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication))(url);
    if (!opened && mounted) showToast(context, 'Could not open Maps.');
  }

  // ---- pieces

  /// The week around the chosen day, each day with its booking count; arrows move a week.
  Widget _weekStrip(CalendarData d, {bool arrows = false}) => Row(children: [
        if (arrows) _arrow(LucideIcons.chevronLeft, 'week-back', () => _go(_date.subtract(const Duration(days: 7)))),
        for (final w in d.week)
          Expanded(
            child: Semantics(
              button: true,
              selected: w['selected'] == true,
              label: '${w['weekday']} ${w['day']}, ${w['count']} bookings',
              child: InkWell(
                key: ValueKey('day-${w['date']}'),
                borderRadius: BorderRadius.circular(14),
                onTap: () => _go(DateTime.parse('${w['date']}')),
                child: ExcludeSemantics(child: _dayCell('${w['weekday']}', '${w['day']}', (w['count'] as num?)?.toInt() ?? 0, '${w['date']}' == _iso(_date), '${w['date']}' == _iso(_now))),
              ),
            ),
          ),
        if (arrows) _arrow(LucideIcons.chevronRight, 'week-next', () => _go(_date.add(const Duration(days: 7)))),
      ]);

  Widget _arrow(IconData icon, String key, VoidCallback onTap) =>
      IconButton(key: ValueKey(key), visualDensity: VisualDensity.compact, icon: Icon(icon, size: 20, color: kInk), onPressed: onTap);

  /// One day of the week strip (founder, 2 Nov 2026): its letter (M T W T F S S) over a round day number; filled when chosen, ringed for
  /// today; the number of bookings under it.
  Widget _dayCell(String top, String day, int count, bool selected, bool today) => Column(mainAxisSize: MainAxisSize.min, children: [
        Text(top.isEmpty ? '' : top[0], style: inter(12.5, 600, color: kMuted)),
        const SizedBox(height: 3),
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? kPrimary : Colors.white,
            border: Border.all(color: selected ? kPrimary : today ? kLink : kLine, width: today && !selected ? 2 : 1),
          ),
          child: Text(day, style: inter(14.5, 700, color: selected ? Colors.white : kInk)),
        ),
        const SizedBox(height: 4),
        Text(count == 0 ? ' ' : '$count', style: inter(11, 700, color: kLink)),
      ]);

  // ---- the month as a planner (founder, 2 Nov 2026, after a Dribbble "Planner App" reference): a white month card (founder: "make it white"), and a sheet under it
  // with the chosen day's bookings as pastel cards. Pull the sheet's handle up and the month folds into the chosen week, the sheet showing
  // the day by the hour; pull it down and the month opens again. Tapping the handle does the same.

  static const _cardLine = Color(0xFFE6E8E3); // the card's edge and the line above the sheet
  static const _chosen = kInk; // the chosen day's pill
  static const _soft = Color(0xFF9AA0A6); // weekday letters
  static const _dot = kGreenText; // a day with bookings, and today's ring

  /// Pastel colours for a booking (yellow, pink, green, blue as in the reference), with a deeper ink for its small text.
  static (Color, Color) _pastel(AppointmentView a) => switch (a.status) {
        'deposit_pending' => (const Color(0xFFF7C9D4), const Color(0xFF9D2A4B)), // waiting for the advance: pink
        'checked_in' || 'in_service' => (const Color(0xFFCDE8B9), const Color(0xFF2F6B12)), // happening now: green
        'completed' => (const Color(0xFFCFE0F7), const Color(0xFF24508F)), // done: blue
        'cancelled' || 'no_show' => (const Color(0xFFE6E7EA), const Color(0xFF5B6069)), // grey
        _ => (const Color(0xFFFBE3A1), const Color(0xFF8A5A00)), // booked, coming up: yellow
      };

  Widget _monthGrid(CalendarData d) {
    final days = d.month;
    final lead = days.isEmpty ? 0 : ((days.first['isodow'] as num?)?.toInt() ?? 1) - 1;
    // folded: only the chosen day's week (from the month's own days, so no other call)
    final monday = _date.subtract(Duration(days: _date.weekday - 1));
    final weekIsos = {for (var i = 0; i < 7; i++) _iso(monday.add(Duration(days: i)))};
    final shown = _folded ? days.where((m) => weekIsos.contains('${m['date']}')).toList() : days;
    final pad = _folded ? (shown.isEmpty ? 0 : ((shown.first['isodow'] as num?)?.toInt() ?? 1) - 1) : lead;
    final cells = <Widget>[
      for (var i = 0; i < pad; i++) const SizedBox.shrink(),
      for (final m in shown)
        Semantics(
          button: true,
          label: '${m['day']}, ${m['count']} bookings',
          child: InkWell(
            key: ValueKey('mday-${m['date']}'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => _go(DateTime.parse('${m['date']}'), reload: false),
            child: ExcludeSemantics(child: _monthCell(m)),
          ),
        ),
    ];
    Widget arrow(IconData icon, String key, VoidCallback onTap) =>
        IconButton(key: ValueKey(key), visualDensity: VisualDensity.compact, icon: Icon(icon, size: 20, color: kInk), onPressed: onTap);
    return ClipRRect(
      key: const ValueKey('planner'),
      borderRadius: BorderRadius.circular(26),
      child: Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(26), border: Border.all(color: _cardLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 0),
            child: Row(children: [
              Expanded(child: Text(d.monthLabel, style: inter(19, 800))),
              // back to today from any month or day; the calendar's own Today (2 Nov 2026)
              if (!_isToday || _date.month != _now.month) SmallPill('Today', key: const ValueKey('today'), onTap: () => _go(_now)),
              arrow(LucideIcons.chevronLeft, 'month-back', () {
                _monthStep = -1;
                _go(DateTime(_date.year, _date.month - 1, 1));
              }),
              arrow(LucideIcons.chevronRight, 'month-next', () {
                _monthStep = 1;
                _go(DateTime(_date.year, _date.month + 1, 1));
              }),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(children: [for (final w in _weekdays) Expanded(child: Text(w.substring(0, 2), textAlign: TextAlign.center, style: inter(11.5, 600, color: _soft)))]),
          ),
          // the month folds into the chosen week, and opens again, smoothly
          AnimatedSize(
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              // a new month slides in from the side it comes from, fading (the store's motion, founder's reference video)
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 340),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(position: Tween<Offset>(begin: Offset(0.12 * _monthStep, 0), end: Offset.zero).animate(a), child: child),
                ),
                // a fixed row height (2 Nov 2026): with the height tied to the width, narrow phones cut the dots under the day off (overflow)
                child: GridView(
                  key: ValueKey('grid-${d.monthLabel}'),
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7, mainAxisExtent: 50),
                  children: cells,
                ),
              ),
            ),
          ),
          _sheet(d),
        ]),
      ),
    );
  }

  Widget _monthCell(Map<String, dynamic> m) {
    final selected = '${m['date']}' == _iso(_date);
    final today = m['today'] == true;
    final count = (m['count'] as num?)?.toInt() ?? 0;
    // scales down rather than overflowing when a phone is very narrow
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? _chosen : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            border: today && !selected ? Border.all(color: _dot, width: 1.5) : null,
          ),
          child: Text('${m['day']}', style: inter(14, selected ? 800 : 600, color: selected ? Colors.white : kInk)),
        ),
        const SizedBox(height: 3),
        // a dot for each booking, up to three (the number is in the day's screen-reader label)
        SizedBox(
          key: ValueKey('mdots-${m['date']}'),
          height: 6,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < count.clamp(0, 3); i++)
              Container(width: 4, height: 4, margin: const EdgeInsets.symmetric(horizontal: 1), decoration: const BoxDecoration(color: _dot, shape: BoxShape.circle)),
          ]),
        ),
      ]),
    );
  }

  /// The white sheet under the month: its handle folds or opens the month; the day's bookings as pastel cards, or the day by the hour.
  Widget _sheet(CalendarData d) {
    final items = _dayItems;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // a quick flick or a slow pull of 40 px both count
      onVerticalDragStart: (_) => _pull = 0,
      onVerticalDragUpdate: (e) => _pull += e.delta.dy,
      onVerticalDragEnd: (e) {
        final v = e.primaryVelocity ?? 0;
        if ((v < -120 || _pull < -40) && !_folded) setState(() => _folded = true);
        if ((v > 120 || _pull > 40) && _folded) setState(() => _folded = false);
      },
      child: Container(
        decoration: const BoxDecoration(color: Color(0xFFFAFAF8), border: Border(top: BorderSide(color: _cardLine))),
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(
            child: Semantics(
              button: true,
              label: _folded ? 'Open the month' : 'Fold the month',
              child: InkWell(
                key: const ValueKey('planner-handle'),
                borderRadius: BorderRadius.circular(10),
                onTap: () => setState(() => _folded = !_folded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                  child: Container(width: 40, height: 5, decoration: BoxDecoration(color: const Color(0xFFD9DBDF), borderRadius: BorderRadius.circular(9))),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
              child: Text(_folded ? (_isToday ? 'Today, by the hour' : '${_dayLabel(_date)}, by the hour') : (_isToday ? 'Upcoming today' : 'On ${_dayLabel(_date)}'),
                  style: inter(15, 800)),
            ),
            Text('${items.length} ${items.length == 1 ? 'booking' : 'bookings'}', style: inter(12.5, 600, color: kMuted)),
          ]),
          const SizedBox(height: 10),
          if (d.closed != null) ...[SvcInfo(title: 'Closed', text: d.closed!), const SizedBox(height: 6)],
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            switchInCurve: Curves.easeOutCubic,
            child: _folded
                ? KeyedSubtree(key: const ValueKey('planner-hours'), child: _pastelHours(items))
                : KeyedSubtree(
                    key: const ValueKey('planner-cards'),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (items.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text('No bookings on this day. Tap New booking to add one.', style: inter(13.5, 400, color: kMuted))),
                      // the day's cards cascade in, one after another, each time a day is picked (the store's Entrance)
                      for (final (i, a) in items.indexed) Entrance(key: ValueKey('in-${_iso(_date)}-${a.id}'), index: i, child: _pastelCard(a)),
                    ]),
                  ),
          ),
        ]),
      ),
    );
  }

  /// One booking as a pastel card: what and when, the status, then customer, staff and where it came from.
  Widget _pastelCard(AppointmentView a, {bool compact = false}) {
    final (bg, ink) = _pastel(a);
    Widget meta(IconData icon, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: ink),
          const SizedBox(width: 4),
          Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 600, color: ink))),
        ]);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: ValueKey(compact ? 'block-${a.id}' : 'booking-${a.id}'),
          borderRadius: BorderRadius.circular(16),
          onTap: () => _open(a),
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, compact ? 8 : 11, 12, compact ? 8 : 11),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 800, color: kInk))),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(99)),
                  child: Text(a.statusLabel, style: inter(10.5, 700, color: ink)),
                ),
              ]),
              const SizedBox(height: 6),
              Wrap(spacing: 12, runSpacing: 4, children: [
                meta(LucideIcons.clock, '${a.timeLabel} · ${bookingLength(a.durationMin)}'),
                meta(LucideIcons.user, a.customer),
                if (!compact) meta(LucideIcons.userCheck, a.provider),
                if (!compact && a.serviceAddress.isNotEmpty) meta(LucideIcons.mapPin, a.serviceAddress),
                meta(a.online ? LucideIcons.smartphone : LucideIcons.store, a.online ? 'Online' : 'Offline'),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  /// The folded sheet: the chosen day by the hour, each booking a pastel block at the hour it starts, a line at the current time.
  Widget _pastelHours(List<AppointmentView> items) {
    final starts = items.map((a) => a.startsAt?.hour).whereType<int>();
    final from = starts.isEmpty ? 9 : (starts.reduce((a, b) => a < b ? a : b)).clamp(0, 9);
    final to = starts.isEmpty ? 20 : (starts.reduce((a, b) => a > b ? a : b) + 1).clamp(20, 24);
    return Column(children: [
      for (var h = from; h < to; h++)
        Container(
          constraints: const BoxConstraints(minHeight: 36),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFF0F1F3)))),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 50,
              child: Padding(padding: const EdgeInsets.only(top: 6), child: Text(_clock(DateTime(2000, 1, 1, h)).replaceFirst(':00', ''), style: inter(11.5, 600, color: kMuted))),
            ),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (_isToday && _now.hour == h) _nowLine(),
                for (final a in items.where((a) => a.startsAt?.hour == h))
                  Entrance(key: ValueKey('in-h-${_iso(_date)}-${a.id}'), index: items.indexOf(a), child: Padding(padding: const EdgeInsets.only(top: 6), child: _pastelCard(a, compact: true))),
              ]),
            ),
          ]),
        ),
    ]);
  }

  Widget _nowLine() => Padding(
        key: const ValueKey('now-line'),
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Container(width: 9, height: 9, decoration: const BoxDecoration(color: kLink, shape: BoxShape.circle)),
          Expanded(child: Container(height: 1.5, color: kLink)),
          const SizedBox(width: 6),
          Text('Now ${_clock(_now)}', style: inter(11.5, 700, color: kLink)),
        ]),
      );

  /// A booking in the day timeline: compact, coloured by status.
  Widget _block(AppointmentView a) {
    final (bg, edge) = switch (a.tone) {
      'good' => (kChipGreen, kLink),
      'warn' => (const Color(0xFFFFF9E3), const Color(0xFFF59E0B)),
      'bad' => (kBadBg, kBadText),
      _ => (kInfoGreyBg, kMuted),
    };
    return InkWell(
      key: ValueKey('block-${a.id}'),
      borderRadius: BorderRadius.circular(12),
      onTap: () => _open(a),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12), border: Border(left: BorderSide(color: edge, width: 4))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${a.timeLabel} · ${a.title}', style: inter(14, 700), maxLines: 1, overflow: TextOverflow.ellipsis)),
            Text(a.statusLabel, style: inter(12, 600, color: edge == kMuted ? kInk : edge)),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            SourceTag(online: a.online, short: true),
            const SizedBox(width: 6),
            Expanded(child: Text('${a.customer} · ${a.provider} · ${bookingLength(a.durationMin)}', style: inter(12.5, 400, color: kMuted), maxLines: 1, overflow: TextOverflow.ellipsis)),
          ]),
        ]),
      ),
    );
  }

  /// A booking with everything the day panel shows: time and length, what, status and kind, customer, staff, address, amount.
  Widget _card(AppointmentView a) => SvcCard(
        key: ValueKey('booking-${a.id}'),
        title: '${a.timeLabel} · ${a.title}',
        onTap: () => _open(a),
        children: [
          Wrap(spacing: 8, runSpacing: 6, children: [ApptStatusChip(label: a.statusLabel, tone: a.tone), SourceTag(online: a.online), TagChip(bookingKind(a.fulfilment))]),
          const SizedBox(height: 10),
          SvcKV('Length', bookingLength(a.durationMin)),
          SvcKV('Customer', a.customerPhone.isEmpty ? a.customer : '${a.customer} · ${svcPhone(a.customerPhone)}'),
          SvcKV('Staff', a.resource == null ? a.provider : '${a.provider} · ${a.resource}'),
          if (a.serviceAddress.isNotEmpty) SvcKV('Address', a.serviceAddress),
          SvcKV('Amount', a.paid >= a.amount && a.amount > 0 ? '${svcRupees(a.amount)} · paid' : '${svcRupees(a.amount)} · ${svcRupees(a.paid)} paid'),
        ],
      );

  Widget _column(String name, List<AppointmentView> items) => Container(
        key: ValueKey('column-$name'),
        width: 220,
        margin: const EdgeInsets.only(right: 12),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: kInfoGreyBg, borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(name, style: inter(15, 700))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999)),
              child: Text('${items.length}', style: inter(12.5, 700)),
            ),
          ]),
          const SizedBox(height: 10),
          Expanded(
            child: items.isEmpty
                ? Text('Nothing here', style: inter(13, 400, color: kMuted))
                : ListView(children: [for (final a in items) Padding(padding: const EdgeInsets.only(bottom: 8), child: _block(a))]),
          ),
        ]),
      );

  Widget _empty() => OrderCardBox(child: Text('No bookings on this day. Tap New booking to add one.', style: inter(14, 400, color: kMuted)));
}
