import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../inventory/inventory_widgets.dart';
import '../ui/theme.dart';
import 'kitchen_api.dart';
import 'kitchen_widgets.dart';

/// Figma "Kitchen Display System": live count, search, station chips, six counters, status chips and the ticket cards. Every number and every
/// button comes from `kds_queue`; a tap sends one `kds_ticket_act` and the screen asks again.
class KdsScreen extends StatefulWidget {
  const KdsScreen({super.key, required this.env});
  final KitchenEnv env;
  @override
  State<KdsScreen> createState() => _KdsScreenState();
}

class _KdsScreenState extends State<KdsScreen> {
  KitchenEnv get env => widget.env;
  Facts? _d;
  String? _error;
  String _station = '', _status = 'all', _q = '';
  final _search = TextEditingController();
  Timer? _timer, _debounce;
  final _busy = <String>{}; // ticket ids with a tap in flight

  @override
  void initState() {
    super.initState();
    _load();
    if (env.refreshEvery != null) _timer = Timer.periodic(env.refreshEvery!, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await env.api.queue(station: _station.isEmpty ? null : _station, status: _status, q: _q);
      if (!mounted) return;
      setState(() {
        _d = d;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _act(Facts t, String action, {String? itemId}) async {
    final id = t.s('card_id');
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await env.api.act(t.s('id'), action, station: t.s('station'), itemId: itemId, version: t.s('version'));
      if (action == 'print' && mounted) showToast(context, 'Ticket sent to the printer.');
    } on KitchenApiException catch (e) {
      if (mounted) showToast(context, e.stale ? 'This ticket changed on another screen. Showing the latest.' : e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not update the ticket. Try again.');
    }
    if (mounted) setState(() => _busy.remove(id));
    await _load();
  }

  @override
  Widget build(BuildContext context) => KitchenPage(
        env: env,
        title: 'Kitchen Display System',
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 24), children: [
          InvLoad<Facts>(data: _d, error: _error, onRetry: _load, builder: _body),
        ]),
      );

  List<Widget> _body(Facts d) {
    final stats = d.m('stats'), counts = d.m('counts');
    final tickets = d.l('tickets');
    final canAct = d.m('can').b('act');
    return [
      Align(alignment: Alignment.centerLeft, child: KitchenTag('LIVE · ${d.n('live').toInt()} ORDERS', bg: kLimeSoftH, fg: const Color(0xFF2F7D00), size: 14, weight: 700)),
      const SizedBox(height: 12),
      SizedBox(
        height: 48,
        child: TextField(
          controller: _search,
          onChanged: (v) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 350), () {
              _q = v;
              _load();
            });
          },
          style: inter(15, 400),
          decoration: InputDecoration(
            hintText: 'Search orders or items...',
            hintStyle: inter(15, 400, color: kMuted),
            prefixIcon: const Icon(LucideIcons.search, size: 17, color: kMuted),
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFD9DBD5))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: kInk)),
          ),
        ),
      ),
      const SizedBox(height: 12),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _Pill('All', _station.isEmpty, () => _pickStation('')),
          for (final s in d.l('stations')) ...[const SizedBox(width: 8), _Pill(s.s('name'), _station == s.s('key'), () => _pickStation(s.s('key')), key: ValueKey('station-chip-${s.s('key')}'))],
        ]),
      ),
      const SizedBox(height: 14),
      GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.45,
        children: [
          _Stat('QUEUE / CRITICAL', stats.n('queue_critical'), const Color(0xFFFFF1F1), const Color(0xFFB91C1C)),
          _Stat('PENDING', stats.n('pending'), const Color(0xFFFFFAEB), const Color(0xFFB45309)),
          _Stat('DINE-IN ORDERS', stats.n('dine_in'), const Color(0xFFEEF4FF), const Color(0xFF1D4ED8)),
          _Stat('ONLINE DELIVERY', stats.n('online_delivery'), const Color(0xFFF5F0FF), const Color(0xFF7E22CE)),
          _Stat('DELAYED', stats.n('delayed'), const Color(0xFFFFF3E8), const Color(0xFFC2410C)),
          _Stat('COMPLETED TODAY', stats.n('completed_today'), const Color(0xFFEAF8F0), const Color(0xFF15803D)),
        ],
      ),
      const SizedBox(height: 14),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (id, label, color) in [('all', 'All', kInk), ('new', 'New', const Color(0xFF1D4ED8)), ('in_progress', 'In progress', kAmberText), ('ready', 'Ready', const Color(0xFF15803D)), ('served', 'Served', kInk)])
          _Pill('$label ${counts.n(id).toInt()}', _status == id, () {
            setState(() => _status = id);
            _load();
          }, key: ValueKey('status-$id'), color: color, tight: true),
      ]),
      const SizedBox(height: 14),
      if (tickets.isEmpty) InvCard(child: Text(_q.isNotEmpty || _status != 'all' || _station.isNotEmpty ? 'No orders match.' : 'No orders in the kitchen right now.', style: inter(15, 400, color: kMuted))),
      for (final t in tickets) _TicketCard(key: ValueKey('ticket-${t.s('card_id')}'), t: t, canAct: canAct, busy: _busy.contains(t.s('card_id')), onAct: _act),
    ];
  }

  void _pickStation(String key) {
    setState(() => _station = key);
    _load();
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, this.active, this.onTap, {super.key, this.color = kInk, this.tight = false});
  final String label;
  final bool active, tight;
  final VoidCallback onTap;
  final Color color;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: active,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: tight ? 14 : 18, vertical: 9),
            decoration: BoxDecoration(
              color: active ? kLimeSoftH : Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: active ? const Color(0xFF76EC00) : kLine, width: active ? 1.6 : 1),
            ),
            child: Text(label, style: inter(14, active ? 700 : 500, color: active ? kInk : color == kInk ? kMuted : color)),
          ),
        ),
      );
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.bg, this.fg);
  final String label;
  final num value;
  final Color bg, fg;
  @override
  Widget build(BuildContext context) => Semantics(
        label: '$label ${value.toInt()}',
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
          child: ExcludeSemantics(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(label, maxLines: 1, style: inter(11.5, 600, color: fg))),
              const Spacer(),
              Text('${value.toInt()}', style: inter(25, 700)),
            ]),
          ),
        ),
      );
}

class _TicketCard extends StatelessWidget {
  const _TicketCard({super.key, required this.t, required this.canAct, required this.busy, required this.onAct});
  final Facts t;
  final bool canAct, busy;
  final Future<void> Function(Facts t, String action, {String? itemId}) onAct;
  @override
  Widget build(BuildContext context) {
    final chip = t.s('chip');
    final (label, bg, fg) = ticketLook(chip);
    final items = t.l('items');
    final urgent = t.s('priority') == 'urgent';
    final live = chip == 'new' || chip == 'in_progress';
    final note = t.so('order_note');
    final channel = t.s('channel');
    final stations = t.ls('stations');
    return InvCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('#${t.s('display_no')}', style: inter(20, 700))),
          if (urgent) Text('URGENT · ${t.n('age_minutes').toInt()}m', style: inter(15, 700, color: kRedText)) else Text('${t.n('age_minutes').toInt()}m', style: inter(15, 500, color: t.b('delayed') ? kAmberText : kMuted)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          KitchenTag(label, bg: bg, fg: fg, size: 13.5, weight: 700),
          const SizedBox(width: 16),
          Flexible(child: Text(channelLabel(channel), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(15, 400, color: kMuted))),
          const Spacer(),
          Text('${t.n('done_count').toInt()}/${t.n('item_count').toInt()} items done', style: inter(14.5, 400, color: kMuted)),
        ]),
        const SizedBox(height: 6),
        for (final i in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(child: Text(i.s('name'), style: inter(17, 400, color: i.b('done') ? kMuted : kInk))),
              Semantics(
                label: '${i.s('name')} done',
                toggled: i.b('done'),
                child: Switch(
                  key: ValueKey('item-${i.s('id')}'),
                  value: i.b('done'),
                  activeThumbColor: Colors.white,
                  activeTrackColor: const Color(0xFF76EC00),
                  inactiveTrackColor: const Color(0xFFD1D5DB),
                  inactiveThumbColor: Colors.white,
                  trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
                  onChanged: !canAct || busy || !live ? null : (v) => onAct(t, v ? 'item_done' : 'item_undo', itemId: i.s('id')),
                ),
              ),
              SizedBox(width: 44, child: Text('x${i.n('qty').toInt()}', textAlign: TextAlign.right, style: inter(16, 600))),
            ]),
          ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(color: const Color(0xFFF4F4EF), borderRadius: BorderRadius.circular(12), border: Border.all(color: kCardLine)),
          child: Text('Order note · ${note ?? 'No custom note'}', style: inter(13.5, 400, color: kMuted)),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final s in stations) KitchenTag(s, bg: kGreenIconBg, fg: const Color(0xFF15803D)),
          KitchenTag(
            switch (channel) { 'dine_in' => 'Table ${t.so('table_label') ?? '—'}', 'pickup' => 'Pickup', _ => channelLabel(channel) },
            bg: const Color(0xFFF1F2EE),
            fg: kInk,
            size: 13,
            weight: 500,
          ),
          if (canAct)
            Semantics(
              button: true,
              child: InkWell(
                key: ValueKey('print-${t.s('card_id')}'),
                borderRadius: BorderRadius.circular(12),
                onTap: busy ? null : () => onAct(t, 'print'),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(color: const Color(0xFFF4F4EF), borderRadius: BorderRadius.circular(12), border: Border.all(color: kCardLine)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(LucideIcons.printer, size: 18, color: kInk),
                    const SizedBox(width: 8),
                    Text('Print ticket', style: inter(15, 500)),
                  ]),
                ),
              ),
            ),
          if (canAct && chip == 'new') _Action('Start', 'start', t, busy, onAct),
          if (canAct && chip == 'in_progress') _Action('Ready', 'ready', t, busy, onAct),
          if (chip == 'ready') KitchenTag('Ready', bg: kGreenIconBg, fg: kPostedText, size: 14, weight: 600),
          if (canAct && chip == 'ready') _Action('Mark served', 'serve', t, busy, onAct, soft: true),
        ]),
      ]),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.label, this.action, this.t, this.busy, this.onAct, {this.soft = false});
  final String label, action;
  final Facts t;
  final bool busy, soft;
  final Future<void> Function(Facts t, String action, {String? itemId}) onAct;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: Material(
          color: soft ? Colors.white : const Color(0xFF76EC00),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: soft ? const BorderSide(color: Color(0xFFD9DBD5)) : BorderSide.none),
          child: InkWell(
            key: ValueKey('act-$action-${t.s('card_id')}'),
            borderRadius: BorderRadius.circular(12),
            onTap: busy ? null : () => onAct(t, action),
            child: Container(
              constraints: const BoxConstraints(minWidth: 96),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
              alignment: Alignment.center,
              child: Text(label, style: inter(15, 600)),
            ),
          ),
        ),
      );
}
