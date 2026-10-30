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

const _kTints = [Color(0xFFE3F1FC), Color(0xFFFDF0DC), Color(0xFFFBF3D0), Color(0xFFFCE9E7), Color(0xFFE9F2FB), Color(0xFFFFF7D6)];

/// A dish's picture: its photo, or its first letter on a soft tint; the veg / non-veg mark in the corner (founder, 30 Oct 2026).
Widget _thumb(Facts i) {
  final name = i.s('name').trim();
  final img = i.so('image_url');
  final food = i.s('food_type');
  final mark = food == 'non_veg' ? const Color(0xFFC62828) : food == 'egg' ? const Color(0xFFD97706) : const Color(0xFF15803D);
  return SizedBox(
    width: 58,
    height: 58,
    child: Stack(children: [
      Positioned.fill(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: ColoredBox(
            color: _kTints[(name.isEmpty ? 0 : name.codeUnitAt(0)) % _kTints.length],
            child: img != null && img.isNotEmpty
                ? Image.network(img, fit: BoxFit.cover, errorBuilder: (_, _, _) => Center(child: Text(name.isEmpty ? '?' : name[0].toUpperCase(), style: inter(20, 800))))
                : Center(child: Text(name.isEmpty ? '?' : name[0].toUpperCase(), style: inter(20, 800))),
          ),
        ),
      ),
      // the square-with-dot of Indian menus
      Positioned(
        left: 4,
        top: 4,
        child: Container(
          width: 14,
          height: 14,
          padding: const EdgeInsets.all(2.5),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(3), border: Border.all(color: mark, width: 1.2)),
          child: DecoratedBox(decoration: BoxDecoration(color: mark, shape: BoxShape.circle)),
        ),
      ),
    ]),
  );
}

/// One dish as a card; lime edge once some of it is chosen.
Widget _dishCard({required Key key, required bool chosen, required Widget child}) => AnimatedContainer(
      key: key,
      duration: const Duration(milliseconds: 220),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: chosen ? kLimeBtn : kLine, width: chosen ? 1.8 : 1),
        boxShadow: const [BoxShadow(color: Color(0x0A000000), blurRadius: 10, offset: Offset(0, 3))],
      ),
      child: child,
    );

/// Figma "Add dishes" (redesigned 30 Oct 2026): category pills with counts, each dish a card with its photo, + / steppers and size chips,
/// then one compact card with the total, Hold (save and hold) and Send to kitchen.
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

  /// How many dishes are chosen here, all lines together; and in one category.
  int get _units => _qty.values.fold(0, (a, q) => a + q);
  int _inCat(String c) => _qty.entries.where((e) => _item(_dishOf(e.key))?.s('category') == c).fold(0, (a, e) => a + e.value);

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
    return _dishCard(
      key: ValueKey('dish-$id'),
      chosen: keys.isNotEmpty,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          _thumb(i),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(i.s('name'), maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(15.5, 700)),
              const SizedBox(height: 2),
              Text(rupees(i.n('price')), style: inter(14, 700, color: kInk)),
              Text('Add-ons & combos', style: inter(11.5, 500, color: kMuted)),
            ]),
          ),
          _pillButton(ValueKey('options-$id'), 'Add', () => _addWithOptions(i)),
        ]),
        for (final k in keys)
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(14)),
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
              _stepper(_qty[k] ?? 0, 'Less ${i.s('name')}', 'More ${i.s('name')}', () => _set(k, (_qty[k] ?? 0) - 1), () => _set(k, (_qty[k] ?? 0) + 1),
                  ValueKey('minus-$k'), ValueKey('plus-$k')),
            ]),
          ),
      ]),
    );
  }

  /// A lime "+ Add" pill: the first tap on a dish.
  Widget _pillButton(Key key, String label, VoidCallback onTap) => Semantics(
        button: true,
        label: label,
        child: Material(
          color: kLimeBtn,
          borderRadius: BorderRadius.circular(40),
          child: InkWell(
            key: key,
            borderRadius: BorderRadius.circular(40),
            onTap: _busy ? null : onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(LucideIcons.plus, size: 16, color: kInk),
                const SizedBox(width: 4),
                Text(label, style: inter(14, 800)),
              ]),
            ),
          ),
        ),
      );

  /// The dark "− 2 +" of a chosen line; [qtyKey] goes on the count.
  Widget _stepper(int q, String lessLabel, String moreLabel, VoidCallback less, VoidCallback more, Key minusKey, Key plusKey, {Key? qtyKey}) => Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(color: _kDarkBtn, borderRadius: BorderRadius.circular(40)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _round(LucideIcons.minus, lessLabel, less, minusKey),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 24),
            child: Text('$q', key: qtyKey, textAlign: TextAlign.center, style: inter(15, 800, color: Colors.white)),
          ),
          _round(LucideIcons.plus, moreLabel, more, plusKey),
        ]),
      );

  Widget _round(IconData icon, String label, VoidCallback onTap, Key key) => Semantics(
        button: true,
        label: label,
        child: InkWell(
          key: key,
          customBorder: const CircleBorder(),
          onTap: _busy ? null : onTap,
          child: SizedBox(width: 32, height: 32, child: Icon(icon, size: 17, color: _kLimeText)),
        ),
      );

  /// A dish with sizes: its name, then one line per size with its price and its own − / +.
  Widget _sizedRow(Facts i, {required bool last}) {
    final id = i.s('id');
    final variants = i.l('variants');
    final chosen = variants.any((v) => (_qty['$id#${v.s('id')}'] ?? 0) > 0);
    return _dishCard(
      key: ValueKey('dish-$id'),
      chosen: chosen,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          _thumb(i),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(i.s('name'), maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(15.5, 700)),
              const SizedBox(height: 2),
              Text('Choose a size', style: inter(12, 500, color: kMuted)),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        // one chip per size: tap to add; a chosen size turns lime with its own − / + (founder, 30 Oct 2026)
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final v in variants)
            Builder(builder: (context) {
              final k = '$id#${v.s('id')}', q = _qty[k] ?? 0;
              final label = Text('${v.s('name')} · ${rupees(v.n('price'))}', style: inter(13, 700, color: kInk));
              if (q == 0) {
                return Semantics(
                  button: true,
                  label: 'More ${v.s('name')} ${i.s('name')}',
                  child: Material(
                    color: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(40), side: const BorderSide(color: kLine, width: 1.2)),
                    child: InkWell(
                      key: ValueKey('plus-$id-${v.s('name')}'),
                      borderRadius: BorderRadius.circular(40),
                      onTap: _busy ? null : () => _set(k, 1),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [label, const SizedBox(width: 6), const Icon(LucideIcons.plus, size: 15, color: kInk)]),
                      ),
                    ),
                  ),
                );
              }
              return Container(
                padding: const EdgeInsets.fromLTRB(14, 3, 3, 3),
                decoration: BoxDecoration(color: kLimeBtn, borderRadius: BorderRadius.circular(40)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  label,
                  const SizedBox(width: 8),
                  _stepper(q, 'Less ${v.s('name')} ${i.s('name')}', 'More ${v.s('name')} ${i.s('name')}', () => _set(k, q - 1), () => _set(k, q + 1),
                      ValueKey('minus-$id-${v.s('name')}'), ValueKey('plus-$id-${v.s('name')}'), qtyKey: ValueKey('qty-$id-${v.s('name')}')),
                ]),
              );
            }),
        ]),
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
          // one compact card (founder, 30 Oct 2026): the total and how many dishes, then Hold (save and hold) and Send to kitchen side by side
          : Container(
              margin: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: kLine),
                boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 3))],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Total so far', style: inter(12, 600, color: kMuted)),
                        Text(
                          _units == 0 ? 'No dishes chosen yet' : '$_units dish${_units == 1 ? '' : 'es'} chosen',
                          key: const ValueKey('dishes-chosen'),
                          style: inter(13.5, 700),
                        ),
                      ]),
                    ),
                    Text(rupees(_soFar), key: const ValueKey('total-so-far'), style: inter(22, 800, color: _kGreen)),
                  ]),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: OutlineButtonT('Hold', key: const ValueKey('save-and-hold'), icon: LucideIcons.pause, height: 48, enabledLook: _qty.isNotEmpty,
                        onPressed: _busy || _qty.isEmpty ? null : () => _submit(false)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: LimeButton('Send to kitchen', key: const ValueKey('send-to-kitchen'), icon: LucideIcons.send, height: 48, busy: _busy,
                        onPressed: _qty.isEmpty ? null : () => _submit(true)),
                  ),
                ]),
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
                // lime when picked, like the Bill's pills; a small count of the dishes chosen in that category
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
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          padding: EdgeInsets.fromLTRB(16, 9, _inCat(c) > 0 ? 8 : 16, 9),
                          decoration: BoxDecoration(color: _cat == c ? kLimeBtn : Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: _cat == c ? kLimeBtn : kLine)),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(c, style: inter(14, 700, color: kInk)),
                            if (_inCat(c) > 0) ...[
                              const SizedBox(width: 6),
                              Container(
                                constraints: const BoxConstraints(minWidth: 20),
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(color: _kDarkBtn, borderRadius: BorderRadius.circular(20)),
                                child: Text('${_inCat(c)}', key: ValueKey('cat-count-$c'), textAlign: TextAlign.center, style: inter(11.5, 800, color: Colors.white)),
                              ),
                            ],
                          ]),
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
          if (shown.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Center(child: Text('No dishes on sale here yet.', style: inter(15, 400, color: kMuted)))),
          // each dish its own card, building in one after another; a new category builds in again (lib/ui/motion.dart)
          for (var k = 0; k < shown.length; k++)
            Entrance(key: ValueKey('add-in-$_cat-${shown[k].s('id')}'), index: k, child: _row(shown[k], last: k == shown.length - 1)),
        ],
      ],
    );
  }

  Widget _row(Facts i, {required bool last}) {
    if (dishHasExtras(i)) return _optionsRow(i, last: last);
    if (i.l('variants').isNotEmpty) return _sizedRow(i, last: last);
    final id = i.s('id'), q = _qty[id] ?? 0, note = _note[id];
    return _dishCard(
      key: ValueKey('dish-$id'),
      chosen: q > 0,
      child: Row(children: [
        _thumb(i),
        const SizedBox(width: 12),
        Expanded(
          child: InkWell(
            onTap: q == 0 ? () => _set(id, 1) : () => _editNote(i),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(i.s('name'), maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(15.5, 700)),
              const SizedBox(height: 2),
              Text(q == 0 ? rupees(i.n('price')) : rupees(i.n('price') * q), style: inter(14, 700, color: kInk)),
              if (q > 0) ...[
                Text(['Quantity $q', if (note != null) note].join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 500, color: kMuted)),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(LucideIcons.pencilLine, size: 12, color: kLink),
                  const SizedBox(width: 4),
                  Text(note == null ? 'Add a note' : 'Change note', style: inter(12, 700, color: kLink)),
                ]),
              ],
            ]),
          ),
        ),
        const SizedBox(width: 8),
        if (q == 0)
          Semantics(
            button: true,
            label: 'More ${i.s('name')}',
            child: Material(
              color: kLimeBtn,
              shape: const CircleBorder(),
              child: InkWell(
                key: ValueKey('plus-$id'),
                customBorder: const CircleBorder(),
                onTap: _busy ? null : () => _set(id, 1),
                child: const SizedBox(width: 40, height: 40, child: Icon(LucideIcons.plus, size: 20, color: kInk)),
              ),
            ),
          )
        else
          _stepper(q, 'Less ${i.s('name')}', 'More ${i.s('name')}', () => _set(id, q - 1), () => _set(id, q + 1), ValueKey('minus-$id'), ValueKey('plus-$id')),
      ]),
    );
  }
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
