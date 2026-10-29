import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/net_guard.dart';
import '../inventory/inventory_api.dart' show Facts;
import '../orders/order_screen.dart';
import '../orders/orders_api.dart' show rupees;
import '../tables/table_order_screen.dart';
import '../tables/table_widgets.dart' show TablesEnv;
import '../ui/theme.dart';
import 'kds_board_screen.dart';
import 'kitchen_api.dart';
import 'kitchen_widgets.dart';

/// "KOT view" (founder, 27 Oct 2026): one card per order that went to the kitchen today (`rst_kot_orders`, 0609): its status, number and
/// total, table and dishes, time since it was placed, the captain and whether it is paid, every KOT in order (KOT 1 › KOT 2 › …) with a
/// segment each, how many dishes are ready, the stations with a tick, and Serve, Bill, Print, KDS and View.
/// Optimised 28 Oct 2026: count tiles for the four statuses in one row, orders with dishes to serve first, compact cards (see below).
class KotScreen extends StatefulWidget {
  const KotScreen({super.key, required this.env, this.openOrder});
  final KitchenEnv env;

  /// Opens an order's own page (Bill and View); tests pass their own. By default: the table's order for dine-in, else the order page.
  final void Function(BuildContext context, Facts order)? openOrder;
  @override
  State<KotScreen> createState() => _KotScreenState();
}

class _KotScreenState extends State<KotScreen> {
  Facts? _d;
  String? _error;
  String _status = 'all';
  final _busy = <String>{};
  Timer? _poll;

  /// Orders already known to be cancelled: a new one sounds the cancel alarm once (0621); on opening they are only remembered.
  Set<String>? _cancelSeen;

  @override
  void initState() {
    super.initState();
    _load();
    final every = widget.env.refreshEvery;
    if (every != null) _poll = Timer.periodic(every, (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await widget.env.api.kotOrders(status: _status);
      if (!mounted) return;
      setState(() {
        _d = d;
        _error = null;
      });
      _alarm(d);
    } catch (e) {
      if (mounted) setState(() => _error = errorSentence(e));
    }
  }

  /// A customer, the restaurant or a platform cancelled an order the kitchen has: the same alarm as the KDS, once per order.
  void _alarm(Facts d) {
    final now = {for (final o in d.l('orders')) if (o.s('stage') == 'cancelled' && o.m('cancel').b('recent')) o.s('id')};
    final seen = _cancelSeen;
    _cancelSeen = {...?seen, ...now};
    if (seen != null && now.difference(seen).isNotEmpty && !KdsBoardScreen.muted) widget.env.sounds.cancelled();
  }

  Future<void> _run(Facts o, Future<void> Function() step) async {
    final id = o.s('id');
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await step();
    } on KitchenApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not do that. Try again.');
    }
    if (mounted) setState(() => _busy.remove(id));
    await _load();
  }

  Future<void> _serve(Facts o) => _run(o, () async {
        await widget.env.api.serve(o.ls('ready_item_ids'));
        if (mounted) showToast(context, '#${o.s('display_no')} served.');
      });

  Future<void> _print(Facts o) => _run(o, () async {
        await widget.env.api.act(o.s('latest_ticket'), 'print');
        if (mounted) showToast(context, 'Latest KOT of #${o.s('display_no')} sent to the printer.');
      });

  Future<void> _open(Facts o) async {
    final open = widget.openOrder;
    if (open != null) {
      open(context, o);
    } else if (o.so('table_id') != null && o.s('channel') == 'dine_in') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TableOrderScreen(env: TablesEnv(), tableId: o.s('table_id'))));
    } else {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: o.s('id'))));
    }
    if (mounted) _load();
  }

  /// Cancelled in the last hour first (stop cooking), then ready to serve, cooking (longest waiting first), completed, older cancels.
  static List<Facts> _sorted(List<Facts> orders) {
    int rank(Facts o) => switch (o.s('stage')) {
          'cancelled' => o.m('cancel').b('recent') ? -1 : 4,
          'ready' => o.ls('ready_item_ids').isEmpty ? 2 : 0,
          'new' || 'preparing' => 1,
          _ => 3,
        };
    return [...orders]..sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : b.n('minutes').compareTo(a.n('minutes'));
      });
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final counts = d?.raw['counts'] as Map? ?? const {};
    const statuses = [('all', 'All'), ('preparing', 'Preparing'), ('ready', 'Ready'), ('completed', 'Completed'), ('cancelled', 'Cancelled')];
    return Scaffold(
      backgroundColor: const Color(0xFFF2F3EF),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        leading: IconButton(key: const ValueKey('kot-back'), icon: const Icon(LucideIcons.arrowLeft, color: kInk), onPressed: () => Navigator.of(context).maybePop()),
        title: Text('KOT view', style: inter(18, 800)),
        actions: [IconButton(key: const ValueKey('kot-refresh'), tooltip: 'Refresh', onPressed: _load, icon: const Icon(LucideIcons.refreshCw, size: 20, color: kInk))],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: LayoutBuilder(builder: (context, box) {
          final cols = (box.maxWidth / 380).floor().clamp(1, 4);
          final w = (box.maxWidth - 24 - (cols - 1) * 12) / cols;
          return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 32), children: [
            // four tiles sharing the width: the count large, the status under it
            Row(children: [
              for (final (i, (k, label)) in statuses.indexed) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: Builder(builder: (_) {
                    final (_, ink, tint) = k == 'all' ? ('', kInk, const Color(0xFFE2E4DF)) : _OrderKotCard.look(k);
                    final on = _status == k;
                    return Material(
                      key: ValueKey('kot-status-$k'),
                      color: on ? ink : Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: on ? ink : tint, width: 1.4)),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () {
                          setState(() => _status = k);
                          _load();
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Column(children: [
                            Text('${counts[k] ?? '–'}', style: inter(18, 800, color: on ? Colors.white : ink)),
                            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 700, color: on ? Colors.white : kInk)),
                          ]),
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ]),
            const SizedBox(height: 14),
            if (_error != null && d == null)
              Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kError))))
            else if (d == null)
              const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
            else if (d.l('orders').isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Center(child: Text(_status == 'all' ? 'No kitchen orders yet today.' : 'No orders here right now.', style: inter(14.5, 500, color: kMuted))),
              )
            else
              Wrap(spacing: 12, runSpacing: 12, children: [
                for (final o in _sorted(d.l('orders')))
                  SizedBox(
                    width: w,
                    child: _OrderKotCard(
                      order: o,
                      busy: _busy.contains(o.s('id')),
                      onServe: () => _serve(o),
                      onBill: () => _open(o),
                      onPrint: () => _print(o),
                      onKds: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => KdsBoardScreen(env: widget.env))),
                      onView: () => _open(o),
                    ),
                  ),
              ]),
          ]);
        }),
      ),
    );
  }
}

/// One order on the KOT view, optimised (founder, 28 Oct 2026): a status stripe and tag, where it goes in large type with the order
/// number, items and time under it, the total; one line of facts (how long, paid or not, the captain); the KOT chain with a tick on each
/// ready KOT and the stations; one progress bar; and one main action for the stage (Serve when dishes wait, else Bill), with print,
/// KDS and View as small buttons. Completed orders are quiet and grey; the timer is red only while an order is still cooking and late.
class _OrderKotCard extends StatelessWidget {
  const _OrderKotCard({required this.order, required this.busy, required this.onServe, required this.onBill, required this.onPrint, required this.onKds, required this.onView});
  final Facts order;
  final bool busy;
  final VoidCallback onServe, onBill, onPrint, onKds, onView;

  static const _purple = Color(0xFF7C3AED), _purpleSoft = Color(0xFFEDE4FF), _green = Color(0xFF15803D), _greenSoft = Color(0xFFDCFCE7);
  static const _red = Color(0xFFD1213B);

  /// (name, ink, tint) for a stage.
  static (String, Color, Color) look(String stage) => switch (stage) {
        'ready' => ('READY', _purple, _purpleSoft),
        'preparing' => ('PREPARING', const Color(0xFFB45309), const Color(0xFFFFF1D6)),
        'new' => ('NEW', const Color(0xFF1D4ED8), const Color(0xFFE3EDFF)),
        'cancelled' => ('CANCELLED', _red, const Color(0xFFFFE1E3)),
        _ => ('COMPLETED', const Color(0xFF6B7280), const Color(0xFFEDEEEA)),
      };

  static String _clock(String iso) {
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return '';
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  /// "12 min", "1h 10m", "18h 29m".
  static String age(int minutes) => minutes < 60 ? '$minutes min' : '${minutes ~/ 60}h ${minutes % 60}m';

  @override
  Widget build(BuildContext context) {
    final o = order;
    final no = o.s('display_no');
    final stage = o.s('stage');
    final completed = stage == 'completed';
    final (label, ink, tint) = look(stage);
    final kots = o.l('kots');
    final items = o.n('items').toInt(), ready = o.n('ready').toInt();
    final toServe = o.ls('ready_item_ids');
    final where = switch (o.s('channel')) {
      'dine_in' => o.so('table_label') ?? 'Table',
      'pickup' => 'Takeaway',
      'swiggy' => 'Swiggy',
      'zomato' => 'Zomato',
      'online' => 'OneLocal',
      _ => 'Delivery',
    };
    if (stage == 'cancelled') return _cancelled(where, label, ink, tint);
    final minutes = o.n('minutes').toInt();
    final cooking = stage == 'new' || stage == 'preparing';
    final late = cooking && minutes >= 20; // still in the kitchen after 20 minutes
    final captain = (o.so('captain') ?? '').trim();
    Widget fact(String text, IconData icon, Color fg, Color bg, {Key? key}) => Container(
          key: key,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 12.5, color: fg),
            const SizedBox(width: 4),
            Text(text, style: inter(11.5, 700, color: fg)),
          ]),
        );
    Widget small(IconData icon, String key, String tip, VoidCallback onTap) => Tooltip(
          message: tip,
          child: Material(
            color: const Color(0xFFF4F5F1),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              key: ValueKey(key),
              borderRadius: BorderRadius.circular(10),
              onTap: busy ? null : onTap,
              child: SizedBox(width: 40, height: 40, child: Icon(icon, size: 18, color: kInk)),
            ),
          ),
        );
    // the main action for the stage
    final Widget main = completed
        ? OutlinedButton.icon(
            key: ValueKey('kot-complete-$no'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(40), side: const BorderSide(color: kLine), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            onPressed: busy ? null : onView,
            icon: const Icon(LucideIcons.circleCheck, size: 16, color: Color(0xFF6B7280)),
            label: Text('Completed', style: inter(13, 700, color: const Color(0xFF6B7280))),
          )
        : toServe.isNotEmpty
            ? FilledButton.icon(
                key: ValueKey('kot-serve-$no'),
                style: FilledButton.styleFrom(backgroundColor: _purple, minimumSize: const Size.fromHeight(40), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                onPressed: busy ? null : onServe,
                icon: const Icon(LucideIcons.handPlatter, size: 16),
                label: Text('Serve ${toServe.length}', style: inter(13, 800, color: Colors.white)),
              )
            : FilledButton.icon(
                key: ValueKey('kot-bill-$no'),
                style: FilledButton.styleFrom(backgroundColor: kInk, minimumSize: const Size.fromHeight(40), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                onPressed: busy ? null : onBill,
                icon: const Icon(LucideIcons.receiptText, size: 16, color: Color(0xFFA3F03C)),
                label: Text('Bill', style: inter(13, 800, color: const Color(0xFFA3F03C))),
              );
    return Opacity(
      opacity: completed ? .72 : 1,
      child: Container(
        key: ValueKey('kot-order-$no'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: completed ? kLine : tint, width: 1.4),
          boxShadow: completed ? null : const [BoxShadow(color: Color(0x0F000000), blurRadius: 8, offset: Offset(0, 2))],
        ),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(width: 5, color: ink), // the stage stripe
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  // where it goes, the stage, the total
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Flexible(child: Text(where, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(18, 800))),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(6)),
                            child: Text(label, key: ValueKey('kot-stage-$no'), style: inter(10, 800, color: ink)),
                          ),
                        ]),
                        const SizedBox(height: 2),
                        Text('#$no · $items item${items == 1 ? '' : 's'} · ${_clock(o.s('created_at'))}', key: ValueKey('kot-line-$no'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 500, color: kMuted)),
                      ]),
                    ),
                    Text(rupees(o.n('total')), style: inter(18, 800)),
                  ]),
                  const SizedBox(height: 9),
                  // how long, paid or not, who took it
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    fact(age(minutes), LucideIcons.clock, late ? const Color(0xFFD1213B) : const Color(0xFF4B5563), late ? const Color(0xFFFFE1E3) : const Color(0xFFF1F2EE), key: ValueKey('kot-age-$no')),
                    if (o.b('paid')) fact('Paid', LucideIcons.circleCheck, _green, _greenSoft) else fact('Unpaid', LucideIcons.creditCard, const Color(0xFF92400E), const Color(0xFFFFF4CF)),
                    if (captain.isNotEmpty) fact(captain, LucideIcons.userRound, const Color(0xFF4B5563), const Color(0xFFF1F2EE)),
                    // a table transfer (0617)
                    if (o.mo('moved') != null)
                      fact('Moved ${o.m('moved').s('from')} → ${o.m('moved').s('to')}', LucideIcons.arrowLeftRight, const Color(0xFFB45309), const Color(0xFFFFF1D6), key: ValueKey('kot-moved-$no')),
                    if (!completed && stage == 'ready' && toServe.isEmpty) fact('All served', LucideIcons.handPlatter, _green, _greenSoft, key: ValueKey('kot-served-$no')),
                  ]),
                  if (kots.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    // the KOT chain, a tick on each one that is ready, then the stations
                    Wrap(spacing: 4, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      for (final (n, k) in kots.indexed) ...[
                        if (n > 0) const Icon(LucideIcons.chevronRight, size: 12, color: kMuted),
                        Builder(builder: (_) {
                          final done = k.n('items') > 0 && k.n('ready') >= k.n('items');
                          return Container(
                            key: ValueKey('kot-chip-${k.raw['kot_no']}'),
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(color: done ? _greenSoft : _purpleSoft, borderRadius: BorderRadius.circular(6)),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text('KOT ${k.raw['kot_no']}', style: inter(11, 800, color: done ? _green : _purple)),
                              if (done) ...[const SizedBox(width: 3), const Icon(LucideIcons.check, size: 11, color: _green)],
                            ]),
                          );
                        }),
                      ],
                    ]),
                  ],
                  const SizedBox(height: 10),
                  // one bar: dishes ready of all
                  Row(children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(value: items == 0 ? 0 : ready / items, minHeight: 6, backgroundColor: const Color(0xFFEDEEEA), color: completed ? const Color(0xFF9CA3AF) : ink),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('$ready/$items ready', key: ValueKey('kot-ready-$no'), style: inter(11.5, 800, color: kMuted)),
                  ]),
                  if (o.l('stations').isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      [for (final s in o.l('stations')) '${s.s('name')}${s.b('done') ? ' ✓' : ''}'].join('  ·  '),
                      key: ValueKey('kot-stations-$no'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: inter(11.5, 600, color: kMuted),
                    ),
                  ],
                  const SizedBox(height: 10),
                  // the main action, then print, KDS, View
                  Row(children: [
                    Expanded(child: main),
                    if (!completed && toServe.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      small(LucideIcons.receiptText, 'kot-bill-$no', 'Bill', onBill),
                    ],
                    const SizedBox(width: 6),
                    small(LucideIcons.printer, 'kot-print-$no', 'Print latest KOT', onPrint),
                    const SizedBox(width: 6),
                    small(LucideIcons.chefHat, 'kot-kds-$no', 'Open the KDS', onKds),
                    const SizedBox(width: 6),
                    small(LucideIcons.eye, 'kot-view-$no', 'View the order', onView),
                  ]),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// An order cancelled after it reached the kitchen (0621): red, with "Stop cooking" while it is under an hour old, who cancelled it
  /// (Customer, Restaurant, Swiggy, Zomato, OneLocal) and why, the dishes struck through and its KOTs crossed out. Only View is left.
  Widget _cancelled(String where, String label, Color ink, Color tint) {
    final o = order;
    final no = o.s('display_no');
    final c = o.m('cancel');
    final recent = c.b('recent');
    final reason = (c.so('reason') ?? '').trim();
    final items = o.n('items').toInt();
    return Opacity(
      opacity: recent ? 1 : .72,
      child: Container(
        key: ValueKey('kot-order-$no'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: recent ? ink : kLine, width: recent ? 2 : 1.4),
        ),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(width: 5, color: ink),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Flexible(child: Text(where, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(18, 800))),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(6)),
                            child: Text(label, key: ValueKey('kot-stage-$no'), style: inter(10, 800, color: ink)),
                          ),
                        ]),
                        const SizedBox(height: 2),
                        Text('#$no · $items item${items == 1 ? '' : 's'} · ${_clock(o.s('created_at'))}', key: ValueKey('kot-line-$no'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 500, color: kMuted)),
                      ]),
                    ),
                    Text(rupees(o.n('total')), style: inter(18, 800, color: kMuted).copyWith(decoration: TextDecoration.lineThrough)),
                  ]),
                  const SizedBox(height: 9),
                  // who cancelled, when, why
                  Container(
                    key: ValueKey('kot-cancel-$no'),
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                    decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(10)),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(LucideIcons.octagonX, size: 18, color: ink),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(recent ? 'Stop cooking' : 'Cancelled', style: inter(13.5, 800, color: ink)),
                          Text('By ${c.s('by')} · ${_clock(c.s('at'))}', style: inter(12, 700, color: ink)),
                          if (reason.isNotEmpty) Text('“$reason”', maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(12, 500, color: kInk)),
                        ]),
                      ),
                    ]),
                  ),
                  if (o.l('dishes').isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      [for (final d in o.l('dishes')) '${d.n('qty').toInt()}× ${d.s('name')}'].join('  ·  '),
                      key: ValueKey('kot-dishes-$no'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: inter(12.5, 600, color: kMuted).copyWith(decoration: TextDecoration.lineThrough),
                    ),
                  ],
                  if (o.l('kots').isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final k in o.l('kots'))
                        Container(
                          key: ValueKey('kot-chip-${k.raw['kot_no']}'),
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(6)),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text('KOT ${k.raw['kot_no']}', style: inter(11, 800, color: ink).copyWith(decoration: TextDecoration.lineThrough)),
                            const SizedBox(width: 3),
                            Icon(LucideIcons.x, size: 11, color: ink),
                          ]),
                        ),
                    ]),
                  ],
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    key: ValueKey('kot-view-$no'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(40), side: const BorderSide(color: kLine), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                    onPressed: busy ? null : onView,
                    icon: const Icon(LucideIcons.eye, size: 16, color: kInk),
                    label: Text('View order', style: inter(13, 700)),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
