import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ads/ads_screens.dart';
import '../home/home_nav.dart';
import '../inventory/inventory_api.dart' show Facts;
import '../money/money_style.dart';
import '../ui/app_header.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'builder_screen.dart' show StorePageBuilder;
import 'growth_screens.dart' show OffersScreen;
import 'menu_link_screen.dart';
import 'settings_screens.dart' show DeliveryScreen, HoursScreen, ProfileScreen;
import 'storefront_api.dart';

// Page Manager (founder, 28 Oct 2026; was "Business profile"): everything about the shop's page on OneLocal from one dashboard — how far
// the page is set up, whether it is live, its link, Ads and Offers up front, then the profile, the page, hours, delivery, link and reviews.

class PageManagerScreen extends StatefulWidget {
  const PageManagerScreen({super.key, required this.api});
  final StorefrontApi api;
  @override
  State<PageManagerScreen> createState() => _PageManagerScreenState();
}

class _PageManagerScreenState extends State<PageManagerScreen> {
  Facts? _settings, _builder;
  List<Facts> _offers = const [], _ads = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // the settings are needed; the rest only add counts and the live status, so a refusal there leaves them out
      final settings = await widget.api.settings();
      final rest = await Future.wait<Object?>([
        widget.api.builder().then<Object?>((v) => v).catchError((Object _) => null),
        widget.api.offers().then<Object?>((v) => v).catchError((Object _) => null),
        widget.api.ads().then<Object?>((v) => v).catchError((Object _) => null),
      ]);
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _builder = rest[0] as Facts?;
        _offers = (rest[1] as List<Facts>?) ?? const [];
        _ads = (rest[2] as List<Facts>?) ?? const [];
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = tr('Could not load your page. Check your connection.'));
    }
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  String _hoursToday(Facts hours) {
    if (!hours.b('configured')) return tr('Not set yet');
    final today = DateTime.now().weekday;
    final d = hours.l('days').where((d) => d.n('day').toInt() == today).firstOrNull;
    if (d == null) return tr('Set your hours');
    return d.b('open') ? '${tr('Today')} ${d.s('opens')} – ${d.s('closes')}' : '${tr('Closed today')} (${_days[today - 1]})';
  }

  String _delivery(Facts dl) {
    if (!dl.b('configured')) return tr('Not set yet');
    final parts = [
      if (dl.b('home_delivery')) '${dl.n('radius_km').toStringAsFixed(dl.n('radius_km') % 1 == 0 ? 0 : 1)} km',
      if (dl.b('pickup')) tr('Pickup'),
      if ((dl.no('min_order_minor') ?? 0) > 0) '${tr('min')} ₹${(dl.n('min_order_minor') / 100).round()}',
    ];
    return parts.isEmpty ? tr('Not set yet') : parts.join(' · ');
  }

  bool _isOn(Facts f) {
    final s = '${f.s('phase')} ${f.s('status')}'.toLowerCase();
    return f.b('running') || s.contains('live') || s.contains('active') || s.contains('running');
  }

  // ---------------------------------------------------------------------------------------------------------------- the top card
  Widget _hero(Facts p, Facts hours, Facts delivery) {
    final name = p.s('public_name').isEmpty ? (HomeNav.storeName ?? tr('Your shop')) : p.s('public_name');
    final slug = p.so('store_slug');
    final source = _builder?.s('source') ?? '';
    final (status, statusColor) = slug == null || slug.isEmpty
        ? (tr('Not published yet'), const Color(0xFFFFB547))
        : source == 'draft'
            ? (tr('Changes not published'), const Color(0xFFFFB547))
            : (tr('Live on OneLocal'), kMoneyLime);
    // what makes a page ready, in the order a shop does it
    final steps = [
      (tr('Name'), p.s('public_name').isNotEmpty),
      (tr('Logo'), (p.so('logo_url') ?? p.so('logo_path')) != null),
      (tr('Banner'), (p.so('cover_url') ?? p.so('cover_path')) != null),
      (tr('About'), p.s('description').isNotEmpty),
      (tr('Hours'), hours.b('configured')),
      (tr('Delivery'), delivery.b('configured')),
      (tr('Store link'), slug != null && slug.isNotEmpty),
    ];
    final done = steps.where((s) => s.$2).length;
    final missing = steps.where((s) => !s.$2).map((s) => s.$1).toList();
    final logo = p.so('logo_url');
    return MoneyDarkCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 52,
            height: 52,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: kMoneyLime, borderRadius: BorderRadius.circular(16)),
            alignment: Alignment.center,
            child: logo != null
                ? Image.network(logo, fit: BoxFit.cover, width: 52, height: 52, errorBuilder: (_, _, _) => const Icon(LucideIcons.store, color: kMoneyDeep))
                : Text(shortStoreName(name).characters.take(2).toString(), style: inter(18, 800, color: kMoneyDeep)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, key: const ValueKey('pm-name'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(18, 800, color: Colors.white)),
              const SizedBox(height: 4),
              Container(
                key: const ValueKey('pm-status'),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: kMoneyDeepSoft, borderRadius: BorderRadius.circular(40)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 7, height: 7, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text(status, style: inter(11, 700, color: Colors.white)),
                ]),
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: Text(done == steps.length ? tr('Your page is ready') : '${tr('Your page is')} $done/${steps.length} ${tr('ready')}', style: inter(13, 700, color: Colors.white))),
          Text('${(done * 100 / steps.length).round()}%', style: inter(13, 800, color: kMoneyLime)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(key: const ValueKey('pm-progress'), value: done / steps.length, minHeight: 7, color: kMoneyLime, backgroundColor: kMoneyDeepSoft),
        ),
        if (missing.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('${tr('Still to add')}: ${missing.join(', ')}', maxLines: 2, style: inter(11.5, 500, color: const Color(0xFFB8BCC4))),
        ],
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: FilledButton(
              key: const ValueKey('pm-edit-page'),
              onPressed: () => _open(StorePageBuilder(api: widget.api)),
              style: FilledButton.styleFrom(backgroundColor: kMoneyLime, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(LucideIcons.layoutTemplate, size: 17, color: kMoneyDeep),
                const SizedBox(width: 7),
                Flexible(child: Text(tr('Edit store page'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14.5, 800, color: kMoneyDeep))),
              ]),
            ),
          ),
          const SizedBox(width: 10),
          Material(
            color: kMoneyDeepSoft,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              key: const ValueKey('pm-share'),
              borderRadius: BorderRadius.circular(16),
              onTap: () => _open(const MenuLinkScreen()),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(LucideIcons.share2, size: 17, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(tr('Share'), style: inter(14, 700, color: Colors.white)),
                ]),
              ),
            ),
          ),
        ]),
      ]),
    );
  }

  // ---------------------------------------------------------------------------------------------------------------- Ads and Offers
  Widget _grow(String key, String title, String sub, String count, IconData icon, {required bool dark, required VoidCallback onTap}) {
    final fg = dark ? Colors.white : kMoneyDeep, soft = dark ? const Color(0xFFB8BCC4) : const Color(0xFF3F4A12);
    return Expanded(
      child: Material(
        color: dark ? kMoneyDeep : kMoneyLime,
        borderRadius: BorderRadius.circular(kMoneyCardRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey(key),
          onTap: onTap,
          child: Stack(children: [
            if (dark) const Positioned.fill(child: MoneyRings(opacity: 0.06)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 14, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(color: dark ? kMoneyDeepSoft : kMoneyDeep, borderRadius: BorderRadius.circular(12)),
                    child: Icon(icon, size: 19, color: kMoneyLime),
                  ),
                  const Spacer(),
                  Icon(LucideIcons.arrowUpRight, size: 18, color: fg),
                ]),
                const SizedBox(height: 14),
                Text(title, style: inter(16, 800, color: fg)),
                const SizedBox(height: 2),
                Text(sub, maxLines: 2, style: inter(11.5, 500, color: soft)),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(color: dark ? kMoneyDeepSoft : kMoneyDeep.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(40)),
                  child: Text(count, style: inter(11.5, 800, color: dark ? kMoneyLime : kMoneyDeep)),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------------------------------------------- the page's parts
  Widget _tile(String key, String title, String sub, IconData icon, Color tint, VoidCallback onTap) => Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey(key),
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Ink(
            padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
            decoration: moneyCard(),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(color: tint.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(12)),
                  child: Icon(icon, size: 19, color: tint),
                ),
                const Spacer(),
                const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
              ]),
              const SizedBox(height: 12),
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14.5, 800)),
              const SizedBox(height: 2),
              Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(11.5, 500, color: kMuted)),
            ]),
          ),
        ),
      );

  Widget _section(String text) => Padding(padding: const EdgeInsets.fromLTRB(4, 20, 4, 10), child: Text(text, style: inter(17, 800)));

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(title: tr('Page Manager'), onBack: Navigator.of(context).canPop() ? () => Navigator.of(context).maybePop() : null),
        Expanded(
          child: s == null
              ? Center(
                  child: _error == null
                      ? const CircularProgressIndicator()
                      : Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kMuted))),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: LayoutBuilder(builder: (context, c) {
                    final p = s.m('profile'), hours = s.m('hours'), delivery = s.m('delivery');
                    final adsOn = _ads.where(_isOn).length, offersOn = _offers.where(_isOn).length;
                    final tiles = [
                      _tile('pm-profile', tr('Shop profile'), tr('Name, logo, banner, about, address'), LucideIcons.store, const Color(0xFF15803D), () => _open(ProfileScreen(api: widget.api))),
                      _tile('pm-page', tr('Store page'), tr('Sections, products, theme, preview'), LucideIcons.layoutTemplate, const Color(0xFF2B6FE0), () => _open(StorePageBuilder(api: widget.api))),
                      _tile('pm-hours', tr('Business hours'), _hoursToday(hours), LucideIcons.clock, const Color(0xFFE8711C), () => _open(HoursScreen(api: widget.api))),
                      _tile('pm-delivery', tr('Delivery & pickup'), _delivery(delivery), LucideIcons.truck, const Color(0xFF8B3DF2), () => _open(DeliveryScreen(api: widget.api))),
                      _tile('pm-link', tr('Store link & QR'), (p.so('store_slug') ?? '').isEmpty ? tr('Choose your link') : tr('Share or print it'), LucideIcons.qrCode, const Color(0xFF475569),
                          () => _open(const MenuLinkScreen())),
                      if (HomeNav.reviews != null)
                        _tile('pm-reviews', tr('Reviews'), tr('What customers say'), LucideIcons.star, const Color(0xFFD1124F), () => HomeNav.reviews!(context)),
                    ];
                    final cols = c.maxWidth >= 700 ? 3 : 2;
                    return ListView(key: const ValueKey('page-manager'), padding: const EdgeInsets.fromLTRB(14, 10, 14, 120), children: [ // room under the floating bottom bar
                      _hero(p, hours, delivery),
                      _section(tr('Grow your sales')),
                      IntrinsicHeight(
                        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          _grow('pm-ads', tr('Ads'), tr('Show your shop to more people nearby'), adsOn > 0 ? '$adsOn ${tr('running')}' : tr('Start an ad'), LucideIcons.megaphone,
                              dark: false, onTap: () => _open(AdsHomeScreen(storefront: widget.api))),
                          const SizedBox(width: 12),
                          _grow('pm-offers', tr('Offers & promotions'), tr('Deals customers see on your page'),
                              offersOn > 0 ? '$offersOn ${tr('live')}' : (_offers.isEmpty ? tr('Add an offer') : '${_offers.length} ${tr('saved')}'), LucideIcons.badgePercent,
                              dark: true, onTap: () => _open(OffersScreen(api: widget.api))),
                        ]),
                      ),
                      _section(tr('Your page')),
                      for (var i = 0; i < tiles.length; i += cols)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: IntrinsicHeight(
                            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              for (var j = 0; j < cols; j++) ...[
                                if (j > 0) const SizedBox(width: 12),
                                Expanded(child: i + j < tiles.length ? tiles[i + j] : const SizedBox()),
                              ],
                            ]),
                          ),
                        ),
                    ]);
                  }),
                ),
        ),
      ]),
    );
  }
}
