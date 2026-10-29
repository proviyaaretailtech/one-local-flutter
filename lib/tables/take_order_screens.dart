import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import 'dish_options_sheet.dart';
import 'table_order_screen.dart';
import 'table_widgets.dart';
import 'tables_api.dart';
import '../ui/motion.dart';

// "Take an order at a table" (founder-approved 2026-10-20; Figma BEP6SKzfNy1lH0D6pHwGFv, Journey 3): Add dishes (18:403), Sent to kitchen (18:467),
// Ready to serve (18:556). The database (migration 0485) places or extends the table's order, works out the bill, makes the KOT and decides who may do
// what; these screens send the choices and draw the answers. No kitchen setup is needed: dishes go to the default Main Kitchen queue.

const _kDarkBtn = Color(0xFF0F1F17);
const _kLimeText = Color(0xFF8BE33A);
const _kGreen = Color(0xFF16A34A);
const _kAmber = Color(0xFFB45309);

/// Dark full-width button with lime text ("Send to kitchen", "Back to tables", "Mark as served").
class DarkButton extends StatelessWidget {
  const DarkButton(this.label, {super.key, required this.onPressed, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: onPressed != null && !busy,
        child: Material(
          color: onPressed == null ? const Color(0xFF9AA39E) : _kDarkBtn,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: busy ? null : onPressed,
            child: Container(
              height: 56,
              alignment: Alignment.center,
              child: busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: _kLimeText))
                  : Text(label, style: inter(16, 700, color: onPressed == null ? Colors.white70 : _kLimeText)),
            ),
          ),
        ),
      );
}

Widget _letter(String name, {Color bg = const Color(0xFFFFF3D6)}) => Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Text(name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase(), style: inter(16, 700)),
    );

/// Figma "Add dishes": category tabs, dish rows with quantity and note, Total so far, Send to kitchen, Save and hold.
class AddDishesScreen extends StatefulWidget {
  const AddDishesScreen({super.key, required this.env, required this.tableId, required this.tableLabel, this.guests});
  final TablesEnv env;
  final String tableId, tableLabel;
  final int? guests;
  @override
  State<AddDishesScreen> createState() => _AddDishesScreenState();
}

class _AddDishesScreenState extends State<AddDishesScreen> {
  Facts? _menu;
  num _already = 0;
  String? _error;
  String? _cat;
  final _qty = <String, int>{};
  final _note = <String, String>{};
  String? _key; // one per intent: kept while the choice does not change, so a retried tap is the same request
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final menu = await widget.env.api.menu();
      num already = 0;
      try {
        already = (await widget.env.api.orderView(widget.tableId)).n('subtotal');
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _menu = menu;
        _already = already;
        _error = null;
        final cats = menu.raw['categories'] as List? ?? const [];
        _cat ??= cats.isEmpty ? null : cats.first.toString();
      });
    } catch (e) {
      if (mounted) setState(() => _error = sayError(e));
    }
  }

  List<Facts> get _items => _menu?.l('items') ?? const [];
  Facts? _item(String id) => _items.where((i) => i.s('id') == id).firstOrNull;

  void _set(String id, int q) => setState(() {
        if (q <= 0) {
          _qty.remove(id);
          _note.remove(id);
          _extras.remove(id);
        } else {
          _qty[id] = q.clamp(1, 99);
        }
        _key = null;
      });

  Future<void> _editNote(Facts i) async {
    final c = TextEditingController(text: _note[i.s('id')] ?? '');
    final v = await showOlDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Note for ${i.s('name')}', style: inter(17, 700)),
        content: TextField(key: const ValueKey('dish-note-field'), controller: c, maxLength: 200, autofocus: true, decoration: const InputDecoration(hintText: 'e.g. less butter')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(key: const ValueKey('dish-note-save'), onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (v == null) return;
    setState(() {
      if (v.isEmpty) {
        _note.remove(i.s('id'));
      } else {
        _note[i.s('id')] = v;
      }
      _key = null;
    });
  }

  // Display only: what the dishes chosen here add to the bill so far; the bill itself is worked out by the database.
  num get _soFar => _already + _qty.entries.fold<num>(0, (a, e) => a + _priceOf(e.key) * e.value);

  // A choice's key is the dish id, or "dish#size" for a size of a dish with sizes (0611: Small / Medium / Large).
  // 0624: then "~…" for the add-ons and combos chosen in the pop-up; what was chosen is kept in _extras.
  static String _main(String k) => k.split('~').first;
  static String _dishOf(String k) => _main(k).split('#').first;
  static String? _sizeOf(String k) => _main(k).contains('#') ? _main(k).split('#').last : null;
  final _extras = <String, DishChoice>{};
  num _priceOf(String k) {
    final item = _item(_dishOf(k));
    final size = _sizeOf(k);
    final v = size == null ? null : item?.l('variants').where((x) => x.s('id') == size).firstOrNull;
    return (v?.n('price') ?? item?.n('price') ?? 0) + (_extras[k]?.extra ?? 0);
  }

  /// Opens the pop-up (0624) and adds one of the dish as chosen; the same choice again adds to that line.
  Future<void> _addWithOptions(Facts i) async {
    final c = await showDishOptions(context, i);
    if (c == null || !mounted) return;
    final k = '${i.s('id')}${c.variantId == null ? '' : '#${c.variantId}'}${c.signature}';
    setState(() {
      if (c.hasExtras) _extras[k] = c;
      _qty[k] = ((_qty[k] ?? 0) + 1).clamp(1, 99);
      _key = null;
    });
  }

  /// A dish with add-ons or combos (0624): its name and Add (opens the pop-up), then one line per way it was chosen, with what was chosen,
  /// its price and its own − / +.
  Widget _optionsRow(Facts i, {required bool last}) {
    final id = i.s('id');
    final keys = [for (final k in _qty.keys) if (_dishOf(k) == id) k];
    return Container(
      key: ValueKey('dish-$id'),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
      decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: kLine))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          _letter(i.s('name')),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(i.s('name'), style: inter(15, 600)),
              Text('${rupees(i.n('price'))} · add-ons & combos', style: inter(12.5, 400, color: kMuted)),
            ]),
          ),
          TextButton.icon(
            key: ValueKey('options-$id'),
            onPressed: _busy ? null : () => _addWithOptions(i),
            icon: const Icon(LucideIcons.plus, size: 16, color: kLink),
            label: Text('Add', style: inter(14, 700, color: kLink)),
          ),
        ]),
        for (final k in keys)
          Padding(
            padding: const EdgeInsets.only(left: 48, top: 6),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Builder(builder: (_) {
                    final size = _sizeOf(k) == null ? null : i.l('variants').where((v) => v.s('id') == _sizeOf(k)).firstOrNull?.s('name');
                    final what = [if (size != null) size, if ((_extras[k]?.summary ?? '').isNotEmpty) _extras[k]!.summary].join(' · ');
                    return Text(what.isEmpty ? 'Plain' : what, key: ValueKey('line-$k'), style: inter(13, 600));
                  }),
                  Text('${rupees(_priceOf(k))} each', style: inter(12, 500, color: kMuted)),
                ]),
              ),
              Text('${_qty[k]}', style: inter(14, 800)),
              const SizedBox(width: 6),
              _step(LucideIcons.minus, 'Less ${i.s('name')}', () => _set(k, (_qty[k] ?? 0) - 1), ValueKey('minus-$k')),
              _step(LucideIcons.plus, 'More ${i.s('name')}', () => _set(k, (_qty[k] ?? 0) + 1), ValueKey('plus-$k')),
            ]),
          ),
      ]),
    );
  }

  /// A dish with sizes: its name, then one line per size with its price and its own − / +.
  Widget _sizedRow(Facts i, {required bool last}) {
    final id = i.s('id');
    return Container(
      key: ValueKey('dish-$id'),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
      decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: kLine))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          _letter(i.s('name')),
          const SizedBox(width: 12),
          Expanded(child: Text(i.s('name'), style: inter(15, 600))),
          Text('Choose a size', style: inter(12, 500, color: kMuted)),
        ]),
        for (final v in i.l('variants'))
          Builder(builder: (context) {
            final k = '$id#${v.s('id')}', q = _qty[k] ?? 0;
            return Padding(
              padding: const EdgeInsets.only(left: 48, top: 4),
              child: Row(children: [
                Expanded(child: Text('${v.s('name')} · ${rupees(v.n('price'))}', style: inter(13.5, q > 0 ? 700 : 500, color: q > 0 ? kInk : kMuted))),
                if (q > 0) Text('$q', key: ValueKey('qty-$id-${v.s('name')}'), style: inter(14, 800)),
                const SizedBox(width: 6),
                if (q > 0) _step(LucideIcons.minus, 'Less ${v.s('name')} ${i.s('name')}', () => _set(k, q - 1), ValueKey('minus-$id-${v.s('name')}')),
                _step(LucideIcons.plus, 'More ${v.s('name')} ${i.s('name')}', () => _set(k, q + 1), ValueKey('plus-$id-${v.s('name')}')),
              ]),
            );
          }),
      ]),
    );
  }

  Future<void> _submit(bool send) async {
    if (_qty.isEmpty) return showToast(context, 'Choose at least one dish.');
    final key = _key ??= TablesApi.newKey();
    setState(() => _busy = true);
    try {
      final r = await widget.env.api.addDishes(
        widget.tableId,
        [
          for (final e in _qty.entries)
            {
              'menu_item_id': _dishOf(e.key), 'qty': e.value, if (_sizeOf(e.key) != null) 'variant_id': _sizeOf(e.key), if (_note[e.key] != null) 'notes': _note[e.key],
              ...?_extras[e.key]?.lineFields,
            },
        ],
        send: send,
        key: key,
        guests: widget.guests,
      );
      if (!mounted) return;
      final kot = r.mo('kot');
      if (send && kot != null) {
        await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => SentToKitchenScreen(env: widget.env, tableLabel: widget.tableLabel, kot: kot)));
      } else {
        Navigator.of(context).pop(true);
        showToast(context, 'Saved on ${widget.tableLabel}. Send to the kitchen when ready.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showToast(context, sayError(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cats = (_menu?.raw['categories'] as List? ?? const []).map((e) => e.toString()).toList();
    final shown = _items.where((i) => _cat == null || i.s('category') == _cat).toList();
    return TablesPage(
      env: widget.env,
      title: widget.tableLabel,
      subtitle: [if (widget.guests != null) '${widget.guests} guests', 'Dine-in'].join(' · '),
      back: true,
      onRefresh: _load,
      footer: _menu == null
          ? null
          : Container(
              color: kBg,
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
                  child: Row(children: [
                    Expanded(child: Text('Total so far', style: inter(16, 600))),
                    Text(rupees(_soFar), key: const ValueKey('total-so-far'), style: inter(20, 700, color: _kGreen)),
                  ]),
                ),
                const SizedBox(height: 10),
                DarkButton('Send to kitchen', key: const ValueKey('send-to-kitchen'), busy: _busy, onPressed: _qty.isEmpty ? null : () => _submit(true)),
                const SizedBox(height: 10),
                OutlineButtonT('Save and hold', key: const ValueKey('save-and-hold'), height: 52, enabledLook: _qty.isNotEmpty, onPressed: _busy || _qty.isEmpty ? null : () => _submit(false)),
              ]),
            ),
      children: [
        if (_menu == null && _error == null) tablesLoading(),
        if (_error != null) TablesError(_error!, onRetry: _load),
        if (_menu != null) ...[
          if (cats.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(children: [
                for (final c in cats)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Semantics(
                      button: true,
                      selected: _cat == c,
                      child: InkWell(
                        key: ValueKey('cat-$c'),
                        borderRadius: BorderRadius.circular(999),
                        onTap: () => setState(() => _cat = c),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                          decoration: BoxDecoration(color: _cat == c ? _kDarkBtn : Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: _cat == c ? _kDarkBtn : kLine)),
                          child: Text(c, style: inter(14, 600, color: _cat == c ? Colors.white : kInk)),
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
          if (shown.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Center(child: Text('No dishes on sale here yet.', style: inter(15, 400, color: kMuted)))),
          Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
            child: Column(children: [for (var k = 0; k < shown.length; k++) _row(shown[k], last: k == shown.length - 1)]),
          ),
        ],
      ],
    );
  }

  Widget _row(Facts i, {required bool last}) {
    if (dishHasExtras(i)) return _optionsRow(i, last: last);
    if (i.l('variants').isNotEmpty) return _sizedRow(i, last: last);
    final id = i.s('id'), q = _qty[id] ?? 0, note = _note[id];
    return Container(
      key: ValueKey('dish-$id'),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: kLine))),
      child: Row(children: [
        _letter(i.s('name')),
        const SizedBox(width: 12),
        Expanded(
          child: InkWell(
            onTap: q == 0 ? () => _set(id, 1) : () => _editNote(i),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(i.s('name'), style: inter(15, 600)),
              Text(q == 0 ? rupees(i.n('price')) : ['Quantity $q', if (note != null) note].join(' · '), style: inter(12.5, 400, color: kMuted)),
              if (q > 0) Text(note == null ? 'Add a note' : 'Change note', style: inter(12, 600, color: kLink)),
            ]),
          ),
        ),
        if (q > 0) Text(rupees(i.n('price') * q), style: inter(15, 700)),
        const SizedBox(width: 6),
        if (q > 0) _step(LucideIcons.minus, 'Less ${i.s('name')}', () => _set(id, q - 1), ValueKey('minus-$id')),
        _step(LucideIcons.plus, 'More ${i.s('name')}', () => _set(id, q + 1), ValueKey('plus-$id')),
      ]),
    );
  }

  Widget _step(IconData icon, String label, VoidCallback onTap, Key key) => Semantics(
        button: true,
        label: label,
        child: InkWell(
          key: key,
          customBorder: const CircleBorder(),
          onTap: _busy ? null : onTap,
          child: Container(width: 36, height: 36, margin: const EdgeInsets.only(left: 4), decoration: const BoxDecoration(color: kBg, shape: BoxShape.circle), child: Icon(icon, size: 18, color: kInk)),
        ),
      );
}

/// Figma "Sent to kitchen": KOT #N sent, how many dishes, station and time, Back to tables.
class SentToKitchenScreen extends StatelessWidget {
  const SentToKitchenScreen({super.key, required this.env, required this.tableLabel, required this.kot});
  final TablesEnv env;
  final String tableLabel;
  final Facts kot;
  @override
  Widget build(BuildContext context) {
    final n = kot.n('dishes').toInt();
    final stations = (kot.raw['stations'] as List? ?? const []).map((e) => e.toString()).join(', ');
    final at = kot.t('sent_at');
    return TablesPage(
      env: env,
      title: 'Sent to kitchen',
      subtitle: tableLabel,
      back: true,
      children: [
        const SizedBox(height: 24),
        Center(
          child: Container(
            width: 88,
            height: 88,
            decoration: const BoxDecoration(color: Color(0xFFE6F7DA), shape: BoxShape.circle),
            child: const Icon(LucideIcons.check, size: 40, color: _kGreen),
          ),
        ),
        const SizedBox(height: 16),
        Center(child: Text('KOT #${kot.n('kot_no').toInt()} sent', key: const ValueKey('kot-sent'), style: inter(22, 700, color: _kGreen))),
        const SizedBox(height: 6),
        Center(child: Text('$n ${n == 1 ? 'item' : 'items'}. The kitchen screen shows it now.', style: inter(14, 400, color: kMuted))),
        const SizedBox(height: 22),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: Column(children: [
            _kv('Station', stations.isEmpty ? 'Main Kitchen' : stations),
            const Divider(height: 1, color: kLine),
            _kv('Time', at == null ? '—' : clock12Padded(at)),
          ]),
        ),
        const SizedBox(height: 22),
        DarkButton('Back to tables', key: const ValueKey('back-to-tables'), onPressed: () => Navigator.of(context).pop(true)),
      ],
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [Expanded(child: Text(k, style: inter(14, 400, color: kMuted))), Text(v, style: inter(14, 700))]),
      );
}

/// Figma "Ready to serve": the dishes the kitchen says are done (and the ones still cooking), Mark as served.
class ReadyToServeScreen extends StatefulWidget {
  const ReadyToServeScreen({super.key, required this.env});
  final TablesEnv env;
  @override
  State<ReadyToServeScreen> createState() => _ReadyToServeScreenState();
}

class _ReadyToServeScreenState extends State<ReadyToServeScreen> {
  Facts? _d;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.env.api.readyList();
      if (mounted) setState(() {
        _d = d;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = sayError(e));
    }
  }

  Future<void> _serve(List<Facts> ready) async {
    setState(() => _busy = true);
    try {
      final r = await widget.env.api.markServed([for (final i in ready) i.s('item_id')]);
      if (!mounted) return;
      final served = r.n('served').toInt();
      final done = r.l('orders').where((o) => o.b('all_served')).toList();
      setState(() => _busy = false);
      showToast(context, served == 0 ? 'Already served.' : '$served ${served == 1 ? 'dish' : 'dishes'} served.');
      if (done.length == 1) {
        final tableId = ready.firstWhere((i) => i.s('order_id') == done.first.s('order_id'), orElse: () => ready.first).s('table_id');
        final open = await showOlDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('${done.first.s('table_label')}: everything served', style: inter(17, 700)),
            content: Text('The table can go to the bill.', style: inter(14, 400)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Later')),
              TextButton(key: const ValueKey('open-bill'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Open the bill')),
            ],
          ),
        );
        if (open == true && mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TableOrderScreen(env: widget.env, tableId: tableId)));
      }
    } catch (e) {
      if (mounted) showToast(context, sayError(e));
    }
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _d?.l('items') ?? const <Facts>[];
    final ready = items.where((i) => i.s('status') == 'ready').toList();
    final can = _d?.m('can').b('serve') ?? false;
    return TablesPage(
      env: widget.env,
      title: 'Ready to serve',
      subtitle: 'The kitchen says these are done',
      back: true,
      onRefresh: _load,
      // no greyed-out button when nothing is waiting at the pass
      footer: _d == null || items.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
              child: DarkButton('Mark as served', key: const ValueKey('mark-served'), busy: _busy, onPressed: ready.isEmpty || !can ? null : () => _serve(ready)),
            ),
      children: [
        if (_d == null && _error == null) tablesLoading(),
        if (_error != null) TablesError(_error!, onRetry: _load),
        if (_d != null && items.isEmpty) Padding(padding: const EdgeInsets.all(32), child: Center(child: Text('Nothing waiting at the pass.', style: inter(15, 400, color: kMuted)))),
        if (items.isNotEmpty)
          Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
            child: Column(children: [
              for (var k = 0; k < items.length; k++)
                Container(
                  key: ValueKey('ready-${items[k].s('item_id')}'),
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  decoration: BoxDecoration(border: k == items.length - 1 ? null : const Border(bottom: BorderSide(color: kLine))),
                  child: Row(children: [
                    _letter('T', bg: items[k].s('status') == 'ready' ? const Color(0xFFE6F7DA) : const Color(0xFFFFF3D6)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${items[k].s('table_label')} · ${items[k].s('name')}${items[k].n('qty') > 1 ? ' ×${items[k].n('qty').toInt()}' : ''}', style: inter(15, 600)),
                        Text('KOT #${items[k].n('kot_no').toInt()} · ${items[k].s('station')}', style: inter(12.5, 400, color: kMuted)),
                      ]),
                    ),
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(items[k].s('status_label'), style: inter(14, 700, color: items[k].s('status') == 'ready' ? _kGreen : _kAmber)),
                      if (items[k].s('status') != 'ready') Text('${items[k].n('minutes').toInt()} min', style: inter(12, 500, color: _kAmber)),
                    ]),
                  ]),
                ),
            ]),
          ),
      ],
    );
  }
}
