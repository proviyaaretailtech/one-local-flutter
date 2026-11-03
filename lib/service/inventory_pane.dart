import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'service_api.dart';
import 'service_widgets.dart';
import 'staff_screen.dart';

/// One section of the Inventory tab: its key in `svc_inventory`, tile label, heading, line, what "add" adds, and its tile colours.
typedef _Section = ({String key, String tile, String title, String line, String add, String kind, Color bg, Color fg});

const List<_Section> _sections = [
  (key: 'team', tile: 'Team', title: 'Team', line: 'The people who take bookings', add: '', kind: '', bg: kInfoGreyBg, fg: kInk),
  (key: 'places', tile: 'Places', title: 'Places', line: 'Rooms, chairs, courts, bays: anything a booking uses', add: 'Add a place', kind: 'place', bg: kChipGreen, fg: kGreenText),
  (key: 'tools', tile: 'Tools', title: 'Tools and gear', line: 'Things that go out and come back', add: 'Add a tool', kind: 'tool', bg: Color(0xFFFFF1D6), fg: Color(0xFF7A4E00)),
  (key: 'materials', tile: 'Materials', title: 'Materials', line: 'Things you use up', add: 'Add a material', kind: 'material', bg: Color(0xFFF1E8F7), fg: Color(0xFF6E3B98)),
  (key: 'care', tile: 'In care', title: 'Items in care', line: 'Customers\' things you are looking after', add: 'Take in an item', kind: 'care', bg: kInfoGreyBg, fg: kMuted),
];

/// The service catalogue's Inventory tab (founder's design, 3 Nov 2026): five sections (Team, Places, Tools, Materials, In care) picked
/// from a row of count tiles, what needs doing in the picked one, and its list. Every label, state and number is the server's.
class InventoryPane extends StatefulWidget {
  const InventoryPane({super.key, required this.api, this.business = '', this.onNavigate, this.onAlerts});
  final ServiceApi api;
  final String business;
  final ValueChanged<String>? onNavigate;

  /// How many things need doing (shown on the Inventory tab).
  final ValueChanged<int>? onAlerts;
  @override
  State<InventoryPane> createState() => InventoryPaneState();
}

class InventoryPaneState extends State<InventoryPane> {
  StaffData? _team;
  InventoryData? _inv;
  String? _error;
  String _section = 'team';

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    try {
      final r = await Future.wait([widget.api.staff(), widget.api.inventory()]);
      if (!mounted) return;
      setState(() {
        _team = r[0] as StaffData;
        _error = null;
      });
      _take(r[1] as InventoryData);
    } catch (e) {
      if (mounted) setState(() => _error = e is ServiceApiException ? e.message : e.toString());
    }
  }

  void _take(InventoryData d) {
    setState(() => _inv = d);
    widget.onAlerts?.call(d.alerts.length);
  }

  /// Sends one change with a fresh key and shows the inventory the server sends back.
  Future<void> _send(Future<InventoryData> Function(String key) call, {String? done}) async {
    try {
      _take(await call(ServiceApi.newKey()));
      if (done != null && mounted) showToast(context, done);
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  int _count(String key) => key == 'team' ? _team!.count('all') : _inv!.count(key);

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return OrderCardBox(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_error!, style: inter(13.5, 500)),
        const SizedBox(height: 8),
        SmallPill('Try again', onTap: reload),
      ]));
    }
    if (_team == null || _inv == null) return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kGreenText)));
    final s = _sections.firstWhere((x) => x.key == _section);
    final alerts = _inv!.alerts.where((a) => _alertSection(a.s('kind')) == s.key).toList();
    final canAdd = s.key == 'team' ? _team!.canEdit : (s.key == 'care' || _inv!.canEdit);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _tiles(),
      const SizedBox(height: 14),
      for (final a in alerts) _alert(a),
      Row(children: [
        Expanded(child: Text(s.title, style: inter(17, 800))),
        if (canAdd) SmallPill('+ Add', key: ValueKey('inv-add-${s.key}'), onTap: () => _add(s), fg: kGreenText),
      ]),
      const SizedBox(height: 2),
      Text(s.key == 'team' ? '${_team!.count('available')} free now · ${_team!.count('on_job')} on a job · ${_team!.count('off_duty')} off' : s.line,
          style: inter(13, 400, color: kMuted)),
      const SizedBox(height: 10),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: KeyedSubtree(key: ValueKey('inv-list-${s.key}'), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _list(s))),
      ),
    ]);
  }

  String _alertSection(String kind) => switch (kind) { 'material' => 'materials', 'tool' => 'tools', 'care' => 'care', _ => 'places' };

  /// Team · Places · Tools · Materials · In care, each with its count; a dot when it has something to do.
  Widget _tiles() => Row(children: [
        for (final s in _sections)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: s.key == 'care' ? 0 : 6),
              child: Material(
                color: _section == s.key ? kChipGreen : Colors.white,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  key: ValueKey('inv-tile-${s.key}'),
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => setState(() => _section = s.key),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: _section == s.key ? kLink : kLine, width: _section == s.key ? 1.5 : 1)),
                    child: Column(children: [
                      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text('${_count(s.key)}', style: inter(17, 800)),
                        if (_inv!.alerts.any((a) => _alertSection(a.s('kind')) == s.key)) ...[
                          const SizedBox(width: 3),
                          Container(width: 6, height: 6, decoration: const BoxDecoration(color: Color(0xFFE3A008), shape: BoxShape.circle)),
                        ],
                      ]),
                      const SizedBox(height: 2),
                      FittedBox(fit: BoxFit.scaleDown, child: Text(s.tile, style: inter(11, 600, color: kMuted))),
                    ]),
                  ),
                ),
              ),
            ),
          ),
      ]);

  Widget _alert(SvcData a) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          key: ValueKey('inv-alert-${a.s('id')}'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFFFFF6E5), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFF5DDB0))),
          child: Row(children: [
            const Icon(LucideIcons.triangleAlert, size: 20, color: Color(0xFF7A4E00)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.s('title'), style: inter(14, 700)),
                if (a.s('line').isNotEmpty) Text(a.s('line'), style: inter(12.5, 400, color: kMuted)),
              ]),
            ),
          ]),
        ),
      );

  List<Widget> _list(_Section s) {
    if (s.key == 'team') {
      final t = _team!;
      if (t.providers.isEmpty) return [_empty('No team yet. Add the people who take bookings.')];
      return [
        for (var i = 0; i < t.providers.length; i++)
          Entrance(key: ValueKey('in-team-${t.providers[i].s('staff_id')}'), index: i, child: _person(t.providers[i])),
      ];
    }
    final rows = _inv!.section(s.key);
    if (rows.isEmpty) {
      return [
        _empty(switch (s.key) {
          'places' => 'No places yet. Add the rooms, chairs, courts or bays your bookings use.',
          'tools' => 'No tools yet. Add the gear that goes out with a job or a customer.',
          'materials' => 'No materials yet. Add what you use up, and get a warning before it runs out.',
          _ => 'Nothing in your care. Take in an item when a customer leaves something with you.',
        })
      ];
    }
    return [for (var i = 0; i < rows.length; i++) Entrance(key: ValueKey('in-${s.key}-${rows[i].s('id')}'), index: i, child: _row(s, rows[i]))];
  }

  Widget _empty(String text) => OrderCardBox(child: Text(text, style: inter(14, 400, color: kMuted)));

  String _initials(String name) => name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2).map((w) => w[0].toUpperCase()).join();

  Widget _lead(String text, Color bg, Color fg) => Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: inter(13, 800, color: fg)),
      );

  /// A card: the lead tile, name and state, the server's line, the services it is for, and a fill bar when there is one.
  Widget _card({required Key key, required Widget lead, required String name, required Widget state, String line = '', String services = '', int? bar, String tone = 'good', VoidCallback? onTap}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: OrderCardBox(
            radius: 16,
            padding: const EdgeInsets.all(12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              lead,
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [Expanded(child: Text(name, style: inter(15.5, 700))), state]),
                  if (line.isNotEmpty) ...[const SizedBox(height: 2), Text(line, style: inter(13, 400, color: kMuted))],
                  if (services.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Padding(padding: EdgeInsets.only(top: 2), child: Icon(LucideIcons.link, size: 14, color: kMuted)),
                      const SizedBox(width: 6),
                      Expanded(child: Text(services, style: inter(12.5, 500))),
                    ]),
                  ],
                  if (bar != null) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: Container(
                        height: 6,
                        color: kInfoGreyBg,
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: (bar.clamp(0, 100)) / 100,
                          child: Container(color: switch (tone) { 'bad' => kError, 'warn' => const Color(0xFFE3A008), _ => kLink }),
                        ),
                      ),
                    ),
                  ],
                ]),
              ),
            ]),
          ),
        ),
      );

  Future<void> _openTeam() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => StaffScreen(api: widget.api, business: widget.business, onNavigate: widget.onNavigate)));
    if (mounted) reload();
  }

  Widget _person(SvcData p) => _card(
        key: ValueKey('team-${p.s('staff_id')}'),
        lead: _lead(_initials(p.s('name')), kInfoGreyBg, kInk),
        name: p.s('name'),
        state: svcStatus(p.s('state_label'), p.s('tone')),
        line: [p.s('title'), p.s('availability')].where((x) => x.isNotEmpty).join(' · '),
        services: p.s('services').isEmpty ? 'No services yet' : p.s('services'),
        onTap: _openTeam,
      );

  Widget _row(_Section s, SvcData r) {
    final care = s.key == 'care';
    return _card(
      key: ValueKey('inv-${r.s('id')}'),
      lead: _lead(care ? r.s('tag') : _initials(r.s('name')), s.bg, s.fg),
      name: care ? '${r.s('item')} · ${r.s('customer_name')}' : r.s('name'),
      state: svcStatus(r.s('state_label'), r.s('tone')),
      line: r.s('line'),
      services: r.s('services'),
      bar: r.raw['bar'] == null ? null : r.i('bar'),
      tone: r.s('tone'),
      onTap: () => _actions(s, r),
    );
  }

  // ------------------------------------------------------------------------------------------------------------------ actions
  Future<num?> _askQty(String title, {String hint = 'How many'}) async {
    final t = await askText(context, title, hint: hint, keyboard: const TextInputType.numberWithOptions(decimal: true));
    if (t == null || t.isEmpty) return null;
    final n = num.tryParse(t);
    if ((n == null || n <= 0) && mounted) showToast(context, 'Enter a number above 0.');
    return n != null && n > 0 ? n : null;
  }

  Future<void> _actions(_Section s, SvcData r) async {
    final edit = _inv!.canEdit;
    final options = <(String, String)>[
      if (s.key == 'tools') ...[
        if (r.n('qty_out') < r.n('qty')) ('out', 'Lend out'),
        if (r.n('qty_out') > 0) ('back', 'Got back'),
      ],
      if (s.key == 'materials') ...[('add', 'Add stock'), if (r.n('qty') > 0) ('use', 'Use some')],
      if (s.key == 'care') ...[
        if (r.s('status') != 'in_work') ('in_work', 'Working on it'),
        if (r.s('status') != 'ready') ('ready', 'Ready to collect'),
        ('returned', 'Handed back'),
        ('edit', 'Change details'),
      ],
      if (s.key != 'care' && s.key != 'materials' && edit) r.b('blocked') ? ('unblock', 'Take it back in use') : ('block', 'Block for now'),
      if (s.key != 'care' && edit) ...[('edit', 'Edit'), ('remove', 'Remove')],
    ];
    if (options.isEmpty) return;
    final pick = await showOrderSheet<String>(context, title: s.key == 'care' ? '${r.s('item')} · ${r.s('tag')}' : r.s('name'), body: (ctx) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (v, l) in options) ...[
              LightCta(key: ValueKey('inv-act-$v'), label: l, onPressed: () => Navigator.pop(ctx, v)),
              const SizedBox(height: 8),
            ],
          ],
        ));
    if (pick == null || !mounted) return;
    final id = r.s('id');
    switch (pick) {
      case 'out':
        final n = await _askQty('How many go out?');
        if (n == null || !mounted) return;
        final who = await askText(context, 'Who has them? (optional)', hint: 'With Arjun at a job · due back 9 pm', action: 'Lend out');
        if (who == null) return;
        await _send((k) => widget.api.moveInventory(id, 'out', n, note: who.isEmpty ? null : who, key: k));
      case 'back':
        final n = await _askQty('How many came back?');
        if (n != null) await _send((k) => widget.api.moveInventory(id, 'back', n, key: k));
      case 'add':
        final n = await _askQty('How much came in?', hint: r.s('unit').isEmpty ? 'How much' : 'How many ${r.s('unit')}');
        if (n != null) await _send((k) => widget.api.moveInventory(id, 'add', n, key: k));
      case 'use':
        final n = await _askQty('How much was used?', hint: r.s('unit').isEmpty ? 'How much' : 'How many ${r.s('unit')}');
        if (n != null) await _send((k) => widget.api.moveInventory(id, 'use', n, key: k));
      case 'block':
        final why = await askText(context, 'Why is it blocked?', hint: 'Under repair · painting · booked privately', action: 'Block');
        if (why != null) await _send((k) => widget.api.saveInventory({'id': id, 'name': r.s('name'), 'blocked': true, 'blocked_note': why, 'blocked_until': ''}, key: k));
      case 'unblock':
        await _send((k) => widget.api.saveInventory({'id': id, 'name': r.s('name'), 'blocked': false, 'blocked_note': '', 'blocked_until': ''}, key: k), done: '${r.s('name')} is back in use.');
      case 'remove':
        await _send((k) => widget.api.saveInventory({'id': id, 'archived': true}, key: k), done: '${r.s('name')} removed.');
      case 'in_work' || 'ready' || 'returned':
        await _send((k) => widget.api.saveCare({'id': id, 'status': pick}, key: k),
            done: pick == 'returned' ? '${r.s('item')} handed back to ${r.s('customer_name')}.' : null);
      case 'edit':
        if (s.key == 'care') {
          await _careForm(r);
        } else {
          await _form(s, r);
        }
    }
  }

  Future<void> _add(_Section s) async {
    if (s.key == 'team') return _openTeam();
    if (s.key == 'care') return _careForm(null);
    return _form(s, null);
  }

  Widget _field(String key, String label, TextEditingController c, {bool number = false, String hint = ''}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          key: ValueKey('inv-$key'),
          controller: c,
          keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
          decoration: InputDecoration(labelText: label, hintText: hint),
        ),
      );

  /// Add or edit a place, tool or material: its name, how many, a note, the services it is for (materials: unit, reorder level, use per booking).
  Future<void> _form(_Section s, SvcData? r) async {
    final mat = s.kind == 'material';
    String num0(String k) => r == null || r.raw[k] == null ? '' : _plain(r.n(k));
    final name = TextEditingController(text: r?.s('name') ?? '');
    final qty = TextEditingController(text: r == null ? (mat ? '' : '1') : _plain(r.n('qty')));
    final unit = TextEditingController(text: r?.s('unit') ?? '');
    final reorder = TextEditingController(text: num0('reorder_at'));
    final per = TextEditingController(text: num0('per_booking'));
    final note = TextEditingController(text: r?.s('note') ?? '');
    final picked = <String>{...?r?.ls('service_ids')};
    final key = ServiceApi.newKey();
    final saved = await showOrderSheet<bool>(context, title: r == null ? s.add : 'Edit ${r.s('name')}', body: (ctx) => StatefulBuilder(
          builder: (ctx, set) => SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _field('name', 'Name', name, hint: switch (s.kind) { 'place' => 'Chair 1, Court 2, Party hall', 'tool' => 'Ladder, Rackets, Sound system', _ => 'Shampoo, Shuttlecocks, Gloves' }),
              Row(children: [
                Expanded(child: _field('qty', mat ? 'In stock' : 'How many', qty, number: true)),
                if (mat) ...[const SizedBox(width: 10), Expanded(child: _field('unit', 'Unit', unit, hint: 'tubes, bottles, kg'))],
              ]),
              if (mat)
                Row(children: [
                  Expanded(child: _field('reorder', 'Warn me at', reorder, number: true)),
                  const SizedBox(width: 10),
                  Expanded(child: _field('per', 'Used per booking', per, number: true)),
                ]),
              _field('note', 'Note (optional)', note),
              if (_inv!.services.isNotEmpty) ...[
                Text('Used for', style: inter(13, 600, color: kMuted)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final sv in _inv!.services)
                    ModeChip(sv.s('name'), selected: picked.contains(sv.s('id')),
                        onTap: () => set(() => picked.contains(sv.s('id')) ? picked.remove(sv.s('id')) : picked.add(sv.s('id')))),
                ]),
                const SizedBox(height: 12),
              ],
              DarkCta(key: const ValueKey('inv-save'), label: 'Save', onPressed: () => Navigator.pop(ctx, true)),
            ]),
          ),
        ));
    if (saved != true || !mounted) return;
    num? n(TextEditingController c) => c.text.trim().isEmpty ? null : num.tryParse(c.text.trim());
    if (name.text.trim().isEmpty) {
      showToast(context, 'Enter a name.');
      return;
    }
    await _send(
      (_) => widget.api.saveInventory({
        if (r != null) 'id': r.s('id'),
        'kind': s.kind,
        'name': name.text.trim(),
        'qty': n(qty) ?? (mat ? 0 : 1),
        'note': note.text.trim(),
        if (mat) ...{'unit': unit.text.trim(), 'reorder_at': n(reorder), 'per_booking': n(per)},
        'service_ids': picked.toList(),
      }, key: key),
      done: r == null ? '${name.text.trim()} added.' : 'Saved.',
    );
  }

  /// Take in a customer's item (or change its details): what it is, whose, their number, a note and the day it was promised.
  Future<void> _careForm(SvcData? r) async {
    final item = TextEditingController(text: r?.s('item') ?? '');
    final who = TextEditingController(text: r?.s('customer_name') ?? '');
    final phone = TextEditingController(text: r?.s('customer_phone') ?? '');
    final note = TextEditingController(text: r?.s('note') ?? '');
    DateTime? promised = DateTime.tryParse(r?.s('promised_on') ?? '');
    final key = ServiceApi.newKey();
    final saved = await showOrderSheet<bool>(context, title: r == null ? 'Take in an item' : 'Change details', body: (ctx) => StatefulBuilder(
          builder: (ctx, set) => SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _field('item', 'What is it', item, hint: 'Kit bag, laptop, dress, racket'),
              _field('customer', 'Customer\'s name', who),
              _field('phone', 'Mobile number (optional)', phone, number: true),
              _field('care-note', 'Note (optional)', note, hint: 'Restringing, left at the counter'),
              LightCta(
                key: const ValueKey('inv-promised'),
                label: promised == null ? 'Promised for (optional)' : 'Promised for ${promised!.day}/${promised!.month}/${promised!.year}',
                onPressed: () async {
                  final now = DateTime.now();
                  final d = await showDatePicker(context: ctx, initialDate: promised ?? now, firstDate: now.subtract(const Duration(days: 365)), lastDate: now.add(const Duration(days: 365)));
                  if (d != null) set(() => promised = d);
                },
              ),
              const SizedBox(height: 12),
              DarkCta(key: const ValueKey('inv-save'), label: r == null ? 'Take in' : 'Save', onPressed: () => Navigator.pop(ctx, true)),
            ]),
          ),
        ));
    if (saved != true || !mounted) return;
    if (item.text.trim().isEmpty || who.text.trim().isEmpty) {
      showToast(context, 'Enter the item and the customer\'s name.');
      return;
    }
    String iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    await _send(
      (_) => widget.api.saveCare({
        if (r != null) 'id': r.s('id'),
        'item': item.text.trim(),
        'customer_name': who.text.trim(),
        'customer_phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
        'note': note.text.trim(),
        'promised_on': promised == null ? null : iso(promised!),
      }, key: key),
      done: r == null ? '${item.text.trim()} taken in.' : 'Saved.',
    );
  }
}

/// 4 for 4.00, 2.5 for 2.50.
String _plain(num v) => v == v.roundToDouble() ? v.round().toString() : v.toString();
