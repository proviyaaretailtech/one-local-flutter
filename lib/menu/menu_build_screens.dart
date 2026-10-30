import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/net_guard.dart';
import '../catalogue/item_photo.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'menu_api.dart' show MenuApiException;
import 'menu_build_api.dart';
import 'menu_build_widgets.dart';
import 'menu_widgets.dart' show FoodTypeMark, MenuError;
import 'recipes_screen.dart' show RecipeEditorScreen;

const _foodOptions = [('veg', 'Veg'), ('non_veg', 'Non-veg'), ('egg', 'Egg')];

// ---------------------------------------------------------------- quick add

/// Quick add: a dish from its photo, name, category, price, veg / non-veg / egg and course, as a full page in the style of the store's
/// Quick add (founder, 28 Oct 2026): white cards, a dashed photo box, lime choice chips and Add dish fixed at the bottom.
/// Answers the new dish's settings (null when cancelled).
class QuickAddSheet extends StatefulWidget {
  const QuickAddSheet({super.key, required this.api, this.categories = const [], this.labels = const {}, this.photos = const DeviceItemPhotos()});
  final MenuBuildApi api;
  final List<String> categories;

  /// How a category shows in the dropdown, by name: a subcategory as "Beverages › Cold coffee" (0616).
  final Map<String, String> labels;

  /// Picks and saves the dish's photo (tests pass a fake).
  final ItemPhotoService photos;
  static Future<DishSettings?> open(BuildContext context, MenuBuildApi api, {List<String> categories = const [], Map<String, String> labels = const {}, ItemPhotoService? photos}) =>
      Navigator.of(context).push<DishSettings>(MaterialPageRoute(builder: (_) => QuickAddSheet(api: api, categories: categories, labels: labels, photos: photos ?? const DeviceItemPhotos())));
  @override
  State<QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends State<QuickAddSheet> {
  static const _newCategory = '__new__';
  final _name = TextEditingController();
  late final _cat = TextEditingController(text: widget.categories.isEmpty ? '' : widget.categories.first);
  // the dropdown's choice: one of the categories, or a new one typed below it (also when there are no categories yet)
  late String _catChoice = widget.categories.isEmpty ? _newCategory : widget.categories.first;
  final _price = TextEditingController();
  String _food = 'veg', _course = 'eat';
  ItemPhoto? _photo;
  bool _busy = false;
  String? _error;

  Future<void> _pickPhoto() async {
    try {
      final p = await widget.photos.pick();
      if (p != null && mounted) setState(() => _photo = p);
    } on ItemPhotoUnavailable catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _save() async {
    final price = numOf(_price.text);
    final category = (_catChoice == _newCategory ? _cat.text : _catChoice).trim();
    if (_name.text.trim().length < 2) return setState(() => _error = 'Enter the dish name.');
    if (category.isEmpty) return setState(() => _error = 'Choose or type a category.');
    if (price == null || price <= 0) return setState(() => _error = 'Enter a selling price above zero.');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await widget.api.quickAdd(name: _name.text.trim(), category: category, price: price, foodType: _food, course: _course);
      // the photo goes on the new dish; the dish stays added even when the photo cannot be saved
      final photo = _photo;
      if (photo != null) {
        try {
          await widget.photos.attach(s.id, photo);
        } catch (e) {
          if (mounted) showToast(context, '${s.name} was added, but its photo could not be saved: ${e is ItemPhotoUnavailable ? e.message : 'try again in its settings'}.');
        }
      }
      if (mounted) Navigator.of(context).pop(s);
    } on MenuApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "Tap to add photo" beside the dish name, in a dashed box (as the store's Quick add); once chosen, the photo itself (tap to change).
  Widget _photoSpot() => SizedBox(
        width: 104,
        height: 120,
        child: CustomPaint(
          foregroundPainter: _photo == null ? const _DashedBox(color: Color(0xFFB9BDB3), radius: 16) : null,
          child: Material(
            color: const Color(0xFFF6F7F3),
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('qa-photo'),
              onTap: _busy ? null : _pickPhoto,
              child: _photo != null
                  ? Image.memory(_photo!.bytes, fit: BoxFit.cover, width: 104, height: 120, key: const ValueKey('qa-photo-preview'), errorBuilder: (_, _, _) => const Icon(LucideIcons.image, color: kMuted))
                  : Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(LucideIcons.camera, size: 22, color: kMuted),
                        const SizedBox(height: 6),
                        Text('Tap to add\nphoto', textAlign: TextAlign.center, style: inter(12.5, 500, color: kMuted)),
                      ]),
                    ),
            ),
          ),
        ),
      );

  static const _line = Color(0xFFDADDD5);
  static InputDecoration _deco(String hint, {String? prefix}) => InputDecoration(
        hintText: hint,
        hintStyle: inter(14.5, 400, color: const Color(0xFF9AA095)),
        prefixText: prefix,
        prefixStyle: inter(15, 600),
        counterText: '',
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _line)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _line)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kInk, width: 1.4)),
      );

  Widget _label(String s) => Padding(padding: const EdgeInsets.only(bottom: 7), child: Text(s, style: inter(13.5, 600, color: const Color(0xFF4B5148))));

  /// A white rounded card, as each block of the store's Quick add.
  Widget _card(List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22), border: Border.all(color: const Color(0xFFECEDE8))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );

  /// Choice chips as the store's "Sold in": the chosen one lime, the others white with a line.
  Widget _chips(String label, String keyPrefix, List<(String, String)> options, String value, ValueChanged<String> onChanged) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _label(label),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (v, text) in options)
            Material(
              key: ValueKey('$keyPrefix-$v'),
              color: v == value ? kMbLime : Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: v == value ? kMbLime : _line)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onChanged(v),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                  child: Text(text, style: inter(14.5, v == value ? 700 : 500, color: kInk)),
                ),
              ),
            ),
        ]),
      ]);

  /// Category as a dropdown of the menu's categories, with "+ New category" to type one.
  Widget _category() => Padding(
        padding: EdgeInsets.zero,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _label('Category'),
          if (widget.categories.isNotEmpty)
            DropdownButtonFormField<String>(
              key: const ValueKey('qa-category-dropdown'),
              initialValue: _catChoice,
              isExpanded: true,
              icon: const Icon(LucideIcons.chevronDown, size: 18, color: kMuted),
              style: inter(14.5, 500),
              borderRadius: BorderRadius.circular(14),
              dropdownColor: Colors.white,
              decoration: _deco('Choose a category'),
              items: [
                for (final c in widget.categories) DropdownMenuItem(value: c, child: Text(widget.labels[c] ?? c, key: ValueKey('qa-cat-$c'), style: inter(14.5, 500))),
                DropdownMenuItem(
                  value: _newCategory,
                  child: Row(key: const ValueKey('qa-cat-new'), children: [
                    const Icon(LucideIcons.plus, size: 16, color: kLink),
                    const SizedBox(width: 6),
                    Text('New category', style: inter(14.5, 600, color: kLink)),
                  ]),
                ),
              ],
              onChanged: (v) => setState(() {
                _catChoice = v ?? _catChoice;
                if (_catChoice == _newCategory) _cat.clear();
              }),
            ),
          if (_catChoice == _newCategory) ...[
            if (widget.categories.isNotEmpty) const SizedBox(height: 8),
            TextField(
              key: const ValueKey('qa-category'),
              controller: _cat,
              maxLength: 60,
              autofocus: widget.categories.isNotEmpty,
              style: inter(14.5, 500),
              decoration: _deco('For example Shakes'),
            ),
          ],
        ]),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(
          backgroundColor: kBg,
          surfaceTintColor: kBg,
          elevation: 0,
          leadingWidth: 64,
          leading: Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Center(
              child: Material(
                color: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFFECEDE8))),
                child: InkWell(
                  key: const ValueKey('qa-back'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.of(context).maybePop(),
                  child: const SizedBox(width: 42, height: 42, child: Icon(LucideIcons.arrowLeft, size: 20, color: kInk)),
                ),
              ),
            ),
          ),
          title: Text('Quick add a dish', style: inter(18, 700)),
        ),
        body: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 24), children: [
          // photo, name and category
          _card([
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _photoSpot(),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _label('Dish name'),
                  TextField(key: const ValueKey('qa-name'), controller: _name, maxLength: 120, style: inter(14.5, 500), decoration: _deco('For example Peri Peri Fries')),
                ]),
              ),
            ]),
            const SizedBox(height: 14),
            _category(),
          ]),
          // what it sells for
          _card([
            _label('Selling price'),
            TextField(
              key: const ValueKey('qa-price'),
              controller: _price,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: inter(15, 600),
              decoration: _deco('0', prefix: '₹ '),
            ),
          ]),
          // what kind of dish
          _card([
            _chips('Type', 'qa-food', _foodOptions, _food, (v) => setState(() => _food = v)),
            const SizedBox(height: 14),
            _chips('Course', 'qa-course', const [('eat', 'Food'), ('drink', 'Drink')], _course, (v) => setState(() => _course = v)),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
            child: Row(children: [
              const Icon(LucideIcons.slidersHorizontal, size: 16, color: kLink),
              const SizedBox(width: 8),
              Expanded(child: Text('Recipe, kitchen station and add-ons: set them in the dish\'s settings after adding.', style: inter(13, 600, color: kLink))),
            ]),
          ),
        ]),
        // the button stays at the bottom, above the keyboard
        bottomNavigationBar: Container(
          color: Colors.white,
          padding: EdgeInsets.fromLTRB(14, 10, 14, 12 + MediaQuery.viewInsetsOf(context).bottom),
          child: SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, key: const ValueKey('qa-error'), style: inter(13, 500, color: kError))),
              SizedBox(
                height: 54,
                child: FilledButton(
                  key: const ValueKey('qa-save'),
                  style: FilledButton.styleFrom(backgroundColor: kInk, disabledBackgroundColor: kMuted, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                  onPressed: _busy ? null : _save,
                  child: Text(_busy ? 'Saving…' : 'Add dish', style: inter(16, 700, color: kMbLime)),
                ),
              ),
            ]),
          ),
        ),
      );
}

/// A dashed rounded border (the empty photo box).
class _DashedBox extends CustomPainter {
  const _DashedBox({required this.color, required this.radius});
  final Color color;
  final double radius;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)));
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 9) {
        canvas.drawPath(m.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBox old) => old.color != color || old.radius != radius;
}

// ---------------------------------------------------------------- detailed settings

/// A dish's detailed settings: name, price, category, type, course, kitchen station, preparation time, recommended, code, add-on groups;
/// with its recipe's cost and margin and a way into the recipe.
class DishSettingsScreen extends StatefulWidget {
  const DishSettingsScreen({super.key, required this.api, required this.dishId});
  final MenuBuildApi api;
  final String dishId;
  static Route<bool> route(MenuBuildApi api, String dishId) => MaterialPageRoute(builder: (_) => DishSettingsScreen(api: api, dishId: dishId));
  @override
  State<DishSettingsScreen> createState() => _DishSettingsScreenState();
}

class _DishSettingsScreenState extends State<DishSettingsScreen> {
  DishSettings? _s;
  Object? _error;
  final _name = TextEditingController(), _price = TextEditingController(), _prep = TextEditingController(), _sku = TextEditingController();
  String _food = 'veg', _course = 'eat', _station = 'main', _categoryId = '';
  bool _recommended = false, _busy = false, _changed = false;
  Set<String> _groups = {}, _comboGroups = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _fill(DishSettings s) {
    _s = s;
    _name.text = s.name;
    _price.text = (s.priceMinor / 100).toStringAsFixed(s.priceMinor % 100 == 0 ? 0 : 2);
    _prep.text = '${s.prepMinutes}';
    _sku.text = s.sku;
    _food = s.foodType;
    _course = s.course;
    _station = s.station.isEmpty ? 'main' : s.station;
    _categoryId = s.categoryId;
    _recommended = s.recommended;
    _groups = s.addonGroupIds.toSet();
    _comboGroups = s.comboGroupIds.toSet();
  }

  /// New / edit a combo group, then show the fresh list (what was typed above stays); a new group is ticked on this dish.
  Future<void> _openComboGroup(ComboGroup? group) async {
    final id = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => ComboGroupEditor(api: widget.api, group: group)));
    if (id == null || !mounted) return;
    try {
      final fresh = await widget.api.settings(widget.dishId);
      if (!mounted) return;
      setState(() {
        _s = DishSettings({..._s!.raw, 'combo_groups': fresh.raw['combo_groups']});
        if (group == null && id.isNotEmpty) _comboGroups.add(id);
        _comboGroups.removeWhere((g) => !fresh.comboGroups.any((x) => x.id == g));
      });
    } on MenuApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  Future<void> _newComboGroup() => _openComboGroup(null);

  Future<void> _editComboGroup(String id) async {
    try {
      final g = (await widget.api.comboGroups()).groups.where((x) => x.id == id).firstOrNull;
      if (g != null && mounted) await _openComboGroup(g);
    } on MenuApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final s = await widget.api.settings(widget.dishId);
      if (mounted) setState(() => _fill(s));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _save() async {
    final s = _s;
    final price = numOf(_price.text);
    if (s == null) return;
    if (price == null || price <= 0) return showToast(context, 'Enter a selling price above zero.');
    setState(() => _busy = true);
    try {
      final next = await widget.api.saveSettings(s.id, s.version, {
        'name': _name.text.trim(), 'price': price, 'category_id': _categoryId, 'food_type': _food, 'course': _course, 'station': _station,
        'prep_minutes': int.tryParse(_prep.text.trim()) ?? s.prepMinutes, 'is_recommended': _recommended, 'sku': _sku.text.trim().isEmpty ? null : _sku.text.trim(),
        'addon_group_ids': _groups.toList(),
        'combo_group_ids': _comboGroups.toList(),
      });
      if (!mounted) return;
      setState(() {
        _fill(next);
        _changed = true;
      });
      showToast(context, 'Saved.');
    } on MenuApiException catch (e) {
      if (mounted) showToast(context, e.stale ? 'This dish was changed on another device. Reloaded the latest.' : e.message);
      if (e.stale) _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        leading: IconButton(icon: const Icon(LucideIcons.chevronLeft, color: kInk), onPressed: () => Navigator.of(context).pop(_changed)),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('DISH SETTINGS', style: inter(10, 700, color: kMuted).copyWith(letterSpacing: 0.8)),
          Text(s?.name ?? '', style: inter(17, 700)),
        ]),
      ),
      body: s == null
          ? (_error != null ? MenuError(error: _error!, onRetry: _load) : const Center(child: CircularProgressIndicator(color: kLink)))
          : ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 110), children: [
              _RecipeSummary(recipe: s.recipe, onOpen: () async {
                await Navigator.of(context).push(RecipeEditorScreen.route(widget.api, s.id));
                _load();
              }),
              MbCard(
                title: 'Basics',
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  MbField(label: 'Dish name', controller: _name, fieldKey: const ValueKey('ds-name'), maxLength: 120),
                  MbField(label: 'Selling price', controller: _price, number: true, prefix: '₹ ', fieldKey: const ValueKey('ds-price')),
                  Text('Category', style: inter(13, 600, color: kMuted)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final c in s.categories)
                      ChoiceChip(
                        key: ValueKey('ds-cat-${c.name}'),
                        label: Text(c.name, style: inter(12, 600, color: _categoryId == c.id ? Colors.white : kInk)),
                        selected: _categoryId == c.id,
                        showCheckmark: false,
                        selectedColor: kInk,
                        backgroundColor: kField,
                        side: const BorderSide(color: kFieldBorder),
                        onSelected: (_) => setState(() => _categoryId = c.id),
                      ),
                  ]),
                  const SizedBox(height: 12),
                  MbSegments(label: 'Type', keyPrefix: 'ds-food', options: _foodOptions, value: _food, onChanged: (v) => setState(() => _food = v)),
                  MbSegments(label: 'Course', keyPrefix: 'ds-course', options: const [('eat', 'Food'), ('drink', 'Drink')], value: _course, onChanged: (v) => setState(() => _course = v)),
                ]),
              ),
              MbCard(
                title: 'Kitchen',
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  MbSegments(
                    label: 'Station (where the KOT goes)',
                    keyPrefix: 'ds-station',
                    options: [for (final st in s.stations) (st, st[0].toUpperCase() + st.substring(1))],
                    value: _station,
                    onChanged: (v) => setState(() => _station = v),
                  ),
                  MbField(label: 'Preparation time', controller: _prep, number: true, decimals: false, suffix: 'min', fieldKey: const ValueKey('ds-prep')),
                ]),
              ),
              MbCard(
                title: 'Selling',
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SwitchListTile(
                    key: const ValueKey('ds-recommended'),
                    contentPadding: EdgeInsets.zero,
                    title: Text('Recommended dish', style: inter(14, 600)),
                    subtitle: Text('Shown first to customers and on the POS', style: inter(12, 400, color: kMuted)),
                    value: _recommended,
                    activeTrackColor: kMbLime,
                    onChanged: (v) => setState(() => _recommended = v),
                  ),
                  MbField(label: 'Item code (optional)', controller: _sku, hint: 'e.g. BEV-AMR', fieldKey: const ValueKey('ds-sku'), maxLength: 40),
                ]),
              ),
              MbCard(
                title: 'Add-on groups',
                child: s.addonGroups.isEmpty
                    ? Text('No add-on groups yet. Create them in Menu → Add-ons (for example "Extra dips").', style: inter(13, 400, color: kMuted, height: 1.4))
                    : Column(children: [
                        for (final g in s.addonGroups)
                          CheckboxListTile(
                            key: ValueKey('ds-group-${g.name}'),
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            activeColor: kInk,
                            value: _groups.contains(g.id),
                            title: Text(g.name, style: inter(14, 600)),
                            subtitle: Text('${g.addons} add-on${g.addons == 1 ? '' : 's'}', style: inter(12, 400, color: kMuted)),
                            onChanged: (v) => setState(() => v == true ? _groups.add(g.id) : _groups.remove(g.id)),
                          ),
                      ]),
              ),
              // 0624: combos offered with this dish ("Make it a meal"); billing asks for them in the same pop-up as add-ons
              MbCard(
                title: 'Combo groups',
                trailing: TextButton.icon(
                  key: const ValueKey('ds-combo-group-new'),
                  onPressed: _newComboGroup,
                  icon: const Icon(LucideIcons.plus, size: 16, color: kLink),
                  label: Text('New', style: inter(14, 600, color: kLink)),
                ),
                child: s.comboGroups.isEmpty
                    ? Text('No combo groups yet. Tap New to group combos (for example "Make it a meal" with fries & a drink).',
                        style: inter(13, 400, color: kMuted, height: 1.4))
                    : Column(children: [
                        for (final g in s.comboGroups)
                          CheckboxListTile(
                            key: ValueKey('ds-combo-group-${g.name}'),
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            activeColor: kInk,
                            value: _comboGroups.contains(g.id),
                            title: Text(g.name, style: inter(14, 600)),
                            subtitle: Text('${g.combos} combo${g.combos == 1 ? '' : 's'}', style: inter(12, 400, color: kMuted)),
                            secondary: IconButton(
                              key: ValueKey('ds-combo-group-edit-${g.name}'),
                              tooltip: 'Edit group',
                              icon: const Icon(LucideIcons.pencil, size: 16, color: kMuted),
                              onPressed: () => _editComboGroup(g.id),
                            ),
                            onChanged: (v) => setState(() => v == true ? _comboGroups.add(g.id) : _comboGroups.remove(g.id)),
                          ),
                      ]),
              ),
            ]),
      bottomNavigationBar: s == null
          ? null
          : SafeArea(minimum: const EdgeInsets.fromLTRB(14, 8, 14, 12), child: MbPrimaryButton('Save settings', busy: _busy, onPressed: _save, key: const ValueKey('ds-save'))),
    );
  }
}

/// New / edit a combo group (0624): its name, how many combos the customer may pick, and which combos. Pops the group's id when saved
/// ('' when deleted).
class ComboGroupEditor extends StatefulWidget {
  const ComboGroupEditor({super.key, required this.api, this.group});
  final MenuBuildApi api;
  final ComboGroup? group;
  @override
  State<ComboGroupEditor> createState() => _ComboGroupEditorState();
}

class _ComboGroupEditorState extends State<ComboGroupEditor> {
  late final _name = TextEditingController(text: widget.group?.name ?? '');
  late int _min = widget.group?.minSelect ?? 0, _max = widget.group?.maxSelect ?? 1;
  late final Set<String> _picked = {...?widget.group?.comboIds};
  ComboGroups? _data;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.comboGroups();
      if (mounted) setState(() => _data = d);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return showToast(context, 'Enter the group name.');
    if (_picked.isEmpty) return showToast(context, 'Choose at least one combo.');
    setState(() => _busy = true);
    try {
      final r = await widget.api.saveComboGroup(id: widget.group?.id, name: _name.text.trim(), minSelect: _min, maxSelect: _max, comboIds: _picked.toList());
      if (mounted) Navigator.of(context).pop((r.raw['id'] as String?) ?? widget.group?.id ?? '');
    } on MenuApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showOlDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete "${widget.group!.name}"?'),
        content: const Text('It comes off every dish that offers it. The combos themselves stay.'),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete'))],
      ),
    );
    if (ok != true) return;
    try {
      await widget.api.deleteComboGroup(widget.group!.id);
      if (mounted) Navigator.of(context).pop('');
    } on MenuApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  Widget _stepper(String label, int value, int min, int max, ValueChanged<int> on) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: inter(13, 600, color: kMuted)),
          Row(children: [
            IconButton(onPressed: value > min ? () => on(value - 1) : null, icon: const Icon(LucideIcons.minus, size: 18)),
            Text('$value', style: inter(16, 700)),
            IconButton(onPressed: value < max ? () => on(value + 1) : null, icon: const Icon(LucideIcons.plus, size: 18)),
          ]),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final combos = _data?.combos ?? const [];
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        title: Text(widget.group == null ? 'New combo group' : 'Edit combo group', style: inter(17, 700)),
        actions: [if (widget.group != null) IconButton(key: const ValueKey('combo-group-delete'), tooltip: 'Delete group', onPressed: _delete, icon: const Icon(LucideIcons.trash2, color: kError))],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 110), children: [
        MbCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            MbField(label: 'Group name', controller: _name, hint: 'e.g. Make it a meal', fieldKey: const ValueKey('combo-group-name'), maxLength: 60),
            Row(children: [
              _stepper('Customer must pick at least', _min, 0, _max, (v) => setState(() => _min = v)),
              _stepper('and at most', _max, _min < 1 ? 1 : _min, 10, (v) => setState(() => _max = v)),
            ]),
          ]),
        ),
        MbCard(
          title: 'Combos in this group',
          child: _data == null
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(child: _error == null ? const CircularProgressIndicator() : Text(errorSentence(_error!), style: inter(13, 500, color: kMuted))),
                )
              : combos.isEmpty
                  ? Text('No combos yet. Make them in Menu → Combos first.', style: inter(13, 400, color: kMuted, height: 1.4))
                  : Column(children: [
                      for (final c in combos)
                        CheckboxListTile(
                          key: ValueKey('combo-group-combo-${c.name}'),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          activeColor: kInk,
                          value: _picked.contains(c.id),
                          title: Text('${c.name} · ${rupeesMinor(c.priceMinor)}', style: inter(14, 600)),
                          subtitle: c.items.isEmpty ? null : Text(c.items, style: inter(12, 400, color: kMuted)),
                          onChanged: (v) => setState(() => v == true ? _picked.add(c.id) : _picked.remove(c.id)),
                        ),
                    ]),
        ),
      ]),
      bottomNavigationBar: SafeArea(minimum: const EdgeInsets.fromLTRB(14, 8, 14, 12), child: MbPrimaryButton('Save group', busy: _busy, onPressed: _save, key: const ValueKey('combo-group-save'))),
    );
  }
}

class _RecipeSummary extends StatelessWidget {
  const _RecipeSummary({required this.recipe, required this.onOpen});
  final Recipe recipe;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final tone = foodCostTone(recipe.foodCostPct);
    return MbCard(
      title: 'Recipe & margin',
      trailing: TextButton(key: const ValueKey('ds-open-recipe'), onPressed: onOpen, child: Text(recipe.hasRecipe ? 'Edit recipe ›' : 'Add recipe ›', style: inter(14, 600, color: kLink))),
      child: recipe.hasRecipe
          ? Row(children: [
              Expanded(child: Text('Cost ${rupeesMinor(recipe.costMinor)} · margin ${rupeesMinor(recipe.marginMinor)} (${pct(recipe.marginPct)})', style: inter(14, 600))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: tone.$1, borderRadius: BorderRadius.circular(999)),
                child: Text('Food cost ${pct(recipe.foodCostPct)}', style: inter(11, 700, color: tone.$2)),
              ),
            ])
          : Text('No recipe yet. Add its ingredients to see what it costs to make and your margin.', style: inter(13, 400, color: kMuted, height: 1.4)),
    );
  }
}

// ---------------------------------------------------------------- add-ons

/// The Add-ons tab of Menu: add-on groups (for example "Extra dips": pick up to 2) with their add-ons and prices, and how many dishes use each.
class AddonsView extends StatefulWidget {
  const AddonsView({super.key, required this.api});
  final MenuBuildApi api;
  @override
  State<AddonsView> createState() => _AddonsViewState();
}

class _AddonsViewState extends State<AddonsView> {
  late Future<List<AddonGroup>> _f = widget.api.addonGroups();

  Future<void> _edit([AddonGroup? g]) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => AddonGroupEditor(api: widget.api, group: g)));
    if (saved == true && mounted) setState(() { _f = widget.api.addonGroups(); });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<AddonGroup>>(
        future: _f,
        builder: (context, snap) {
          if (!snap.hasData) return snap.hasError ? MenuError(error: snap.error!, onRetry: () => setState(() { _f = widget.api.addonGroups(); })) : const Center(child: CircularProgressIndicator(color: kLink));
          final groups = snap.data!;
          return ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 110), children: [
            FilledButton.icon(
              key: const ValueKey('addon-new'),
              style: FilledButton.styleFrom(backgroundColor: kInk, minimumSize: const Size.fromHeight(46), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              onPressed: () => _edit(),
              icon: const Icon(LucideIcons.plus, size: 18, color: kMbLime),
              label: Text('New add-on group', style: inter(14, 700, color: kMbLime)),
            ),
            const SizedBox(height: 12),
            if (groups.isEmpty)
              const MbEmpty(icon: LucideIcons.layers, title: 'No add-ons yet', body: 'Group extras customers can pick, like "Extra dips" or "Milk options", then attach them to dishes.')
            else
              for (final g in groups)
                MbCard(
                  title: g.name,
                  trailing: TextButton(key: ValueKey('addon-edit-${g.name}'), onPressed: () => _edit(g), child: Text('Edit', style: inter(14, 600, color: kLink))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${g.rule} · on ${g.dishCount} dish${g.dishCount == 1 ? '' : 'es'}', style: inter(12, 500, color: kMuted)),
                    const SizedBox(height: 8),
                    for (final a in g.addons)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(children: [FoodTypeMark(a.foodType), const SizedBox(width: 8), Expanded(child: Text(a.name, style: inter(14, 500))), Text('+${rupeesMinor(a.priceMinor)}', style: inter(14, 600))]),
                      ),
                  ]),
                ),
          ]);
        },
      );
}

/// Create or edit an add-on group: its name, how many a customer may pick, and its add-ons with prices.
class AddonGroupEditor extends StatefulWidget {
  const AddonGroupEditor({super.key, required this.api, this.group});
  final MenuBuildApi api;
  final AddonGroup? group;
  @override
  State<AddonGroupEditor> createState() => _AddonGroupEditorState();
}

/// One add-on row (0624): the ingredient it is made of, how much of it one add-on uses, and its selling price. An add-on made before
/// add-ons came from the ingredient master keeps its name until an ingredient is chosen for it.
class _AddonRow {
  _AddonRow({this.id, this.ingredientId, this.ingredient = '', this.unit = '', String qty = '', String price = '', this.food = 'veg', this.legacyName = ''})
      : qty = TextEditingController(text: qty),
        price = TextEditingController(text: price);
  final String? id;
  String? ingredientId;
  String ingredient, unit, food, legacyName;
  final TextEditingController qty, price;
}

class _AddonGroupEditorState extends State<AddonGroupEditor> {
  late final _name = TextEditingController(text: widget.group?.name ?? '');
  late int _min = widget.group?.minSelect ?? 0, _max = widget.group?.maxSelect ?? 1;
  static String _num(num? v) => v == null ? '' : (v == v.roundToDouble() ? v.toInt().toString() : v.toString());
  late final List<_AddonRow> _rows = [
    for (final a in widget.group?.addons ?? const <Addon>[])
      _AddonRow(
        id: a.id,
        ingredientId: a.ingredientId.isEmpty ? null : a.ingredientId,
        ingredient: a.ingredient,
        unit: a.unit,
        qty: _num(a.consumeQty),
        price: (a.priceMinor / 100).toStringAsFixed(a.priceMinor % 100 == 0 ? 0 : 2),
        food: a.foodType,
        legacyName: a.ingredientId.isEmpty ? a.name : '',
      ),
    if (widget.group == null) _AddonRow(),
  ];
  List<({String id, String name, String unit})>? _ingredients;
  bool _busy = false;

  Future<void> _pickIngredient(_AddonRow r) async {
    try {
      _ingredients ??= await widget.api.addonIngredients();
    } on MenuApiException catch (e) {
      if (mounted) showToast(context, e.message);
      return;
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<({String id, String name, String unit})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (c) => _IngredientPicker(items: _ingredients!),
    );
    if (picked == null || !mounted) return;
    setState(() {
      r.ingredientId = picked.id;
      r.ingredient = picked.name;
      r.unit = picked.unit;
      r.legacyName = '';
    });
  }

  Future<void> _save() async {
    final rows = _rows.where((r) => r.ingredientId != null || r.legacyName.isNotEmpty).toList();
    if (rows.isEmpty) return showToast(context, 'Choose an ingredient for the add-on.');
    for (final r in rows) {
      if (r.ingredientId != null && (numOf(r.qty.text) ?? 0) <= 0) return showToast(context, 'Enter how much ${r.ingredient} one add-on uses.');
    }
    setState(() => _busy = true);
    try {
      await widget.api.saveAddonGroup(
        id: widget.group?.id,
        name: _name.text.trim(),
        minSelect: _min,
        maxSelect: _max,
        addons: [
          for (final r in rows)
            {
              'id': ?r.id,
              if (r.ingredientId != null) ...{'inventory_item_id': r.ingredientId, 'consume_qty': numOf(r.qty.text), 'name': r.ingredient} else 'name': r.legacyName,
              'price': numOf(r.price.text) ?? 0,
              'food_type': r.food,
            },
        ],
      );
      if (mounted) Navigator.of(context).pop(true);
    } on MenuApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showOlDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete "${widget.group!.name}"?'),
        content: const Text('It comes off every dish that offers it.'),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete'))],
      ),
    );
    if (ok != true) return;
    try {
      await widget.api.deleteAddonGroup(widget.group!.id);
      if (mounted) Navigator.of(context).pop(true);
    } on MenuApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  Widget _stepper(String label, int value, int min, int max, ValueChanged<int> on) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: inter(13, 600, color: kMuted)),
          Row(children: [
            IconButton(onPressed: value > min ? () => on(value - 1) : null, icon: const Icon(LucideIcons.minus, size: 18)),
            Text('$value', style: inter(16, 700)),
            IconButton(onPressed: value < max ? () => on(value + 1) : null, icon: const Icon(LucideIcons.plus, size: 18)),
          ]),
        ]),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          elevation: 0,
          title: Text(widget.group == null ? 'New add-on group' : 'Edit add-on group', style: inter(17, 700)),
          actions: [if (widget.group != null) IconButton(key: const ValueKey('addon-delete'), tooltip: 'Delete group', onPressed: _delete, icon: const Icon(LucideIcons.trash2, color: kError))],
        ),
        body: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 110), children: [
          MbCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              MbField(label: 'Group name', controller: _name, hint: 'e.g. Extra dips', fieldKey: const ValueKey('addon-name'), maxLength: 60),
              Row(children: [
                _stepper('Customer must pick at least', _min, 0, _max, (v) => setState(() => _min = v)),
                _stepper('and at most', _max, _min < 1 ? 1 : _min, 20, (v) => setState(() => _max = v)),
              ]),
            ]),
          ),
          MbCard(
            title: 'Add-ons',
            trailing: TextButton.icon(
              key: const ValueKey('addon-row-add'),
              onPressed: () => setState(() => _rows.add(_AddonRow())),
              icon: const Icon(LucideIcons.plus, size: 16, color: kLink),
              label: Text('Add', style: inter(14, 600, color: kLink)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Each add-on is an ingredient. Billing it uses the quantity you enter here from stock.', style: inter(12.5, 500, color: kMuted)),
              const SizedBox(height: 10),
              for (var i = 0; i < _rows.length; i++) _addonRow(i),
            ]),
          ),
        ]),
        bottomNavigationBar: SafeArea(minimum: const EdgeInsets.fromLTRB(14, 8, 14, 12), child: MbPrimaryButton('Save group', busy: _busy, onPressed: _save, key: const ValueKey('addon-save'))),
      );

  /// One add-on: the ingredient (tap to choose), then "Uses" in its unit and the selling price.
  Widget _addonRow(int i) {
    final r = _rows[i];
    final picked = r.ingredientId != null;
    return Container(
      key: ValueKey('addon-row-$i'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 10),
      decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(12), border: Border.all(color: kFieldBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: InkWell(
              key: ValueKey('addon-row-ingredient-$i'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => _pickIngredient(r),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Icon(picked ? LucideIcons.package : LucideIcons.packagePlus, size: 18, color: picked ? kInk : kLink),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      picked ? r.ingredient : (r.legacyName.isNotEmpty ? '${r.legacyName} · choose its ingredient' : 'Choose ingredient'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: inter(14.5, picked ? 700 : 600, color: picked ? kInk : kLink),
                    ),
                  ),
                  const Icon(LucideIcons.chevronDown, size: 16, color: kMuted),
                ]),
              ),
            ),
          ),
          IconButton(tooltip: 'Remove', onPressed: _rows.length > 1 ? () => setState(() => _rows.removeAt(i)) : null, icon: const Icon(LucideIcons.x, size: 18, color: kMuted)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: _cell(r.qty, 'Uses', ValueKey('addon-row-qty-$i'), number: true, suffix: r.unit.isEmpty ? null : r.unit, enabled: picked)),
          const SizedBox(width: 8),
          Expanded(child: _cell(r.price, 'Selling price', ValueKey('addon-row-price-$i'), number: true, prefix: '₹ ')),
          const SizedBox(width: 8),
        ]),
      ]),
    );
  }

  Widget _cell(TextEditingController c, String hint, Key key, {bool number = false, String? prefix, String? suffix, bool enabled = true}) => TextField(
        key: key,
        controller: c,
        enabled: enabled,
        keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
        style: inter(14, 500),
        decoration: InputDecoration(
          labelText: hint,
          prefixText: prefix,
          suffixText: suffix,
          isDense: true,
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kFieldBorder)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kFieldBorder)),
        ),
      );
}

/// The ingredient master, searchable: tap one to make it the add-on.
class _IngredientPicker extends StatefulWidget {
  const _IngredientPicker({required this.items});
  final List<({String id, String name, String unit})> items;
  @override
  State<_IngredientPicker> createState() => _IngredientPickerState();
}

class _IngredientPickerState extends State<_IngredientPicker> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final shown = widget.items.where((i) => _q.isEmpty || i.name.toLowerCase().contains(_q.toLowerCase())).toList();
    return SizedBox(
      height: MediaQuery.of(context).size.height * .75,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 8 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Choose ingredient', style: inter(19, 800)),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('addon-ingredient-search'),
            autofocus: true,
            onChanged: (v) => setState(() => _q = v.trim()),
            decoration: InputDecoration(
              hintText: 'Search the ingredient master',
              prefixIcon: const Icon(LucideIcons.search, size: 18),
              isDense: true,
              filled: true,
              fillColor: kField,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kFieldBorder)),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: shown.isEmpty
                ? Center(child: Text(widget.items.isEmpty ? 'No ingredients yet. Add them in Menu → Ingredients.' : 'No ingredient matches.', style: inter(14, 500, color: kMuted)))
                : ListView(children: [
                    for (final i in shown)
                      ListTile(
                        key: ValueKey('addon-ingredient-${i.name}'),
                        title: Text(i.name, style: inter(15, 600)),
                        trailing: Text(i.unit, style: inter(13, 500, color: kMuted)),
                        onTap: () => Navigator.pop(context, i),
                      ),
                  ]),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- combos

/// The Combos tab of Menu: dishes sold together at one price, with what the customer saves against buying them separately.
class CombosView extends StatefulWidget {
  const CombosView({super.key, required this.api});
  final MenuBuildApi api;
  @override
  State<CombosView> createState() => _CombosViewState();
}

class _CombosViewState extends State<CombosView> {
  late Future<ComboData> _f = widget.api.combos();

  Future<void> _edit(ComboData d, [Combo? c]) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ComboEditor(api: widget.api, dishes: d.dishes, combo: c)));
    if (saved == true && mounted) setState(() { _f = widget.api.combos(); });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ComboData>(
        future: _f,
        builder: (context, snap) {
          if (!snap.hasData) return snap.hasError ? MenuError(error: snap.error!, onRetry: () => setState(() { _f = widget.api.combos(); })) : const Center(child: CircularProgressIndicator(color: kLink));
          final d = snap.data!;
          return ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 110), children: [
            FilledButton.icon(
              key: const ValueKey('combo-new'),
              style: FilledButton.styleFrom(backgroundColor: kInk, minimumSize: const Size.fromHeight(46), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              onPressed: d.dishes.length < 2 ? null : () => _edit(d),
              icon: const Icon(LucideIcons.plus, size: 18, color: kMbLime),
              label: Text('New combo', style: inter(14, 700, color: kMbLime)),
            ),
            const SizedBox(height: 12),
            if (d.combos.isEmpty)
              const MbEmpty(icon: LucideIcons.package, title: 'No combos yet', body: 'Sell two or more dishes together at one price, like "Coffee & Sub".')
            else
              for (final c in d.combos)
                MbCard(
                  title: c.name,
                  trailing: TextButton(key: ValueKey('combo-edit-${c.name}'), onPressed: () => _edit(d, c), child: Text('Edit', style: inter(14, 600, color: kLink))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c.items.map((i) => i.qty > 1 ? '${i.qty} × ${i.name}' : i.name).join(' + '), style: inter(13, 500, color: kMuted)),
                    const SizedBox(height: 8),
                    Row(children: [
                      Text(rupeesMinor(c.priceMinor), style: inter(17, 700)),
                      const SizedBox(width: 8),
                      Text(rupeesMinor(c.separateMinor), style: inter(13, 500, color: kMuted).copyWith(decoration: TextDecoration.lineThrough)),
                      const Spacer(),
                      if (c.savingMinor > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(color: kMbGreenBg, borderRadius: BorderRadius.circular(999)),
                          child: Text('Saves ${rupeesMinor(c.savingMinor)}', style: inter(11, 700, color: kMbGreen)),
                        ),
                    ]),
                  ]),
                ),
          ]);
        },
      );
}

/// Create or edit a combo: name, dishes (and how many of each), price, description.
class ComboEditor extends StatefulWidget {
  const ComboEditor({super.key, required this.api, required this.dishes, this.combo});
  final MenuBuildApi api;
  final List<({String id, String name, int priceMinor, String category})> dishes;
  final Combo? combo;
  @override
  State<ComboEditor> createState() => _ComboEditorState();
}

class _ComboEditorState extends State<ComboEditor> {
  late final _name = TextEditingController(text: widget.combo?.name ?? '');
  late final _desc = TextEditingController(text: widget.combo?.description ?? '');
  late final _price = TextEditingController(text: widget.combo == null ? '' : (widget.combo!.priceMinor / 100).toStringAsFixed(widget.combo!.priceMinor % 100 == 0 ? 0 : 2));
  late final Map<String, int> _qty = {for (final i in widget.combo?.items ?? const []) i.dishId: i.qty};
  bool _busy = false;

  int get _separate => widget.dishes.fold(0, (s, d) => s + d.priceMinor * (_qty[d.id] ?? 0));

  Future<void> _save() async {
    final price = numOf(_price.text);
    if (price == null || price <= 0) return showToast(context, 'Enter a combo price above zero.');
    setState(() => _busy = true);
    try {
      await widget.api.saveCombo(id: widget.combo?.id, name: _name.text.trim(), description: _desc.text, price: price, items: {for (final e in _qty.entries) if (e.value > 0) e.key: e.value});
      if (mounted) Navigator.of(context).pop(true);
    } on MenuApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    try {
      await widget.api.deleteCombo(widget.combo!.id);
      if (mounted) Navigator.of(context).pop(true);
    } on MenuApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final price = numOf(_price.text);
    final saving = price == null ? null : _separate - (price * 100).round();
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        title: Text(widget.combo == null ? 'New combo' : 'Edit combo', style: inter(17, 700)),
        actions: [if (widget.combo != null) IconButton(key: const ValueKey('combo-delete'), tooltip: 'Delete combo', onPressed: _delete, icon: const Icon(LucideIcons.trash2, color: kError))],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 110), children: [
        MbCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            MbField(label: 'Combo name', controller: _name, hint: 'e.g. Coffee & Sub', fieldKey: const ValueKey('combo-name'), maxLength: 80),
            MbField(label: 'Combo price', controller: _price, number: true, prefix: '₹ ', fieldKey: const ValueKey('combo-price'), onChanged: (_) => setState(() {})),
            Text(
              'Separately: ${rupeesMinor(_separate)}${saving == null || _separate == 0 ? '' : saving > 0 ? ' · customer saves ${rupeesMinor(saving)}' : ' · combo costs more than buying separately'}',
              key: const ValueKey('combo-saving'),
              style: inter(13, 600, color: saving != null && saving < 0 ? kMbAmber : kMbGreen),
            ),
            const SizedBox(height: 12),
            MbField(label: 'Description (optional)', controller: _desc, hint: 'What makes it a good deal', maxLength: 300),
          ]),
        ),
        MbCard(
          title: 'Dishes in the combo',
          child: Column(children: [
            for (final d in widget.dishes)
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(d.name, style: inter(14, 600)),
                    Text('${d.category.isEmpty ? '' : '${d.category} · '}${rupeesMinor(d.priceMinor)}', style: inter(12, 400, color: kMuted)),
                  ]),
                ),
                IconButton(onPressed: (_qty[d.id] ?? 0) > 0 ? () => setState(() => _qty[d.id] = (_qty[d.id] ?? 0) - 1) : null, icon: const Icon(LucideIcons.minus, size: 18)),
                SizedBox(width: 22, child: Text('${_qty[d.id] ?? 0}', key: ValueKey('combo-qty-${d.name}'), textAlign: TextAlign.center, style: inter(15, 700))),
                IconButton(key: ValueKey('combo-plus-${d.name}'), onPressed: () => setState(() => _qty[d.id] = (_qty[d.id] ?? 0) + 1), icon: const Icon(LucideIcons.plus, size: 18)),
              ]),
          ]),
        ),
      ]),
      bottomNavigationBar: SafeArea(minimum: const EdgeInsets.fromLTRB(14, 8, 14, 12), child: MbPrimaryButton('Save combo', busy: _busy, onPressed: _save, key: const ValueKey('combo-save'))),
    );
  }
}
