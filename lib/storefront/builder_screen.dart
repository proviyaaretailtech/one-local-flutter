import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../onboarding/document_picker.dart';
import '../setup/setup_api.dart' show ImagePicker;
import '../ui/theme.dart';
import 'growth_screens.dart';
import 'publish_screens.dart';
import 'section_editors.dart';
import 'settings_screens.dart';
import 'sf_widgets.dart';
import 'storefront_api.dart';

/// Holds the page being edited. Every change is saved to the server as the DRAFT straight away (the server checks it and bumps the draft
/// version); the live page changes only when it is published. A stale draft (changed on another device) reloads and says so.
class BuilderController extends ChangeNotifier {
  BuilderController(this.api, {this.picker = const ImagePicker()});
  final StorefrontApi api;
  final DocumentPicker picker;
  List<Facts> library = const [];
  Facts? state;
  Facts? options;
  String? error;
  bool busy = false;
  final Map<String, String?> _urls = {};

  List<Section> get sections => (state?.m('definition').raw['sections'] as List? ?? const []).whereType<Map>().map((e) => Section(e.cast<String, dynamic>())).toList();
  Map<String, dynamic> get theme => Map<String, dynamic>.from((state?.m('definition').raw['theme'] as Map?) ?? const {});
  int get draftVersion => state?.n('draft_version').toInt() ?? 0;
  int get publishedVersion => state?.n('published_version').toInt() ?? 0;
  bool get unpublished => state?.b('has_unpublished_changes') ?? false;
  bool get canPublish => state?.b('can_publish') ?? false;
  List<Facts> get catalogueCategories => options?.l('catalogue_categories') ?? const [];

  /// Categories of this page's Category Grid sections (a banner may link to one of them).
  List<({String id, String name})> get pageCategories => [
        for (final s in sections.where((s) => s.type == 'category_grid')) for (final c in s.list('categories')) (id: '${c['id']}', name: '${c['name']}'),
      ];

  String? imageUrl(String? id) => id == null ? null : _urls[id];

  Future<void> load() async {
    try {
      state = await api.builder();
      options ??= await api.options();
      error = null;
    } catch (e) {
      error = sfMessage(e);
    }
    await refreshImages();
    notifyListeners();
  }

  Future<void> refreshImages() async {
    try {
      library = await api.images();
      for (final i in library) {
        _urls[i.s('id')] = i.so('image_url');
      }
    } catch (_) {/* pictures show a placeholder until the list loads */}
    notifyListeners();
  }

  void rememberImage(Facts uploaded) {
    library = [uploaded, ...library];
    _urls[uploaded.s('id')] = uploaded.so('image_url');
    notifyListeners();
  }

  /// Saves the whole page as the draft. Returns true when the server accepted it.
  Future<bool> save(List<Section> next, {Map<String, dynamic>? theme}) async {
    busy = true;
    notifyListeners();
    try {
      state = await api.saveDraft(draftVersion, {'theme': theme ?? this.theme, 'sections': next.map((s) => s.toJson()).toList()});
      error = null;
      return true;
    } on StorefrontException catch (e) {
      error = e.stale ? 'This page was changed on another device. It has been reloaded; please make your change again.' : e.message;
      if (e.stale) await load();
      return false;
    } catch (e) {
      error = sfMessage(e);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> replace(Section s) => save([for (final x in sections) x.id == s.id ? s : x]);
  Future<bool> add(Section s) => save([...sections, s]);
  Future<bool> remove(String id) => save(sections.where((s) => s.id != id).toList());
  Future<bool> setEnabled(String id, bool on) => save([for (final s in sections) if (s.id == id) (s.copy()..raw['enabled'] = on) else s]);
  Future<bool> move(int from, int to) {
    final l = sections;
    final s = l.removeAt(from);
    l.insert(to, s);
    return save(l);
  }

  Future<bool> setTheme(Map<String, dynamic> t) => save(sections, theme: t);

  Future<void> discard() async {
    try {
      state = await api.discardDraft(draftVersion: draftVersion);
      error = null;
    } catch (e) {
      error = sfMessage(e);
    }
    notifyListeners();
  }
}

String _newId() => 's${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

Section newSection(String type) => Section({
      'id': _newId(),
      'type': type,
      'title': const {'category_grid': 'Shop by Category', 'product_list': 'Featured products', 'deals': 'Deals'}[type],
      'enabled': true,
      'config': switch (type) {
        'banner' => {'slides': []},
        'category_grid' => {'layout': 'grid', 'columns': 3, 'categories': []},
        'product_list' => {'layout': 'grid', 'columns': 3, 'show_ratings': true, 'show_delivery_time': true, 'show_discount': true, 'show_add_button': true, 'product_ids': []},
        'deals' => {'offer_id': null, 'message': null, 'product_ids': []},
        'brand' => {'brand': null, 'product_ids': []},
        'divider' => {'height': 16},
        'ads' => {'ad_id': null},
        _ => {},
      },
    });

IconData sectionIcon(String type) => switch (type) {
      'header' => LucideIcons.panelTop,
      'banner' => LucideIcons.image,
      'category_grid' => LucideIcons.layoutGrid,
      'product_list' => LucideIcons.grid2x2,
      'deals' => LucideIcons.tag,
      'custom_card' => LucideIcons.square,
      'brand' => LucideIcons.flag,
      'divider' => LucideIcons.minus,
      _ => LucideIcons.image,
    };

/// Figma "Store Page Builder": Sections / Theme, the section list with reorder handles, Add Section, shortcuts and Preview Store.
class StorePageBuilder extends StatefulWidget {
  const StorePageBuilder({super.key, required this.api, this.picker = const ImagePicker()});
  final StorefrontApi api;
  final DocumentPicker picker;
  @override
  State<StorePageBuilder> createState() => _StorePageBuilderState();
}

class _StorePageBuilderState extends State<StorePageBuilder> {
  late final BuilderController c = BuilderController(widget.api, picker: widget.picker)..addListener(_changed);

  @override
  void initState() {
    super.initState();
    c.load();
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _afterSave(Future<bool> saved) async {
    final ok = await saved;
    if (!ok && mounted && c.error != null) showToast(context, c.error!);
  }

  Future<void> _edit(Section s) async {
    final Section? out = await Navigator.of(context).push<Section>(MaterialPageRoute(builder: (_) => editorFor(s, c)));
    if (out != null) await _afterSave(c.replace(out));
  }

  Future<void> _add() async {
    final type = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => AddSectionScreen(options: c.options)));
    if (type == null || !mounted) return;
    final s = newSection(type);
    if (!await c.add(s)) {
      if (mounted && c.error != null) showToast(context, c.error!);
      return;
    }
    if (mounted && type != 'divider') await _edit(s);
  }

  Future<void> _menu(Section s) async {
    final a = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: Icon(s.enabled ? LucideIcons.eyeOff : LucideIcons.eye), title: Text(s.enabled ? 'Hide from storefront' : 'Show on storefront'), onTap: () => Navigator.pop(context, 'toggle')),
          if (s.type != 'header') ListTile(leading: const Icon(LucideIcons.trash2, color: kError), title: const Text('Remove section'), onTap: () => Navigator.pop(context, 'remove')),
        ]),
      ),
    );
    if (a == 'toggle') await _afterSave(c.setEnabled(s.id, !s.enabled));
    if (a == 'remove') await _afterSave(c.remove(s.id));
  }

  Future<void> _settingsHub() async {
    final api = widget.api;
    final go = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final e in const [('profile', 'Business profile', LucideIcons.store), ('offers', 'Offers & promotions', LucideIcons.tag), ('hours', 'Business hours', LucideIcons.clock), ('delivery', 'Delivery settings', LucideIcons.truck), ('ads', 'Ads', LucideIcons.megaphone)])
            ListTile(leading: Icon(e.$3), title: Text(e.$2), trailing: const Icon(LucideIcons.chevronRight, size: 18), onTap: () => Navigator.pop(context, e.$1)),
        ]),
      ),
    );
    if (go == null || !mounted) return;
    final Widget screen = switch (go) {
      'profile' => ProfileScreen(api: api),
      'offers' => OffersScreen(api: api),
      'hours' => HoursScreen(api: api),
      'delivery' => DeliveryScreen(api: api),
      _ => AdsScreen(api: api, categories: c.catalogueCategories),
    };
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    c.load();
  }

  Future<void> _preview() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PreviewScreen(api: widget.api, c: c)));
    c.load();
  }

  @override
  Widget build(BuildContext context) {
    final list = c.sections;
    return SfPage(
      title: 'Store Page Builder',
      subtitle: 'Create and customise your store page',
      trailing: IconButton(tooltip: 'Store settings', onPressed: _settingsHub, icon: const Icon(LucideIcons.settings, size: 22)),
      bottom: Column(mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          onTap: _settingsHub,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(children: [
              const Icon(LucideIcons.settings, size: 18),
              const SizedBox(width: 10),
              Expanded(child: Text('Profile · Offers · Hours · Delivery', style: inter(14, 400, color: kMuted))),
              const Icon(LucideIcons.chevronRight, size: 18),
            ]),
          ),
        ),
        SfSave('Preview Store', onPressed: c.state == null ? null : _preview),
      ]),
      children: [
        Row(children: [
          Expanded(child: _Tab('Sections', true, () {})),
          const SizedBox(width: 12),
          Expanded(child: _Tab('Theme', false, () async {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ThemeScreen(api: widget.api, c: c)));
            c.load();
          })),
        ]),
        const SizedBox(height: 14),
        if (c.state == null && c.error != null)
          SfCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Could not load the page', style: inter(15, 700)), const SizedBox(height: 6), Text(c.error!, style: inter(13, 400, color: kMuted)), const SizedBox(height: 10), SfSoft('Try again', onPressed: c.load)]))
        else if (c.state == null)
          const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kInk)))
        else ...[
          if (c.unpublished)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                const Icon(LucideIcons.pencil, size: 14, color: kMuted),
                const SizedBox(width: 6),
                Expanded(child: Text('Changes saved as a draft. Publish to make them live.', style: inter(13, 400, color: kMuted))),
                TextButton(onPressed: () => _afterSave(Future(() async { await c.discard(); return c.error == null; })), child: Text('Discard draft', style: inter(13, 600, color: kError))),
              ]),
            ),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: list.length,
            onReorderItem: (a, b) => _afterSave(c.move(a, b)),
            itemBuilder: (_, i) {
              final s = list[i];
              return KeyedSubtree(
                key: ValueKey(s.id),
                child: SfCard(
                  onTap: () => s.type == 'header' ? Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileScreen(api: widget.api))) : _edit(s),
                  padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
                  child: Row(children: [
                    ReorderableDragStartListener(index: i, child: Padding(padding: const EdgeInsets.all(8), child: Icon(LucideIcons.gripVertical, size: 18, color: s.enabled ? kMuted : kLine))),
                    Container(width: 92, height: 56, decoration: BoxDecoration(color: s.enabled ? const Color(0xFFFFF4B8) : kSfField, borderRadius: BorderRadius.circular(12)), child: Icon(sectionIcon(s.type), color: kInk.withValues(alpha: s.enabled ? 1 : 0.35))),
                    const SizedBox(width: 14),
                    Expanded(child: Text(s.label, style: inter(16, 700, color: s.enabled ? kInk : kMuted))),
                    if (!s.enabled) Padding(padding: const EdgeInsets.only(right: 6), child: Text('Hidden', style: inter(12, 500, color: kMuted))),
                    IconButton(tooltip: 'More for ${s.label}', visualDensity: VisualDensity.compact, onPressed: () => _menu(s), icon: const Icon(LucideIcons.ellipsis, size: 18)),
                    const Icon(LucideIcons.chevronRight, size: 18),
                  ]),
                ),
              );
            },
          ),
          InkWell(
            onTap: _add,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              height: 76,
              alignment: Alignment.center,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFD1D5DB), width: 1.5)),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(LucideIcons.plus, size: 20), const SizedBox(width: 10), Text('Add Section', style: inter(16, 700))]),
            ),
          ),
        ],
        if (c.busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator(color: kInk, backgroundColor: kLine)),
      ],
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab(this.label, this.selected, this.onTap);
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: selected ? kSfLimeSoft : kSfField, borderRadius: BorderRadius.circular(14), border: Border.all(color: selected ? kSfLimeLine : Colors.transparent, width: 1.5)),
            child: Text(label, style: inter(15, selected ? 700 : 500, color: selected ? kInk : kMuted)),
          ),
        ),
      );
}

/// Figma "Add Section": the types the server offers, each a row.
class AddSectionScreen extends StatelessWidget {
  const AddSectionScreen({super.key, required this.options});
  final Facts? options;
  @override
  Widget build(BuildContext context) {
    final types = options?.l('section_types') ?? const [];
    return SfPage(
      title: 'Add Section',
      children: [
        if (types.isEmpty) Text('Section types could not be loaded. Go back and try again.', style: inter(14, 400, color: kMuted)),
        for (final t in types)
          SfCard(
            onTap: () => Navigator.of(context).pop(t.s('type')),
            child: Row(children: [
              Container(width: 52, height: 52, decoration: BoxDecoration(color: kSfField, borderRadius: BorderRadius.circular(14)), child: Icon(sectionIcon(t.s('type')), size: 22)),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(t.s('label'), style: inter(16, 700)), Text(t.s('hint'), style: inter(13, 400, color: kMuted))])),
              const Icon(LucideIcons.chevronRight, size: 18),
            ]),
          ),
      ],
    );
  }
}
