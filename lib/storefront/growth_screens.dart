import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../onboarding/document_picker.dart';
import '../orders/order_widgets.dart' show TagChip;
import '../setup/setup_api.dart' show ImagePicker;
import '../ui/theme.dart';
import 'builder_screen.dart';
import 'section_editors.dart';
import 'sf_widgets.dart';
import 'storefront_api.dart';

Future<DateTime?> _pickDay(BuildContext context, DateTime? current) =>
    showDatePicker(context: context, initialDate: current ?? DateTime.now(), firstDate: DateTime(2024), lastDate: DateTime(2100));

class _DateBox extends StatelessWidget {
  const _DateBox({required this.label, required this.value, required this.onTap});
  final String label;
  final DateTime? value;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SfLabel(label, top: 8),
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(color: const Color(0xFFFAFBF8), borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
              child: Text(value == null ? 'Choose' : dayText(value!.toIso8601String()), style: inter(15, 400, color: value == null ? kMuted : kInk)),
            ),
          ),
        ]),
      );
}

/// Offers of this business: the ones made here (editable) and head-office ones (read only), with the phase the database works out.
class OffersScreen extends StatelessWidget {
  const OffersScreen({super.key, required this.api});
  final StorefrontApi api;
  @override
  Widget build(BuildContext context) => SfLoader<List<Facts>>(
        load: api.offers,
        builder: (ctx, offers, reload) => SfPage(
          title: 'Offers & Promotions',
          bottom: SfSave('New offer', onPressed: () async {
            await Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => OfferEditScreen(api: api)));
            reload();
          }),
          children: [
            if (offers.isEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('No offers yet. Create one to show discounted products on your storefront.', style: inter(14, 400, color: kMuted))),
            for (final o in offers)
              SfCard(
                onTap: o.raw['editable'] == true ? () async {
                  await Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => OfferEditScreen(api: api, offer: o)));
                  reload();
                } : null,
                child: Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(o.s('title'), style: inter(16, 700)),
                    if (o.so('message') != null) Text(o.s('message'), style: inter(13, 400, color: kMuted)),
                    const SizedBox(height: 4),
                    Text(o.so('start_date') == null && o.so('end_date') == null ? 'No dates' : '${dayText(o.so('start_date'))} – ${dayText(o.so('end_date'))}', style: inter(12.5, 400, color: kMuted)),
                    if (o.raw['editable'] != true) Text('Managed by Proviyaa', style: inter(12, 500, color: kMuted)),
                  ])),
                  TagChip(o.s('phase')),
                ]),
              ),
          ],
        ),
      );
}

/// Figma "Offers & Promotions": section title, promotion message, products on offer, dates, show on storefront, Save Offers.
class OfferEditScreen extends StatefulWidget {
  const OfferEditScreen({super.key, required this.api, this.offer});
  final StorefrontApi api;
  final Facts? offer;
  @override
  State<OfferEditScreen> createState() => _OfferEditScreenState();
}

class _OfferEditScreenState extends State<OfferEditScreen> {
  late final title = TextEditingController(text: widget.offer?.so('title') ?? '');
  late final message = TextEditingController(text: widget.offer?.so('message') ?? '');
  late List<String> ids = widget.offer?.ls('product_ids') ?? [];
  late DateTime? start = DateTime.tryParse(widget.offer?.so('start_date') ?? '')?.toLocal();
  late DateTime? end = DateTime.tryParse(widget.offer?.so('end_date') ?? '')?.toLocal();
  late bool show = widget.offer?.raw['show_on_storefront'] != false;
  Map<String, Facts> names = {};
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _names();
  }

  Future<void> _names() async {
    if (ids.isEmpty) return;
    try {
      final all = (await widget.api.products(limit: 50)).l('items');
      if (mounted) setState(() => names = {for (final p in all) p.s('id'): p});
    } catch (_) {/* rows show without names until the list loads */}
  }

  Future<void> _select() async {
    final c = BuilderController(widget.api);
    final r = await Navigator.of(context).push<List<String>>(MaterialPageRoute(builder: (_) => SelectProductsScreen(api: widget.api, c: c, selected: ids)));
    if (r != null) { setState(() => ids = r); _names(); }
  }

  Future<void> _save() async {
    setState(() => busy = true);
    try {
      await widget.api.saveOffer({
        if (widget.offer != null) 'id': widget.offer!.s('id'),
        if (widget.offer != null) 'version': widget.offer!.so('version'),
        'title': title.text.trim(),
        'message': message.text.trim().isEmpty ? null : message.text.trim(),
        'product_ids': ids,
        'start_date': start == null ? null : DateTime.utc(start!.year, start!.month, start!.day).toIso8601String(),
        'end_date': end == null ? null : DateTime.utc(end!.year, end!.month, end!.day, 23, 59, 59).toIso8601String(),
        'show_on_storefront': show,
      });
      if (mounted) { showToast(context, 'Offer saved.'); Navigator.of(context).pop(); }
    } catch (e) {
      if (mounted) { setState(() => busy = false); sfToast(context, e); }
    }
  }

  Future<void> _act(String action, String done) async {
    try {
      await widget.api.actOffer(widget.offer!.s('id'), action);
      if (mounted) { showToast(context, done); Navigator.of(context).pop(); }
    } catch (e) {
      if (mounted) sfToast(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.offer;
    final phase = o?.so('phase');
    return SfPage(
      title: 'Offers & Promotions',
      trailing: o == null ? null : PopupMenuButton<String>(
        tooltip: 'More',
        onSelected: (v) => switch (v) { 'pause' => _act('pause', 'Offer paused.'), 'resume' => _act('resume', 'Offer resumed.'), 'end' => _act('end', 'Offer ended.'), _ => _act('delete', 'Offer deleted.') },
        itemBuilder: (_) => [
          if (phase == 'paused') const PopupMenuItem(value: 'resume', child: Text('Resume offer')) else if (phase == 'live' || phase == 'scheduled') const PopupMenuItem(value: 'pause', child: Text('Pause offer')),
          if (phase != 'ended') const PopupMenuItem(value: 'end', child: Text('End offer')),
          const PopupMenuItem(value: 'delete', child: Text('Delete offer')),
        ],
      ),
      bottom: SfSave('Save Offers', busy: busy, onPressed: title.text.trim().isEmpty ? null : _save),
      children: [
        const SfLabel('Section Title', top: 4),
        SfField(controller: title, maxLength: 40, hint: 'Section title', onChanged: (_) => setState(() {})),
        const SfLabel('Promotion Message', top: 8),
        SfField(controller: message, maxLength: 60, hint: 'Promotion message'),
        const SfLabel('Products on Offer'),
        for (final id in ids)
          SfCard(
            child: Row(children: [
              SfThumb(names[id]?.so('image_url'), size: 44),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(names[id]?.s('name') ?? 'Product', style: inter(14, 500)), if (names[id] != null) Text(rs(names[id]!.no('price_minor')), style: inter(14, 700))])),
              if (names[id]?.no('discount_pct') != null) Text('${names[id]!.n('discount_pct')}% OFF', style: inter(12, 700, color: const Color(0xFF16803C))),
              IconButton(tooltip: 'Remove from offer', onPressed: () => setState(() => ids = ids.where((x) => x != id).toList()), icon: const Icon(LucideIcons.x, size: 16)),
            ]),
          ),
        SfSoft('Select Products', icon: LucideIcons.plus, onPressed: _select),
        Row(children: [
          _DateBox(label: 'Start Date', value: start, onTap: () async { final d = await _pickDay(context, start); if (d != null) setState(() => start = d); }),
          const SizedBox(width: 14),
          _DateBox(label: 'End Date', value: end, onTap: () async { final d = await _pickDay(context, end); if (d != null) setState(() => end = d); }),
        ]),
        const SizedBox(height: 8),
        SfToggle(title: 'Show offers on storefront', value: show, onChanged: (v) => setState(() => show = v)),
      ],
    );
  }
}

/// Ads of this business and where each stands. A partner asks for an ad; Proviyaa approves it, so "Pending review" is the first state.
class AdsScreen extends StatelessWidget {
  const AdsScreen({super.key, required this.api, this.categories = const [], this.picker = const ImagePicker()});
  final StorefrontApi api;
  final List<Facts> categories;
  final DocumentPicker picker;

  static String statusText(Facts a) => switch (a.s('status')) {
        'pending' => 'Pending review',
        'approved' => a.b('running') ? 'Running' : 'Approved',
        'live' => a.b('running') ? 'Running' : 'Approved',
        'rejected' => 'Rejected',
        'ended' => 'Ended',
        final s => s,
      };

  @override
  Widget build(BuildContext context) => SfLoader<List<Facts>>(
        load: api.ads,
        builder: (ctx, ads, reload) => SfPage(
          title: 'Ads',
          subtitle: 'Boost your visibility with ads',
          bottom: SfSave('New ad', onPressed: () async {
            await Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => AdEditScreen(api: api, categories: categories, picker: picker)));
            reload();
          }),
          children: [
            if (ads.isEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('No ads yet. Proviyaa reviews every ad before it runs.', style: inter(14, 400, color: kMuted))),
            for (final a in ads)
              SfCard(
                onTap: () async {
                  await Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => AdEditScreen(api: api, ad: a, categories: categories, picker: picker)));
                  reload();
                },
                child: Row(children: [
                  SfThumb(a.so('image_url'), size: 52, width: 84),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(a.s('title'), style: inter(15, 700)),
                    Text('${dayText(a.so('starts_on'))} – ${dayText(a.so('ends_on'))} · ${rs(a.no('daily_budget_minor'))}/day', style: inter(12.5, 400, color: kMuted)),
                    if (a.s('status') == 'rejected' && a.s('review_note').isNotEmpty) Text(a.s('review_note'), style: inter(12.5, 500, color: kError)),
                  ])),
                  TagChip(statusText(a)),
                ]),
              ),
          ],
        ),
      );
}

/// Figma "Ads": picture, title (40), message (60), link to a category or product, daily budget, dates, enable. Saving sends it for review.
class AdEditScreen extends StatefulWidget {
  const AdEditScreen({super.key, required this.api, this.ad, this.categories = const [], this.picker = const ImagePicker()});
  final StorefrontApi api;
  final Facts? ad;
  final List<Facts> categories;
  final DocumentPicker picker;
  @override
  State<AdEditScreen> createState() => _AdEditScreenState();
}

class _AdEditScreenState extends State<AdEditScreen> {
  late final BuilderController c = BuilderController(widget.api, picker: widget.picker);
  late final title = TextEditingController(text: widget.ad?.so('title') ?? '');
  late final message = TextEditingController(text: widget.ad?.so('message') ?? '');
  late final budget = TextEditingController(text: rupeeText(widget.ad?.no('daily_budget_minor')));
  late String? image = widget.ad?.so('image_id');
  late String linkType = widget.ad?.so('link_type') ?? 'none';
  late String? target = widget.ad?.so('link_target');
  late DateTime? start = DateTime.tryParse(widget.ad?.so('starts_on') ?? '');
  late DateTime? end = DateTime.tryParse(widget.ad?.so('ends_on') ?? '');
  late bool enabled = widget.ad?.raw['enabled'] != false;
  String? targetLabel;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    c.refreshImages().then((_) { if (mounted) setState(() {}); });
  }

  Future<void> _save() async {
    setState(() => busy = true);
    try {
      await widget.api.saveAd({
        if (widget.ad != null) 'id': widget.ad!.s('id'),
        if (widget.ad != null) 'version': widget.ad!.so('version'),
        'title': title.text.trim(),
        'message': message.text.trim().isEmpty ? null : message.text.trim(),
        'image_id': image,
        'link_type': linkType,
        'link_target': linkType == 'none' ? null : target,
        'daily_budget_minor': paise(budget.text),
        'starts_on': start == null ? null : isoDay(start!),
        'ends_on': end == null ? null : isoDay(end!),
        'enabled': enabled,
      });
      if (mounted) { showToast(context, 'Ad sent for review.'); Navigator.of(context).pop(); }
    } catch (e) {
      if (mounted) { setState(() => busy = false); sfToast(context, e); }
    }
  }

  Future<void> _act(String action, String done) async {
    try {
      await widget.api.actAd(widget.ad!.s('id'), action);
      if (mounted) { showToast(context, done); Navigator.of(context).pop(); }
    } catch (e) {
      if (mounted) sfToast(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ad = widget.ad;
    final cats = widget.categories.map((e) => e.s('name')).toList();
    return SfPage(
      title: 'Ads',
      subtitle: ad == null ? 'Boost your visibility with ads' : AdsScreen.statusText(ad),
      trailing: ad == null ? null : PopupMenuButton<String>(
        tooltip: 'More',
        onSelected: (v) => _act(v, v == 'end' ? 'Ad ended.' : 'Ad deleted.'),
        itemBuilder: (_) => [if (ad.s('status') == 'approved' || ad.s('status') == 'live') const PopupMenuItem(value: 'end', child: Text('End ad')) else const PopupMenuItem(value: 'delete', child: Text('Delete ad'))],
      ),
      bottom: SfSave(ad == null ? 'Save Ad' : 'Save Ad', busy: busy, onPressed: title.text.trim().isEmpty || image == null ? null : _save),
      children: [
        if (ad != null && ad.s('status') == 'rejected' && ad.s('review_note').isNotEmpty) SfNote('Rejected: ${ad.s('review_note')}', icon: LucideIcons.info),
        if (ad != null && (ad.s('status') == 'approved' || ad.s('status') == 'live')) const SfNote('Changing the content of an approved ad sends it for review again.', icon: LucideIcons.info),
        SfThumb(c.imageUrl(image) ?? widget.ad?.so('image_url'), size: 170, width: double.infinity, radius: 18),
        const SfLabel('Ad Image'),
        SfImagePicker(c: c, kind: 'ad', selectedId: image, onChanged: (v) => setState(() => image = v)),
        const SfLabel('Ad Title'),
        SfField(controller: title, maxLength: 40, hint: 'Ad title', onChanged: (_) => setState(() {})),
        const SfLabel('Ad Message', top: 8),
        SfField(controller: message, maxLength: 60, hint: 'Ad message'),
        const SfLabel('Link to', top: 8),
        SfChoice<String>(options: const [('none', 'None', null), ('category', 'Category', null), ('product', 'Product', null)], value: linkType, onChanged: (v) => setState(() { linkType = v; target = null; targetLabel = null; })),
        if (linkType == 'category') ...[
          const SfLabel('Select Category'),
          DropdownButtonFormField<String>(
            initialValue: cats.contains(target) ? target : null,
            isExpanded: true,
            hint: const Text('Choose a category'),
            items: [for (final n in cats) DropdownMenuItem(value: n, child: Text(n))],
            onChanged: (v) => setState(() => target = v),
            decoration: InputDecoration(filled: true, fillColor: const Color(0xFFFAFBF8), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kLine))),
          ),
        ],
        if (linkType == 'product') ...[
          const SfLabel('Select Product'),
          SfSoft(targetLabel ?? (target == null ? 'Choose a product' : 'Product chosen'), icon: LucideIcons.search, onPressed: () async {
            final p = await pickProduct(context, widget.api);
            if (p != null) setState(() { target = p.s('id'); targetLabel = p.s('name'); });
          }),
        ],
        const SfLabel('Daily Budget'),
        SfField(controller: budget, number: true, prefix: '₹'),
        Padding(padding: const EdgeInsets.only(top: 6), child: Text('Maximum amount to spend per day.', style: inter(13, 400, color: kMuted))),
        Row(children: [
          _DateBox(label: 'Start Date', value: start, onTap: () async { final d = await _pickDay(context, start); if (d != null) setState(() => start = d); }),
          const SizedBox(width: 14),
          _DateBox(label: 'End Date', value: end, onTap: () async { final d = await _pickDay(context, end); if (d != null) setState(() => end = d); }),
        ]),
        const SizedBox(height: 8),
        SfToggle(title: 'Enable ad', sub: 'Run during the selected dates', value: enabled, onChanged: (v) => setState(() => enabled = v)),
      ],
    );
  }
}
