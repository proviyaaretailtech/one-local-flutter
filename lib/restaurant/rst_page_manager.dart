import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/net_guard.dart';
import '../home/home_nav.dart';
import '../inventory/inventory_api.dart' show Facts;
import '../money/rst_money.dart' show RmDarkCard, kRmDeep, kRmDeepSoft, kRmLime, kRmRadius, rmCard, rs, RmRings;
import '../storefront/builder_screen.dart';
import '../storefront/growth_screens.dart';
import '../storefront/menu_link_screen.dart';
import '../storefront/settings_screens.dart';
import '../storefront/storefront_api.dart';
import '../ui/app_header.dart';
import '../ui/theme.dart';
import 'restaurant_more_screen.dart';

// Page Manager for the restaurant, in the store's design (founder, 29 Oct 2026: "make a page manager for restaurant POS as shown"):
// the page's readiness card with Edit store page and Share, Grow your sales (Ads, Offers & promotions) and Your page (Shop profile, Store
// page, Business hours, Delivery & pickup, Store link & QR, Reviews). Everything opens the storefront screens the store already uses;
// the data is sf_settings_get, sf_builder_get and menu_link_get.

/// One thing the page needs before it is ready, and whether it is there.
typedef PageCheck = (String label, bool done);

/// The seven things a finished page has: name, logo, banner, about, address, hours and a store link.
List<PageCheck> pageChecks(Facts settings) {
  final p = settings.m('profile');
  bool has(String k) => (p.so(k) ?? '').trim().isNotEmpty;
  return [
    ('Name', has('public_name')),
    ('Logo', has('logo_url') || has('logo_path')),
    ('Banner', has('cover_url') || has('cover_path')),
    ('About', has('description')),
    ('Address', has('address_line')),
    ('Business hours', settings.m('hours').b('configured')),
    ('Store link', has('store_slug')),
  ];
}

/// "Today 12:00 – 23:00", "Closed today" or "Not set" from the hours (day 1 = Monday, as [DateTime.weekday]).
String hoursLine(Facts hours, DateTime today) {
  if (!hours.b('configured')) return 'Not set';
  final day = hours.l('days').where((d) => d.n('day') == today.weekday).firstOrNull;
  if (day == null || !day.b('open')) return 'Closed today';
  return 'Today ${day.s('opens')} – ${day.s('closes')}';
}

/// "5 km · Pickup · min ₹500" from the delivery settings.
String deliveryLine(Facts d) {
  if (!d.b('configured')) return 'Not set';
  final parts = [
    if (d.b('home_delivery')) d.no('radius_km') == null ? 'Delivery' : '${_num(d.no('radius_km')!)} km',
    if (d.b('pickup')) 'Pickup',
    if (d.no('min_order_minor') != null && d.n('min_order_minor') > 0) 'min ${rs(d.n('min_order_minor'))}',
  ];
  return parts.isEmpty ? 'No delivery or pickup' : parts.join(' · ');
}

String _num(num v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

class RstPageManagerScreen extends StatefulWidget {
  const RstPageManagerScreen({super.key, this.api, this.linkApi, this.today, this.linkBase});
  final StorefrontApi? api;
  final MenuLinkApi? linkApi;

  /// Tests fix "today" and the link's address.
  final DateTime? today;
  final String? linkBase;

  static Route<void> route() => MaterialPageRoute(settings: const RouteSettings(name: 'page-manager'), builder: (_) => const RstPageManagerScreen());

  @override
  State<RstPageManagerScreen> createState() => _RstPageManagerScreenState();
}

class _RstPageManagerScreenState extends State<RstPageManagerScreen> {
  late final StorefrontApi _api = widget.api ?? StorefrontApi();
  late final MenuLinkApi _links = widget.linkApi ?? MenuLinkApi();
  Facts? _settings, _builder, _link;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([_api.settings(), _api.builder(), _links.get()]);
      if (!mounted) return;
      setState(() {
        _settings = r[0];
        _builder = r[1];
        _link = r[2];
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e is StorefrontException ? e.message : errorSentence(e));
    }
  }

  /// Opens a page and reads everything again on the way back (a saved profile or a publish changes the card).
  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  void _openRoute(HomeRoute route) {
    route(context);
    RestaurantMoreScreen.whenUncovered(context, _load);
  }

  String? get _url {
    final path = _link?.so('path');
    return path == null ? null : MenuLinkApi.urlFor(path, base: widget.linkBase);
  }

  Future<void> _share() async {
    final url = _url;
    if (url == null || _link?.b('live') != true) {
      showToast(context, 'Publish your page and choose a store link first, then share it.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) showToast(context, 'Link copied. Paste it anywhere to share your page.');
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppHeader(
          title: 'Page Manager',
          onBack: Navigator.of(context).canPop() ? () => Navigator.of(context).maybePop() : null,
          trailing: HomeNav.wallet == null ? null : HeaderRound(key: const ValueKey('pm-wallet'), icon: LucideIcons.wallet, label: 'Wallet', onTap: () => HomeNav.wallet!(context)),
        ),
        Expanded(
          child: s == null
              ? Center(
                  child: _error == null
                      ? const CircularProgressIndicator()
                      : Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Text(_error!, key: const ValueKey('pm-error'), textAlign: TextAlign.center, style: inter(14, 500, color: kMuted)),
                            const SizedBox(height: 12),
                            OutlinedButton(onPressed: _load, child: Text('Try again', style: inter(14, 600))),
                          ]),
                        ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 10, 16, 28), children: [
                    _ready(s),
                    const SizedBox(height: 26),
                    Text('Grow your sales', style: inter(18, 800)),
                    const SizedBox(height: 12),
                    IntrinsicHeight(
                      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Expanded(child: _grow('pm-ads', 'Ads', 'Show your restaurant to more people nearby', 'Start an ad', LucideIcons.megaphone, lime: true, onTap: () => _open(AdsScreen(api: _api)))),
                        const SizedBox(width: 12),
                        Expanded(child: _grow('pm-offers', 'Offers & promotions', 'Deals customers see on your page', 'Add an offer', LucideIcons.badgePercent, lime: false, onTap: () => _open(OffersScreen(api: _api)))),
                      ]),
                    ),
                    const SizedBox(height: 26),
                    Text('Your page', style: inter(18, 800)),
                    const SizedBox(height: 12),
                    ..._tiles(s),
                  ]),
                ),
        ),
      ]),
    );
  }

  Widget _ready(Facts s) {
    final p = s.m('profile');
    final checks = pageChecks(s);
    final done = checks.where((c) => c.$2).length;
    final missing = [for (final c in checks) if (!c.$2) c.$1];
    final b = _builder ?? const Facts({});
    final published = b.n('published_version') > 0;
    final (statusText, statusColor) = !published
        ? ('Not published yet', const Color(0xFFF59E0B))
        : b.b('has_unpublished_changes')
            ? ('Changes not published', const Color(0xFFF59E0B))
            : ('Live', const Color(0xFF22C55E));
    final name = p.so('public_name') ?? _builder?.m('store').so('name') ?? HomeNav.storeName ?? 'Your restaurant';
    final logo = p.so('logo_url');
    return RmDarkCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 56,
            height: 56,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(shape: BoxShape.circle, color: kRmDeepSoft, border: Border.all(color: Colors.white24)),
            child: logo == null
                ? Center(child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(), style: inter(22, 800, color: kRmLime)))
                : Image.network(logo, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.store, color: kRmLime)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, key: const ValueKey('pm-name'), maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(19, 800, color: Colors.white)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: kRmDeepSoft, borderRadius: BorderRadius.circular(40)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Text(statusText, key: const ValueKey('pm-status'), style: inter(12, 700, color: Colors.white)),
                ]),
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: Text('Your page is $done/${checks.length} ready', key: const ValueKey('pm-ready'), style: inter(14.5, 700, color: Colors.white))),
          Text('${(done * 100 / checks.length).round()}%', style: inter(14.5, 800, color: kRmLime)),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(value: done / checks.length, minHeight: 7, backgroundColor: kRmDeepSoft, valueColor: const AlwaysStoppedAnimation(kRmLime)),
        ),
        const SizedBox(height: 10),
        Text(missing.isEmpty ? 'Everything is in place.' : 'Still to add: ${missing.join(', ')}', key: const ValueKey('pm-missing'), style: inter(12.5, 500, color: const Color(0xFFB8BCC4))),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(
            flex: 3,
            child: _pill('pm-edit', 'Edit store page', LucideIcons.layoutTemplate, lime: true, onTap: () => _open(StorePageBuilder(api: _api))),
          ),
          const SizedBox(width: 10),
          Expanded(flex: 2, child: _pill('pm-share', 'Share', LucideIcons.share2, lime: false, onTap: _share)),
        ]),
      ]),
    );
  }

  Widget _pill(String key, String label, IconData icon, {required bool lime, required VoidCallback onTap}) => Material(
        color: lime ? kRmLime : kRmDeepSoft,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          key: ValueKey(key),
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 18, color: lime ? kRmDeep : Colors.white),
              const SizedBox(width: 8),
              Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(15, 800, color: lime ? kRmDeep : Colors.white))),
            ]),
          ),
        ),
      );

  Widget _grow(String key, String title, String sub, String action, IconData icon, {required bool lime, required VoidCallback onTap}) {
    final fg = lime ? kRmDeep : Colors.white;
    final soft = lime ? const Color(0xFF3F4A12) : const Color(0xFFB8BCC4);
    return ClipRRect(
      borderRadius: BorderRadius.circular(kRmRadius),
      child: Material(
        color: lime ? kRmLime : kRmDeep,
        child: InkWell(
          key: ValueKey(key),
          onTap: onTap,
          child: Stack(children: [
            if (!lime) const Positioned.fill(child: RmRings()),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(color: lime ? kRmDeep : kRmDeepSoft, borderRadius: BorderRadius.circular(14)),
                    child: Icon(icon, size: 22, color: kRmLime),
                  ),
                  const Spacer(),
                  Icon(LucideIcons.arrowUpRight, size: 20, color: fg),
                ]),
                const SizedBox(height: 18),
                Text(title, style: inter(17, 800, color: fg)),
                const SizedBox(height: 4),
                Text(sub, style: inter(12.5, 500, color: soft)),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: lime ? const Color(0x1A16181D) : kRmDeepSoft, borderRadius: BorderRadius.circular(40)),
                  child: Text(action, style: inter(12.5, 800, color: lime ? kRmDeep : kRmLime)),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  List<Widget> _tiles(Facts s) {
    final p = s.m('profile');
    final slug = p.so('store_slug');
    final reviews = HomeNav.reviews;
    final tiles = [
      _tile('pm-profile', 'Shop profile', 'Name, logo, banner, about, address', LucideIcons.store, const Color(0xFFE6F4EA), const Color(0xFF15803D), () => _open(ProfileScreen(api: _api))),
      _tile('pm-page', 'Store page', 'Sections, menu, theme, preview', LucideIcons.layoutTemplate, const Color(0xFFE5EDFF), const Color(0xFF2563EB), () => _open(StorePageBuilder(api: _api))),
      _tile('pm-hours', 'Business hours', hoursLine(s.m('hours'), widget.today ?? DateTime.now()), LucideIcons.clock, const Color(0xFFFFEDE3), const Color(0xFFEA580C), () => _open(HoursScreen(api: _api))),
      _tile('pm-delivery', 'Delivery & pickup', deliveryLine(s.m('delivery')), LucideIcons.truck, const Color(0xFFF1E8FF), const Color(0xFF7C3AED), () => _open(DeliveryScreen(api: _api))),
      _tile('pm-link', 'Store link & QR', slug == null ? 'Choose your link' : '/$slug', LucideIcons.qrCode, const Color(0xFFEDEEF1), const Color(0xFF475569), () => _open(MenuLinkScreen(api: _links, linkBase: widget.linkBase))),
      _tile('pm-reviews', 'Reviews', 'What customers say', LucideIcons.star, const Color(0xFFFFE4EC), const Color(0xFFE11D48), reviews == null ? null : () => _openRoute(reviews)),
    ];
    return [
      for (var i = 0; i < tiles.length; i += 2)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: tiles[i]),
              const SizedBox(width: 12),
              Expanded(child: i + 1 < tiles.length ? tiles[i + 1] : const SizedBox()),
            ]),
          ),
        ),
    ];
  }

  Widget _tile(String key, String title, String sub, IconData icon, Color bg, Color fg, VoidCallback? onTap) => Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Container(
          decoration: rmCard(),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: ValueKey(key),
              borderRadius: BorderRadius.circular(22),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(width: 46, height: 46, decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)), child: Icon(icon, size: 22, color: fg)),
                    const Spacer(),
                    if (onTap == null)
                      Text('Soon', style: inter(11, 700, color: kMuted))
                    else
                      const Icon(LucideIcons.chevronRight, size: 20, color: kMuted),
                  ]),
                  const SizedBox(height: 16),
                  Text(title, style: inter(15.5, 800)),
                  const SizedBox(height: 4),
                  Text(sub, key: ValueKey('$key-sub'), maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(12.5, 500, color: kMuted)),
                ]),
              ),
            ),
          ),
        ),
      );
}
