import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';
import 'menu_api.dart' show MenuApiException;
import 'menu_build_api.dart';
import 'menu_build_widgets.dart' show kMbLime;

/// Menu → Categories (founder, 28 Oct 2026): the menu's categories and their subcategories, one level deep (Beverages › Cold coffee).
/// Add a category (or, in its dialog, a subcategory; also ⋮ → Add subcategory), rename, move up or down, make a subcategory a main one, and delete an empty one. The database checks
/// every rule (`menu_category_*`, 0616) and says why when it refuses; a person who may not change the menu sees the list only.
class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key, required this.api});
  final MenuBuildApi api;
  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  MenuCategories? _d;
  String? _error;
  bool _busy = false;
  bool _changed = false; // the Menu reloads when something changed

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.categories();
      if (mounted) {
        setState(() {
          _d = d;
          _error = null;
        });
      }
    } on MenuApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load the categories. Pull to try again.');
    }
  }

  Future<void> _run(Future<MenuCategories> Function() step, String done) async {
    setState(() => _busy = true);
    try {
      final d = await step();
      if (!mounted) return;
      setState(() {
        _d = d;
        _changed = true;
      });
      showToast(context, done);
    } on MenuApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not save. Try again.');
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Name it, and (for a new one) where it goes: a main category, or under one.
  Future<(String, String?)?> _ask({required String title, String name = '', String? parentId, bool chooseParent = false}) {
    final c = TextEditingController(text: name);
    var parent = parentId;
    final mains = _d?.main ?? const <MenuCat>[];
    return showDialog<(String, String?)>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: Text(title, style: inter(18, 700)),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              key: const ValueKey('cat-name'),
              controller: c,
              autofocus: true,
              maxLength: 60,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(hintText: 'For example Cold coffee', counterText: ''),
            ),
            if (chooseParent && mains.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Put it under', style: inter(13, 600, color: kMuted)),
              DropdownButton<String?>(
                key: const ValueKey('cat-parent'),
                value: parent,
                isExpanded: true,
                items: [
                  DropdownMenuItem<String?>(value: null, child: Text('Nothing: a main category', style: inter(14.5, 500))),
                  for (final m in mains) DropdownMenuItem<String?>(value: m.id, child: Text(m.name, key: ValueKey('cat-parent-${m.name}'), style: inter(14.5, 500))),
                ],
                onChanged: (v) => set(() => parent = v),
              ),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
            TextButton(key: const ValueKey('cat-save'), onPressed: () => Navigator.pop(d, (c.text.trim(), parent)), child: const Text('Save')),
          ],
        ),
      ),
    );
  }

  Future<void> _add({String? under}) async {
    final r = await _ask(title: under == null ? 'New category' : 'New subcategory', parentId: under, chooseParent: true);
    if (r == null || r.$1.isEmpty) return;
    await _run(() => widget.api.saveCategory(name: r.$1, parentId: r.$2), r.$2 == null ? '${r.$1} added.' : '${r.$1} added as a subcategory.');
  }

  Future<void> _rename(MenuCat c) async {
    final r = await _ask(title: 'Rename category', name: c.name);
    if (r == null || r.$1.isEmpty || r.$1 == c.name) return;
    await _run(() => widget.api.saveCategory(id: c.id, name: r.$1), 'Renamed to ${r.$1}.');
  }

  /// Swaps places with the one before or after it among its siblings.
  Future<void> _move(MenuCat c, List<MenuCat> siblings, int by) async {
    final i = siblings.indexWhere((x) => x.id == c.id), j = i + by;
    if (i < 0 || j < 0 || j >= siblings.length) return;
    final other = siblings[j];
    // the order numbers may repeat; give the pair their positions' numbers, apart
    final a = siblings[i].sortOrder, b = other.sortOrder == a ? a + by : other.sortOrder;
    await _run(() async {
      await widget.api.saveCategory(id: other.id, name: other.name, sortOrder: a);
      return widget.api.saveCategory(id: c.id, name: c.name, sortOrder: b);
    }, by < 0 ? '${c.name} moved up.' : '${c.name} moved down.');
  }

  Future<void> _delete(MenuCat c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete ${c.name}?', style: inter(18, 700)),
        content: Text('Only an empty category can be deleted.', style: inter(14.5, 400, color: kMuted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Keep')),
          TextButton(key: const ValueKey('cat-delete-yes'), onPressed: () => Navigator.pop(d, true), child: const Text('Delete', style: TextStyle(color: kError))),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => widget.api.deleteCategory(c.id), '${c.name} deleted.');
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final edit = d?.canEdit ?? false;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(
          backgroundColor: kBg,
          surfaceTintColor: kBg,
          leading: IconButton(key: const ValueKey('cat-back'), icon: const Icon(LucideIcons.arrowLeft, color: kInk), onPressed: () => Navigator.of(context).pop(_changed)),
          title: Text('Categories', style: inter(18, 800)),
        ),
        body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 100), children: [
            Text('Group your dishes. A category can hold subcategories, for example Beverages › Cold coffee.', style: inter(13, 400, color: kMuted)),
            const SizedBox(height: 12),
            if (d == null && _error == null) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
            if (_error != null && d == null) Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kError))),
            if (d != null && d.main.isEmpty) Padding(padding: const EdgeInsets.all(32), child: Center(child: Text('No categories yet.', style: inter(15, 500, color: kMuted)))),
            if (d != null)
              for (final (i, m) in d.main.indexed) _mainCard(d, m, i, edit),
            if (d != null && !edit) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Your role can see the categories but not change them.', style: inter(13, 500, color: kMuted))),
          ]),
        ),
        floatingActionButton: edit
            ? FloatingActionButton.extended(
                key: const ValueKey('cat-add'),
                backgroundColor: kMbLime,
                foregroundColor: kInk,
                onPressed: _busy ? null : () => _add(),
                icon: const Icon(LucideIcons.plus),
                label: Text('New category', style: inter(15, 800)),
              )
            : null,
      ),
    );
  }

  Widget _mainCard(MenuCategories d, MenuCat m, int i, bool edit) {
    final subs = d.subsOf(m.id);
    final mains = d.main;
    return Container(
      key: ValueKey('cat-main-${m.name}'),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFECEDE8))),
      child: Column(children: [
        _row(
          m,
          icon: LucideIcons.folder,
          line: '${m.dishes} dish${m.dishes == 1 ? '' : 'es'}${subs.isEmpty ? '' : ' · ${subs.length} subcategor${subs.length == 1 ? 'y' : 'ies'}'}',
          edit: edit,
          actions: [
            ('sub', 'Add subcategory', LucideIcons.folderPlus),
            ('rename', 'Rename', LucideIcons.pencil),
            if (i > 0) ('up', 'Move up', LucideIcons.arrowUp),
            if (i < mains.length - 1) ('down', 'Move down', LucideIcons.arrowDown),
            ('delete', 'Delete', LucideIcons.trash2),
          ],
          onAction: (a) => switch (a) {
            'sub' => _add(under: m.id),
            'rename' => _rename(m),
            'up' => _move(m, mains, -1),
            'down' => _move(m, mains, 1),
            _ => _delete(m),
          },
        ),
        for (final (j, s) in subs.indexed)
          Container(
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFF1F2EE)))),
            padding: const EdgeInsets.only(left: 22),
            child: _row(
              s,
              icon: LucideIcons.cornerDownRight,
              line: '${s.dishes} dish${s.dishes == 1 ? '' : 'es'}',
              edit: edit,
              actions: [
                ('rename', 'Rename', LucideIcons.pencil),
                if (j > 0) ('up', 'Move up', LucideIcons.arrowUp),
                if (j < subs.length - 1) ('down', 'Move down', LucideIcons.arrowDown),
                ('main', 'Make it a main category', LucideIcons.folderUp),
                ('delete', 'Delete', LucideIcons.trash2),
              ],
              onAction: (a) => switch (a) {
                'rename' => _rename(s),
                'up' => _move(s, subs, -1),
                'down' => _move(s, subs, 1),
                'main' => _run(() => widget.api.saveCategory(id: s.id, name: s.name, clearParent: true), '${s.name} is now a main category.'),
                _ => _delete(s),
              },
            ),
          ),
      ]),
    );
  }

  Widget _row(MenuCat c, {required IconData icon, required String line, required bool edit, required List<(String, String, IconData)> actions, required Future<void> Function(String) onAction}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: const Color(0xFFF1F7E8), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 17, color: const Color(0xFF4D7C0F)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name, style: inter(15, 700)),
              Text(line, style: inter(12, 500, color: kMuted)),
            ]),
          ),
          if (edit)
            PopupMenuButton<String>(
              key: ValueKey('cat-more-${c.name}'),
              enabled: !_busy,
              icon: const Icon(LucideIcons.ellipsisVertical, size: 18, color: kMuted),
              onSelected: onAction,
              itemBuilder: (_) => [
                for (final (k, label, i) in actions)
                  PopupMenuItem(
                    key: ValueKey('cat-$k-${c.name}'),
                    value: k,
                    child: Row(children: [Icon(i, size: 16, color: k == 'delete' ? kError : kInk), const SizedBox(width: 10), Flexible(child: Text(label, style: inter(14, 500, color: k == 'delete' ? kError : kInk)))]),
                  ),
              ],
            ),
        ]),
      );
}
