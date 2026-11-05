import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/net_guard.dart';
import '../inventory/inventory_api.dart' show Facts;
import '../menu/menu_api.dart';
import '../money/money_style.dart' show moneyCard;
import '../orders/order_widgets.dart' show TagChip;
import '../storefront/growth_screens.dart' show OfferEditScreen, OffersScreen;
import '../storefront/sf_widgets.dart';
import '../storefront/storefront_api.dart';
import '../ui/theme.dart';
import 'experience_api.dart';
import 'experience_screen.dart' show ExperienceController;

// The three cards of the builder beside the page itself (spec part 2, contract D): Create with AI at the top, and under the blocks the
// dishes with their stock switches and the live offers. The page never holds a price or an offer: dishes, prices, stock and offers are read
// from the menu and the offers each time a guest opens the page.

/// "Create with AI": an optional style line, then the server fills the DRAFT (look, colours, welcome words, chef's picks, order labels)
/// from the business profile and the menu. The preview updates at once; nothing is live until Publish. One Undo brings the page back.
class GxAiCard extends StatefulWidget {
  const GxAiCard({super.key, required this.c});
  final ExperienceController c;
  @override
  State<GxAiCard> createState() => _GxAiCardState();
}

class _GxAiCardState extends State<GxAiCard> {
  final _style = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _style.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _error = null);
    final msg = await widget.c.createWithAi(_style.text);
    if (mounted) setState(() => _error = msg);
  }

  Future<void> _undo() async {
    final msg = await widget.c.undoAi();
    if (!mounted) return;
    showToast(context, msg ?? 'Your page is back as it was before AI.');
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final note = c.aiNote;
    return Container(
      key: const ValueKey('gx-ai-card'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: moneyCard(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: kSfLimeSoft, borderRadius: BorderRadius.circular(12)),
            child: const Icon(LucideIcons.wandSparkles, size: 19, color: kInk),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Create with AI', style: inter(16, 800)),
              const SizedBox(height: 2),
              Text('AI reads your business profile and menu and fills the look, colours, welcome words and chef\'s picks. Nothing goes live until you publish.',
                  style: inter(12.5, 500, color: kMuted, height: 1.35)),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        SfField(key: const ValueKey('gx-ai-style'), controller: _style, maxLength: 200, hint: 'Style (optional), e.g. warm bakery, rustic', label: 'Style'),
        const SizedBox(height: 8),
        if (c.aiBusy)
          Padding(
            key: const ValueKey('gx-ai-busy'),
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Reading your menu and filling the page…', style: inter(13, 600, color: kMuted)),
              const SizedBox(height: 6),
              const LinearProgressIndicator(color: kInk, backgroundColor: kLine),
            ]),
          ),
        SfSave('Create with AI', key: const ValueKey('gx-ai-create'), busy: c.aiBusy, onPressed: c.busy ? null : _create),
        if (_error != null)
          Container(
            key: const ValueKey('gx-ai-error'),
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(14)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(LucideIcons.circleAlert, size: 17, color: Color(0xFFB91C1C)),
              const SizedBox(width: 8),
              Expanded(child: Text(_error!, style: inter(13, 600, color: const Color(0xFFB91C1C), height: 1.35))),
            ]),
          )
        else if (note != null)
          Container(
            key: const ValueKey('gx-ai-note'),
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.fromLTRB(12, 12, 6, 6),
            decoration: BoxDecoration(color: kSfLimeSoft, borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(LucideIcons.sparkles, size: 17, color: kInk),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('AI filled your page — review and Publish', style: inter(14, 800)),
                    const SizedBox(height: 3),
                    Text(note, key: const ValueKey('gx-ai-note-text'), style: inter(12.5, 500, height: 1.35)),
                  ]),
                ),
              ]),
              if (c.canUndoAi)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const ValueKey('gx-ai-undo'),
                    onPressed: c.busy ? null : _undo,
                    icon: const Icon(LucideIcons.undo2, size: 16),
                    label: Text('Undo', style: inter(13, 700)),
                  ),
                ),
            ]),
          ),
      ]),
    );
  }
}

/// "Dishes & stock": every dish with its photo, price and an In stock switch (`rst_menu_stock_set`). A switch moves at once and moves back
/// when the server says no. Import menu and the full Menu screen open from here. [generation] changes when the menu changed elsewhere.
class GxStockCard extends StatefulWidget {
  const GxStockCard({super.key, required this.menu, required this.generation, required this.onImport, required this.onOpenMenu});
  final MenuApi menu;
  final int generation;
  final VoidCallback onImport, onOpenMenu;
  @override
  State<GxStockCard> createState() => _GxStockCardState();
}

class _GxStockCardState extends State<GxStockCard> {
  static const _few = 8;
  MenuData? _data;
  String? _error;
  bool _all = false;
  final _stock = <String, bool>{};
  final _saving = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(GxStockCard old) {
    super.didUpdateWidget(old);
    if (old.generation != widget.generation) _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.menu.menu();
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = null;
        _stock.clear();
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorSentence(e));
    }
  }

  Future<void> _set(MenuDish d, bool on) async {
    setState(() {
      _stock[d.id] = on;
      _saving.add(d.id);
    });
    try {
      await widget.menu.setStock(dishId: d.id, inStock: on);
    } catch (e) {
      if (!mounted) return;
      setState(() => _stock[d.id] = !on);
      showToast(context, errorSentence(e));
    } finally {
      if (mounted) setState(() => _saving.remove(d.id));
    }
  }

  Widget _row(MenuDish d, String category, bool canEdit) {
    final on = _stock[d.id] ?? d.inStock;
    return Padding(
      key: ValueKey('gx-dish-${d.id}'),
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Opacity(opacity: on ? 1 : 0.5, child: SfThumb(d.imageUrl, size: 44, radius: 10, icon: LucideIcons.soup)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14.5, 700, color: on ? kInk : kMuted)),
            Text([rs(d.priceMinor), category, if (!on) 'Out of stock'].where((s) => s.isNotEmpty).join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 500, color: kMuted)),
          ]),
        ),
        Semantics(
          label: 'In stock: ${d.name}',
          toggled: on,
          child: Switch(
            key: ValueKey('gx-stock-${d.id}'),
            value: on,
            onChanged: canEdit && !_saving.contains(d.id) ? (v) => _set(d, v) : null,
            activeThumbColor: Colors.white,
            activeTrackColor: kSfLime,
            inactiveTrackColor: const Color(0xFFD1D5DB),
            inactiveThumbColor: Colors.white,
            trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final dishes = [for (final c in data?.categories ?? const <MenuCategory>[]) for (final d in c.items) (d, c.name)];
    final out = dishes.where((x) => !(_stock[x.$1.id] ?? x.$1.inStock)).length;
    final shown = _all ? dishes : dishes.take(_few).toList();
    return Container(
      key: const ValueKey('gx-stock-card'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: moneyCard(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(LucideIcons.utensils, size: 19, color: kInk),
          const SizedBox(width: 10),
          Expanded(child: Text('Dishes & stock', style: inter(16, 800))),
          if (data != null) Text('${dishes.length} dishes${out > 0 ? ' · $out out' : ''}', key: const ValueKey('gx-stock-count'), style: inter(12, 600, color: kMuted)),
        ]),
        const SizedBox(height: 4),
        Text('Prices and photos come from your menu. Switch a dish off when it runs out: guests cannot order it until you switch it back on.',
            style: inter(12.5, 500, color: kMuted, height: 1.35)),
        const SizedBox(height: 8),
        if (_error != null) ...[
          Text(_error!, key: const ValueKey('gx-stock-error'), style: inter(13, 500, color: kError)),
          TextButton(onPressed: _load, child: const Text('Try again')),
        ] else if (data == null)
          const Padding(padding: EdgeInsets.all(12), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: kInk))))
        else if (dishes.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('No dishes yet. Import your menu, or add dishes in the Menu.', style: inter(13.5, 500)))
        else ...[
          for (final (d, cat) in shown) _row(d, cat, data.canEdit),
          if (!data.canEdit) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Your role cannot change stock. Ask the owner or a manager.', key: const ValueKey('gx-stock-readonly'), style: inter(12.5, 500, color: kMuted))),
          if (dishes.length > _few)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('gx-stock-more'),
                onPressed: () => setState(() => _all = !_all),
                child: Text(_all ? 'Show fewer' : 'Show all ${dishes.length} dishes', style: inter(13, 700)),
              ),
            ),
        ],
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: SfSoft('Import menu', key: const ValueKey('gx-import'), icon: LucideIcons.clipboardPaste, onPressed: widget.onImport)),
          const SizedBox(width: 8),
          Expanded(child: SfSoft('Full menu', key: const ValueKey('gx-open-menu'), icon: LucideIcons.bookOpen, onPressed: widget.onOpenMenu)),
        ]),
      ]),
    );
  }
}

/// "Offers": the live and scheduled offers (`sf_offer_list`) and the active coupons (`pos_coupon_list`), with Create offer opening the
/// existing offer editor. Offers show on the guest page by themselves; they are never typed into the page's words.
class GxOffersCard extends StatefulWidget {
  const GxOffersCard({super.key, required this.storefront, required this.api, this.today});
  final StorefrontApi storefront;
  final ExperienceApi api;

  /// Tests fix "now" for coupon end dates.
  final DateTime? today;
  @override
  State<GxOffersCard> createState() => _GxOffersCardState();
}

class _GxOffersCardState extends State<GxOffersCard> {
  List<Facts>? _offers;
  List<Facts> _coupons = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<Facts>? offers;
    String? error;
    try {
      offers = await widget.storefront.offers();
    } catch (e) {
      error = errorSentence(e);
    }
    var coupons = const <Facts>[];
    try {
      coupons = await widget.api.coupons();
    } catch (_) {/* a role that may not see coupons sees the offers only */}
    if (!mounted) return;
    setState(() {
      _offers = offers ?? const [];
      _coupons = coupons;
      _error = error;
    });
  }

  Future<void> _edit([Facts? offer]) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OfferEditScreen(api: widget.storefront, offer: offer)));
    if (mounted) await _load();
  }

  Future<void> _all() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OffersScreen(api: widget.storefront)));
    if (mounted) await _load();
  }

  static String _couponTerms(Facts c) {
    final v = c.n('value');
    final amount = v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(2);
    final min = c.no('min_order');
    return [c.s('kind') == 'percent' ? '$amount% off' : '₹$amount off', if (min != null && min > 0) 'orders from ₹${min.round()}', if (c.s('label').isNotEmpty) c.s('label')].join(' · ');
  }

  Widget _row({required Key key, required IconData icon, required String title, required String sub, required String chip, VoidCallback? onTap}) => Material(
        key: key,
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: const Color(0xFFFFF4E5), borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 17, color: const Color(0xFFB45309)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14.5, 700)),
                  if (sub.isNotEmpty) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 500, color: kMuted)),
                ]),
              ),
              TagChip(chip),
              if (onTap != null) const Icon(LucideIcons.chevronRight, size: 16, color: kMuted),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final now = widget.today ?? DateTime.now();
    final offers = (_offers ?? const <Facts>[]).where((o) => o.s('phase') == 'live' || o.s('phase') == 'scheduled').toList();
    final coupons = _coupons.where((c) => c.b('active') && (c.t('ends_at') == null || c.t('ends_at')!.isAfter(now))).toList();
    return Container(
      key: const ValueKey('gx-offers-card'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: moneyCard(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(LucideIcons.tag, size: 19, color: kInk),
          const SizedBox(width: 10),
          Expanded(child: Text('Offers', style: inter(16, 800))),
          TextButton(key: const ValueKey('gx-offers-all'), onPressed: _all, child: Text('All offers', style: inter(13, 700))),
        ]),
        Container(
          key: const ValueKey('gx-offers-note'),
          margin: const EdgeInsets.only(top: 4, bottom: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xFFF7F8F6), borderRadius: BorderRadius.circular(12)),
          child: Text(
            'Live offers and coupons show on your guest page by themselves, with their own dates (an offer shows when its "Show offers on storefront" switch is on). '
            'Never type an offer or a price into the welcome words: that sends your page to OneLocal review.',
            style: inter(12.5, 500, height: 1.35),
          ),
        ),
        if (_offers == null)
          const Padding(padding: EdgeInsets.all(12), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: kInk))))
        else ...[
          if (_error != null) Text(_error!, key: const ValueKey('gx-offers-error'), style: inter(13, 500, color: kError)),
          for (final o in offers)
            _row(
              key: ValueKey('gx-offer-${o.s('id')}'),
              icon: LucideIcons.tag,
              title: o.s('title'),
              sub: o.so('message') ?? (o.so('end_date') == null ? '' : 'Until ${dayText(o.so('end_date'))}'),
              chip: o.s('phase') == 'live' ? 'Live' : 'Scheduled',
              onTap: o.raw['editable'] == true ? () => _edit(o) : null,
            ),
          for (final c in coupons)
            _row(key: ValueKey('gx-coupon-${c.s('code')}'), icon: LucideIcons.ticket, title: c.s('code'), sub: _couponTerms(c), chip: 'Coupon'),
          if (_error == null && offers.isEmpty && coupons.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text('No live offers or coupons right now.', key: const ValueKey('gx-offers-empty'), style: inter(13.5, 500))),
        ],
        const SizedBox(height: 6),
        SfSoft('Create offer', key: const ValueKey('gx-offer-create'), icon: LucideIcons.plus, onPressed: () => _edit()),
      ]),
    );
  }
}
