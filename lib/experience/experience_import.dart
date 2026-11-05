import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/net_guard.dart';
import '../menu/menu_build_api.dart';
import '../storefront/sf_widgets.dart';
import '../ui/theme.dart';
import 'experience_api.dart';

// Import menu (spec part 2, contract D): the owner pastes a menu (or picks a .csv / .txt file), the AI reads it into dishes
// (menu_ai_import, nothing saved), the owner checks each one, and "Add N dishes" adds them one by one through the menu's own quick add
// (menu_item_quick_add: the database checks the role, the name and the price). A category the menu does not have yet is added first
// with the category screen's own save (menu_category_save). A dish that fails keeps its reason and can be fixed and added again.

/// A file the person chose: its name and bytes, or null.
typedef MenuFilePicker = Future<({String name, Uint8List bytes})?> Function();

Future<({String name, Uint8List bytes})?> pickMenuTextFile() async {
  final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['csv', 'txt']);
  if (f == null) return null;
  return (name: f.name, bytes: await f.readAsBytes());
}

const kImportMax = 20000;

class GxImportScreen extends StatefulWidget {
  const GxImportScreen({super.key, required this.api, required this.menu, this.pickFile = pickMenuTextFile});
  final ExperienceApi api;
  final MenuBuildApi menu;
  final MenuFilePicker? pickFile;
  @override
  State<GxImportScreen> createState() => _GxImportScreenState();
}

class _GxImportScreenState extends State<GxImportScreen> {
  final _text = TextEditingController();
  List<GxImportDish>? _dishes;
  bool _reading = false, _adding = false;
  String? _error, _summary;
  int _done = 0, _total = 0, _added = 0;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final pick = widget.pickFile;
    if (pick == null) return;
    try {
      final f = await pick();
      if (f == null || !mounted) return;
      var t = utf8.decode(f.bytes, allowMalformed: true);
      if (t.length > kImportMax) {
        t = t.substring(0, kImportMax);
        showToast(context, 'Only the first 20,000 characters of ${f.name} were read. Import the rest after.');
      }
      setState(() {
        _text.text = t;
        _error = null;
      });
    } catch (_) {
      if (mounted) showToast(context, 'That file could not be read. Paste the menu instead.');
    }
  }

  Future<void> _read() async {
    setState(() {
      _reading = true;
      _error = null;
    });
    try {
      final d = await widget.api.aiImportMenu(_text.text);
      if (mounted) setState(() => _dishes = d);
    } catch (e) {
      if (mounted) setState(() => _error = errorSentence(e));
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _add() async {
    final todo = _dishes!.where((d) => d.ready).toList();
    setState(() {
      _adding = true;
      _summary = null;
      _done = 0;
      _total = todo.length;
      for (final d in todo) {
        d.error = null;
      }
    });
    // the categories the menu has (by name, any case), then each missing one through the category screen's own save
    final have = <String, String>{};
    var listed = false;
    try {
      for (final c in (await widget.menu.categories()).all) {
        have[c.name.toLowerCase()] = c.name;
      }
      listed = true;
    } catch (_) {/* quick add finds or adds the category by name itself */}
    final failedCats = <String, String>{};
    for (final name in {for (final d in todo) d.category.trim()}) {
      if (!listed || have.containsKey(name.toLowerCase())) continue;
      try {
        await widget.menu.saveCategory(name: name);
        have[name.toLowerCase()] = name;
      } catch (e) {
        failedCats[name.toLowerCase()] = 'The category "$name" could not be added: ${errorSentence(e)}';
      }
    }
    for (final d in todo) {
      final catError = failedCats[d.category.trim().toLowerCase()];
      if (catError != null) {
        d.error = catError;
      } else {
        try {
          await widget.menu.quickAdd(name: d.name.trim(), category: have[d.category.trim().toLowerCase()] ?? d.category.trim(), price: d.price!, foodType: d.foodType);
          d.added = true;
          _added++;
        } catch (e) {
          d.error = errorSentence(e);
        }
      }
      if (mounted) setState(() => _done++);
    }
    if (!mounted) return;
    final failed = todo.where((d) => !d.added).length;
    setState(() {
      _adding = false;
      _summary = failed == 0 ? null : '${todo.length - failed} added, $failed not added. Fix them and add again, or untick them.';
    });
    if (failed == 0) {
      showToast(context, '${todo.length} dish${todo.length == 1 ? '' : 'es'} added to your menu.');
      Navigator.of(context).pop(_added);
    }
  }

  Widget _paste() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Paste your menu as it is: a list, a photo\'s text, or a CSV with name, category and price. AI turns it into dishes; you check them before anything is added.',
            style: inter(13.5, 500, color: kMuted, height: 1.4)),
        const SizedBox(height: 12),
        SfField(
          key: const ValueKey('gx-import-text'),
          controller: _text,
          lines: 12,
          maxLength: kImportMax,
          hint: 'Hot Beverages\nCappuccino 99\nAmericano 89\n\nSandwiches\nPaneer Subway 209 (veg)',
          onChanged: (_) => setState(() {}),
          label: 'Menu',
        ),
        if (widget.pickFile != null) ...[
          const SizedBox(height: 10),
          SfSoft('Pick a .csv or .txt file', key: const ValueKey('gx-import-file'), icon: LucideIcons.fileUp, onPressed: _reading ? null : _pick),
        ],
        if (_reading)
          Padding(
            key: const ValueKey('gx-import-reading'),
            padding: const EdgeInsets.only(top: 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('AI is reading your menu…', style: inter(13, 600, color: kMuted)),
              const SizedBox(height: 6),
              const LinearProgressIndicator(color: kInk, backgroundColor: kLine),
            ]),
          ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, key: const ValueKey('gx-import-error'), style: inter(13.5, 600, color: kError))),
      ]);

  Widget _review(List<GxImportDish> dishes) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('${dishes.length} dish${dishes.length == 1 ? '' : 'es'} found. Check each one; untick any you do not want.', style: inter(13.5, 600, height: 1.35))),
          TextButton(
            key: const ValueKey('gx-import-back'),
            onPressed: _adding ? null : () => setState(() => _dishes = null),
            child: Text('Edit text', style: inter(13, 700)),
          ),
        ]),
        const SizedBox(height: 8),
        for (var i = 0; i < dishes.length; i++) _DishRow(key: ValueKey('gx-import-row-$i'), i: i, d: dishes[i], enabled: !_adding, onChanged: () => setState(() {})),
        if (_summary != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_summary!, key: const ValueKey('gx-import-summary'), style: inter(13.5, 700, color: kError))),
      ]);

  @override
  Widget build(BuildContext context) {
    final dishes = _dishes;
    final ready = dishes?.where((d) => d.ready).length ?? 0;
    return SfPage(
      title: 'Import menu',
      subtitle: dishes == null ? 'Paste your menu; AI turns it into dishes' : 'Review the dishes, then add them',
      onBack: () => Navigator.of(context).pop(_added),
      bottom: Column(mainAxisSize: MainAxisSize.min, children: [
        if (_adding) ...[
          Text('Adding $_done of $_total…', key: const ValueKey('gx-import-progress'), style: inter(13, 600, color: kMuted)),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: _total == 0 ? null : _done / _total, color: kInk, backgroundColor: kLine),
          const SizedBox(height: 8),
        ],
        dishes == null
            ? SfSave('Read with AI', key: const ValueKey('gx-import-read'), busy: _reading, onPressed: _text.text.trim().length >= 20 ? _read : null)
            : SfSave(ready == 0 ? 'Nothing to add' : 'Add $ready dish${ready == 1 ? '' : 'es'}', key: const ValueKey('gx-import-add'), lime: true, busy: _adding, onPressed: ready == 0 ? null : _add),
      ]),
      children: [dishes == null ? _paste() : _review(dishes)],
    );
  }
}

/// One dish to check: include, name, category, price, veg / non-veg / egg; its error or "Added" under it.
class _DishRow extends StatefulWidget {
  const _DishRow({super.key, required this.i, required this.d, required this.enabled, required this.onChanged});
  final int i;
  final GxImportDish d;
  final bool enabled;
  final VoidCallback onChanged;
  @override
  State<_DishRow> createState() => _DishRowState();
}

class _DishRowState extends State<_DishRow> {
  late final _name = TextEditingController(text: widget.d.name);
  late final _cat = TextEditingController(text: widget.d.category);
  late final _price = TextEditingController(text: _money(widget.d.price));

  static String _money(double? v) => v == null ? '' : (v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(2));

  @override
  void dispose() {
    _name.dispose();
    _cat.dispose();
    _price.dispose();
    super.dispose();
  }

  InputDecoration _box(String label) => InputDecoration(
        labelText: label,
        isDense: true,
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
        disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kInk)),
      );

  @override
  Widget build(BuildContext context) {
    final d = widget.d, i = widget.i;
    final edit = widget.enabled && !d.added;
    final problem = d.include && !d.added ? d.problem : null;
    return SfCard(
      padding: const EdgeInsets.fromLTRB(6, 10, 12, 10),
      child: Opacity(
        opacity: d.include || d.added ? 1 : 0.5,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          d.added
              ? Padding(padding: const EdgeInsets.all(12), child: Icon(LucideIcons.circleCheck, key: ValueKey('gx-import-added-$i'), size: 22, color: kLink))
              : Checkbox(
                  key: ValueKey('gx-import-include-$i'),
                  value: d.include,
                  activeColor: kInk,
                  onChanged: widget.enabled ? (v) => setState(() { d.include = v ?? false; widget.onChanged(); }) : null,
                ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                key: ValueKey('gx-import-name-$i'),
                controller: _name,
                enabled: edit,
                maxLength: 60,
                style: inter(14.5, 700),
                decoration: _box('Dish').copyWith(counterText: ''),
                onChanged: (v) { d.name = v; widget.onChanged(); },
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: ValueKey('gx-import-cat-$i'),
                    controller: _cat,
                    enabled: edit,
                    maxLength: 40,
                    style: inter(13.5, 500),
                    decoration: _box('Category').copyWith(counterText: ''),
                    onChanged: (v) { d.category = v; widget.onChanged(); },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: ValueKey('gx-import-price-$i'),
                    controller: _price,
                    enabled: edit,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: inter(13.5, 600),
                    decoration: _box('Price').copyWith(prefixText: '₹ '),
                    onChanged: (v) { d.price = double.tryParse(v.trim()); widget.onChanged(); },
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                for (final (k, label) in const [('veg', 'Veg'), ('non_veg', 'Non-veg'), ('egg', 'Egg')])
                  ChoiceChip(
                    key: ValueKey('gx-import-food-$i-$k'),
                    label: Text(label, style: inter(12.5, 600)),
                    selected: d.foodType == k,
                    selectedColor: kSfLimeSoft,
                    showCheckmark: false,
                    onSelected: edit ? (_) => setState(() { d.foodType = k; widget.onChanged(); }) : null,
                  ),
                if (!d.vegKnown && !d.added) Text('Check veg', style: inter(12, 600, color: const Color(0xFFB45309))),
              ]),
              if (d.added)
                Padding(padding: const EdgeInsets.only(top: 6), child: Text('Added to your menu', style: inter(12.5, 700, color: kLink)))
              else if (d.error != null || problem != null)
                Padding(padding: const EdgeInsets.only(top: 6), child: Text(d.error ?? problem!, key: ValueKey('gx-import-error-$i'), style: inter(12.5, 600, color: kError))),
            ]),
          ),
        ]),
      ),
    );
  }
}
