import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'tables_api.dart';
import 'table_widgets.dart';

/// Manage tables (0602): add a table, rename it or change its seats, remove it. Every rule (who may, unique names, 1 to 50 seats, not
/// while it has guests or a reservation, hidden instead of deleted when it has past bills) is the database's; this screen draws its answers.
class ManageTablesScreen extends StatefulWidget {
  const ManageTablesScreen({super.key, required this.env});
  final TablesEnv env;
  @override
  State<ManageTablesScreen> createState() => _ManageTablesScreenState();
}

class _ManageTablesScreenState extends State<ManageTablesScreen> {
  Facts? _d;
  String? _error;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.env.api.tableList();
      if (mounted) {
        setState(() {
          _d = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is TablesApiException ? e.message : 'Could not load the tables. Check your connection and try again.');
    }
  }

  /// "T6" after T1..T5: the next free number, so adding a table is one tap in the usual case.
  String _nextLabel(List<Facts> tables) {
    final taken = {for (final t in tables) t.s('label').toUpperCase()};
    for (var n = tables.length + 1; n < 1000; n++) {
      if (!taken.contains('T$n')) return 'T$n';
    }
    return '';
  }

  Future<void> _edit({Facts? table, required List<Facts> tables}) async {
    final saved = await showModalBottomSheet<Facts>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _TableSheet(api: widget.env.api, table: table, suggested: _nextLabel(tables)),
    );
    if (saved == null || !mounted) return;
    setState(() {
      _d = saved;
      _changed = true;
    });
    showToast(context, table == null ? 'Table added.' : 'Table saved.');
  }

  Future<void> _remove(Facts t) async {
    final label = t.s('label');
    final ok = await showOlDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove $label?'),
        content: Text(t.b('has_history')
            ? '$label has past bills, so it is hidden from the floor rather than deleted. Adding a table called $label again brings it back.'
            : '$label comes off the floor.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(key: const ValueKey('remove-confirm'), onPressed: () => Navigator.pop(c, true), child: Text('Remove', style: inter(14, 700, color: kError))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final d = await widget.env.api.removeTable(t.s('id'));
      if (!mounted) return;
      setState(() {
        _d = d;
        _changed = true;
      });
      showToast(context, d.b('hidden') ? '$label hidden (it has past bills).' : '$label removed.');
    } on TablesApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final tables = d?.l('tables') ?? const <Facts>[];
    final canManage = d?.b('can_manage') ?? false;
    final seats = tables.fold<int>(0, (s, t) => s + t.n('seats').toInt());
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: TablesPage(
        env: widget.env,
        title: 'Manage tables',
        subtitle: d == null ? null : '${tables.length} table${tables.length == 1 ? '' : 's'} · $seats seats',
        back: true,
        banner: true,
        nav: false,
        onRefresh: _load,
        footer: canManage
            ? SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                child: LimeButton('Add table', key: const ValueKey('table-add'), icon: LucideIcons.plus, onPressed: () => _edit(tables: tables)),
              )
            : null,
        children: [
          if (d == null && _error == null) tablesLoading(),
          if (d == null && _error != null) TablesError(_error!, onRetry: _load),
          if (d != null && !canManage)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('Only the owner or a floor manager can add, rename or remove tables.', style: inter(13, 400, color: kMuted)),
            ),
          if (d != null && tables.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(child: Text('No tables yet. Add your first table below.', textAlign: TextAlign.center, style: inter(15, 400, color: kMuted))),
            ),
          for (final t in tables)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Material(
                color: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0xFFECEDE8))),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                  child: Row(children: [
                    Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(12)),
                      child: Text(t.s('label'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13, 800)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(t.s('label'), key: ValueKey('table-row-${t.s('label')}'), style: inter(16, 700)),
                        Text('${t.n('seats').toInt()} seats · ${_stateWord(t.s('status'))}', style: inter(13, 400, color: kMuted)),
                      ]),
                    ),
                    if (canManage) ...[
                      IconButton(key: ValueKey('table-edit-${t.s('label')}'), tooltip: 'Rename or change seats', onPressed: () => _edit(table: t, tables: tables), icon: const Icon(LucideIcons.pencil, size: 19, color: kInk)),
                      IconButton(key: ValueKey('table-remove-${t.s('label')}'), tooltip: 'Remove table', onPressed: () => _remove(t), icon: const Icon(LucideIcons.trash2, size: 19, color: kError)),
                    ],
                  ]),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _stateWord(String s) => switch (s) { 'occupied' => 'Occupied', 'reserved' => 'Reserved', 'cleaning' => 'Cleaning', _ => 'Available' };
}

/// Add or edit one table: its name and its seats.
class _TableSheet extends StatefulWidget {
  const _TableSheet({required this.api, this.table, required this.suggested});
  final TablesApi api;
  final Facts? table;
  final String suggested;
  @override
  State<_TableSheet> createState() => _TableSheetState();
}

class _TableSheetState extends State<_TableSheet> {
  late final _label = TextEditingController(text: widget.table?.s('label') ?? widget.suggested);
  late int _seats = widget.table?.n('seats').toInt() ?? 4;
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    if (_label.text.trim().isEmpty) return setState(() => _error = 'Give the table a name.');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final d = await widget.api.saveTable(id: widget.table?.s('id'), label: _label.text.trim(), seats: _seats);
      if (mounted) Navigator.of(context).pop(d);
    } on TablesApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(18, 18, 18, 18 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(widget.table == null ? 'Add table' : 'Edit ${widget.table!.s('label')}', style: inter(20, 700)),
          const SizedBox(height: 14),
          Text('Name', style: inter(13, 600, color: kMuted)),
          const SizedBox(height: 6),
          TextField(
            key: const ValueKey('table-label'),
            controller: _label,
            maxLength: 20,
            textCapitalization: TextCapitalization.characters,
            style: inter(16, 600),
            decoration: InputDecoration(
              hintText: 'e.g. T6 or PATIO 1',
              counterText: '',
              isDense: true,
              filled: true,
              fillColor: kField,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kFieldBorder)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kFieldBorder)),
            ),
          ),
          const SizedBox(height: 14),
          Text('Seats', style: inter(13, 600, color: kMuted)),
          Row(children: [
            IconButton(key: const ValueKey('seats-minus'), onPressed: _seats > 1 ? () => setState(() => _seats--) : null, icon: const Icon(LucideIcons.minus)),
            SizedBox(width: 40, child: Text('$_seats', key: const ValueKey('seats-value'), textAlign: TextAlign.center, style: inter(20, 800))),
            IconButton(key: const ValueKey('seats-plus'), onPressed: _seats < 50 ? () => setState(() => _seats++) : null, icon: const Icon(LucideIcons.plus)),
            const SizedBox(width: 8),
            Text('${_seats == 1 ? 'guest' : 'guests'} at most', style: inter(13, 400, color: kMuted)),
          ]),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: inter(13, 500, color: kError))),
          const SizedBox(height: 14),
          LimeButton(widget.table == null ? 'Add table' : 'Save', key: const ValueKey('table-save'), busy: _busy, onPressed: _save),
        ]),
      );
}
