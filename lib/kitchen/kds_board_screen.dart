import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/net_guard.dart';
import '../inventory/inventory_api.dart' show Facts;
import '../ui/theme.dart';
import 'kitchen_api.dart';
import 'kitchen_widgets.dart';

/// "KDS view" (founder, 27 Oct 2026): the kitchen board. On the left, what is still to cook, by Category, by Item, or Overall. On the right,
/// one card per ticket and station: a coloured header (the table or source, and Hand over), the KOT number with a running MM:SS timer,
/// every dish with its photo, quantity and a switch to mark it done, a progress bar, and "ADD-ON KOT 2 • DINE-IN • T1".
/// The data is the kitchen queue (`kds_queue`); the switches and Hand over are `kds_ticket_act` (item_done / item_undo, then ready + serve).
/// Optimised for the pass (founder, 28 Oct 2026): status filters with counts (All, New, Cooking, Late, Ready), the most urgent tickets
/// first (late, new, cooking oldest first, ready last), late tickets blink, ready ones carry Hand over on the board itself, the "to cook"
/// panel folds away on a phone; and sounds (with a mute switch): a chime for a new ticket, a warning when one runs late, a beep when one
/// is ready. Two layouts (founder, 28 Oct 2026): List (default), each ticket a simple checklist right on the board; and Grid, compact
/// cards that pop up the full ticket on a phone, for when the list gets long.
class KdsBoardScreen extends StatefulWidget {
  const KdsBoardScreen({super.key, required this.env});

  /// Sound on or off, kept for the whole session (a kitchen mutes once).
  static bool muted = false;

  /// 'list' (each ticket a simple checklist, no pop-up) or 'grid' (compact cards; on a phone a tap pops up the full ticket). Kept for the session.
  static String layout = 'list';

  /// Cancelled orders the kitchen has acknowledged (Got it), kept for the session.
  static final dismissedCancels = <String>{};
  final KitchenEnv env;
  @override
  State<KdsBoardScreen> createState() => _KdsBoardScreenState();
}

class _KdsBoardScreenState extends State<KdsBoardScreen> {
  KitchenEnv get env => widget.env;
  Facts? _d;
  Map<String, ({String? image, String category})> _dishes = const {};
  String? _error;
  String _side = 'category';
  final _openCats = <String>{};
  final _busy = <String>{};
  final _rev = ValueNotifier<int>(0); // moves on every change, so an open ticket pop-up follows the latest data
  Timer? _poll, _tick;
  String _filter = 'all';
  bool _todoOpen = false; // the "to cook" panel on a phone: folded until asked

  // what the board has already seen, so each sound plays once: ticket ids, late ones, ready ones (null until the first load)
  Set<String>? _seen;
  final _lateSeen = <String>{}, _readySeen = <String>{}, _movedSeen = <String>{}, _cancelSeen = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
    env.api.dishes().then((d) => mounted ? setState(() => _dishes = d) : null).catchError((_) => null);
    if (env.refreshEvery != null) {
      _poll = Timer.periodic(env.refreshEvery!, (_) => _load());
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        _rev.value++; // the MM:SS timers, on the board and in an open ticket
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    _rev.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await env.api.queue(status: 'all');
      if (mounted) {
        setState(() {
          _d = d;
          _error = null;
        });
        _rev.value++;
        _sound();
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorSentence(e));
    }
  }

  /// One sound per change since the last look: new ticket > late > ready. The first load only remembers what is there.
  void _sound() {
    final cards = _cards;
    final ids = {for (final c in cards) c.s('card_id')};
    final late = {for (final c in cards) if (_status(c) == 'late') c.s('card_id')};
    final ready = {for (final c in cards) if (_status(c) == 'ready') c.s('card_id')};
    final first = _seen == null;
    final isNew = !first && ids.difference(_seen!).isNotEmpty;
    final newLate = late.difference(_lateSeen).isNotEmpty;
    final newReady = ready.difference(_readySeen).isNotEmpty;
    // a table transfer (0617): the ticket's last move, once
    final moved = {for (final c in cards) if (c.mo('moved') != null) '${c.s('card_id')}@${c.m('moved').s('at')}'};
    final newMoved = moved.difference(_movedSeen).isNotEmpty;
    _seen = {...?_seen, ...ids};
    _lateSeen.addAll(late);
    _readySeen.addAll(ready);
    _movedSeen.addAll(moved);
    // an order the kitchen had was cancelled (0618): the alarm, once; on opening the board only remembered
    final cancelled = {for (final x in _d?.l('cancelled') ?? const <Facts>[]) x.s('order_id')};
    final newCancel = !first && cancelled.difference(_cancelSeen).isNotEmpty;
    _cancelSeen.addAll(cancelled);
    if (first || KdsBoardScreen.muted) return;
    if (newCancel) {
      env.sounds.cancelled();
    } else if (isNew) {
      env.sounds.arrive();
    } else if (newLate || newMoved) {
      env.sounds.warning();
    } else if (newReady) {
      env.sounds.ready();
    }
  }

  /// new | cooking | late | ready, as the board colours and sorts it.
  static String _status(Facts c) {
    if (_TicketCard.isReady(c)) return 'ready';
    if (c.b('delayed')) return 'late';
    if (c.s('chip') == 'in_progress' || c.l('items').any((i) => i.b('done'))) return 'cooking';
    return 'new';
  }

  /// The open cards (not yet handed over), most urgent first: late, new, cooking (oldest first in each), ready last.
  List<Facts> get _cards {
    const rank = {'late': 0, 'new': 1, 'cooking': 2, 'ready': 3};
    final open = [for (final c in _d?.l('tickets') ?? const <Facts>[]) if (c.s('chip') != 'served') c];
    open.sort((a, b) {
      final r = rank[_status(a)]!.compareTo(rank[_status(b)]!);
      return r != 0 ? r : a.s('created_at').compareTo(b.s('created_at'));
    });
    return open;
  }

  List<Facts> get _shown => _filter == 'all' ? _cards : [for (final c in _cards) if (_status(c) == _filter) c];

  Future<void> _act(Facts card, String action, {String? itemId}) async {
    final id = card.s('card_id');
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    _rev.value++;
    try {
      await env.api.act(card.s('id'), action, station: card.s('station'), itemId: itemId, version: card.s('version'));
      if (action == 'print' && mounted) showToast(context, 'KOT ${card.raw['kot_no']} sent to the printer.');
    } on KitchenApiException catch (e) {
      if (mounted) showToast(context, e.stale ? 'This ticket changed on another screen. Showing the latest.' : e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not update the ticket. Try again.');
    }
    if (mounted) setState(() => _busy.remove(id));
    _rev.value++;
    await _load();
  }

  /// Hand over: the card is made ready (when it is not yet) and served, one after the other.
  Future<void> _handOver(Facts card) async {
    final id = card.s('card_id');
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    _rev.value++;
    try {
      var version = card.s('version');
      if (card.s('chip') != 'ready') {
        final r = await env.api.act(card.s('id'), 'ready', station: card.s('station'), version: version);
        version = r.so('version') ?? '';
      }
      await env.api.act(card.s('id'), 'serve', station: card.s('station'), version: version.isEmpty ? null : version);
      if (mounted) showToast(context, 'KOT ${card.raw['kot_no']} handed over.');
    } on KitchenApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not hand over the ticket. Try again.');
    }
    if (mounted) setState(() => _busy.remove(id));
    _rev.value++;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return Scaffold(
      backgroundColor: const Color(0xFFF2F3EF),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        leading: IconButton(key: const ValueKey('kds-back'), icon: const Icon(LucideIcons.arrowLeft, color: kInk), onPressed: () => Navigator.of(context).maybePop()),
        title: Row(children: [
          Text('KDS view', style: inter(18, 800)),
          const SizedBox(width: 10),
          if (d != null) Flexible(child: KitchenTag('LIVE · ${_cards.length}', bg: const Color(0xFFE6F9D5), fg: const Color(0xFF2F7D00), size: 12, weight: 700)),
        ]),
        actions: [
          IconButton(
            key: const ValueKey('kds-sound'),
            tooltip: KdsBoardScreen.muted ? 'Sound off: tap to turn on' : 'Sound on: tap to mute',
            onPressed: () {
              setState(() => KdsBoardScreen.muted = !KdsBoardScreen.muted);
              showToast(context, KdsBoardScreen.muted ? 'Kitchen sounds off.' : 'Kitchen sounds on: new, late and ready tickets.');
              if (!KdsBoardScreen.muted) env.sounds.ready(); // a test beep; also lets the browser play later sounds
            },
            icon: Icon(KdsBoardScreen.muted ? LucideIcons.volumeX : LucideIcons.volume2, size: 21, color: KdsBoardScreen.muted ? kMuted : kInk),
          ),
          IconButton(key: const ValueKey('kds-refresh'), tooltip: 'Refresh', onPressed: _load, icon: const Icon(LucideIcons.refreshCw, size: 20, color: kInk)),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8), child: Align(alignment: Alignment.centerLeft, child: _layoutSwitch())),
        ),
      ),
      body: d == null
          ? Center(
              child: _error != null
                  ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kError)))
                  : const CircularProgressIndicator(),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: LayoutBuilder(builder: (context, box) {
                final wide = box.maxWidth >= 760;
                final grid = KdsBoardScreen.layout == 'list' ? _list() : _grid(wide ? box.maxWidth - 280 : box.maxWidth - 24, compact: !wide);
                if (wide) {
                  return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 260, child: ListView(padding: const EdgeInsets.all(12), children: [_sidebar()])),
                    Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(4, 12, 12, 24), children: [..._cancelAlerts(), _filters(), const SizedBox(height: 12), grid])),
                  ]);
                }
                return ListView(padding: const EdgeInsets.fromLTRB(12, 10, 12, 24), children: [
                  ..._cancelAlerts(),
                  _filters(),
                  const SizedBox(height: 10),
                  _todoBar(),
                  if (_todoOpen) ...[const SizedBox(height: 8), _sidebar()],
                  const SizedBox(height: 12),
                  grid,
                ]);
              }),
            ),
    );
  }

  // ---------------------------------------------------------------- status filters, and the folded "to cook" bar (phones)

  static const _looks = {
    'all': ('All', Color(0xFF1F2937), Color(0xFFF1F2EE)),
    'new': ('New', Color(0xFF1D4ED8), Color(0xFFE3EDFF)),
    'cooking': ('Cooking', Color(0xFFB45309), Color(0xFFFFF1D6)),
    'late': ('Late', Color(0xFFD1213B), Color(0xFFFFE1E3)),
    'ready': ('Ready', Color(0xFF15803D), Color(0xFFDDF6E4)),
  };

  Widget _filters() {
    final cards = _cards;
    int count(String k) => k == 'all' ? cards.length : cards.where((c) => _status(c) == k).length;
    // five tiles sharing the width (all always in view on a phone): the count large, the status under it
    return Row(children: [
      for (final (i, e) in _looks.entries.indexed) ...[
        if (i > 0) const SizedBox(width: 6),
        Expanded(
          child: Material(
            key: ValueKey('kds-filter-${e.key}'),
            color: _filter == e.key ? e.value.$2 : Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: _filter == e.key ? e.value.$2 : e.value.$3, width: 1.4)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => setState(() => _filter = e.key),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Column(children: [
                  Text('${count(e.key)}', style: inter(18, 800, color: _filter == e.key ? Colors.white : e.value.$2)),
                  Text(e.value.$1, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 700, color: _filter == e.key ? Colors.white : kInk)),
                ]),
              ),
            ),
          ),
        ),
      ],
    ]);
  }

  /// "To cook · 12 dishes": opens the Category / Item / Overall panel on a phone.
  Widget _todoBar() {
    var dishes = 0;
    for (final c in _cards) {
      for (final i in c.l('items')) {
        if (!i.b('done')) dishes += i.n('qty').toInt();
      }
    }
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: kLine)),
      child: InkWell(
        key: const ValueKey('kds-todo-toggle'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _todoOpen = !_todoOpen),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            const Icon(LucideIcons.chefHat, size: 18, color: kInk),
            const SizedBox(width: 8),
            Expanded(child: Text('To cook · $dishes ${dishes == 1 ? 'dish' : 'dishes'}', style: inter(14, 700))),
            Text(_todoOpen ? 'Hide' : 'By category', style: inter(12.5, 600, color: kMuted)),
            Icon(_todoOpen ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 18, color: kMuted),
          ]),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- the left panel: what is left to cook

  Widget _sidebar() {
    // dishes still to make (not done) on open cards, by name
    final todo = <String, int>{};
    for (final c in _cards) {
      for (final i in c.l('items')) {
        if (!i.b('done')) todo[i.s('name')] = (todo[i.s('name')] ?? 0) + i.n('qty').toInt();
      }
    }
    final byCat = <String, Map<String, int>>{};
    for (final e in todo.entries) {
      final cat = (_dishes[e.key]?.category ?? '').isEmpty ? 'Other' : _dishes[e.key]!.category;
      byCat.putIfAbsent(cat, () => {})[e.key] = e.value;
    }
    Widget badge(int n, {bool green = false}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
          decoration: BoxDecoration(
            color: green ? const Color(0xFFEAF8F0) : const Color(0xFFFFF7E6),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: green ? const Color(0xFF86D9A5) : const Color(0xFFF5C26B)),
          ),
          child: Text('$n', style: inter(12.5, 700, color: green ? const Color(0xFF15803D) : const Color(0xFFB45309))),
        );
    Widget row(String name, int n, {Key? key}) => Container(
          key: key,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
          child: Row(children: [Expanded(child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(14, 500))), badge(n, green: true)]),
        );
    final cards = _cards;
    final total = cards.fold<int>(0, (a, c) => a + c.l('items').length);
    final done = cards.fold<int>(0, (a, c) => a + c.l('items').where((i) => i.b('done')).length);
    final overall = [
      ('Open tickets', cards.length),
      ('Dishes to make', todo.values.fold<int>(0, (a, b) => a + b)),
      ('Dishes done', done),
      ('Delayed tickets', cards.where((c) => c.b('delayed')).length),
      ('Ready to hand over', cards.where((c) => c.s('chip') == 'ready').length),
    ];
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(color: const Color(0xFFF4F5F1), borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              for (final (k, label) in const [('category', 'Category'), ('item', 'Item'), ('overall', 'Overall')])
                Expanded(
                  child: InkWell(
                    key: ValueKey('kds-side-$k'),
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => setState(() => _side = k),
                    child: Container(
                      height: 36,
                      alignment: Alignment.center,
                      decoration: _side == k ? BoxDecoration(color: const Color(0xFF7ED321), borderRadius: BorderRadius.circular(10)) : null,
                      child: Text(label, style: inter(13, _side == k ? 800 : 600)),
                    ),
                  ),
                ),
            ]),
          ),
        ),
        if (_side == 'overall')
          for (final (label, n) in overall) row(label, n, key: ValueKey('kds-overall-$label'))
        else if (_side == 'item')
          if (todo.isEmpty)
            Padding(padding: const EdgeInsets.all(16), child: Text('Nothing left to cook.', style: inter(13.5, 500, color: kMuted)))
          else
            for (final e in (todo.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))) row(e.key, e.value, key: ValueKey('kds-todo-${e.key}'))
        else if (byCat.isEmpty)
          Padding(padding: const EdgeInsets.all(16), child: Text('Nothing left to cook.', style: inter(13.5, 500, color: kMuted)))
        else
          for (final cat in byCat.keys.toList()..sort()) ...[
            InkWell(
              key: ValueKey('kds-cat-$cat'),
              onTap: () => setState(() => _openCats.contains(cat) ? _openCats.remove(cat) : _openCats.add(cat)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                color: const Color(0xFFF8F9F6),
                child: Row(children: [
                  Expanded(child: Text(cat.toUpperCase(), style: inter(13, 800))),
                  badge(byCat[cat]!.values.fold<int>(0, (a, b) => a + b)),
                  const SizedBox(width: 6),
                  Icon(_openCats.contains(cat) ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 18, color: kMuted),
                ]),
              ),
            ),
            if (_openCats.contains(cat)) for (final e in byCat[cat]!.entries) row(e.key, e.value, key: ValueKey('kds-todo-${e.key}')),
          ],
        if (total > 0) const SizedBox(height: 4),
      ]),
    );
  }

  // ---------------------------------------------------------------- cancelled orders (0618)

  /// One red, blinking alert per order cancelled after it reached the kitchen: "CANCELLED · Stop cooking", where it was going, its KOTs
  /// and dishes; Got it hides it for the session.
  List<Widget> _cancelAlerts() {
    final blink = DateTime.now().second.isEven;
    return [
      for (final x in _d?.l('cancelled') ?? const <Facts>[])
        if (!KdsBoardScreen.dismissedCancels.contains(x.s('order_id')))
          AnimatedContainer(
            key: ValueKey('kds-cancel-${x.s('display_no')}'),
            duration: const Duration(milliseconds: 350),
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            decoration: BoxDecoration(
              color: blink ? const Color(0xFFD1213B) : const Color(0xFFB91C1C),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [BoxShadow(color: const Color(0xFFD1213B).withValues(alpha: blink ? .45 : .2), blurRadius: blink ? 16 : 8, offset: const Offset(0, 3))],
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(padding: EdgeInsets.only(top: 2), child: Icon(LucideIcons.octagonX, size: 24, color: Colors.white)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('CANCELLED · Stop cooking', style: inter(15, 900, color: Colors.white)),
                  Text(
                    [
                      '#${x.s('display_no')}',
                      x.so('table_label') ?? _TicketCard._where(x),
                      if (x.l('items').isNotEmpty) 'KOT ${[for (final k in (x.raw['kots'] as List?) ?? const []) k].join(', ')}',
                    ].join(' · '),
                    style: inter(12.5, 700, color: Colors.white.withValues(alpha: .9)),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [for (final i in x.l('items')) '${i.n('qty').toInt()}× ${i.s('name')}${(i.so('variant') ?? '').isEmpty ? '' : ' (${i.s('variant')})'}'].join('  ·  '),
                    style: inter(13.5, 700, color: Colors.white),
                  ),
                  // who cancelled and why (0621)
                  if ((x.so('by') ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'By ${x.s('by')}${(x.so('reason') ?? '').trim().isEmpty ? '' : ' · “${x.s('reason').trim()}”'}',
                        key: ValueKey('kds-cancel-by-${x.s('display_no')}'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: inter(12.5, 600, color: Colors.white.withValues(alpha: .92)),
                      ),
                    ),
                ]),
              ),
              TextButton(
                key: ValueKey('kds-cancel-ok-${x.s('display_no')}'),
                style: TextButton.styleFrom(backgroundColor: Colors.white, foregroundColor: const Color(0xFFB91C1C), visualDensity: VisualDensity.compact),
                onPressed: () => setState(() => KdsBoardScreen.dismissedCancels.add(x.s('order_id'))),
                child: Text('Got it', style: inter(13, 800, color: const Color(0xFFB91C1C))),
              ),
            ]),
          ),
    ];
  }

  // ---------------------------------------------------------------- list or grid

  /// List (a checklist per ticket) | Grid (compact cards, tap for the full ticket).
  Widget _layoutSwitch() => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: const Color(0xFFF1F2EE), borderRadius: BorderRadius.circular(10)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final (k, label, icon) in const [('list', 'List', LucideIcons.list), ('grid', 'Grid', LucideIcons.layoutGrid)])
            Material(
              color: KdsBoardScreen.layout == k ? Colors.white : Colors.transparent,
              elevation: KdsBoardScreen.layout == k ? 1 : 0,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                key: ValueKey('kds-view-$k'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => KdsBoardScreen.layout = k),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, size: 15, color: KdsBoardScreen.layout == k ? kInk : kMuted),
                    const SizedBox(width: 6),
                    Text(label, style: inter(12.5, 700, color: KdsBoardScreen.layout == k ? kInk : kMuted)),
                  ]),
                ),
              ),
            ),
        ]),
      );

  /// The list: one ticket under the other, each a simple checklist; a tap on a dish ticks it, Hand over sits on the ticket.
  Widget _list() {
    final cards = _shown;
    if (cards.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 60),
        child: Center(
          child: Text(_cards.isEmpty ? 'No tickets in the kitchen right now.' : 'No ${_looks[_filter]!.$1.toLowerCase()} tickets.', style: inter(15, 500, color: kMuted)),
        ),
      );
    }
    final blink = DateTime.now().second.isEven;
    return Column(children: [
      for (final c in cards)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: _ListTicket(
              card: c,
              status: _status(c),
              addOn: _addOn(c),
              blink: blink,
              busy: _busy.contains(c.s('card_id')),
              onToggle: (item, on) => _act(c, on ? 'item_done' : 'item_undo', itemId: item.s('id')),
              onHandOver: () => _handOver(c),
              onPrint: () => _act(c, 'print'),
            ),
          ),
        ),
    ]);
  }

  // ---------------------------------------------------------------- the ticket cards

  /// An order's earlier KOTs make this one an add-on.
  bool _addOn(Facts c) {
    final mine = (c.raw['kot_no'] as num?)?.toInt() ?? 0;
    return (_d?.l('tickets') ?? const <Facts>[]).any((x) => x.s('order_id') == c.s('order_id') && ((x.raw['kot_no'] as num?)?.toInt() ?? 0) < mine);
  }

  Widget _fullCard(Facts c) => _TicketCard(
        card: c,
        addOn: _addOn(c),
        busy: _busy.contains(c.s('card_id')),
        photoOf: (name) => _dishes[name]?.image,
        onToggle: (item, on) => _act(c, on ? 'item_done' : 'item_undo', itemId: item.s('id')),
        onHandOver: () => _handOver(c),
        onPrint: () => _act(c, 'print'),
      );

  /// On a tablet, full cards side by side. On a phone, two compact cards to a row; a tap opens the full ticket (founder, 28 Oct 2026).
  Widget _grid(double width, {required bool compact}) {
    final cards = _shown;
    if (cards.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 60),
        child: Center(
          child: Text(_cards.isEmpty ? 'No tickets in the kitchen right now.' : 'No ${_looks[_filter]!.$1.toLowerCase()} tickets.', style: inter(15, 500, color: kMuted)),
        ),
      );
    }
    final cols = compact ? 2 : (width / 230).floor().clamp(1, 6);
    final gap = compact ? 10.0 : 12.0;
    final w = (width - (cols - 1) * gap) / cols;
    final blink = DateTime.now().second.isEven; // late tickets blink with the clock
    return Wrap(spacing: gap, runSpacing: gap, children: [
      for (final c in cards)
        SizedBox(
          width: w,
          child: compact
              ? _MiniTicket(
                  card: c,
                  status: _status(c),
                  addOn: _addOn(c),
                  blink: blink,
                  busy: _busy.contains(c.s('card_id')),
                  onTap: () => _openTicket(c),
                  onHandOver: () => _handOver(c),
                )
              : _fullCard(c),
        ),
    ]);
  }

  /// The full ticket in a pop-up: switches, Hand over and print work there, and it follows the latest data; once handed over it closes.
  Future<void> _openTicket(Facts card) => showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 24),
          backgroundColor: Colors.transparent,
          child: ValueListenableBuilder<int>(
            valueListenable: _rev,
            builder: (ctx, _, _) {
              final now = _cards.where((x) => x.s('card_id') == card.s('card_id')).firstOrNull;
              if (now == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
                });
                return const SizedBox.shrink();
              }
              return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton.filled(
                    key: const ValueKey('kds-detail-close'),
                    style: IconButton.styleFrom(backgroundColor: Colors.white),
                    onPressed: () => Navigator.of(ctx).pop(),
                    icon: const Icon(LucideIcons.x, color: kInk),
                  ),
                ),
                const SizedBox(height: 6),
                Flexible(child: SingleChildScrollView(child: KeyedSubtree(key: const ValueKey('kds-detail'), child: _fullCard(now)))),
              ]);
            },
          ),
        ),
      );
}

/// A ticket at a glance (phones, two to a row): a status stripe and tag, where it goes, KOT and a timer pill, the dishes still to make
/// (quantity first), and at the bottom progress, or Hand over once it is ready. Late tickets blink; a tap opens the full ticket.
class _MiniTicket extends StatelessWidget {
  const _MiniTicket({required this.card, required this.status, required this.addOn, required this.blink, required this.busy, required this.onTap, required this.onHandOver});
  final Facts card;
  final String status;
  final bool addOn, blink, busy;
  final VoidCallback onTap, onHandOver;

  static const _tag = {'new': 'NEW', 'cooking': 'COOKING', 'late': 'LATE', 'ready': 'READY'};

  @override
  Widget build(BuildContext context) {
    final c = card;
    final (_, ink, tint) = _KdsLook.of(status);
    final items = c.l('items');
    final done = items.where((i) => i.b('done')).length;
    final ready = status == 'ready';
    final late = status == 'late';
    // the dishes still to make first; done ones after, faded
    final ordered = [...items.where((i) => !i.b('done')), ...items.where((i) => i.b('done'))];
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: late && blink ? ink : tint, width: late ? 2 : 1.2),
        boxShadow: [BoxShadow(color: late && blink ? ink.withValues(alpha: .25) : const Color(0x0F000000), blurRadius: late && blink ? 12 : 6, offset: const Offset(0, 2))],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('kds-mini-${c.s('card_id')}'),
          onTap: onTap,
          child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(width: 5, color: ink), // the status stripe
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 9, 8, 0),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_TicketCard._where(c), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(17, 800)),
                        Text('${addOn ? '+' : ''}KOT-${c.raw['kot_no'] ?? '—'} · ${_TicketCard._kind(c).replaceAll('-', ' ')}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(10.5, 600, color: kMuted)),
                        if (_TicketCard.moved(c) != null) Padding(padding: const EdgeInsets.only(top: 3), child: _TicketCard.movedTag(c, size: 9.5)),
                      ]),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(6)),
                      child: Text(_tag[status]!, key: ValueKey('kds-status-${c.s('card_id')}'), style: inter(9.5, 800, color: ink)),
                    ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 8, 2),
                  child: Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(8)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(ready ? LucideIcons.circleCheck : LucideIcons.timer, size: 13, color: ink),
                        const SizedBox(width: 4),
                        Text(_TicketCard.clock(c), style: inter(14, 800, color: ink)),
                      ]),
                    ),
                  ]),
                ),
                for (final i in ordered.take(4))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 4, 8, 0),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(width: 22, child: Text('${i.n('qty').toInt()}×', style: inter(12.5, 800, color: i.b('done') ? kMuted : kInk))),
                      Expanded(
                        child: Text(
                          [i.s('name'), if ((i.so('variant') ?? '').isNotEmpty) '(${i.s('variant')})'].join(' '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: inter(12.5, i.b('done') ? 500 : 650, color: i.b('done') ? kMuted : kInk).copyWith(decoration: i.b('done') ? TextDecoration.lineThrough : null),
                        ),
                      ),
                      if (i.b('done')) const Icon(LucideIcons.check, size: 13, color: Color(0xFF22A34A)),
                    ]),
                  ),
                if (items.length > 4) Padding(padding: const EdgeInsets.fromLTRB(32, 2, 8, 0), child: Text('+${items.length - 4} more', style: inter(11, 600, color: kMuted))),
                const SizedBox(height: 8),
                if (ready)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: SizedBox(
                      height: 34,
                      child: FilledButton.icon(
                        key: ValueKey('kds-mini-handover-${c.s('card_id')}'),
                        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF15803D), padding: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                        onPressed: busy ? null : onHandOver,
                        icon: busy
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(LucideIcons.handPlatter, size: 15, color: Colors.white),
                        label: Text('Hand over', style: inter(12.5, 800, color: Colors.white)),
                      ),
                    ),
                  )
                else ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(value: items.isEmpty ? 0 : done / items.length, minHeight: 5, backgroundColor: const Color(0xFFE9EBE6), color: ink),
                    ),
                  ),
                  Padding(padding: const EdgeInsets.fromLTRB(10, 5, 10, 8), child: Text('$done/${items.length} done', style: inter(10.5, 600, color: kMuted))),
                ],
              ]),
            ),
          ])),
        ),
      ),
    );
  }
}

/// A ticket in the list view: one header line (where, KOT, status, timer, print), then the dishes as a checklist with big tap rows
/// (quantity, name, size, note, takeaway), and Hand over once it is ready. No pop-up: everything is on the ticket.
class _ListTicket extends StatelessWidget {
  const _ListTicket({required this.card, required this.status, required this.addOn, required this.blink, required this.busy, required this.onToggle, required this.onHandOver, required this.onPrint});
  final Facts card;
  final String status;
  final bool addOn, blink, busy;
  final void Function(Facts item, bool on) onToggle;
  final VoidCallback onHandOver, onPrint;

  @override
  Widget build(BuildContext context) {
    final c = card;
    final id = c.s('card_id');
    final (_, ink, tint) = _KdsLook.of(status);
    final items = c.l('items');
    final done = items.where((i) => i.b('done')).length;
    final late = status == 'late';
    return AnimatedContainer(
      key: ValueKey('kds-list-$id'),
      duration: const Duration(milliseconds: 350),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: late && blink ? ink : tint, width: late ? 2 : 1.2),
      ),
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(width: 5, color: ink),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // where, KOT and kind, status, timer, print
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 9, 4, 6),
                child: Row(children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(text: _TicketCard._where(c), style: inter(16, 800)),
                        TextSpan(text: '  ${addOn ? '+' : ''}KOT-${c.raw['kot_no'] ?? '—'} · ${_TicketCard._kind(c).replaceAll('-', ' ')}', style: inter(11.5, 600, color: kMuted)),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(8)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(status == 'ready' ? LucideIcons.circleCheck : LucideIcons.timer, size: 13, color: ink),
                      const SizedBox(width: 4),
                      Text(_TicketCard.clock(c), key: ValueKey('kds-list-timer-$id'), style: inter(13.5, 800, color: ink)),
                    ]),
                  ),
                  IconButton(
                    key: ValueKey('kds-list-print-$id'),
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Print KOT',
                    onPressed: busy ? null : onPrint,
                    icon: const Icon(LucideIcons.printer, size: 17, color: kMuted),
                  ),
                ]),
              ),
              if (_TicketCard.moved(c) != null) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8), child: Align(alignment: Alignment.centerLeft, child: _TicketCard.movedTag(c))),
              // the checklist
              for (final i in items)
                InkWell(
                  key: ValueKey('kds-check-${i.s('id')}'),
                  onTap: busy ? null : () => onToggle(i, !i.b('done')),
                  child: Container(
                    decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFF0F1EC)))),
                    padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: i.b('done') ? const Color(0xFF22A34A) : Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: i.b('done') ? const Color(0xFF22A34A) : const Color(0xFFBFC3BA), width: 1.6),
                        ),
                        child: i.b('done') ? const Icon(LucideIcons.check, size: 15, color: Colors.white) : null,
                      ),
                      const SizedBox(width: 10),
                      SizedBox(width: 28, child: Text('${i.n('qty').toInt()}×', style: inter(14.5, 800, color: i.b('done') ? kMuted : kInk))),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(
                            [i.s('name'), if ((i.so('variant') ?? '').isNotEmpty) '(${i.s('variant')})'].join(' '),
                            style: inter(14.5, i.b('done') ? 500 : 650, color: i.b('done') ? kMuted : kInk).copyWith(decoration: i.b('done') ? TextDecoration.lineThrough : null),
                          ),
                          // add-ons and combos chosen at billing (0624)
                          if (i.ls('add_ons').isNotEmpty)
                            Text('+ ${i.ls('add_ons').join(', ')}', key: ValueKey('kds-addons-${i.s('id')}'), style: inter(12.5, 700, color: const Color(0xFF15803D))),
                          if ((i.so('notes') ?? '').isNotEmpty) Text(i.s('notes'), style: inter(12, 600, color: const Color(0xFFB45309))),
                          if (i.b('takeaway')) Text('TAKEAWAY · pack it', style: inter(10.5, 800, color: const Color(0xFFC2410C))),
                        ]),
                      ),
                    ]),
                  ),
                ),
              // progress, or Hand over once ready
              Container(
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFF0F1EC)))),
                padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
                child: Row(children: [
                  Expanded(
                    child: Row(children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(value: items.isEmpty ? 0 : done / items.length, minHeight: 5, backgroundColor: const Color(0xFFE9EBE6), color: ink),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('$done/${items.length}', style: inter(12, 700, color: kMuted)),
                    ]),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    key: ValueKey('kds-list-handover-$id'),
                    style: FilledButton.styleFrom(
                      backgroundColor: status == 'ready' ? const Color(0xFF15803D) : const Color(0xFFE9EBE6),
                      foregroundColor: status == 'ready' ? Colors.white : kInk,
                      visualDensity: VisualDensity.compact,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: busy ? null : onHandOver,
                    icon: busy
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(LucideIcons.handPlatter, size: 15),
                    label: Text('Hand over', style: inter(12.5, 800, color: status == 'ready' ? Colors.white : kInk)),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The board's status colours: (name, ink, tint).
class _KdsLook {
  static (String, Color, Color) of(String status) => switch (status) {
        'late' => ('Late', const Color(0xFFD1213B), const Color(0xFFFFE1E3)),
        'ready' => ('Ready', const Color(0xFF15803D), const Color(0xFFDDF6E4)),
        'cooking' => ('Cooking', const Color(0xFFB45309), const Color(0xFFFFF1D6)),
        _ => ('New', const Color(0xFF1D4ED8), const Color(0xFFE3EDFF)),
      };
}

class _TicketCard extends StatelessWidget {
  const _TicketCard({required this.card, required this.addOn, required this.busy, required this.photoOf, required this.onToggle, required this.onHandOver, required this.onPrint});
  final Facts card;
  final bool addOn, busy;
  final String? Function(String name) photoOf;
  final void Function(Facts item, bool on) onToggle;
  final VoidCallback onHandOver, onPrint;

  static String _where(Facts c) => switch (c.s('channel')) {
        'dine_in' => c.so('table_label') ?? 'Table',
        'pickup' => 'Takeaway',
        'swiggy' => 'Swiggy',
        'zomato' => 'Zomato',
        'online' => 'OneLocal',
        _ => 'Delivery',
      };
  /// The card's colours (header, ink, border): red when delayed, green ready, amber cooking, blue new.
  static (Color, Color, Color) look(Facts c) => c.b('delayed')
      ? (const Color(0xFFFFE1E3), const Color(0xFFD1213B), const Color(0xFFF2A3AE))
      : switch (c.s('chip')) {
          'ready' => (const Color(0xFFDDF6E4), const Color(0xFF15803D), const Color(0xFF9ED9B0)),
          'in_progress' => (const Color(0xFFFFF1D6), const Color(0xFFB45309), const Color(0xFFF2C77B)),
          _ => (const Color(0xFFE3EDFF), const Color(0xFF1D4ED8), const Color(0xFFA9C2F5)),
        };

  /// MM:SS since the ticket was sent.
  /// The timer stops once the ticket is ready (every dish done): it then shows how long the kitchen took, frozen at the ready time.
  static String clock(Facts c) {
    final since = DateTime.tryParse(c.s('created_at'));
    final end = isReady(c) ? (DateTime.tryParse(c.s('ready_at')) ?? DateTime.now()) : DateTime.now();
    final secs = since == null ? 0 : end.difference(since).inSeconds.clamp(0, 99 * 3600);
    return '${(secs ~/ 60).toString().padLeft(2, '0')}:${(secs % 60).toString().padLeft(2, '0')}';
  }

  /// Ready: the kitchen marked it ready, or every dish is ticked.
  static bool isReady(Facts c) => c.s('chip') == 'ready' || c.s('chip') == 'served' || (c.l('items').isNotEmpty && c.l('items').every((i) => i.b('done')));

  /// Green once ready, red while late, ink otherwise.
  static Color clockColor(Facts c) => isReady(c) ? const Color(0xFF15803D) : c.b('delayed') ? const Color(0xFFD1213B) : kInk;

  /// "Moved T2 → T5" after a table transfer (0617), or null.
  static String? moved(Facts c) {
    final m = c.mo('moved');
    return m == null ? null : 'Moved ${m.s('from')} → ${m.s('to')}';
  }

  /// The amber "Moved T2 → T5" tag for a ticket whose order changed table.
  static Widget movedTag(Facts c, {double size = 11}) => Container(
        key: ValueKey('kds-moved-${c.s('card_id')}'),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: const Color(0xFFFFF1D6), borderRadius: BorderRadius.circular(6), border: Border.all(color: const Color(0xFFF2C77B))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(LucideIcons.arrowLeftRight, size: size + 1, color: const Color(0xFFB45309)),
          const SizedBox(width: 4),
          Flexible(child: Text(moved(c)!, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(size, 800, color: const Color(0xFFB45309)))),
        ]),
      );

  static String _kind(Facts c) => switch (c.s('channel')) {
        'dine_in' => 'DINE-IN',
        'pickup' => 'TAKEAWAY',
        _ => 'DELIVERY',
      };

  @override
  Widget build(BuildContext context) {
    final c = card;
    final items = c.l('items');
    final done = items.where((i) => i.b('done')).length;
    final (bg, ink, line) = look(c);
    final timer = clock(c);
    final kot = c.raw['kot_no'];
    return Container(
      key: ValueKey('kds-card-${c.s('card_id')}'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: line, width: 1.4)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // header: where it goes, and Hand over
        Container(
          color: bg,
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
                Text(c.s('channel') == 'dine_in' ? 'TABLE' : 'ORDER', style: inter(10, 600, color: ink.withValues(alpha: 0.75))),
                Text(_where(c), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(18, 800, color: ink)),
                Text(_kind(c).replaceAll('-', ' '), style: inter(10, 600, color: ink.withValues(alpha: 0.75))),
              ]),
            ),
            InkWell(
              key: ValueKey('kds-handover-${c.s('card_id')}'),
              borderRadius: BorderRadius.circular(10),
              onTap: busy ? null : onHandOver,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Column(children: [
                  busy ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: ink)) : Icon(LucideIcons.circleCheck, size: 20, color: ink),
                  const SizedBox(height: 2),
                  Text('Hand over', style: inter(12.5, 700, color: ink)),
                ]),
              ),
            ),
          ]),
        ),
        // KOT number, the running timer, print
        Container(
          color: const Color(0xFFF8F9F6),
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('KOT-${kot ?? '—'}', style: inter(15, 800)),
                Text('TOKEN NO.', style: inter(9.5, 600, color: kMuted)),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(timer, key: ValueKey('kds-timer-${c.s('card_id')}'), style: inter(15, 800, color: clockColor(c))),
              Text(isReady(c) ? 'READY IN' : 'MM:SS', style: inter(9.5, 600, color: kMuted)),
            ]),
            IconButton(
              key: ValueKey('kds-print-${c.s('card_id')}'),
              visualDensity: VisualDensity.compact,
              tooltip: 'Print KOT',
              onPressed: busy ? null : onPrint,
              icon: const Icon(LucideIcons.printer, size: 18, color: kMuted),
            ),
          ]),
        ),
        // the dishes, each with a switch
        for (final i in items)
          Container(
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFEDEEEA)))),
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: photoOf(i.s('name')) == null
                      ? const ColoredBox(color: Color(0xFFF1F1EC), child: Icon(LucideIcons.utensils, size: 16, color: kMuted))
                      : Image.network(photoOf(i.s('name'))!, fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const ColoredBox(color: Color(0xFFF1F1EC), child: Icon(LucideIcons.utensils, size: 16, color: kMuted))),
                ),
              ),
              const SizedBox(width: 8),
              Text('${i.n('qty').toInt()}', style: inter(14, 800)),
              const SizedBox(width: 6),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    [i.s('name'), if ((i.so('variant') ?? '').isNotEmpty) '(${i.s('variant')})'].join(' '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: inter(13.5, 600, color: i.b('done') ? kMuted : kInk).copyWith(decoration: i.b('done') ? TextDecoration.lineThrough : null),
                  ),
                  if (i.ls('add_ons').isNotEmpty)
                    Text('+ ${i.ls('add_ons').join(', ')}', maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(11.5, 700, color: const Color(0xFF15803D))),
                  if ((i.so('notes') ?? '').isNotEmpty) Text(i.s('notes'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 500, color: const Color(0xFFB45309))),
                  if (i.b('takeaway')) Text('TAKEAWAY', style: inter(10, 800, color: const Color(0xFFC2410C))),
                ]),
              ),
              Switch(
                key: ValueKey('kds-item-${i.s('id')}'),
                value: i.b('done'),
                activeThumbColor: Colors.white,
                activeTrackColor: const Color(0xFF5FCB1E),
                inactiveTrackColor: const Color(0xFFE2E4DF),
                inactiveThumbColor: Colors.white,
                trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
                onChanged: busy ? null : (v) => onToggle(i, v),
              ),
            ]),
          ),
        // progress and where it goes
        ClipRRect(
          child: LinearProgressIndicator(
            value: items.isEmpty ? 0 : done / items.length,
            minHeight: 5,
            backgroundColor: const Color(0xFFE6E8E3),
            color: const Color(0xFF22A34A),
          ),
        ),
        Container(
          color: const Color(0xFFFFF8EC),
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
          child: Text(
            [
              '${addOn ? 'ADD-ON ' : ''}KOT ${kot ?? ''}',
              if (moved(c) != null) moved(c)!.toUpperCase(),
              _kind(c),
              _where(c),
              if ((c.so('station_name') ?? '').isNotEmpty) c.s('station_name'),
              if ((c.so('order_note') ?? '').isNotEmpty) c.s('order_note'),
            ].join(' • '),
            key: ValueKey('kds-foot-${c.s('card_id')}'),
            style: inter(11.5, 500),
          ),
        ),
      ]),
    );
  }
}
