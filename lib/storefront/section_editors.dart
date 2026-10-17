import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../orders/order_widgets.dart' show TagChip;
import '../ui/theme.dart';
import 'builder_screen.dart';
import 'sf_widgets.dart';
import 'storefront_api.dart';

/// The editor screen for a section; it pops with the changed [Section] (the builder saves it) or null when nothing was saved.
Widget editorFor(Section s, BuilderController c) => switch (s.type) {
      'banner' => BannerEditor(section: s, c: c),
      'category_grid' => CategoryGridEditor(section: s, c: c),
      'product_list' => ProductListEditor(section: s, c: c),
      'deals' => DealsEditor(section: s, c: c),
      'custom_card' => CustomCardEditor(section: s, c: c),
      'brand' => BrandEditor(section: s, c: c),
      'divider' => DividerEditor(section: s, c: c),
      'ads' => AdsSectionEditor(section: s, c: c),
      _ => SfPage(title: s.label, children: [Text('This section has nothing to edit.', style: inter(14, 400, color: kMuted))]),
    };

const _layouts = <(String, String, IconData?)>[('grid', 'Grid', LucideIcons.layoutGrid), ('scroll', 'Horizontal Scroll', LucideIcons.columns3), ('list', 'List', LucideIcons.list)];
const _cols = <(int, String, IconData?)>[(2, '2', null), (3, '3', null), (4, '4', null)];

/// Picture chooser: an Upload tile, then the business's earlier pictures of this kind. Uploads go to the server's secure handler.
class SfImagePicker extends StatefulWidget {
  const SfImagePicker({super.key, required this.c, required this.kind, required this.selectedId, required this.onChanged});
  final BuilderController c;
  final String kind;
  final String? selectedId;
  final ValueChanged<String?> onChanged;
  @override
  State<SfImagePicker> createState() => _SfImagePickerState();
}

class _SfImagePickerState extends State<SfImagePicker> {
  bool _busy = false;

  Future<void> _upload() async {
    final picked = await widget.c.picker.pick();
    if (picked == null) return;
    setState(() => _busy = true);
    try {
      final up = await widget.c.api.uploadImage(kind: widget.kind, bytes: picked.bytes, contentType: picked.contentType);
      widget.c.rememberImage(up);
      widget.onChanged(up.s('id'));
    } catch (e) {
      if (mounted) sfToast(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final imgs = widget.c.library.where((i) => i.s('kind') == widget.kind).toList();
    return Wrap(spacing: 10, runSpacing: 10, children: [
      Semantics(
        button: true,
        label: 'Upload Image',
        child: InkWell(
          onTap: _busy ? null : _upload,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: 104,
            height: 104,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
            child: _busy ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: kInk))) : Column(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(LucideIcons.camera, size: 20), const SizedBox(height: 8), Text('Upload Image', style: inter(12.5, 500))]),
          ),
        ),
      ),
      for (final i in imgs)
        Semantics(
          button: true,
          selected: i.s('id') == widget.selectedId,
          label: 'Picture',
          child: InkWell(
            onTap: () => widget.onChanged(i.s('id')),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: 104,
              height: 104,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: i.s('id') == widget.selectedId ? kSfLimeLine : kLine, width: i.s('id') == widget.selectedId ? 2 : 1)),
              child: Stack(children: [
                Positioned.fill(child: SfThumb(widget.c.imageUrl(i.s('id')), size: 100, radius: 12)),
                if (i.s('id') == widget.selectedId) const Positioned(top: 6, right: 6, child: CircleAvatar(radius: 11, backgroundColor: kInk, child: Icon(LucideIcons.check, size: 14, color: Colors.white))),
              ]),
            ),
          ),
        ),
    ]);
  }
}

// ------------------------------------------------------------------------------------------------ banner

/// Banner / Slider: the slides, each edited on the "Edit Banner" screen.
class BannerEditor extends StatefulWidget {
  const BannerEditor({super.key, required this.section, required this.c});
  final Section section;
  final BuilderController c;
  @override
  State<BannerEditor> createState() => _BannerEditorState();
}

class _BannerEditorState extends State<BannerEditor> {
  late final Section s = widget.section.copy();

  Future<void> _edit(int? i) async {
    final slides = s.list('slides');
    final r = await Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => SlideEditor(c: widget.c, slide: i == null ? null : slides[i], isNew: i == null)));
    if (r == null) return;
    if (r['delete'] == true) {
      if (i != null) slides.removeAt(i);
    } else if (i == null) {
      slides.add(r);
    } else {
      slides[i] = r;
    }
    setState(() => s.config['slides'] = slides);
  }

  @override
  Widget build(BuildContext context) {
    final slides = s.list('slides');
    return SfPage(
      title: 'Banner / Slider',
      bottom: SfSave('Save', onPressed: () => Navigator.of(context).pop(s)),
      children: [
        const SfLabel('Banners', top: 4),
        if (slides.isEmpty) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text('No banners yet. Add up to 8.', style: inter(14, 400, color: kMuted))),
        for (var i = 0; i < slides.length; i++)
          SfCard(
            onTap: () => _edit(i),
            child: Row(children: [
              SfThumb(widget.c.imageUrl('${slides[i]['image_id']}'), size: 56, width: 92),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${slides[i]['title'] ?? 'Banner ${i + 1}'}', style: inter(15, 700), maxLines: 1, overflow: TextOverflow.ellipsis), if (slides[i]['subtitle'] != null) Text('${slides[i]['subtitle']}', style: inter(13, 400, color: kMuted), maxLines: 1, overflow: TextOverflow.ellipsis)])),
              const Icon(LucideIcons.chevronRight, size: 18),
            ]),
          ),
        if (slides.length < 8) SfSoft('Add banner', icon: LucideIcons.plus, onPressed: () => _edit(null)),
      ],
    );
  }
}

/// Figma "Edit Banner": image, link target (category or product), title, subtitle, delete. Pops the slide map, or `{delete: true}`.
class SlideEditor extends StatefulWidget {
  const SlideEditor({super.key, required this.c, this.slide, this.isNew = false});
  final BuilderController c;
  final Map<String, dynamic>? slide;
  final bool isNew;
  @override
  State<SlideEditor> createState() => _SlideEditorState();
}

class _SlideEditorState extends State<SlideEditor> {
  late String? image = widget.slide?['image_id'] as String?;
  late String linkType = (widget.slide?['link_type'] as String?) ?? 'none';
  late String? target = widget.slide?['link_target'] as String?;
  late final title = TextEditingController(text: '${widget.slide?['title'] ?? ''}');
  late final subtitle = TextEditingController(text: '${widget.slide?['subtitle'] ?? ''}');
  String? targetLabel;

  Future<void> _pickProduct() async {
    final p = await pickProduct(context, widget.c.api);
    if (p != null) setState(() { target = p.s('id'); targetLabel = p.s('name'); });
  }

  @override
  Widget build(BuildContext context) {
    final cats = widget.c.pageCategories;
    return SfPage(
      title: 'Edit Banner',
      trailing: widget.isNew ? null : IconButton(tooltip: 'Delete banner', onPressed: () => Navigator.of(context).pop({'delete': true}), icon: const Icon(LucideIcons.trash2, size: 20)),
      bottom: SfSave('Save', onPressed: image == null ? null : () => Navigator.of(context).pop({
            if (widget.slide?['id'] != null) 'id': widget.slide!['id'],
            'image_id': image,
            'link_type': linkType,
            'link_target': linkType == 'none' ? null : target,
            'title': title.text.trim().isEmpty ? null : title.text.trim(),
            'subtitle': subtitle.text.trim().isEmpty ? null : subtitle.text.trim(),
          })),
      children: [
        SfThumb(widget.c.imageUrl(image), size: 160, width: double.infinity, radius: 18),
        const SfLabel('Banner Image'),
        SfImagePicker(c: widget.c, kind: 'banner', selectedId: image, onChanged: (v) => setState(() => image = v)),
        const SfLabel('Link to'),
        SfChoice<String>(options: const [('none', 'None', null), ('category', 'Category', null), ('product', 'Product', null)], value: linkType, onChanged: (v) => setState(() { linkType = v; target = null; targetLabel = null; })),
        if (linkType == 'category') ...[
          const SfLabel('Select Category'),
          if (cats.isEmpty) Text('Add a Category Grid section first, then a banner can link to one of its categories.', style: inter(14, 400, color: kMuted))
          else DropdownButtonFormField<String>(
            initialValue: cats.any((e) => e.id == target) ? target : null,
            isExpanded: true,
            hint: const Text('Choose a category'),
            items: [for (final e in cats) DropdownMenuItem(value: e.id, child: Text(e.name))],
            onChanged: (v) => setState(() => target = v),
            decoration: _dd,
          ),
        ],
        if (linkType == 'product') ...[
          const SfLabel('Select Product'),
          SfSoft(targetLabel ?? (target == null ? 'Choose a product' : 'Product chosen'), icon: LucideIcons.search, onPressed: _pickProduct),
        ],
        const SfLabel('Title (optional)'),
        SfField(controller: title, maxLength: 40, hint: 'Title'),
        const SfLabel('Subtitle (optional)', top: 8),
        SfField(controller: subtitle, maxLength: 60, hint: 'Subtitle'),
      ],
    );
  }
}

final _dd = InputDecoration(
  filled: true,
  fillColor: const Color(0xFFFAFBF8),
  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kLine)),
  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kInk)),
);

/// A bottom sheet to search the catalogue and pick ONE product.
Future<Facts?> pickProduct(BuildContext context, StorefrontApi api) => showModalBottomSheet<Facts>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (_) => SizedBox(height: MediaQuery.sizeOf(context).height * 0.75, child: _ProductSheet(api: api)),
    );

class _ProductSheet extends StatefulWidget {
  const _ProductSheet({required this.api});
  final StorefrontApi api;
  @override
  State<_ProductSheet> createState() => _ProductSheetState();
}

class _ProductSheetState extends State<_ProductSheet> {
  final q = TextEditingController();
  List<Facts>? items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.products(q: q.text);
      if (mounted) setState(() => items = r.l('items'));
    } catch (e) {
      if (mounted) { sfToast(context, e); setState(() => items = []); }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          SfField(controller: q, hint: 'Search products', onChanged: (_) => _load()),
          const SizedBox(height: 8),
          Expanded(
            child: items == null
                ? const Center(child: CircularProgressIndicator(color: kInk))
                : ListView(children: [
                    if (items!.isEmpty) Padding(padding: const EdgeInsets.all(20), child: Text('No products found.', style: inter(14, 400, color: kMuted))),
                    for (final p in items!) ListTile(title: Text(p.s('name')), subtitle: Text(rs(p.no('price_minor'))), onTap: () => Navigator.pop(context, p)),
                  ]),
          ),
        ]),
      );
}

// ------------------------------------------------------------------------------------------------ category grid

/// Figma "Edit Category Grid": title, layout, columns, the categories (reorder, delete) and "+ Add Category".
class CategoryGridEditor extends StatefulWidget {
  const CategoryGridEditor({super.key, required this.section, required this.c});
  final Section section;
  final BuilderController c;
  @override
  State<CategoryGridEditor> createState() => _CategoryGridEditorState();
}

class _CategoryGridEditorState extends State<CategoryGridEditor> {
  late final Section s = widget.section.copy();
  late final title = TextEditingController(text: widget.section.title);

  String get layout => '${s.config['layout'] ?? 'grid'}';
  int get columns => (s.config['columns'] as num?)?.toInt() ?? 3;

  Future<void> _editCategory(int? i) async {
    final cats = s.list('categories');
    final r = await Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => CategoryEditScreen(c: widget.c, category: i == null ? null : cats[i])));
    if (r == null) return;
    if (i == null) {
      cats.add(r);
    } else {
      cats[i] = r;
    }
    setState(() => s.config['categories'] = cats);
  }

  @override
  Widget build(BuildContext context) {
    final cats = s.list('categories');
    return SfPage(
      title: 'Edit Category Grid',
      bottom: SfSave('Save', onPressed: () {
        s.raw['title'] = title.text.trim().isEmpty ? null : title.text.trim();
        Navigator.of(context).pop(s);
      }),
      children: [
        const SfLabel('Section Title', top: 4),
        SfField(controller: title, maxLength: 40, hint: 'Section title'),
        const SfLabel('Layout Style', top: 8),
        SfChoice<String>(options: _layouts, value: layout, tall: true, onChanged: (v) => setState(() => s.config['layout'] = v)),
        const SfLabel('Columns'),
        SfChoice<int>(options: _cols, value: columns, onChanged: (v) => setState(() => s.config['columns'] = v)),
        Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 8),
          child: Row(children: [
            Expanded(child: Text('Categories', style: inter(16, 700))),
            Material(
              color: kSfLime,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(borderRadius: BorderRadius.circular(12), onTap: cats.length >= 24 ? null : () => _editCategory(null), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), child: Row(children: [const Icon(LucideIcons.plus, size: 16), const SizedBox(width: 6), Text('Add Category', style: inter(14, 700))]))),
            ),
          ]),
        ),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: cats.length,
          onReorderItem: (a, b) => setState(() {
            final x = cats.removeAt(a);
            cats.insert(b, x);
            s.config['categories'] = cats;
          }),
          itemBuilder: (_, i) => KeyedSubtree(
            key: ValueKey('${cats[i]['id']}'),
            child: SfCard(
              onTap: () => _editCategory(i),
              padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
              child: Row(children: [
                ReorderableDragStartListener(index: i, child: const Padding(padding: EdgeInsets.all(8), child: Icon(LucideIcons.gripVertical, size: 18, color: kMuted))),
                SfThumb(widget.c.imageUrl(cats[i]['image_id'] as String?), size: 48),
                const SizedBox(width: 12),
                Expanded(child: Text('${cats[i]['name']}', style: inter(15, 500))),
                IconButton(tooltip: 'Remove ${cats[i]['name']}', onPressed: () => setState(() { cats.removeAt(i); s.config['categories'] = cats; }), icon: const Icon(LucideIcons.trash2, size: 18, color: kMuted)),
              ]),
            ),
          ),
        ),
      ],
    );
  }
}

/// Figma "Add Category": name (30) and an icon / picture. Pops `{id, name, image_id}`.
class CategoryEditScreen extends StatefulWidget {
  const CategoryEditScreen({super.key, required this.c, this.category});
  final BuilderController c;
  final Map<String, dynamic>? category;
  @override
  State<CategoryEditScreen> createState() => _CategoryEditScreenState();
}

class _CategoryEditScreenState extends State<CategoryEditScreen> {
  late final name = TextEditingController(text: '${widget.category?['name'] ?? ''}');
  late String? image = widget.category?['image_id'] as String?;

  @override
  Widget build(BuildContext context) => SfPage(
        title: widget.category == null ? 'Add Category' : 'Edit Category',
        bottom: SfSave('Save', onPressed: name.text.trim().isEmpty ? null : () => Navigator.of(context).pop({'id': widget.category?['id'] ?? 'c${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}', 'name': name.text.trim(), 'image_id': image})),
        children: [
          Center(child: SfThumb(widget.c.imageUrl(image), size: 220, width: 220, radius: 18)),
          const SfLabel('Category Name'),
          SfField(controller: name, maxLength: 30, hint: 'Category name', onChanged: (_) => setState(() {})),
          const SfLabel('Select Icon / Image'),
          SfImagePicker(c: widget.c, kind: 'category', selectedId: image, onChanged: (v) => setState(() => image = v)),
        ],
      );
}

// ------------------------------------------------------------------------------------------------ product list and products

/// Figma "Edit Product List": title, layout, columns, four display switches, and the products (Select Products).
class ProductListEditor extends StatefulWidget {
  const ProductListEditor({super.key, required this.section, required this.c});
  final Section section;
  final BuilderController c;
  @override
  State<ProductListEditor> createState() => _ProductListEditorState();
}

class _ProductListEditorState extends State<ProductListEditor> {
  late final Section s = widget.section.copy();
  late final title = TextEditingController(text: widget.section.title);

  bool flag(String k) => s.config[k] != false;
  List<String> get ids => ((s.config['product_ids'] as List?) ?? const []).map((e) => '$e').toList();

  Future<void> _select() async {
    final r = await Navigator.of(context).push<List<String>>(MaterialPageRoute(builder: (_) => SelectProductsScreen(api: widget.c.api, c: widget.c, selected: ids)));
    if (r != null) setState(() => s.config['product_ids'] = r);
  }

  @override
  Widget build(BuildContext context) => SfPage(
        title: 'Edit Product List',
        bottom: SfSave('Save', onPressed: () {
          s.raw['title'] = title.text.trim().isEmpty ? null : title.text.trim();
          Navigator.of(context).pop(s);
        }),
        children: [
          const SfLabel('Section Title', top: 4),
          SfField(controller: title, maxLength: 40, hint: 'Section title'),
          const SfLabel('Layout Style', top: 8),
          SfChoice<String>(options: _layouts, value: '${s.config['layout'] ?? 'grid'}', tall: true, onChanged: (v) => setState(() => s.config['layout'] = v)),
          const SfLabel('Number of Columns'),
          SfChoice<int>(options: _cols, value: (s.config['columns'] as num?)?.toInt() ?? 3, onChanged: (v) => setState(() => s.config['columns'] = v)),
          const SizedBox(height: 8),
          SfToggle(title: 'Show Ratings', value: flag('show_ratings'), onChanged: (v) => setState(() => s.config['show_ratings'] = v)),
          SfToggle(title: 'Show Delivery Time', value: flag('show_delivery_time'), onChanged: (v) => setState(() => s.config['show_delivery_time'] = v)),
          SfToggle(title: 'Show Discount %', value: flag('show_discount'), onChanged: (v) => setState(() => s.config['show_discount'] = v)),
          SfToggle(title: 'Show Add Button', value: flag('show_add_button'), onChanged: (v) => setState(() => s.config['show_add_button'] = v)),
          const SfLabel('Products'),
          SfSoft(ids.isEmpty ? 'Select Products' : '${ids.length} products · change', icon: LucideIcons.plus, onPressed: _select),
        ],
      );
}

/// Figma "Select Products": search, All Products / Best Sellers / On Offer, tick rows, "Add N Products". Pops the chosen ids.
class SelectProductsScreen extends StatefulWidget {
  const SelectProductsScreen({super.key, required this.api, required this.c, required this.selected});
  final StorefrontApi api;
  final BuilderController c;
  final List<String> selected;
  @override
  State<SelectProductsScreen> createState() => _SelectProductsScreenState();
}

class _SelectProductsScreenState extends State<SelectProductsScreen> {
  final q = TextEditingController();
  String filter = 'all';
  late final Set<String> chosen = {...widget.selected};
  late final List<String> order = [...widget.selected];
  List<Facts>? items;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.products(filter: filter, q: q.text, limit: 50);
      if (mounted) setState(() { items = r.l('items'); error = null; });
    } catch (e) {
      if (mounted) setState(() => error = sfMessage(e));
    }
  }

  void _toggle(String id, bool on) => setState(() {
        if (on) { chosen.add(id); order.add(id); } else { chosen.remove(id); order.remove(id); }
      });

  Future<void> _editProduct(Facts p) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProductEditScreen(api: widget.api, c: widget.c, product: p)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final n = chosen.length;
    return SfPage(
      title: 'Select Products',
      bottom: SfSave(n == 0 ? 'Done' : 'Add $n Product${n == 1 ? '' : 's'}', onPressed: () => Navigator.of(context).pop(order.where(chosen.contains).toList())),
      children: [
        SfField(controller: q, hint: 'Search products', onChanged: (_) => _load()),
        const SizedBox(height: 12),
        SfChoice<String>(options: const [('all', 'All Products', null), ('best_sellers', 'Best Sellers', null), ('on_offer', 'On Offer', null)], value: filter, onChanged: (v) { filter = v; _load(); }),
        const SizedBox(height: 12),
        if (error != null) Text(error!, style: inter(14, 400, color: kError))
        else if (items == null) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator(color: kInk)))
        else if (items!.isEmpty) Padding(padding: const EdgeInsets.all(20), child: Text(filter == 'best_sellers' ? 'No sales in the last 30 days yet.' : 'No products found.', style: inter(14, 400, color: kMuted))),
        for (final p in items ?? const <Facts>[])
          Container(
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: kLine))),
            child: Row(children: [
              Checkbox(value: chosen.contains(p.s('id')), activeColor: kSfLime, checkColor: kInk, onChanged: (v) => _toggle(p.s('id'), v == true)),
              SfThumb(widget.c.imageUrl(p.so('image_id')) ?? p.so('image_url'), size: 52),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p.s('name'), style: inter(14.5, 500)),
                    const SizedBox(height: 2),
                    Row(children: [Text(rs(p.no('price_minor')), style: inter(14, 600)), if (p.no('discount_pct') != null) ...[const SizedBox(width: 6), Text(rs(p.no('mrp_minor')), style: inter(12, 400, color: kMuted).copyWith(decoration: TextDecoration.lineThrough))]]),
                  ]),
                ),
              ),
              if (p.no('discount_pct') != null) TagChip('${p.n('discount_pct')}% OFF'),
              IconButton(tooltip: 'Edit ${p.s('name')}', onPressed: () => _editProduct(p), icon: const Icon(LucideIcons.pencil, size: 16)),
            ]),
          ),
      ],
    );
  }
}

/// Figma "Edit Product Details". Price, original price (MRP), name and category are catalogue facts and the server saves them through the
/// catalogue's own rules (price cannot exceed MRP; a stale item is refused); description, picture and "Show on storefront" belong to the storefront.
class ProductEditScreen extends StatefulWidget {
  const ProductEditScreen({super.key, required this.api, required this.c, required this.product});
  final StorefrontApi api;
  final BuilderController c;
  final Facts product;
  @override
  State<ProductEditScreen> createState() => _ProductEditScreenState();
}

class _ProductEditScreenState extends State<ProductEditScreen> {
  late final name = TextEditingController(text: widget.product.s('name'));
  late final desc = TextEditingController(text: widget.product.so('description') ?? '');
  late final price = TextEditingController(text: rupeeText(widget.product.no('price_minor')));
  late final mrp = TextEditingController(text: rupeeText(widget.product.no('mrp_minor')));
  late String? category = widget.product.so('category');
  late bool visible = widget.product.raw['visible'] != false;
  late String? image = widget.product.so('image_id');
  bool busy = false;

  Future<void> _save() async {
    setState(() => busy = true);
    final p = widget.product;
    final body = <String, Object?>{
      'id': p.s('id'),
      'version': p.n('version').toInt(),
      if (name.text.trim() != p.s('name')) 'name': name.text.trim(),
      if (paise(price.text) != null && paise(price.text) != p.no('price_minor')) 'price_minor': paise(price.text),
      if (paise(mrp.text) != p.no('mrp_minor') && paise(mrp.text) != null) 'mrp_minor': paise(mrp.text),
      if (category != null && category != p.so('category')) 'category': category,
      'description': desc.text.trim().isEmpty ? null : desc.text.trim(),
      'visible': visible,
      'image_id': image,
    };
    try {
      await widget.api.saveProduct(body..removeWhere((k, v) => v == null && k != 'description' && k != 'image_id'));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) { setState(() => busy = false); sfToast(context, e); }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cats = widget.c.catalogueCategories.map((e) => e.s('name')).toList();
    return SfPage(
      title: 'Edit Product Details',
      bottom: SfSave('Save Product', busy: busy, onPressed: name.text.trim().isEmpty ? null : _save),
      children: [
        const SfLabel('Product Image', top: 4),
        SfCard(child: Center(child: SfThumb(widget.c.imageUrl(image) ?? widget.product.so('image_url'), size: 160, width: 160, radius: 12))),
        SfImagePicker(c: widget.c, kind: 'product', selectedId: image, onChanged: (v) => setState(() => image = v)),
        const SfLabel('Product Name'),
        SfField(controller: name, hint: 'Product name', onChanged: (_) => setState(() {})),
        const SfLabel('Description'),
        SfField(controller: desc, maxLength: 300, lines: 3, hint: 'Description'),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const SfLabel('Selling Price'), SfField(controller: price, number: true, prefix: '₹')])),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const SfLabel('Original Price'), SfField(controller: mrp, number: true, prefix: '₹')])),
        ]),
        const SfLabel('Category', top: 8),
        DropdownButtonFormField<String>(
          initialValue: cats.contains(category) ? category : null,
          isExpanded: true,
          hint: Text(category ?? 'No category'),
          items: [for (final n in cats) DropdownMenuItem(value: n, child: Text(n))],
          onChanged: (v) => setState(() => category = v),
          decoration: _dd,
        ),
        const SizedBox(height: 8),
        SfToggle(title: 'Show on storefront', value: visible, onChanged: (v) => setState(() => visible = v)),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------------ the other section types

/// Deals / Offer section: pick one of this business's offers (made on "Offers & Promotions"), an optional message and extra products.
class DealsEditor extends StatefulWidget {
  const DealsEditor({super.key, required this.section, required this.c});
  final Section section;
  final BuilderController c;
  @override
  State<DealsEditor> createState() => _DealsEditorState();
}

class _DealsEditorState extends State<DealsEditor> {
  late final Section s = widget.section.copy();
  late final title = TextEditingController(text: widget.section.title);
  late final message = TextEditingController(text: '${widget.section.config['message'] ?? ''}');

  @override
  Widget build(BuildContext context) => SfPage(
        title: 'Deals / Offer Section',
        bottom: SfSave('Save', onPressed: () {
          s.raw['title'] = title.text.trim().isEmpty ? null : title.text.trim();
          s.config['message'] = message.text.trim().isEmpty ? null : message.text.trim();
          Navigator.of(context).pop(s);
        }),
        children: [
          const SfLabel('Section Title', top: 4),
          SfField(controller: title, maxLength: 40, hint: 'Section title'),
          const SfLabel('Promotion Message', top: 8),
          SfField(controller: message, maxLength: 60, hint: 'Promotion message'),
          const SfLabel('Offer'),
          SfLoader<List<Facts>>(
            load: widget.c.api.offers,
            builder: (_, offers, _) {
              final mine = offers.where((o) => o.raw['editable'] == true).toList();
              if (mine.isEmpty) return Text('No offers yet. Create one under Offers & Promotions, then choose it here.', style: inter(14, 400, color: kMuted));
              return Column(children: [
                for (final o in mine)
                  SfCard(
                    selected: s.config['offer_id'] == o.s('id'),
                    onTap: () => setState(() => s.config['offer_id'] = s.config['offer_id'] == o.s('id') ? null : o.s('id')),
                    child: Row(children: [Expanded(child: Text(o.s('title'), style: inter(15, 600))), TagChip(o.s('phase'))]),
                  ),
              ]);
            },
          ),
        ],
      );
}

class CustomCardEditor extends StatefulWidget {
  const CustomCardEditor({super.key, required this.section, required this.c});
  final Section section;
  final BuilderController c;
  @override
  State<CustomCardEditor> createState() => _CustomCardEditorState();
}

class _CustomCardEditorState extends State<CustomCardEditor> {
  late final Section s = widget.section.copy();
  late final heading = TextEditingController(text: '${widget.section.config['heading'] ?? ''}');
  late final body = TextEditingController(text: '${widget.section.config['body'] ?? ''}');

  @override
  Widget build(BuildContext context) => SfPage(
        title: 'Custom Card',
        bottom: SfSave('Save', onPressed: () {
          s.config['heading'] = heading.text.trim().isEmpty ? null : heading.text.trim();
          s.config['body'] = body.text.trim().isEmpty ? null : body.text.trim();
          Navigator.of(context).pop(s);
        }),
        children: [
          SfThumb(widget.c.imageUrl(s.config['image_id'] as String?), size: 150, width: double.infinity, radius: 18),
          const SfLabel('Image'),
          SfImagePicker(c: widget.c, kind: 'card', selectedId: s.config['image_id'] as String?, onChanged: (v) => setState(() => s.config['image_id'] = v)),
          const SfLabel('Heading'),
          SfField(controller: heading, maxLength: 40, hint: 'Heading'),
          const SfLabel('Text', top: 8),
          SfField(controller: body, maxLength: 120, lines: 3, hint: 'Text'),
        ],
      );
}

class BrandEditor extends StatefulWidget {
  const BrandEditor({super.key, required this.section, required this.c});
  final Section section;
  final BuilderController c;
  @override
  State<BrandEditor> createState() => _BrandEditorState();
}

class _BrandEditorState extends State<BrandEditor> {
  late final Section s = widget.section.copy();
  late final brand = TextEditingController(text: '${widget.section.config['brand'] ?? ''}');
  List<String> get ids => ((s.config['product_ids'] as List?) ?? const []).map((e) => '$e').toList();

  @override
  Widget build(BuildContext context) => SfPage(
        title: 'Brand Section',
        bottom: SfSave('Save', onPressed: () {
          s.config['brand'] = brand.text.trim().isEmpty ? null : brand.text.trim();
          Navigator.of(context).pop(s);
        }),
        children: [
          const SfLabel('Brand name', top: 4),
          SfField(controller: brand, maxLength: 40, hint: 'Brand name'),
          const SfLabel('Products'),
          SfSoft(ids.isEmpty ? 'Select Products' : '${ids.length} products · change', icon: LucideIcons.plus, onPressed: () async {
            final r = await Navigator.of(context).push<List<String>>(MaterialPageRoute(builder: (_) => SelectProductsScreen(api: widget.c.api, c: widget.c, selected: ids)));
            if (r != null) setState(() => s.config['product_ids'] = r);
          }),
        ],
      );
}

class DividerEditor extends StatefulWidget {
  const DividerEditor({super.key, required this.section, required this.c});
  final Section section;
  final BuilderController c;
  @override
  State<DividerEditor> createState() => _DividerEditorState();
}

class _DividerEditorState extends State<DividerEditor> {
  late final Section s = widget.section.copy();
  double get h => ((s.config['height'] as num?) ?? 16).toDouble();

  @override
  Widget build(BuildContext context) => SfPage(
        title: 'Divider',
        bottom: SfSave('Save', onPressed: () => Navigator.of(context).pop(s)),
        children: [
          Text('Space between sections: ${h.round()}', style: inter(16, 700)),
          Slider(value: h.clamp(8, 64), min: 8, max: 64, divisions: 14, activeColor: kInk, onChanged: (v) => setState(() => s.config['height'] = v.round())),
        ],
      );
}

/// Ads section: choose one of this business's ad requests to show on the page.
class AdsSectionEditor extends StatefulWidget {
  const AdsSectionEditor({super.key, required this.section, required this.c});
  final Section section;
  final BuilderController c;
  @override
  State<AdsSectionEditor> createState() => _AdsSectionEditorState();
}

class _AdsSectionEditorState extends State<AdsSectionEditor> {
  late final Section s = widget.section.copy();

  @override
  Widget build(BuildContext context) => SfPage(
        title: 'Ads',
        bottom: SfSave('Save', onPressed: () => Navigator.of(context).pop(s)),
        children: [
          Text('An ad is shown only while Proviyaa has approved it and it is inside its dates.', style: inter(13, 400, color: kMuted)),
          const SfLabel('Your ads'),
          SfLoader<List<Facts>>(
            load: widget.c.api.ads,
            builder: (_, ads, _) {
              if (ads.isEmpty) return Text('No ads yet. Create one under Ads in the store settings.', style: inter(14, 400, color: kMuted));
              return Column(children: [
                for (final a in ads)
                  SfCard(
                    selected: s.config['ad_id'] == a.s('id'),
                    onTap: () => setState(() => s.config['ad_id'] = s.config['ad_id'] == a.s('id') ? null : a.s('id')),
                    child: Row(children: [SfThumb(a.so('image_url'), size: 44), const SizedBox(width: 12), Expanded(child: Text(a.s('title'), style: inter(15, 600))), TagChip(a.s('status'))]),
                  ),
              ]);
            },
          ),
        ],
      );
}
