import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../orders/order_widgets.dart' show TagChip;
import '../ui/theme.dart';
import 'builder_screen.dart';
import 'sf_widgets.dart';
import 'storefront_api.dart';

/// Where store links point. The server answers only the path (`/noice-store`); the domain is the app's setting.
const kStoreHost = 'onelocal.app';

/// The storefront as a customer would see it, drawn from the server's `sf_preview` answer. [theme] overrides the colours (Theme & Publish
/// previews unsaved colours). Ratings are not shown: the database holds no ratings for a store page yet.
class StorefrontCanvas extends StatelessWidget {
  const StorefrontCanvas({super.key, required this.facts, this.theme});
  final Facts facts;
  final Map<String, dynamic>? theme;

  Map<String, dynamic> get _theme => {...facts.m('theme').raw, ...?theme};

  @override
  Widget build(BuildContext context) {
    final t = _theme;
    final primary = hexColor(t['primary'] as String?), secondary = hexColor(t['secondary'] as String?), bg = hexColor(t['background'] as String?);
    final r = t['section_style'] == 'square' ? 0.0 : 16.0;
    final store = facts.m('store');
    final delivery = facts.m('delivery');
    final hours = facts.m('hours');
    final days = hours.l('days').map((d) => d.raw).toList();
    return Container(
      color: bg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final s in facts.l('sections')) _section(context, s, primary, secondary, r, delivery),
        Container(
          width: double.infinity,
          color: const Color(0xFFF7F8F6),
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(store.s('public_name'), style: inter(17, 700, color: secondary)),
            if (store.so('description') != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(store.s('description'), style: inter(13.5, 400, color: kMuted))),
            if (store.so('address_line') != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(store.s('address_line'), style: inter(12.5, 400, color: kMuted))),
            if (hours.b('show') && days.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(hoursSummary(days), style: inter(14, 400))),
            ..._deliveryLines(delivery).map((l) => Padding(padding: const EdgeInsets.only(top: 4), child: Text(l, style: inter(14, 400)))),
          ]),
        ),
      ]),
    );
  }

  static List<String> _deliveryLines(Facts d) {
    if (!d.b('configured')) return const [];
    final out = <String>[];
    if (d.b('home_delivery')) {
      out.add('Delivery within ${_km(d.no('radius_km'))} km${d.no('est_min_minutes') != null ? ' · ${d.n('est_min_minutes')}–${d.n('est_max_minutes')} min' : ''}');
      final fee = d.no('delivery_fee_minor');
      final free = d.no('free_above_minor');
      if (fee != null) out.add('${rs(fee)} delivery${free != null ? ' · Free above ${rs(free)}' : ''}');
      final min = d.no('min_order_minor');
      if (min != null) {
        out.add('Minimum order ${rs(min)}${d.b('pickup') ? ' · Store pickup available' : ''}');
      } else if (d.b('pickup')) {
        out.add('Store pickup available');
      }
    } else if (d.b('pickup')) {
      out.add('Store pickup only');
    }
    return out;
  }

  static String _km(num? v) => v == null ? '' : (v == v.roundToDouble() ? '${v.round()}' : '$v');

  Widget _section(BuildContext context, Facts s, Color primary, Color secondary, double r, Facts delivery) {
    final cfg = s.m('config');
    switch (s.s('type')) {
      case 'header':
        return Container(
          color: primary,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            Icon(LucideIcons.menu, size: 20, color: secondary),
            Expanded(child: Text(facts.m('store').s('public_name'), textAlign: TextAlign.center, style: inter(20, 800, color: secondary), maxLines: 1, overflow: TextOverflow.ellipsis)),
            Icon(LucideIcons.search, size: 20, color: secondary),
            const SizedBox(width: 12),
            Icon(LucideIcons.shoppingCart, size: 20, color: secondary),
          ]),
        );
      case 'banner':
        final slides = cfg.l('slides');
        if (slides.isEmpty) return const SizedBox.shrink();
        return SizedBox(height: 170, child: Stack(fit: StackFit.expand, children: [
          SfThumb(slides.first.so('image_url'), size: 170, width: double.infinity, radius: 0),
          if (slides.first.so('title') != null) Positioned(left: 14, bottom: 12, right: 14, child: Text(slides.first.s('title'), style: inter(18, 800, color: Colors.white, shadows: const [Shadow(blurRadius: 6, color: Colors.black54)]))),
        ]));
      case 'category_grid':
        final cats = cfg.l('categories');
        final cols = cfg.no('columns')?.toInt() ?? 3;
        return Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (s.so('title') != null) Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 8), child: Text(s.s('title'), style: inter(16, 700, color: secondary))),
            GridView.count(
              crossAxisCount: cols, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 0.95,
              children: [
                for (final c in cats)
                  Container(
                    decoration: BoxDecoration(color: const Color(0xFFFFF0A8), borderRadius: BorderRadius.circular(r)),
                    padding: const EdgeInsets.all(6),
                    child: Column(children: [Text(c.s('name'), textAlign: TextAlign.center, style: inter(12, 700, color: const Color(0xFF1E2A78)), maxLines: 2, overflow: TextOverflow.ellipsis), const SizedBox(height: 4), Expanded(child: SfThumb(c.so('image_url'), size: 60, width: double.infinity, radius: 8))]),
                  ),
              ],
            ),
          ]),
        );
      case 'product_list':
      case 'brand':
      case 'deals':
        final items = cfg.l('items');
        if (s.s('type') == 'deals' && cfg.raw['offer_live'] == false) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.so('title') ?? cfg.so('brand') ?? '', style: inter(16, 700, color: secondary)),
            if (s.s('type') == 'deals' && cfg.so('message') != null) Text(cfg.s('message'), style: inter(13, 400, color: kMuted)),
            const SizedBox(height: 8),
            if (items.isEmpty) Text('No products in this section yet.', style: inter(13, 400, color: kMuted))
            else if (cfg.s('layout') == 'list')
              for (final p in items) Padding(padding: const EdgeInsets.only(bottom: 8), child: _productRow(p, cfg, primary, r))
            else
              SizedBox(height: 232, child: ListView(scrollDirection: Axis.horizontal, children: [for (final p in items) Padding(padding: const EdgeInsets.only(right: 10), child: _productCard(p, cfg, delivery, primary, r))])),
          ]),
        );
      case 'custom_card':
        return Padding(
          padding: const EdgeInsets.all(10),
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(r), color: Colors.white, border: Border.all(color: kLine)),
            clipBehavior: Clip.antiAlias,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (cfg.so('image_url') != null) SfThumb(cfg.so('image_url'), size: 120, width: double.infinity, radius: 0),
              Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [if (cfg.so('heading') != null) Text(cfg.s('heading'), style: inter(16, 700)), if (cfg.so('body') != null) Text(cfg.s('body'), style: inter(13.5, 400, color: kMuted))])),
            ]),
          ),
        );
      case 'divider':
        return SizedBox(height: (cfg.no('height') ?? 16).toDouble());
      case 'ads':
        final ad = cfg.mo('ad');
        if (ad == null) return const SizedBox.shrink();
        return Padding(padding: const EdgeInsets.all(10), child: Stack(children: [
          SfThumb(ad.so('image_url'), size: 120, width: double.infinity, radius: r),
          Positioned(top: 8, left: 8, child: TagChip(ad.b('running') ? 'Ad' : 'Ad · not running yet')),
        ]));
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _productCard(Facts p, Facts cfg, Facts delivery, Color primary, double r) => Container(
        width: 150,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(r), border: Border.all(color: kLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SfThumb(p.so('image_url'), size: 84, width: double.infinity, radius: 8),
          if (cfg.raw['show_discount'] != false && p.no('discount_pct') != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('${p.n('discount_pct')}% OFF', style: inter(12, 700, color: const Color(0xFF16803C)))),
          Text(p.s('name'), maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(13, 700)),
          if (cfg.raw['show_delivery_time'] != false && delivery.no('est_min_minutes') != null) Text('${delivery.n('est_min_minutes')}–${delivery.n('est_max_minutes')} min', style: inter(11.5, 400, color: kMuted)),
          const Spacer(),
          Row(children: [
            Expanded(child: Text(rs(p.no('price_minor')), style: inter(14, 700))),
            if (cfg.raw['show_add_button'] != false) Container(width: 28, height: 28, decoration: BoxDecoration(color: primary, borderRadius: BorderRadius.circular(8)), child: const Icon(LucideIcons.plus, size: 16)),
          ]),
        ]),
      );

  Widget _productRow(Facts p, Facts cfg, Color primary, double r) => Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(r), border: Border.all(color: kLine)),
        child: Row(children: [
          SfThumb(p.so('image_url'), size: 52),
          const SizedBox(width: 10),
          Expanded(child: Text(p.s('name'), style: inter(14, 600))),
          Text(rs(p.no('price_minor')), style: inter(14, 700)),
          if (cfg.raw['show_add_button'] != false) Padding(padding: const EdgeInsets.only(left: 8), child: Container(width: 28, height: 28, decoration: BoxDecoration(color: primary, borderRadius: BorderRadius.circular(8)), child: const Icon(LucideIcons.plus, size: 16))),
        ]),
      );
}

/// Publishes the saved draft; on success opens "Your page is live!". Returns whether it went live.
Future<bool> publishNow(BuildContext context, StorefrontApi api, BuilderController c, {Facts? preview}) async {
  try {
    final r = await api.publish(expectedVersion: c.publishedVersion, draftVersion: c.draftVersion);
    String? cover;
    for (final s in preview?.l('sections') ?? const <Facts>[]) {
      if (s.s('type') == 'banner' && s.m('config').l('slides').isNotEmpty) { cover = s.m('config').l('slides').first.so('image_url'); break; }
    }
    if (!context.mounted) return true;
    await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => LiveScreen(result: r, coverUrl: cover)));
    return true;
  } on StorefrontException catch (e) {
    if (context.mounted) showToast(context, e.stale ? 'The page changed since you last looked. Reload the builder and review it before publishing.' : e.message);
    return false;
  } catch (e) {
    if (context.mounted) sfToast(context, e);
    return false;
  }
}

/// Figma "Live Preview": the page as customers see it, then Edit or Publish.
class PreviewScreen extends StatefulWidget {
  const PreviewScreen({super.key, required this.api, required this.c});
  final StorefrontApi api;
  final BuilderController c;
  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  Facts? facts;
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return SfPage(
      title: 'Live Preview',
      bottom: Row(children: [
        Expanded(child: SfSoft('Edit', onPressed: () => Navigator.of(context).pop())),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: SfSave(
            c.unpublished ? 'Publish' : 'Up to date',
            lime: true,
            busy: busy,
            onPressed: !c.canPublish || !c.unpublished || facts == null ? null : () async {
              setState(() => busy = true);
              final ok = await publishNow(context, widget.api, c, preview: facts);
              if (!ok && mounted) setState(() => busy = false);
            },
          ),
        ),
      ]),
      children: [
        if (!c.canPublish) const SfNote('Your role can edit the page but cannot publish it. Ask the owner or a manager to publish.', icon: LucideIcons.info),
        SfLoader<Facts>(
          load: () async {
            final f = await widget.api.preview();
            if (mounted) setState(() => facts = f);
            return f;
          },
          builder: (ctx, f, _) => Container(
            margin: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(border: Border.all(color: kInk, width: 3), borderRadius: BorderRadius.circular(22)),
            clipBehavior: Clip.antiAlias,
            child: StorefrontCanvas(facts: f),
          ),
        ),
      ],
    );
  }
}

/// Figma "Theme & Publish": three colours, section style, a live preview of the unsaved colours, "Save & Publish".
class ThemeScreen extends StatefulWidget {
  const ThemeScreen({super.key, required this.api, required this.c});
  final StorefrontApi api;
  final BuilderController c;
  @override
  State<ThemeScreen> createState() => _ThemeScreenState();
}

class _ThemeScreenState extends State<ThemeScreen> {
  late final primary = TextEditingController(text: '${widget.c.theme['primary'] ?? '#76EC00'}');
  late final secondary = TextEditingController(text: '${widget.c.theme['secondary'] ?? '#0A0A0A'}');
  late final background = TextEditingController(text: '${widget.c.theme['background'] ?? '#FFFFFF'}');
  late String style = '${widget.c.theme['section_style'] ?? 'rounded'}';
  bool busy = false;
  Facts? facts;

  static final _hex = RegExp(r'^#[0-9A-Fa-f]{6}$');
  bool get valid => [primary, secondary, background].every((c) => _hex.hasMatch(c.text.trim()));
  Map<String, dynamic> get theme => {'primary': primary.text.trim().toUpperCase(), 'secondary': secondary.text.trim().toUpperCase(), 'background': background.text.trim().toUpperCase(), 'section_style': style};

  Future<void> _save({required bool publish}) async {
    setState(() => busy = true);
    final c = widget.c;
    if (!await c.setTheme(theme)) {
      if (mounted) { setState(() => busy = false); showToast(context, c.error ?? 'Could not save the theme.'); }
      return;
    }
    if (!mounted) return;
    if (!publish) { Navigator.of(context).pop(); return; }
    final ok = await publishNow(context, widget.api, c, preview: facts);
    if (!ok && mounted) setState(() => busy = false);
  }

  Widget _row(String label, TextEditingController ctl) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          Expanded(child: Text(label, style: inter(16, 400))),
          SizedBox(
            width: 170,
            child: TextField(
              controller: ctl,
              onChanged: (_) => setState(() {}),
              style: inter(15, 400, color: kMuted),
              decoration: InputDecoration(
                filled: true, fillColor: kSfField, isDense: true,
                prefixIcon: Padding(padding: const EdgeInsets.all(10), child: Container(width: 22, height: 22, decoration: BoxDecoration(color: hexColor(ctl.text.trim()), shape: BoxShape.circle, border: Border.all(color: kLine)))),
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                errorText: _hex.hasMatch(ctl.text.trim()) ? null : 'Use #RRGGBB',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
            ),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final can = widget.c.canPublish;
    return SfPage(
      title: 'Theme & Publish',
      bottom: SfSave(can ? 'Save & Publish' : 'Save Theme', lime: can, busy: busy, onPressed: valid ? () => _save(publish: can) : null),
      children: [
        _row('Primary Color', primary),
        _row('Secondary Color', secondary),
        _row('Background Color', background),
        const SfLabel('Section Style'),
        SfChoice<String>(options: const [('rounded', 'Rounded', null), ('square', 'Square', null)], value: style, onChanged: (v) => setState(() => style = v)),
        const SfLabel('Preview Changes'),
        SfLoader<Facts>(
          load: () async => facts = await widget.api.preview(),
          builder: (_, f, _) => Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(22), border: Border.all(color: kLine)),
            clipBehavior: Clip.antiAlias,
            child: StorefrontCanvas(facts: f, theme: valid ? theme : null),
          ),
        ),
      ],
    );
  }
}

/// Figma "Page Status": "Your page is live!", the store link, copy it, open it, back to the builder.
class LiveScreen extends StatelessWidget {
  const LiveScreen({super.key, required this.result, this.coverUrl});
  final Facts result;
  final String? coverUrl;

  String get link => '$kStoreHost${result.s('path')}';

  @override
  Widget build(BuildContext context) => SfPage(
        title: 'Page Status',
        bottom: Column(mainAxisSize: MainAxisSize.min, children: [
          SfSave('View Live Store', lime: true, onPressed: () async {
            final ok = await launchUrl(Uri.parse('https://$link'), mode: LaunchMode.externalApplication).catchError((_) => false);
            if (!ok && context.mounted) showToast(context, 'Could not open the store. Copy the link instead.');
          }),
          const SizedBox(height: 10),
          SfSoft('Back to Builder', onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst || r.settings.name == 'storefront')),
        ]),
        children: [
          const SizedBox(height: 16),
          Center(child: Container(width: 120, height: 120, decoration: const BoxDecoration(color: kSfLimeSoft, shape: BoxShape.circle), child: Center(child: Container(width: 72, height: 72, decoration: const BoxDecoration(color: kSfLime, shape: BoxShape.circle), child: const Icon(LucideIcons.check, size: 34))))),
          const SizedBox(height: 18),
          Text('Your page is live!', textAlign: TextAlign.center, style: inter(28, 800)),
          const SizedBox(height: 10),
          Text('${result.s('store_name')} is now on OneLocal. Customers can explore your catalog, offers and delivery options.', textAlign: TextAlign.center, style: inter(15, 400, color: kMuted, height: 1.45)),
          const SizedBox(height: 22),
          SfCard(
            padding: EdgeInsets.zero,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ClipRRect(borderRadius: const BorderRadius.vertical(top: Radius.circular(18)), child: SfThumb(coverUrl, size: 150, width: double.infinity, radius: 0)),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [Expanded(child: Text(result.s('store_name'), style: inter(16, 700))), const TagChip('Live')]),
                  const SizedBox(height: 4),
                  Text(link, style: inter(14, 400, color: kMuted)),
                ]),
              ),
            ]),
          ),
          SfSoft('Copy Store Link', icon: LucideIcons.copy, onPressed: () async {
            await Clipboard.setData(ClipboardData(text: 'https://$link'));
            if (context.mounted) showToast(context, 'Store link copied.');
          }),
          const SizedBox(height: 14),
          Row(children: [
            const Icon(LucideIcons.pencil, size: 16),
            const SizedBox(width: 10),
            Expanded(child: Text('You can edit your page anytime. Save and publish to make your changes live.', style: inter(13.5, 400, color: kMuted))),
          ]),
        ],
      );
}
