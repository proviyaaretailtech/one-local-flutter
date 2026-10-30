import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../ui/theme.dart';
import 'table_widgets.dart' show rupees, kLimeBtn;

// The one pop-up billing shows for a dish (founder, 29 Oct 2026): its size, its add-on groups and its combo groups (0624), each group with
// how many may be chosen. Used by Add dishes (dine-in) and by the Bill's Takeaway / Delivery picker.

/// What was chosen for one dish: a size, add-ons (an id with how many) and combos.
class DishChoice {
  const DishChoice({this.variantId, this.variantName, this.addons = const {}, this.combos = const {}, this.extra = 0, this.summary = ''});
  final String? variantId, variantName;
  final Map<String, int> addons; // add-on id → how many
  final Set<String> combos;
  final num extra; // what the add-ons and combos add to one dish
  final String summary; // "2 × Cheese slices · fries & Cole (combo)"

  bool get hasExtras => addons.isNotEmpty || combos.isNotEmpty;

  /// The part of a cart key that tells two choices of the same dish apart ('' without add-ons or combos).
  String get signature {
    if (!hasExtras) return '';
    final a = (addons.entries.map((e) => '${e.key}*${e.value}').toList()..sort()).join(',');
    final c = (combos.toList()..sort()).join(',');
    return '~$a~$c';
  }

  /// The line's add-ons and combos as the server takes them (an add-on id once per piece).
  Map<String, Object> get lineFields => {
        if (addons.isNotEmpty) 'addons': [for (final e in addons.entries) for (var i = 0; i < e.value; i++) e.key],
        if (combos.isNotEmpty) 'combos': combos.toList(),
      };
}

/// True when a dish should open the pop-up: it has sizes, add-ons or combos.
bool dishHasOptions(Facts item) => item.l('variants').isNotEmpty || dishHasExtras(item);
bool dishHasExtras(Facts item) => (item.mo('options')?.l('addon_groups').isNotEmpty ?? false) || (item.mo('options')?.l('combo_groups').isNotEmpty ?? false);

/// Opens the pop-up for [item]; the choice, or null when closed.
Future<DishChoice?> showDishOptions(BuildContext context, Facts item) => showModalBottomSheet<DishChoice>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _DishOptions(item: item),
    );

class _DishOptions extends StatefulWidget {
  const _DishOptions({required this.item});
  final Facts item;
  @override
  State<_DishOptions> createState() => _DishOptionsState();
}

class _DishOptionsState extends State<_DishOptions> {
  late final List<Facts> _sizes = widget.item.l('variants');
  late final List<Facts> _addonGroups = widget.item.mo('options')?.l('addon_groups') ?? const [];
  late final List<Facts> _comboGroups = widget.item.mo('options')?.l('combo_groups') ?? const [];
  late String? _size = (_sizes.where((v) => v.b('is_default')).firstOrNull ?? _sizes.firstOrNull)?.s('id');
  final _addons = <String, int>{};
  final _combos = <String>{};

  num get _base => _sizes.where((v) => v.s('id') == _size).firstOrNull?.n('price') ?? widget.item.n('price');

  int _picked(Facts g) => g.l('addons').fold(0, (a, x) => a + (_addons[x.s('id')] ?? 0));
  int _pickedCombos(Facts g) => g.l('combos').where((c) => _combos.contains(c.s('id'))).length;

  num get _extra {
    num e = 0;
    for (final g in _addonGroups) {
      for (final a in g.l('addons')) {
        e += a.n('price') * (_addons[a.s('id')] ?? 0);
      }
    }
    for (final g in _comboGroups) {
      for (final c in g.l('combos')) {
        if (_combos.contains(c.s('id'))) e += c.n('price');
      }
    }
    return e;
  }

  /// The first group still short of its minimum, as a sentence; null when every group is satisfied.
  String? get _missing {
    for (final g in _addonGroups) {
      if (_picked(g) < g.n('min')) return 'Choose ${g.n('min').toInt()} from ${g.s('name')}';
    }
    for (final g in _comboGroups) {
      if (_pickedCombos(g) < g.n('min')) return 'Choose ${g.n('min').toInt()} from ${g.s('name')}';
    }
    return null;
  }

  void _setAddon(Facts g, Facts a, int q) => setState(() {
        final id = a.s('id');
        final max = g.n('max').toInt();
        final others = _picked(g) - (_addons[id] ?? 0);
        // one pick per group: tapping another one swaps
        if (max == 1 && q > 0) {
          for (final x in g.l('addons')) {
            _addons.remove(x.s('id'));
          }
          _addons[id] = 1;
          return;
        }
        final v = q.clamp(0, max - others);
        if (v <= 0) {
          _addons.remove(id);
        } else {
          _addons[id] = v;
        }
      });

  void _toggleCombo(Facts g, Facts c) => setState(() {
        final id = c.s('id');
        if (_combos.contains(id)) {
          _combos.remove(id);
          return;
        }
        if (g.n('max') == 1) {
          for (final x in g.l('combos')) {
            _combos.remove(x.s('id'));
          }
        } else if (_pickedCombos(g) >= g.n('max')) {
          return;
        }
        _combos.add(id);
      });

  void _done() {
    final names = <String>[];
    for (final g in _addonGroups) {
      for (final a in g.l('addons')) {
        final q = _addons[a.s('id')] ?? 0;
        if (q > 0) names.add('${q > 1 ? '$q × ' : ''}${a.s('name')}');
      }
    }
    for (final g in _comboGroups) {
      for (final c in g.l('combos')) {
        if (_combos.contains(c.s('id'))) names.add('${c.s('name')} (combo)');
      }
    }
    Navigator.pop(
      context,
      DishChoice(
        variantId: _size,
        variantName: _sizes.where((v) => v.s('id') == _size).firstOrNull?.s('name'),
        addons: Map.of(_addons),
        combos: Set.of(_combos),
        extra: _extra,
        summary: names.join(' · '),
      ),
    );
  }

  Widget _head(String title, String rule) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Row(children: [
          Expanded(child: Text(title, style: inter(15.5, 800))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: const Color(0xFFF1F2EE), borderRadius: BorderRadius.circular(20)),
            child: Text(rule, style: inter(11.5, 700, color: kMuted)),
          ),
        ]),
      );

  static String _rule(num min, num max) => min == 0 ? 'Optional · up to ${max.toInt()}' : (min == max ? 'Pick ${min.toInt()}' : 'Pick ${min.toInt()} to ${max.toInt()}');

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    final missing = _missing;
    final each = _base + _extra;
    return SizedBox(
      height: MediaQuery.of(context).size.height * .85,
      child: Column(children: [
        const SizedBox(height: 10),
        Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(4))),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
          child: Row(children: [
            Expanded(child: Text(i.s('name'), key: const ValueKey('opt-title'), style: inter(20, 800))),
            Text(rupees(_base), style: inter(16, 700, color: kMuted)),
          ]),
        ),
        Expanded(
          child: ListView(key: const ValueKey('opt-list'), padding: const EdgeInsets.fromLTRB(18, 0, 18, 12), children: [
            if (_sizes.isNotEmpty) ...[
              _head('Size', 'Pick 1'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final v in _sizes)
                  ChoiceChip(
                    key: ValueKey('opt-size-${v.s('name')}'),
                    label: Text('${v.s('name')} · ${rupees(v.n('price'))}', style: inter(13.5, 700, color: _size == v.s('id') ? Colors.white : kInk)),
                    selected: _size == v.s('id'),
                    selectedColor: kInk,
                    backgroundColor: Colors.white,
                    showCheckmark: false,
                    side: BorderSide(color: _size == v.s('id') ? kInk : kLine),
                    onSelected: (_) => setState(() => _size = v.s('id')),
                  ),
              ]),
            ],
            for (final g in _addonGroups) ...[
              _head(g.s('name'), _rule(g.n('min'), g.n('max'))),
              for (final a in g.l('addons')) _addonRow(g, a),
            ],
            for (final g in _comboGroups) ...[
              _head(g.s('name'), _rule(g.n('min'), g.n('max'))),
              for (final c in g.l('combos')) _comboRow(g, c),
            ],
          ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (missing != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(missing, key: const ValueKey('opt-missing'), style: inter(13, 600, color: kError))),
              FilledButton(
                key: const ValueKey('opt-add'),
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF0F1F17), minimumSize: const Size.fromHeight(54), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                onPressed: missing == null ? _done : null,
                child: Text('Add · ${rupees(each)}', style: inter(16, 800, color: kLimeBtn)),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _addonRow(Facts g, Facts a) {
    final id = a.s('id'), q = _addons[id] ?? 0;
    final single = g.n('max') == 1;
    final full = _picked(g) >= g.n('max');
    return Container(
      key: ValueKey('opt-addon-${a.s('name')}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(color: q > 0 ? kNote : Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: q > 0 ? kLimeBtn : kLine)),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a.s('name'), style: inter(14.5, 700)),
            Text('+${rupees(a.n('price'))}', style: inter(12.5, 600, color: kMuted)),
          ]),
        ),
        if (single)
          Checkbox(key: ValueKey('opt-addon-check-${a.s('name')}'), value: q > 0, activeColor: kInk, onChanged: (v) => _setAddon(g, a, v == true ? 1 : 0))
        else ...[
          if (q > 0) ...[
            _step(LucideIcons.minus, () => _setAddon(g, a, q - 1), ValueKey('opt-addon-minus-${a.s('name')}')),
            SizedBox(width: 26, child: Text('$q', key: ValueKey('opt-addon-qty-${a.s('name')}'), textAlign: TextAlign.center, style: inter(15, 800))),
          ],
          _step(LucideIcons.plus, full ? null : () => _setAddon(g, a, q + 1), ValueKey('opt-addon-plus-${a.s('name')}')),
        ],
      ]),
    );
  }

  Widget _comboRow(Facts g, Facts c) {
    final on = _combos.contains(c.s('id'));
    return Material(
      color: on ? kNote : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: on ? kLimeBtn : kLine)),
      child: InkWell(
        key: ValueKey('opt-combo-${c.s('name')}'),
        borderRadius: BorderRadius.circular(14),
        onTap: () => _toggleCombo(g, c),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(children: [
            Icon(on ? LucideIcons.circleCheck : LucideIcons.circle, size: 20, color: on ? const Color(0xFF16A34A) : kMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.s('name'), style: inter(14.5, 700)),
                if (c.s('items').isNotEmpty) Text(c.s('items'), style: inter(12, 500, color: kMuted)),
              ]),
            ),
            Text('+${rupees(c.n('price'))}', style: inter(14, 700)),
          ]),
        ),
      ),
    );
  }

  Widget _step(IconData icon, VoidCallback? onTap, Key key) => InkWell(
        key: key,
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: onTap == null ? const Color(0xFFF1F2EE) : kBg, shape: BoxShape.circle),
          child: Icon(icon, size: 17, color: onTap == null ? kMuted : kInk),
        ),
      );
}
