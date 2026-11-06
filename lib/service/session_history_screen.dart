import 'package:flutter/material.dart';

import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'service_api.dart';
import 'service_widgets.dart';
import 'visit_screens.dart';

// History of events and activities (6 Nov 2026): the last 90 days, finished or from an earlier day. A finished session cannot be reopened, so
// this is where it can be looked back at: who came, who did not, and the money taken at the door. Every figure is the server's (svc_session_history).

const _ways = [('cash', 'Cash'), ('upi', 'UPI'), ('card', 'Card')];

class SessionHistoryScreen extends StatefulWidget {
  const SessionHistoryScreen({super.key, required this.api, this.category, this.business = '', this.onNavigate});
  final ServiceApi api;

  /// events or activities; opens on that type.
  final String? category;
  final String business;
  final ValueChanged<String>? onNavigate;
  @override
  State<SessionHistoryScreen> createState() => _SessionHistoryScreenState();
}

class _SessionHistoryScreenState extends State<SessionHistoryScreen> {
  late String? _category = widget.category;
  List<SvcData>? _rows;
  String? _error;
  int _seq = 0;
  final _open = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mine = ++_seq;
    setState(() => _error = null);
    try {
      final r = await widget.api.sessionHistory(category: _category);
      if (mounted && mine == _seq) setState(() => _rows = r);
    } on ServiceApiException catch (e) {
      if (mounted && mine == _seq) setState(() => _error = e.message);
    } catch (_) {
      if (mounted && mine == _seq) setState(() => _error = 'Could not load the history. Check the connection and try again.');
    }
  }

  void _pick(String? category) {
    if (category == _category) return;
    setState(() {
      _category = category;
      _rows = null;
    });
    _load();
  }

  Widget _card(SvcData x) {
    final key = x.s('key');
    final open = _open.contains(key);
    final capacity = x.raw['capacity'] == null ? null : x.i('capacity');
    final finished = x.b('finished');
    final guests = x.l('guests');
    final byWay = x.m('by_method');
    final counts = [
      '${x.i('walk_ins')} walk-in${x.i('walk_ins') == 1 ? '' : 's'}',
      if (x.i('booked') > 0) '${x.i('booked')} booked',
      if (x.i('no_show') > 0) '${x.i('no_show')} no-show',
      if (x.i('cancelled') > 0) '${x.i('cancelled')} cancelled',
    ].join(' · ');
    final money = [
      '${svcRupees(x.n('taken'))} at the door',
      for (final (id, label) in _ways)
        if (byWay.n(id) > 0) '$label ${svcRupees(byWay.n(id))}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: kLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            key: ValueKey('history-$key'),
            onTap: () => setState(() => open ? _open.remove(key) : _open.add(key)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(x.s('title'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14.5, 700)),
                    Text('${x.s('date_label')} · ${x.s('time_label')}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 400, color: kMuted)),
                    const SizedBox(height: 4),
                    Text(capacity == null ? '${x.i('admitted')} admitted' : '${x.i('admitted')} of $capacity admitted', style: inter(13.5, 700)),
                    Text(counts, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 400, color: kMuted)),
                    Text(money, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 400, color: kMuted)),
                  ]),
                ),
                const SizedBox(width: 8),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  ApptStatusChip(label: finished ? 'Finished' : 'Not finished', tone: finished ? 'good' : 'warn'),
                  if (guests.isNotEmpty) Icon(open ? Icons.expand_less : Icons.expand_more, size: 20, color: kMuted),
                ]),
              ]),
            ),
          ),
          if (open) ...[
            if (finished && x.s('finished_label').isNotEmpty)
              Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 6), child: Text('Finished ${x.s('finished_label')}', style: inter(11.5, 400, color: kMuted))),
            for (final g in guests) _guest(g),
          ],
        ]),
      ),
    );
  }

  Widget _guest(SvcData g) => InkWell(
        key: ValueKey('history-guest-${g.s('id')}'),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AppointmentDetailScreen(api: widget.api, id: g.s('id'), business: widget.business, onNavigate: widget.onNavigate))),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(g.s('customer'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13, 600)),
                Text('${g.s('display_no')} · ${g.i('admitted')} of ${g.i('places')} came', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 400, color: kMuted)),
              ]),
            ),
            Text(g.s('status_label'), style: inter(11.5, 600, color: kMuted)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return ServicePage(
      title: 'Session history',
      subtitle: 'Last 90 days',
      onRefresh: _load,
      error: _error,
      onRetry: _load,
      body: rows == null
          ? null
          : [
              Wrap(spacing: 6, children: [
                for (final (id, label) in const [(null, 'All'), ('events', 'Events'), ('activities', 'Activities')])
                  ModeChip(label, key: ValueKey('history-tab-${id ?? 'all'}'), selected: _category == id, onTap: () => _pick(id)),
              ]),
              const SizedBox(height: 10),
              if (rows.isEmpty) OrderCardBox(child: Text('No finished or past sessions yet.', style: inter(14, 400, color: kMuted))),
              for (final x in rows) _card(x),
            ],
    );
  }
}
