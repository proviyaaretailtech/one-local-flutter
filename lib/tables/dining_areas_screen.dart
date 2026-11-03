import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'floor_screen.dart';
import 'reservations_screen.dart' show ReservationsScreen, clock12;
import 'table_qr_screen.dart';
import 'table_widgets.dart' hide clock12;

/// Dining Areas (0646, founder 3 Nov 2026, after the web panel's page): the outlet's sections of the floor (AC Hall, Rooftop, Garden …)
/// with their tables. Stats on top (areas, tables linked, areas in use, areas needing tables, the largest), the next booking per table, then
/// the areas: filter (All / Active / Inactive / No tables), search, and per area its kind, tables, an on/off switch, edit and delete, and up /
/// down arrows for the order the floor and order-taking show them. Tap an area to choose its tables. Table managers change them; the database
/// checks every change (names, joined tables, an area with tables cannot be deleted).

const _types = {
  'indoor': 'Indoor', 'outdoor': 'Outdoor', 'rooftop': 'Rooftop', 'ac_hall': 'AC Hall', 'garden': 'Garden', 'private': 'Private room', 'bar': 'Bar',
  'terrace': 'Terrace',
};
const _amber = Color(0xFFB45309), _green = Color(0xFF15803D);

class DiningAreasScreen extends StatefulWidget {
  const DiningAreasScreen({super.key, required this.env});
  final TablesEnv env;
  static Route<bool> route(TablesEnv env) => MaterialPageRoute(builder: (_) => DiningAreasScreen(env: env));
  @override
  State<DiningAreasScreen> createState() => _DiningAreasScreenState();
}

class _DiningAreasScreenState extends State<DiningAreasScreen> {
  Facts? _d;
  String? _error;
  String _filter = 'all';
  final _q = TextEditingController();
  bool _busy = false, _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await widget.env.api.areas();
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

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    setState(() => _busy = true);
    try {
      await action();
      _changed = true;
      if (done != null && mounted) showToast(context, done);
    } catch (e) {
      if (mounted) showToast(context, sayError(e));
    }
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  Future<void> _edit([Facts? area]) async {
    final r = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _AreaSheet(area: area),
    );
    if (r == null || !mounted) return;
    await _run(() => widget.env.api.saveArea(id: area?.s('id'), name: r.$1, type: r.$2), done: area == null ? '${r.$1} added.' : '${r.$1} saved.');
  }

  Future<void> _delete(Facts a) async {
    final ok = await showOlDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${a.s('name')}?', style: inter(18, 700)),
        content: Text('The area is removed from the floor and order-taking.', style: inter(15, 400, color: kMuted)),
        actions: [
          TextButton(key: const ValueKey('area-delete-no'), onPressed: () => Navigator.pop(c, false), child: const Text('No')),
          TextButton(key: const ValueKey('area-delete-yes'), onPressed: () => Navigator.pop(c, true), child: const Text('Yes, delete')),
        ],
      ),
    );
    if (ok == true) await _run(() => widget.env.api.deleteArea(a.s('id')), done: '${a.s('name')} deleted.');
  }

  Future<void> _move(List<Facts> all, int from, int to) async {
    final ids = [for (final a in all) a.s('id')];
    final id = ids.removeAt(from);
    ids.insert(to, id);
    await _run(() => widget.env.api.reorderAreas(ids));
  }

  Future<void> _tables(Facts area) async {
    final Facts list;
    try {
      list = await widget.env.api.tableList();
    } catch (e) {
      if (mounted) showToast(context, sayError(e));
      return;
    }
    if (!mounted) return;
    final areaNames = {for (final a in _d?.l('areas') ?? const <Facts>[]) for (final t in a.l('tables')) t.s('id'): a.s('name')};
    final picked = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _TablesSheet(area: area, tables: list.l('tables'), areaOf: areaNames),
    );
    if (picked == null || !mounted) return;
    await _run(() => widget.env.api.setAreaTables(area.s('id'), picked), done: 'Tables of ${area.s('name')} saved.');
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final can = d?.m('can').b('manage') ?? false;
    final areas = d?.l('areas') ?? const <Facts>[];
    final st = d?.m('stats');
    final q = _q.text.trim().toLowerCase();
    final shown = [
      for (final (i, a) in areas.indexed)
        if ((_filter == 'all' || (_filter == 'active' && a.b('active')) || (_filter == 'inactive' && !a.b('active')) || (_filter == 'empty' && a.n('table_count') == 0)) &&
            (q.isEmpty || a.s('name').toLowerCase().contains(q)))
          (i, a),
    ];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (did, _) {
        if (!did) Navigator.of(context).pop(_changed);
      },
      child: TablesPage(
        env: widget.env,
        title: 'Dining areas',
        subtitle: 'Sections of the floor: AC Hall, Rooftop, Garden …',
        back: true,
        banner: true,
        nav: false,
        onRefresh: _load,
        footer: can
            ? SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                child: LimeButton('Add area', key: const ValueKey('area-add'), icon: LucideIcons.plus, onPressed: _busy ? null : () => _edit()),
              )
            : null,
        children: [
          if (d == null && _error == null) tablesLoading(),
          if (_error != null) TablesError(_error!, onRetry: _load),
          if (d != null && st != null) ...[
            Wrap(spacing: 8, runSpacing: 8, children: [
              _Stat('area-stat-areas', 'Dining areas', '${st.n('areas').toInt()}', '${st.n('active').toInt()} active · ${st.n('inactive').toInt()} inactive', LucideIcons.layers, kInk),
              _Stat('area-stat-linked', 'Tables linked', '${st.n('tables_linked').toInt()}', '${st.n('tables_unassigned').toInt()} without an area', LucideIcons.table, _green),
              _Stat('area-stat-use', 'Areas in use', '${st.n('in_use').toInt()}/${st.n('areas').toInt()}', 'have tables', LucideIcons.armchair, _green),
              _Stat('area-stat-needs', 'Needs tables', '${st.n('needs_tables').toInt()}', 'empty areas', LucideIcons.qrCode, _amber),
              _Stat('area-stat-largest', 'Largest area', st.mo('largest')?.s('name') ?? '—',
                  st.mo('largest') == null ? 'no tables yet' : '${st.m('largest').n('tables').toInt()} tables', LucideIcons.layoutGrid, kInk),
            ]),
            const SizedBox(height: 12),
            _Card(
              title: 'Upcoming reservations',
              sub: 'Next booking per table',
              action: TextButton(
                key: const ValueKey('area-reservations'),
                onPressed: () => Navigator.of(context).push(ReservationsScreen.route(widget.env)),
                child: Text('Open', style: inter(14, 700, color: kInk)),
              ),
              child: d.l('upcoming').isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Column(children: [
                        const Icon(LucideIcons.calendarClock, color: kMuted),
                        const SizedBox(height: 6),
                        Text('No upcoming reservations', style: inter(14, 700)),
                        Text('Confirmed table bookings will appear here.', style: inter(12.5, 500, color: kMuted)),
                      ]),
                    )
                  : Column(children: [
                      for (final u in d.l('upcoming'))
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(LucideIcons.calendarCheck, size: 18),
                          title: Text('${u.s('guest_name')} · ${u.n('guests').toInt()} guests', style: inter(14, 700)),
                          subtitle: Text('Table ${u.s('table_label')}${(u.so('area_name') ?? '').isEmpty ? '' : ' · ${u.s('area_name')}'}', style: inter(12.5, 500, color: kMuted)),
                          trailing: Text('${u.s('local_date').substring(8)}/${u.s('local_date').substring(5, 7)} ${clock12(u.s('local_time'))}', style: inter(13, 700)),
                        ),
                    ]),
            ),
            const SizedBox(height: 12),
            _Card(
              title: 'Areas & sections',
              sub: 'The first one shows first on the floor and in order-taking',
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextField(
                  key: const ValueKey('area-search'),
                  controller: _q,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search areas…',
                    prefixIcon: const Icon(LucideIcons.search, size: 18),
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(spacing: 8, children: [
                  for (final (k, label, n) in [
                    ('all', 'All', areas.length),
                    ('active', 'Active', st.n('active').toInt()),
                    ('inactive', 'Inactive', st.n('inactive').toInt()),
                    ('empty', 'No tables', st.n('needs_tables').toInt()),
                  ])
                    ChoiceChip(
                      key: ValueKey('area-filter-$k'),
                      label: Text('$label $n', style: inter(13, 700, color: _filter == k ? kLimeBtn : kInk)),
                      selected: _filter == k,
                      showCheckmark: false,
                      selectedColor: kInk,
                      backgroundColor: Colors.white,
                      onSelected: (_) => setState(() => _filter = k),
                    ),
                ]),
                const SizedBox(height: 10),
                if (areas.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text(can ? 'No areas yet. Add your first area below: AC Hall, Rooftop, Garden …' : 'No areas yet.',
                        textAlign: TextAlign.center, style: inter(14, 500, color: kMuted)),
                  )
                else if (shown.isEmpty)
                  Padding(padding: const EdgeInsets.symmetric(vertical: 18), child: Text('No areas match.', textAlign: TextAlign.center, style: inter(14, 500, color: kMuted))),
                for (final (i, a) in shown) _area(areas, i, a, can),
              ]),
            ),
            const SizedBox(height: 12),
            _Card(
              title: 'Quick actions',
              child: Column(children: [
                if (can) _Quick('area-quick-add', LucideIcons.plus, 'Add area', 'New section or floor', () => _edit()),
                _Quick('area-quick-qr', LucideIcons.qrCode, 'Tables & QR', 'Table QR codes for guests',
                    () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TableQrScreen(env: widget.env)))),
                _Quick('area-quick-floor', LucideIcons.layoutGrid, 'Table status', 'The live floor',
                    () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FloorScreen(env: widget.env)))),
              ]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _area(List<Facts> all, int i, Facts a, bool can) {
    final id = a.s('id'), n = a.n('table_count').toInt();
    return Container(
      key: ValueKey('area-${a.s('name')}'),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFE5E7EB))),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: can && !_busy ? () => _tables(a) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: const Color(0xFFEAF7DE), borderRadius: BorderRadius.circular(12)),
              child: const Icon(LucideIcons.armchair, size: 20, color: _green),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.s('name'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(15.5, 800, color: a.b('active') ? kInk : kMuted)),
                const SizedBox(height: 2),
                Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: const Color(0xFFF1F2EE), borderRadius: BorderRadius.circular(6)),
                    child: Text('#${i + 1}', style: inter(11, 700, color: kMuted)),
                  ),
                  Text(_types[a.s('area_type')] ?? a.s('area_type'), style: inter(12, 500, color: kMuted)),
                  Text(n == 0 ? 'No tables yet' : '$n table${n == 1 ? '' : 's'} · ${a.n('seats').toInt()} seats',
                      key: ValueKey('area-tables-${a.s('name')}'), style: inter(12, 700, color: n == 0 ? _amber : _green)),
                ]),
              ]),
            ),
            if (can) ...[
              Column(mainAxisSize: MainAxisSize.min, children: [
                InkWell(
                  key: ValueKey('area-up-${a.s('name')}'),
                  onTap: _busy || i == 0 ? null : () => _move(all, i, i - 1),
                  child: Icon(LucideIcons.chevronUp, size: 18, color: i == 0 ? kLine : kInk),
                ),
                InkWell(
                  key: ValueKey('area-down-${a.s('name')}'),
                  onTap: _busy || i == all.length - 1 ? null : () => _move(all, i, i + 1),
                  child: Icon(LucideIcons.chevronDown, size: 18, color: i == all.length - 1 ? kLine : kInk),
                ),
              ]),
              Switch(
                key: ValueKey('area-active-${a.s('name')}'),
                value: a.b('active'),
                activeTrackColor: const Color(0xFF6BD12B),
                onChanged: _busy
                    ? null
                    : (v) => _run(() => widget.env.api.setAreaActive(id, v),
                        done: v ? '${a.s('name')} is on the floor again.' : '${a.s('name')} is off: its free tables are not offered.'),
              ),
              IconButton(key: ValueKey('area-edit-${a.s('name')}'), tooltip: 'Rename or change kind', onPressed: _busy ? null : () => _edit(a),
                  icon: const Icon(LucideIcons.pencil, size: 18, color: kInk)),
              IconButton(key: ValueKey('area-delete-${a.s('name')}'), tooltip: 'Delete area', onPressed: _busy ? null : () => _delete(a),
                  icon: const Icon(LucideIcons.trash2, size: 18, color: kError)),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.k, this.label, this.value, this.foot, this.icon, this.tint);
  final String k, label, value, foot;
  final IconData icon;
  final Color tint;
  @override
  Widget build(BuildContext context) => Container(
        key: ValueKey(k),
        width: 160,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFE5E7EB))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(label.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(10.5, 800, color: kMuted).copyWith(letterSpacing: .6))),
            Icon(icon, size: 15, color: tint),
          ]),
          const SizedBox(height: 4),
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(20, 800, color: tint)),
          Text(foot, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 500, color: kMuted)),
        ]),
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child, this.sub, this.action});
  final String title;
  final String? sub;
  final Widget child;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE5E7EB))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: inter(15.5, 800)),
                if (sub != null) Text(sub!, style: inter(12, 500, color: kMuted)),
              ]),
            ),
            ?action,
          ]),
          const SizedBox(height: 8),
          child,
        ]),
      );
}

class _Quick extends StatelessWidget {
  const _Quick(this.k, this.icon, this.title, this.sub, this.onTap);
  final String k, title, sub;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFFE5E7EB))),
          child: ListTile(
            key: ValueKey(k),
            onTap: onTap,
            leading: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: const Color(0xFFEAF7DE), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 18, color: _green),
            ),
            title: Text(title, style: inter(14, 800)),
            subtitle: Text(sub, style: inter(12, 500, color: kMuted)),
          ),
        ),
      );
}

/// Add or edit an area: its name and kind. Answers (name, kind).
class _AreaSheet extends StatefulWidget {
  const _AreaSheet({this.area});
  final Facts? area;
  @override
  State<_AreaSheet> createState() => _AreaSheetState();
}

class _AreaSheetState extends State<_AreaSheet> {
  late final _name = TextEditingController(text: widget.area?.s('name') ?? '');
  late String _type = widget.area?.s('area_type') ?? 'indoor';
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(18, 14, 18, 18 + MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.area == null ? 'Add area' : 'Edit ${widget.area!.s('name')}', style: inter(19, 800)),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('area-name'),
              controller: _name,
              autofocus: true,
              maxLength: 40,
              decoration: InputDecoration(labelText: 'Name (for example Rooftop)', border: OutlineInputBorder(borderRadius: BorderRadius.circular(14))),
            ),
            Text('Kind', style: inter(13.5, 700)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final e in _types.entries)
                ChoiceChip(
                  key: ValueKey('area-type-${e.key}'),
                  label: Text(e.value, style: inter(13, 700, color: _type == e.key ? kLimeBtn : kInk)),
                  selected: _type == e.key,
                  showCheckmark: false,
                  selectedColor: kInk,
                  backgroundColor: Colors.white,
                  onSelected: (_) => setState(() => _type = e.key),
                ),
            ]),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: inter(14, 500, color: kError))),
            const SizedBox(height: 14),
            LimeButton(
              widget.area == null ? 'Add area' : 'Save',
              key: const ValueKey('area-save'),
              onPressed: () {
                if (_name.text.trim().isEmpty) return setState(() => _error = 'Give the area a name.');
                Navigator.of(context).pop((_name.text.trim(), _type));
              },
            ),
          ]),
        ),
      );
}

/// The tables of an area: tick the ones in it. A table in another area shows where it is now (it moves here when ticked).
class _TablesSheet extends StatefulWidget {
  const _TablesSheet({required this.area, required this.tables, required this.areaOf});
  final Facts area;
  final List<Facts> tables;
  final Map<String, String> areaOf;
  @override
  State<_TablesSheet> createState() => _TablesSheetState();
}

class _TablesSheetState extends State<_TablesSheet> {
  late final _on = {for (final t in widget.area.l('tables')) t.s('id')};

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
        child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Tables in ${widget.area.s('name')}', style: inter(19, 800)),
            Text('Tick the tables that are in this area. Joined tables move together.', style: inter(13, 500, color: kMuted)),
            const SizedBox(height: 8),
            if (widget.tables.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text('No tables yet: add them in Manage tables.', style: inter(14, 500, color: kMuted))),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final t in widget.tables)
                  CheckboxListTile(
                    key: ValueKey('area-table-${t.s('label')}'),
                    value: _on.contains(t.s('id')),
                    onChanged: (v) => setState(() => v == true ? _on.add(t.s('id')) : _on.remove(t.s('id'))),
                    title: Text(t.s('label'), style: inter(15, 700)),
                    subtitle: Text(
                      [
                        '${t.n('seats').toInt()} seats',
                        if (widget.areaOf[t.s('id')] != null && widget.areaOf[t.s('id')] != widget.area.s('name')) 'now in ${widget.areaOf[t.s('id')]}',
                      ].join(' · '),
                      style: inter(12.5, 500, color: kMuted),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
              ]),
            ),
            const SizedBox(height: 10),
            LimeButton('Save · ${_on.length} table${_on.length == 1 ? '' : 's'}', key: const ValueKey('area-tables-save'), onPressed: () => Navigator.of(context).pop(_on.toList())),
          ]),
        ),
      );
}
