import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart';
import '../inventory/inventory_widgets.dart';
import '../ui/theme.dart';
import 'actions_screen.dart';
import 'reserve_screen.dart';
import 'table_widgets.dart';

/// Figma "Tables" (screen-1-tables-grid) and its bottom sheet (screen-2-bottom-sheet): every table of the store with its state, filter chips,
/// a 2-column grid. Tap a free, reserved or cleaning table for the sheet; tap an occupied one for its actions.
/// With [pickFor] set the same grid is used to choose a destination table (transfer): a tap returns that table instead.
class FloorScreen extends StatefulWidget {
  const FloorScreen({super.key, required this.env, this.pickFor, this.pickTitle});
  final TablesEnv env;

  /// Table id being moved; it is not offered as a destination.
  final String? pickFor;
  final String? pickTitle;
  @override
  State<FloorScreen> createState() => _FloorScreenState();
}

class _FloorScreenState extends State<FloorScreen> {
  TablesEnv get env => widget.env;
  String _status = 'all';
  Facts? _d;
  String? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mine = ++_seq;
    try {
      final d = await env.api.floor(status: _status);
      if (!mounted || mine != _seq) return;
      setState(() {
        _d = d;
        _error = null;
      });
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() => _error = sayError(e));
    }
  }

  Future<void> _tap(Facts t) async {
    if (widget.pickFor != null) {
      if (t.s('id') == widget.pickFor) return showToast(context, 'Choose a different table.');
      if (t.mo('merge') != null) return showToast(context, '${t.s('label')} is joined to other tables. Choose another table.');
      Navigator.of(context).pop(t);
      return;
    }
    if (t.s('status') == 'occupied') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ActionsScreen(env: env, tableId: t.s('id'))));
    } else {
      await showTableSheet(context, env, t, storeNow: _storeNow());
    }
    if (mounted) _load();
  }

  /// The store's wall clock now (the server's local_today + local_time), so "Today" and the default time follow the store's zone, not the phone's.
  DateTime Function()? _storeNow() {
    final today = _d?.so('local_today'), hm = _d?.so('local_time');
    final base = today == null || hm == null ? null : DateTime.tryParse('${today}T$hm:00');
    if (base == null) return null;
    final at = DateTime.now();
    return () => base.add(DateTime.now().difference(at));
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final counts = d?.m('counts');
    final tables = d?.l('tables') ?? const <Facts>[];
    return TablesPage(
      env: env,
      title: widget.pickFor != null ? (widget.pickTitle ?? 'Choose table') : 'Tables',
      back: widget.pickFor != null,
      onRefresh: _load,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(children: [
            for (final (id, label) in const [('all', 'All Tables'), ('available', 'Available'), ('occupied', 'Occupied'), ('reserved', 'Reserved'), ('cleaning', 'Cleaning')])
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Semantics(
                  button: true,
                  selected: _status == id,
                  child: InkWell(
                    key: ValueKey('chip-$id'),
                    borderRadius: BorderRadius.circular(999),
                    onTap: () {
                      setState(() => _status = id);
                      _load();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: BoxDecoration(color: _status == id ? kNote : const Color(0xFFF0F1EC), borderRadius: BorderRadius.circular(999)),
                      child: Text(label + (counts == null ? '' : ' (${counts.n(id).toInt()})'), style: inter(16, _status == id ? 600 : 400, color: _status == id ? kLink : kMuted)),
                    ),
                  ),
                ),
              ),
          ]),
        ),
        if (_d == null && _error == null) tablesLoading(),
        if (_d == null && _error != null) TablesError(_error!, onRetry: _load),
        if (d != null && tables.isEmpty)
          Padding(padding: const EdgeInsets.all(32), child: Center(child: Text(_status == 'all' ? 'No tables set up for this store yet.' : 'No $_status tables.', style: inter(15, 400, color: kMuted)))),
        if (tables.isNotEmpty)
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.78,
            children: [for (final t in tables) TableCard(table: t, onTap: () => _tap(t))],
          ),
      ],
    );
  }
}

/// The bottom sheet of a table that is not occupied: "Table T4 / 4 Pax • Available", Start New Order, Reserve Table, View History.
Future<void> showTableSheet(BuildContext context, TablesEnv env, Facts t, {DateTime Function()? storeNow}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (_) => _TableSheet(env: env, table: t, storeNow: storeNow),
  );
}

class _TableSheet extends StatefulWidget {
  const _TableSheet({required this.env, required this.table, this.storeNow});
  final TablesEnv env;
  final Facts table;
  final DateTime Function()? storeNow;
  @override
  State<_TableSheet> createState() => _TableSheetState();
}

class _TableSheetState extends State<_TableSheet> {
  Facts? _v;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await widget.env.api.view(widget.table.s('id'));
      if (mounted) setState(() => _v = v);
    } catch (e) {
      if (mounted) setState(() => _error = sayError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    final t = v?.m('table');
    final status = v?.s('status') ?? widget.table.s('status');
    final (word, _, _, color) = tableLook(status);
    final allowed = v?.ls('allowed') ?? const <String>[];
    final label = t?.s('label') ?? widget.table.s('label');
    final seats = t?.n('seats') ?? widget.table.n('seats');
    final nav = Navigator.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(4)))),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Table $label', style: inter(26, 700)),
                const SizedBox(height: 6),
                Row(children: [
                  Container(width: 18, height: 18, decoration: BoxDecoration(color: status == 'available' ? kTableDot : color, shape: BoxShape.circle)),
                  const SizedBox(width: 10),
                  Text('${pax(seats)} • ${word[0]}${word.substring(1).toLowerCase()}', style: inter(18, 500, color: color)),
                ]),
              ]),
            ),
            Semantics(
              button: true,
              label: 'Close',
              child: InkWell(
                key: const ValueKey('sheet-close'),
                borderRadius: BorderRadius.circular(20),
                onTap: () => nav.pop(),
                child: Container(width: 44, height: 44, decoration: const BoxDecoration(color: kGreyBg, shape: BoxShape.circle), child: const Icon(LucideIcons.x, size: 20, color: kMuted)),
              ),
            ),
          ]),
          const Divider(height: 28, color: kLine),
          if (_v == null && _error == null) Padding(padding: const EdgeInsets.all(20), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: kInk)))),
          if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_error!, style: inter(14, 400, color: kRedText))),
          if (allowed.contains('start_order')) ...[
            LimeButton('Start New Order', icon: LucideIcons.shoppingCart, height: 56, onPressed: () {
              nav.pop();
              final start = widget.env.onStartOrder;
              if (start == null) {
                showToast(context, 'Starting an order from a table opens in a later release.');
              } else {
                start(context, v!.m('table'));
              }
            }),
            const SizedBox(height: 12),
          ],
          if (allowed.contains('reserve')) ...[
            OutlineButtonT('Reserve Table', icon: LucideIcons.calendar, dark: true, height: 56, onPressed: () async {
              nav.pop();
              await nav.push(MaterialPageRoute(builder: (_) => ReserveScreen(env: widget.env, table: v!.m('table'), now: widget.storeNow)));
            }),
          ],
          if (allowed.contains('history'))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton(
                key: const ValueKey('sheet-history'),
                onPressed: () {
                  nav.pop();
                  showHistorySheet(context, widget.env, widget.table.s('id'), label);
                },
                child: Text('View History', style: inter(17, 500, color: kMuted).copyWith(decoration: TextDecoration.underline)),
              ),
            ),
        ]),
      ),
    );
  }
}

/// "View History": orders and reservations of one table, newest first.
Future<void> showHistorySheet(BuildContext context, TablesEnv env, String tableId, String label) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: FutureBuilder<List<Facts>>(
            future: env.api.history(tableId),
            builder: (ctx, snap) {
              final rows = snap.data;
              return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Table $label history', style: inter(20, 700)),
                const SizedBox(height: 10),
                if (snap.hasError) Text(sayError(snap.error!), style: inter(14, 400, color: kRedText)),
                if (rows == null && !snap.hasError) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(color: kInk))),
                if (rows != null && rows.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text('Nothing recorded for this table yet.', style: inter(14, 400, color: kMuted))),
                if (rows != null && rows.isNotEmpty)
                  Flexible(
                    child: ListView(shrinkWrap: true, children: [
                      for (final r in rows)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Icon(r.s('kind') == 'order' ? LucideIcons.receiptText : LucideIcons.calendar, size: 18, color: kMuted),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(r.s('title'), style: inter(15, 600)),
                                Text('${r.t('when') == null ? '' : '${stamp(r.t('when')!)} · '}${r.s('detail')} · ${r.s('status').replaceAll('_', ' ')}', style: inter(12.5, 400, color: kMuted)),
                              ]),
                            ),
                          ]),
                        ),
                    ]),
                  ),
              ]);
            },
          ),
        ),
      ),
    ),
  );
}
