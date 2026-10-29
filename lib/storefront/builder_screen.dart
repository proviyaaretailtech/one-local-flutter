import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ads/ads_screens.dart';
import '../inventory/inventory_api.dart' show Facts;
import '../onboarding/document_picker.dart';
import '../money/money_style.dart';
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
      final msg = e.stale ? 'This page was changed on another device. It has been reloaded; please make your change again.' : e.message;
      if (e.stale) await load();
      error = msg;
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

/// The store's other settings, from the builder's and the profile's "Profile · Offers · Hours · Delivery" link (founder, 27 Oct 2026):
/// a short list that opens the chosen screen. From the profile it also offers the store page itself ([withPage]); from the builder,
/// the profile ([withProfile]).
Future<void> openStoreSettings(BuildContext context, StorefrontApi api, {List<Facts> categories = const [], bool withPage = false, bool withProfile = true}) async {
  // the shop's settings as cards with coloured icons, Ads in lime so it stands out (founder, 28 Oct 2026)
  final go = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: kBg,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(4)))),
          const SizedBox(height: 14),
          Text('Your shop settings', style: inter(19, 800)),
          Text('What customers see on OneLocal', style: inter(13, 500, color: kMuted)),
          const SizedBox(height: 12),
          for (final e in [
            if (withPage) ('page', 'Store page', 'Sections, theme, preview and publish', LucideIcons.layoutTemplate, const Color(0xFF2B6FE0)),
            if (withProfile) ('profile', 'Shop profile', 'Name, logo, banner, address and store link', LucideIcons.store, const Color(0xFF15803D)),
            ('offers', 'Offers & promotions', 'Deals shown on your page', LucideIcons.badgePercent, const Color(0xFFD1124F)),
            ('hours', 'Business hours', 'When you are open', LucideIcons.clock, const Color(0xFFE8711C)),
            ('delivery', 'Delivery & pickup', 'Area, fee and minimum order', LucideIcons.truck, const Color(0xFF8B3DF2)),
            ('ads', 'Ads', 'Boost your visibility with ads', LucideIcons.megaphone, kMoneyDeep),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: e.$1 == 'ads' ? kMoneyLime : Colors.white,
                borderRadius: BorderRadius.circular(18),
                child: InkWell(
                  key: ValueKey('store-settings-${e.$1}'),
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => Navigator.pop(ctx, e.$1),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
                    child: Row(children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(color: e.$1 == 'ads' ? kMoneyDeep : e.$5.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(12)),
                        child: Icon(e.$4, size: 19, color: e.$1 == 'ads' ? kMoneyLime : e.$5),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(e.$2, style: inter(15, 800)),
                          Text(e.$3, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 500, color: e.$1 == 'ads' ? const Color(0xFF3F4A12) : kMuted)),
                        ]),
                      ),
                      Icon(LucideIcons.chevronRight, size: 18, color: e.$1 == 'ads' ? kMoneyDeep : kMuted),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      ),
    ),
  );
  if (go == null || !context.mounted) return;
  final Widget screen = switch (go) {
    'page' => StorePageBuilder(api: api),
    'profile' => ProfileScreen(api: api),
    'offers' => OffersScreen(api: api),
    'hours' => HoursScreen(api: api),
    'delivery' => DeliveryScreen(api: api),
    _ => AdsHomeScreen(storefront: api),
  };
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
}

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
    await openStoreSettings(context, widget.api, categories: c.catalogueCategories);
    if (mounted) c.load();
  }

  Future<void> _preview() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PreviewScreen(api: widget.api, c: c)));
    c.load();
  }

  Future<void> _theme() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ThemeScreen(api: widget.api, c: c)));
    c.load();
  }

  /// The colour of a section's icon tile, by its kind.
  static Color _tint(String type) => switch (type) {
        'header' => const Color(0xFF15803D),
        'banner' || 'slider' => const Color(0xFF2B6FE0),
        'category_grid' => const Color(0xFFE8711C),
        'product_list' => const Color(0xFF8B3DF2),
        'deals' => const Color(0xFFD1124F),
        'ads' => const Color(0xFF0E9F6E),
        'brand' => const Color(0xFFB45309),
        _ => const Color(0xFF475569),
      };

  /// What a section is, in a few words, under its name.
  static String _what(String type) => switch (type) {
        'header' => 'Shop name, logo and banner',
        'banner' || 'slider' => 'Big pictures at the top',
        'category_grid' => 'Your categories as tiles',
        'product_list' => 'A row of products',
        'deals' => 'Your offers and deals',
        'custom_card' => 'A card with your own text',
        'brand' => 'Brands you sell',
        'divider' => 'Space between sections',
        'ads' => 'Your ads on the page',
        _ => 'A part of your page',
      };

  // the dark card at the top (Money's look, founder 28 Oct 2026): draft or live, how many sections, Theme, Preview and Discard draft
  Widget _status() {
    final list = c.sections;
    final shown = list.where((x) => x.enabled).length;
    final draft = c.unpublished;
    return MoneyDarkCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Your store page', style: inter(17, 800, color: Colors.white))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(color: kMoneyDeepSoft, borderRadius: BorderRadius.circular(40)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 7, height: 7, decoration: BoxDecoration(color: draft ? const Color(0xFFFFB547) : kMoneyLime, shape: BoxShape.circle)),
              const SizedBox(width: 5),
              Text(draft ? 'Draft' : 'Live', style: inter(11.5, 700, color: Colors.white)),
            ]),
          ),
        ]),
        const SizedBox(height: 4),
        Text('${list.length} section${list.length == 1 ? '' : 's'} · $shown shown to customers', style: inter(12.5, 500, color: const Color(0xFFB8BCC4))),
        if (draft) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Icon(LucideIcons.pencil, size: 13, color: kMoneyLime),
            const SizedBox(width: 6),
            Expanded(child: Text('Changes saved as a draft. Publish to make them live.', style: inter(12, 500, color: Colors.white))),
          ]),
        ],
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: FilledButton(
              key: const ValueKey('builder-preview'),
              onPressed: c.state == null ? null : _preview,
              style: FilledButton.styleFrom(backgroundColor: kMoneyLime, disabledBackgroundColor: kMoneyDeepSoft, padding: const EdgeInsets.symmetric(vertical: 13), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(LucideIcons.eye, size: 16, color: kMoneyDeep),
                const SizedBox(width: 6),
                Flexible(child: Text(draft ? 'Preview & publish' : 'Preview', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 800, color: kMoneyDeep))),
              ]),
            ),
          ),
          const SizedBox(width: 8),
          _darkButton('builder-theme', LucideIcons.palette, 'Theme', _theme),
        ]),
        if (draft)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey('builder-discard'),
              onPressed: () => _afterSave(Future(() async {
                await c.discard();
                return c.error == null;
              })),
              child: Text('Discard draft', style: inter(12.5, 700, color: const Color(0xFFFF8A8A))),
            ),
          ),
      ]),
    );
  }

  Widget _darkButton(String key, IconData icon, String label, VoidCallback onTap) => Material(
        color: kMoneyDeepSoft,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: ValueKey(key),
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 16, color: Colors.white),
              const SizedBox(width: 6),
              Text(label, style: inter(14, 700, color: Colors.white)),
            ]),
          ),
        ),
      );

  Widget _sectionCard(Section s, int i) {
    final tint = _tint(s.type);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: moneyCard(),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () => s.type == 'header' ? Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileScreen(api: widget.api))) : _edit(s),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 6, 10),
            child: Opacity(
              opacity: s.enabled ? 1 : 0.55,
              child: Row(children: [
                ReorderableDragStartListener(
                  index: i,
                  child: const Padding(padding: EdgeInsets.symmetric(horizontal: 6, vertical: 10), child: Icon(LucideIcons.gripVertical, size: 18, color: kMuted)),
                ),
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(color: tint.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(14)),
                  child: Icon(sectionIcon(s.type), size: 21, color: tint),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(15.5, 800)),
                    const SizedBox(height: 2),
                    Row(children: [
                      if (!s.enabled) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(color: const Color(0xFFF1F2F4), borderRadius: BorderRadius.circular(20)),
                          child: Text('Hidden', style: inter(10.5, 700, color: kMuted)),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Flexible(child: Text(_what(s.type), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 500, color: kMuted))),
                    ]),
                  ]),
                ),
                IconButton(tooltip: 'More for ${s.label}', visualDensity: VisualDensity.compact, onPressed: () => _menu(s), icon: const Icon(LucideIcons.ellipsisVertical, size: 18)),
                const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = c.sections;
    return SfPage(
      title: 'Store Page Builder',
      subtitle: 'Create and customise your store page',
      trailing: IconButton(tooltip: 'Store settings', onPressed: _settingsHub, icon: const Icon(LucideIcons.settings, size: 22)),
      bottom: Column(mainAxisSize: MainAxisSize.min, children: [
        // the shop's other settings, as a card that says what is inside
        Padding(
          padding: const EdgeInsets.only(bottom: 10, top: 6),
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              key: const ValueKey('builder-settings'),
              borderRadius: BorderRadius.circular(18),
              onTap: _settingsHub,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: kLine)),
                child: Row(children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(color: kMoneyDeep, borderRadius: BorderRadius.circular(11)),
                    child: const Icon(LucideIcons.slidersHorizontal, size: 17, color: kMoneyLime),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Shop settings', style: inter(14, 800)),
                      Text('Profile · Offers · Hours · Delivery', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 500, color: kMuted)),
                    ]),
                  ),
                  const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
                ]),
              ),
            ),
          ),
        ),
        SfSave('Preview Store', onPressed: c.state == null ? null : _preview),
      ]),
      children: [
        if (c.state == null && c.error != null)
          SfCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Could not load the page', style: inter(15, 700)), const SizedBox(height: 6), Text(c.error!, style: inter(13, 400, color: kMuted)), const SizedBox(height: 10), SfSoft('Try again', onPressed: c.load)]))
        else if (c.state == null)
          const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kInk)))
        else ...[
          _status(),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
            child: Row(children: [
              Expanded(child: Text('Sections', style: inter(17, 800))),
              const Icon(LucideIcons.gripVertical, size: 14, color: kMuted),
              Text(' Drag to reorder', style: inter(12, 500, color: kMuted)),
            ]),
          ),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: list.length,
            onReorderItem: (a, b) => _afterSave(c.move(a, b)),
            itemBuilder: (_, i) => KeyedSubtree(key: ValueKey(list[i].id), child: _sectionCard(list[i], i)),
          ),
          const SizedBox(height: 4),
          Material(
            color: kMoneyLime,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              key: const ValueKey('builder-add'),
              onTap: _add,
              borderRadius: BorderRadius.circular(20),
              child: SizedBox(
                height: 62,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: const BoxDecoration(color: kMoneyDeep, shape: BoxShape.circle),
                    child: const Icon(LucideIcons.plus, size: 18, color: kMoneyLime),
                  ),
                  const SizedBox(width: 10),
                  Text('Add Section', style: inter(16, 800, color: kMoneyDeep)),
                ]),
              ),
            ),
          ),
        ],
        if (c.busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator(color: kInk, backgroundColor: kLine)),
      ],
    );
  }
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
