import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../inventory/inventory_widgets.dart' show kCardLine;
import '../money/money_flow.dart' show openMoneyLink;
import '../money/money_style.dart';
import '../money/money_transfer.dart' show upiPayLink;
import '../money/store_money.dart' show rs, dayMonth, isoDay;
import '../onboarding/document_picker.dart';
import '../storefront/growth_screens.dart' show OffersScreen;
import '../storefront/storefront_api.dart';
import '../ui/app_header.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'ads_api.dart';
import 'ads_campaign.dart';
import 'advertiser_screens.dart' show AdvertiserApi, BrandProfileScreen;

// The Ads section (founder's sketch and the "Advertising & Partner Growth System" spec, 29 Oct 2026): a dashboard (coins available,
// held, spent and disputed; campaigns by stage; views, clicks and valid clicks), a new campaign (what it is for, where it shows, a 9:16
// photo or video, dates; a price only when OneLocal has approved and switched one on, otherwise OneLocal sends one), the campaign page
// (ads_campaign.dart), the coins wallet (1 coin = ₹10) and topping it up.

/// Where an ad can show, with its icon (the names and what each supports come from the server's `formats`).
const formatIcons = <String, IconData>{
  'home_banner': LucideIcons.panelTop,
  'reel': LucideIcons.clapperboard,
  'popup': LucideIcons.squareStack,
  'category_banner': LucideIcons.layoutGrid,
  'sponsored_product': LucideIcons.package,
  'sponsored_store': LucideIcons.store,
  'search': LucideIcons.search,
  'local_area': LucideIcons.mapPin,
  'brand_awareness': LucideIcons.sparkles,
  'lead_gen': LucideIcons.phoneCall,
};
const _formatNames = <String, String>{
  'home_banner': 'Homepage banner', 'reel': 'Reel / video', 'popup': 'Pop-up', 'category_banner': 'Category banner',
  'sponsored_product': 'Sponsored product', 'sponsored_store': 'Sponsored store', 'search': 'Search ad', 'local_area': 'Local-area ad',
  'brand_awareness': 'Brand awareness', 'lead_gen': 'Lead generation',
};
String formatName(Object? id) => tr(_formatNames['$id'] ?? _formatNames['home_banner']!);
IconData formatIcon(Object? id) => formatIcons['$id'] ?? LucideIcons.megaphone;

/// "per day", "per click"… for a pricing model.
String modelUnit(Object? m) => tr(switch ('$m') {
      'per_day' => 'a day',
      'per_week' => 'a week',
      'fixed' => 'for the campaign',
      'cpc' => 'a valid click',
      'cpm' => 'per 1,000 views',
      'cpl' => 'a lead',
      _ => '',
    });
String modelName(Object? m) => tr(switch ('$m') {
      'per_day' => 'Per day',
      'per_week' => 'Per week',
      'fixed' => 'Fixed fee',
      'cpc' => 'Per click',
      'cpm' => 'Per 1,000 views',
      'cpl' => 'Per lead',
      _ => '$m',
    });
bool isBudgetModel(Object? m) => const ['cpc', 'cpm', 'cpl'].contains('$m');

const objectives = [
  ('awareness', 'Brand awareness', LucideIcons.sparkles),
  ('product', 'Promote a product', LucideIcons.package),
  ('service', 'Promote a service', LucideIcons.wrench),
  ('store_visit', 'More store visits', LucideIcons.store),
  ('website', 'Website visits', LucideIcons.globe),
  ('leads', 'Get leads', LucideIcons.phoneCall),
  ('launch', 'New launch', LucideIcons.rocket),
  ('local', 'Local-area offer', LucideIcons.mapPin),
  ('sales', 'Sales on OneLocal', LucideIcons.shoppingBag),
];

int _int(Object? v) => v is num ? v.round() : int.tryParse('$v') ?? 0;
num numOf(Object? v) => v is num ? v : num.tryParse('$v') ?? 0;

/// Coins as people read them: 120, 2.5, 0.75.
String coinText(Object? v) {
  final n = numOf(v);
  if (n == n.roundToDouble()) return '${n.round()}';
  return n.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
}

String _coinWord(int n) => '$n ${n == 1 ? tr('coin') : tr('coins')}';
String coinsWord(Object? v) => '${coinText(v)} ${numOf(v) == 1 ? tr('coin') : tr('coins')}';

/// The stage of a campaign in words and colours.
(String, Color, Color) stageLook(Object? s) => switch ('$s') {
      'draft' => ('Draft', const Color(0xFFEFF0EC), kMuted),
      'under_review' => ('In review', const Color(0xFFFFF4E0), const Color(0xFFB45309)),
      'changes_requested' => ('Changes asked', const Color(0xFFFFF4E0), const Color(0xFFB45309)),
      'approved' => ('Waiting for price', const Color(0xFFFFF4E0), const Color(0xFFB45309)),
      'awaiting_acceptance' => ('Price to accept', const Color(0xFFE8F0FE), const Color(0xFF1D4ED8)),
      'awaiting_funding' => ('Needs coins', const Color(0xFFFDECEC), const Color(0xFFC62828)),
      'scheduled' => ('Upcoming', const Color(0xFFE8F0FE), const Color(0xFF1D4ED8)),
      'active' => ('Live', const Color(0xFFE8F7EC), const Color(0xFF15803D)),
      'paused' => ('Paused', const Color(0xFFEFF0EC), kMuted),
      'completed' => ('Completed', const Color(0xFFEFF0EC), kMuted),
      'cancelled' => ('Cancelled', const Color(0xFFEFF0EC), kMuted),
      'rejected' => ('Not approved', const Color(0xFFFDECEC), const Color(0xFFC62828)),
      'failed' => ('Did not run', const Color(0xFFFDECEC), const Color(0xFFC62828)),
      _ => ('Ended', const Color(0xFFEFF0EC), kMuted),
    };

/// Stages where the shop has to do something.
const needsShop = ['changes_requested', 'awaiting_acceptance', 'awaiting_funding', 'draft'];

Widget stageChip(Object? stage) {
  final (text, bg, fg) = stageLook(stage);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
    child: Text(tr(text), style: inter(11.5, 700, color: fg)),
  );
}

/// The active prices for a format, from the dashboard's `formats`.
List<Map<String, dynamic>> rulesOf(Map<String, dynamic> home, String format) {
  final f = ((home['formats'] as List?) ?? const []).cast<Map>().where((f) => f['id'] == format).firstOrNull;
  return ((f?['rules'] as List?) ?? const []).cast<Map>().map((r) => r.cast<String, dynamic>()).toList();
}

/// The coin, drawn: a lime disc with a dark "C".
class CoinMark extends StatelessWidget {
  const CoinMark({super.key, this.size = 22});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFE6FF7A), Color(0xFFB7E021)]),
          border: Border.all(color: kMoneyDeep, width: size / 14),
        ),
        child: Text('C', style: inter(size * 0.5, 900, color: kMoneyDeep)),
      );
}

// ============================================================================ dashboard
class AdsHomeScreen extends StatefulWidget {
  const AdsHomeScreen({super.key, this.api, this.storefront, this.root = false, this.onMenu, this.advertiserApi});
  final AdsApi? api;

  /// Opens Offers from the coins page's Discount tile.
  final StorefrontApi? storefront;

  /// The whole app of an advertising-only partner: no back arrow, a menu instead ([onMenu]).
  final bool root;
  final VoidCallback? onMenu;

  /// The brand profile behind the header's brand button.
  final AdvertiserApi? advertiserApi;
  @override
  State<AdsHomeScreen> createState() => _AdsHomeScreenState();
}

class _AdsHomeScreenState extends State<AdsHomeScreen> {
  late final AdsApi _api = widget.api ?? AdsApi();
  Map<String, dynamic>? _h;
  String? _error;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final h = await _api.home();
      if (mounted) {
        setState(() {
          _h = h;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : tr('Could not load your ads.'));
    }
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  void _create(Map<String, dynamic> h) => _open(AdCreateScreen(api: _api, home: h));
  void _wallet() => _open(CoinsScreen(api: _api, storefront: widget.storefront));

  List<Map<String, dynamic>> get _ads => ((_h?['ads'] as List?) ?? const []).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();

  @override
  Widget build(BuildContext context) {
    final h = _h;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(
          title: tr('Ads'),
          back: widget.root ? false : null,
          onBack: widget.root ? null : () => Navigator.of(context).maybePop(),
          onMenu: widget.onMenu,
          trailing: IconButton(
            key: const ValueKey('ads-brand'),
            tooltip: tr('Brand profile'),
            icon: const Icon(LucideIcons.badgeCheck, size: 20, color: kInk),
            onPressed: () => _open(BrandProfileScreen(api: widget.advertiserApi)),
          ),
        ),
        Expanded(
          child: _error != null && h == null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kMuted))))
              : h == null
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(key: const ValueKey('ads-home'), padding: const EdgeInsets.fromLTRB(14, 12, 14, 120), children: [
                        _coinsCard(h),
                        const SizedBox(height: 12),
                        _counts(h),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 54,
                          child: FilledButton.icon(
                            key: const ValueKey('ads-create'),
                            onPressed: () => _create(h),
                            icon: const Icon(LucideIcons.plus, size: 20, color: kMoneyDeep),
                            label: Text(tr('Create campaign'), style: inter(16, 800, color: kMoneyDeep)),
                            style: FilledButton.styleFrom(backgroundColor: kMoneyLime, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _analytics(h),
                        const SizedBox(height: 18),
                        Text(tr('Your campaigns'), style: inter(17, 800)),
                        const SizedBox(height: 8),
                        MoneyPills(
                          keyPrefix: 'ads-filter',
                          options: [
                            ('all', tr('All')),
                            ('live', tr('Live')),
                            ('upcoming', tr('Upcoming')),
                            ('review', tr('In review')),
                            ('draft', tr('Drafts')),
                            ('ended', tr('Ended')),
                          ],
                          selected: _filter,
                          onSelect: (f) => setState(() => _filter = f),
                        ),
                        const SizedBox(height: 10),
                        ..._list(),
                      ]),
                    ),
        ),
      ]),
    );
  }

  Widget _coinsCard(Map<String, dynamic> h) {
    final b = ((h['balances'] as Map?) ?? const {}).cast<String, dynamic>();
    final coins = numOf(b['available'] ?? h['coins']), rupee = _int(h['coin_rupees']).clamp(1, 1000);
    final pending = numOf(b['pending'] ?? h['pending_coins']), held = numOf(b['reserved']), spent = numOf(b['consumed']);
    final expired = numOf(b['expired']), disputed = numOf(b['disputed']), promo = numOf(b['promotional']);
    Widget stat(String key, String label, num v) => Expanded(
          child: Column(key: ValueKey(key), crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr(label), style: inter(11.5, 600, color: const Color(0xFFB8BCC4))),
            Text(coinText(v), style: inter(16, 800, color: Colors.white)),
          ]),
        );
    return MoneyDarkCard(
      key: const ValueKey('ads-coins-card'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(tr('AD CREDITS'), style: inter(12, 700, color: const Color(0xFFB8BCC4)).copyWith(letterSpacing: 1.2)),
          const Spacer(),
          Text('1 ${tr('coin')} = ${rs(rupee * 100)}', style: inter(12, 600, color: const Color(0xFFB8BCC4))),
        ]),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          const CoinMark(size: 34),
          const SizedBox(width: 10),
          Text(coinText(coins), key: const ValueKey('ads-coins'), style: inter(38, 800, color: Colors.white)),
          const SizedBox(width: 8),
          Padding(padding: const EdgeInsets.only(top: 10), child: Text(tr('available'), style: inter(15, 600, color: const Color(0xFFB8BCC4)))),
        ]),
        Text('= ${rs((coins * rupee * 100).round())}${promo > 0 ? ' · ${coinText(promo)} ${tr('promotional')}' : ''}', style: inter(13.5, 600, color: kMoneyLime)),
        const SizedBox(height: 12),
        Row(children: [
          stat('ads-held', 'Held for campaigns', held),
          stat('ads-spent', 'Spent', spent),
          if (disputed > 0) stat('ads-disputed', 'Disputed', disputed),
          if (expired > 0) stat('ads-expired', 'Expired', expired),
        ]),
        if (pending > 0) ...[
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('ads-pending'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: kMoneyDeepSoft, borderRadius: BorderRadius.circular(99)),
            child: Text('+${coinsWord(pending)} ${tr('waiting for OneLocal to confirm your payment')}', style: inter(12, 600, color: Colors.white)),
          ),
        ],
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              key: const ValueKey('ads-topup'),
              onPressed: () => _open(TopUpScreen(api: _api, home: h)),
              icon: const Icon(LucideIcons.plus, size: 17, color: kMoneyDeep),
              label: Text(tr('Top up'), style: inter(14, 800, color: kMoneyDeep)),
              style: FilledButton.styleFrom(backgroundColor: kMoneyLime, padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.icon(
              key: const ValueKey('ads-wallet'),
              onPressed: _wallet,
              icon: const Icon(LucideIcons.wallet, size: 17, color: Colors.white),
              label: Text(tr('Coins & history'), style: inter(14, 700, color: Colors.white)),
              style: FilledButton.styleFrom(backgroundColor: kMoneyDeepSoft, padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _counts(Map<String, dynamic> h) {
    final c = (h['counts'] as Map?) ?? const {};
    Widget tile(String key, String label, int n, Color dot, String filter) => Expanded(
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              key: ValueKey(key),
              borderRadius: BorderRadius.circular(20),
              onTap: () => setState(() => _filter = filter),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Flexible(child: Text(tr(label), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13, 700, color: kMuted))),
                      ]),
                      const SizedBox(height: 4),
                      Text('$n', style: inter(30, 800)),
                    ]),
                  ),
                  const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
                ]),
              ),
            ),
          ),
        );
    final review = _int(c['review']);
    final need = _ads.where((a) => needsShop.contains(a['stage']) && a['stage'] != 'draft').length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        tile('ads-live', 'Live ads', _int(c['live']), const Color(0xFF22C55E), 'live'),
        const SizedBox(width: 10),
        tile('ads-upcoming', 'Upcoming', _int(c['upcoming']), const Color(0xFF3B82F6), 'upcoming'),
      ]),
      if (need > 0)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Material(
            color: const Color(0xFFFFF4E0),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              key: const ValueKey('ads-needs-you'),
              borderRadius: BorderRadius.circular(16),
              onTap: () => setState(() => _filter = 'review'),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                child: Row(children: [
                  const Icon(LucideIcons.bellRing, size: 18, color: Color(0xFFB45309)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('$need ${tr(need == 1 ? 'campaign needs you: a price to accept, coins to hold or changes to make' : 'campaigns need you: prices to accept, coins to hold or changes to make')}',
                        style: inter(12.5, 700, color: const Color(0xFFB45309))),
                  ),
                  const Icon(LucideIcons.chevronRight, size: 16, color: Color(0xFFB45309)),
                ]),
              ),
            ),
          ),
        )
      else if (review > 0)
        Padding(
          padding: const EdgeInsets.only(top: 8, left: 4),
          child: Text('$review ${tr(review == 1 ? 'campaign is' : 'campaigns are')} ${tr("waiting for OneLocal's check")}', style: inter(12.5, 600, color: const Color(0xFFB45309))),
        ),
    ]);
  }

  Widget _analytics(Map<String, dynamic> h) {
    final series = ((h['series'] as List?) ?? const []).cast<Map>();
    final views = [for (final d in series) _int(d['views'])], clicks = [for (final d in series) _int(d['clicks'])];
    int sum(String k) => series.fold(0, (a, d) => a + _int(d[k]));
    final tv = views.fold(0, (a, b) => a + b), tc = clicks.fold(0, (a, b) => a + b), valid = sum('valid_clicks');
    final leads = sum('leads'), visits = sum('visits');
    final spent = series.fold<num>(0, (a, d) => a + numOf(d['spent']));
    Widget total(String label, String v, {Color? line}) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (line != null) ...[
                Container(width: 10, height: 3, decoration: BoxDecoration(color: line, borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 6),
              ],
              Flexible(child: Text(tr(label), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12.5, 600, color: kMuted))),
            ]),
            Text(v, style: inter(22, 800)),
          ]),
        );
    return Container(
      key: const ValueKey('ads-analytics'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: moneyCard(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(tr('Analytics'), style: inter(16, 800)),
          const Spacer(),
          Text(tr('Last 14 days'), style: inter(12, 600, color: kMuted)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          total('Views', '$tv', line: kMoneyDeep),
          total('Clicks', '$tc', line: const Color(0xFFF59E0B)),
          total('Click rate', tv == 0 ? '—' : '${(tc * 100 / tv).toStringAsFixed(1)}%'),
        ]),
        const SizedBox(height: 8),
        Row(key: const ValueKey('ads-analytics-more'), children: [
          total('Valid clicks', '$valid'),
          total('Coins spent', coinText(spent)),
          // leads and visits only once something measures them (the spec: no made-up numbers)
          total(leads > 0 ? 'Leads' : 'Store visits', leads > 0 ? '$leads' : (visits > 0 ? '$visits' : '—')),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          height: 130,
          child: tv == 0 && tc == 0
              ? Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(14)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(tr('Views and clicks show here once your ads start running.'), textAlign: TextAlign.center, style: inter(13, 500, color: kMuted)),
                  ),
                )
              : CustomPaint(painter: _ChartPainter(views, clicks), size: Size.infinite),
        ),
        if (series.isNotEmpty) ...[
          const SizedBox(height: 6),
          Row(children: [
            Text(dayMonth(series.first['day']?.toString()), style: inter(11, 500, color: kMuted)),
            const Spacer(),
            Text(tr('Today'), style: inter(11, 500, color: kMuted)),
          ]),
        ],
        const SizedBox(height: 6),
        Text(tr('Only valid clicks are charged. Repeat clicks from the same person are counted but free.'), style: inter(11.5, 500, color: kMuted)),
      ]),
    );
  }

  List<Widget> _list() {
    final ads = _ads.where((a) => _filter == 'all' || a['phase'] == _filter || (_filter == 'ended' && a['phase'] == 'rejected')).toList();
    if (ads.isEmpty) {
      return [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: moneyCard(),
          child: Column(children: [
            const Icon(LucideIcons.megaphone, size: 30, color: kMuted),
            const SizedBox(height: 8),
            Text(tr(_filter == 'all' ? 'No campaigns yet' : 'Nothing here'), style: inter(15.5, 800)),
            const SizedBox(height: 4),
            Text(tr('Promote your store, a product, a service or a launch. OneLocal checks it, then shows it to people nearby.'),
                textAlign: TextAlign.center, style: inter(13, 500, color: kMuted)),
          ]),
        ),
      ];
    }
    return [for (final a in ads) _adCard(a)];
  }

  Widget _adCard(Map<String, dynamic> a) {
    final format = a['format_id'] ?? (a['ad_type'] == 'banner' ? 'home_banner' : a['ad_type']);
    final spent = numOf(a['spent']), held = numOf(a['held'] ?? a['coins']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          key: ValueKey('ad-${a['id']}'),
          borderRadius: BorderRadius.circular(20),
          onTap: () => _open(CampaignScreen(api: _api, ad: a, home: _h ?? const {})),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              // a 9:16 thumbnail frame
              Container(
                width: 46,
                height: 82,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF2A2E35), kMoneyDeep]),
                ),
                child: Icon(a['media_kind'] == 'video' ? LucideIcons.play : LucideIcons.image, size: 18, color: kMoneyLime),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(formatIcon(format), size: 13, color: kMuted),
                    const SizedBox(width: 4),
                    Expanded(child: Text(formatName(format), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 700, color: kMuted))),
                    const SizedBox(width: 6),
                    stageChip(a['stage'] ?? a['phase']),
                  ]),
                  const SizedBox(height: 4),
                  Text('${a['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(15.5, 800)),
                  const SizedBox(height: 2),
                  Text(
                    a['starts_on'] == null
                        ? tr('Dates not set')
                        : '${dayMonth(a['starts_on']?.toString())} – ${dayMonth(a['ends_on']?.toString())} · ${_int(a['days'])} ${tr('days')}',
                    style: inter(12.5, 500, color: kMuted),
                  ),
                  const SizedBox(height: 6),
                  Row(children: [
                    const CoinMark(size: 15),
                    const SizedBox(width: 4),
                    Text(spent > 0 ? '${coinText(spent)} ${tr('spent')}' : '${coinText(held)} ${tr('held')}', style: inter(12.5, 700)),
                    const SizedBox(width: 12),
                    const Icon(LucideIcons.eye, size: 14, color: kMuted),
                    const SizedBox(width: 4),
                    Text('${_int(a['views'])}', style: inter(12.5, 700)),
                    const SizedBox(width: 12),
                    const Icon(LucideIcons.mousePointerClick, size: 14, color: kMuted),
                    const SizedBox(width: 4),
                    Text('${_int(a['clicks'])}', style: inter(12.5, 700)),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Views (dark) and clicks (amber) over the days, as smooth lines with a soft fill under views.
class _ChartPainter extends CustomPainter {
  _ChartPainter(this.views, this.clicks);
  final List<int> views, clicks;

  @override
  void paint(Canvas canvas, Size size) {
    final top = math.max(1, [...views, ...clicks].fold(0, math.max)).toDouble();
    final grid = Paint()..color = const Color(0xFFECEDE8)..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    Path line(List<int> v) {
      final p = Path();
      for (var i = 0; i < v.length; i++) {
        final x = v.length == 1 ? size.width / 2 : size.width * i / (v.length - 1);
        final y = size.height - size.height * 0.9 * v[i] / top;
        if (i == 0) {
          p.moveTo(x, y);
        } else {
          final px = size.width * (i - 1) / (v.length - 1);
          final py = size.height - size.height * 0.9 * v[i - 1] / top;
          p.cubicTo((px + x) / 2, py, (px + x) / 2, y, x, y);
        }
      }
      return p;
    }

    final vp = line(views);
    final fill = Path.from(vp)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
        fill,
        Paint()
          ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [const Color(0x55D2F64B), const Color(0x00D2F64B)]));
    canvas.drawPath(vp, Paint()..color = kMoneyDeep..style = PaintingStyle.stroke..strokeWidth = 2.5..strokeCap = StrokeCap.round);
    canvas.drawPath(line(clicks), Paint()..color = const Color(0xFFF59E0B)..style = PaintingStyle.stroke..strokeWidth = 2..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_ChartPainter old) => old.views != views || old.clicks != clicks;
}

// ============================================================================ a new campaign
class AdCreateScreen extends StatefulWidget {
  const AdCreateScreen({super.key, required this.api, required this.home, this.today, this.existing});
  final AdsApi api;

  /// The dashboard's facts: balances, formats with their active prices, coin_rupees.
  final Map<String, dynamic> home;

  /// Tests fix "today".
  final DateTime? today;

  /// A draft, or a campaign OneLocal asked to change: edited and sent again.
  final Map<String, dynamic>? existing;
  @override
  State<AdCreateScreen> createState() => _AdCreateScreenState();
}

class _AdCreateScreenState extends State<AdCreateScreen> {
  PickedDocument? _media;
  bool _video = false;
  double? _ratio; // width / height of a picked photo
  late String _format, _objective;
  late String _model;
  final _title = TextEditingController(), _message = TextEditingController(), _budget = TextEditingController(text: '100');
  final _website = TextEditingController(), _area = TextEditingController();
  late DateTime _from, _to;
  late num _coins = numOf(((widget.home['balances'] as Map?) ?? const {})['available'] ?? widget.home['coins']);
  String? _uploadedPath;
  bool _accept = false, _busy = false;
  final _key = AdsApi.newKey();

  DateTime get _today {
    final t = widget.today ?? DateTime.now();
    return DateTime(t.year, t.month, t.day);
  }

  List<Map<String, dynamic>> get _formats =>
      ((widget.home['formats'] as List?) ?? const []).cast<Map>().map((f) => f.cast<String, dynamic>()).toList();
  Map<String, dynamic> get _f => _formats.firstWhere((f) => f['id'] == _format, orElse: () => {'id': _format, 'models': ['per_day'], 'rules': []});
  List<String> get _models => ((_f['models'] as List?) ?? const ['per_day']).map((m) => '$m').toList();
  Map<String, dynamic>? get _rule => rulesOf(widget.home, _format).where((r) => r['pricing_model'] == _model).firstOrNull;

  /// The model to start with for a format: the first one with a price, else its first.
  String _firstModel(String format) {
    final priced = rulesOf(widget.home, format).map((r) => '${r['pricing_model']}').toList();
    final all = ((_formats.firstWhere((f) => f['id'] == format, orElse: () => const {})['models'] as List?) ?? const ['per_day']).map((m) => '$m').toList();
    return all.firstWhere(priced.contains, orElse: () => all.first);
  }

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _format = '${e?['format_id'] ?? (_formats.any((f) => f['id'] == 'reel') ? 'reel' : (_formats.firstOrNull?['id'] ?? 'reel'))}';
    _objective = '${e?['objective'] ?? 'product'}';
    _model = '${e?['pricing_model'] ?? _firstModel(_format)}';
    if (!_models.contains(_model)) _model = _firstModel(_format);
    _from = DateTime.tryParse('${e?['starts_on']}') ?? _today.add(const Duration(days: 1));
    if (_from.isBefore(_today)) _from = _today.add(const Duration(days: 1));
    _to = DateTime.tryParse('${e?['ends_on']}') ?? _from.add(const Duration(days: 6));
    if (_to.isBefore(_from)) _to = _from.add(const Duration(days: 6));
    if (e != null) {
      _title.text = '${e['title'] ?? ''}' == 'Untitled ad' ? '' : '${e['title'] ?? ''}';
      _message.text = '${e['message'] ?? ''}';
      _website.text = '${e['website'] ?? ''}';
      _area.text = '${e['target_area'] ?? ''}';
      if (e['budget_coins'] != null && isBudgetModel(_model)) _budget.text = coinText(e['budget_coins']);
      _uploadedPath = e['media_path'] as String?;
      _video = e['media_kind'] == 'video';
    }
  }

  @override
  void dispose() {
    for (final c in [_title, _message, _budget, _website, _area]) {
      c.dispose();
    }
    super.dispose();
  }

  int get _days => _to.difference(_from).inDays + 1;
  int get _rupee => _int(widget.home['coin_rupees']).clamp(1, 1000);
  num get _budgetCoins => num.tryParse(_budget.text.trim()) ?? 0;

  /// What the campaign holds now, or null when there is no price yet.
  num? get _cost {
    final r = _rule;
    if (r == null) return null;
    final rate = numOf(r['rate_coins']);
    return switch (_model) {
      'per_day' => rate * _days,
      'per_week' => rate * (_days / 7).ceil(),
      'fixed' => rate,
      _ => _budgetCoins,
    };
  }

  bool get _hasMedia => _media != null || _uploadedPath != null;

  Future<void> _pick(bool video) async {
    final d = await pickAdMedia(video: video);
    if (d == null || !mounted) return;
    double? ratio;
    if (!video) {
      try {
        final codec = await ui.instantiateImageCodec(d.bytes);
        final f = await codec.getNextFrame();
        ratio = f.image.width / f.image.height;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _media = d;
      _video = video;
      _ratio = ratio;
      _uploadedPath = null;
    });
  }

  Future<void> _date(bool from) async {
    final d = await showDatePicker(
      context: context,
      initialDate: from ? _from : _to,
      firstDate: from ? _today : _from,
      lastDate: _today.add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return;
    setState(() {
      if (from) {
        _from = d;
        if (_to.isBefore(_from)) _to = _from;
      } else {
        _to = d;
      }
    });
  }

  Map<String, Object?> _body({required bool draft}) => {
        if (widget.existing != null) 'id': widget.existing!['id'],
        if (draft) 'draft': true,
        'format_id': _format,
        'pricing_model': _model,
        'objective': _objective,
        'media_kind': _video ? 'video' : 'image',
        'media_path': _uploadedPath,
        'title': _title.text.trim().isEmpty ? null : _title.text.trim(),
        'message': _message.text.trim().isEmpty ? null : _message.text.trim(),
        'starts_on': isoDay(_from),
        'ends_on': isoDay(_to),
        if (isBudgetModel(_model)) 'budget_coins': _budgetCoins,
        if (_website.text.trim().isNotEmpty) 'website': _website.text.trim(),
        if (_area.text.trim().isNotEmpty) 'target_area': _area.text.trim(),
        if (!draft && _rule != null) 'accept_terms': true,
      };

  Future<void> _send({bool draft = false}) async {
    if (_busy) return;
    if (!draft) {
      if (!_hasMedia) return showToast(context, tr('Add a 9:16 photo or video first.'));
      if (_title.text.trim().isEmpty) return showToast(context, tr('Give the ad a title.'));
      if (_days > 90) return showToast(context, tr('An ad runs for at most 90 days.'));
      if (isBudgetModel(_model) && _rule != null && _budgetCoins <= 0) return showToast(context, tr('Set the most coins this campaign can spend.'));
      if (_rule != null && !_accept) return showToast(context, tr('Tick that you accept the price and terms.'));
    }
    setState(() => _busy = true);
    try {
      if (_media != null && _uploadedPath == null) _uploadedPath = (await widget.api.uploadMedia(_media!)).path;
      final r = await widget.api.save(_body(draft: draft), key: _key);
      if (!mounted) return;
      final ad = ((r['ad'] as Map?) ?? const {}).cast<String, dynamic>();
      final left = numOf(((r['balances'] as Map?) ?? const {})['available'] ?? r['coins']);
      showToast(
        context,
        draft
            ? tr('Saved as a draft. Nothing is sent or held yet.')
            : _rule == null
                ? tr('Sent to OneLocal. They check your ad and send you a price; nothing is held until you accept it.')
                : ad['funded'] == true
                    ? '${tr('Sent to OneLocal for a check.')} ${coinsWord(_cost)} ${tr('held')}; ${coinsWord(left)} ${tr('left')}.'
                    : '${tr('Sent to OneLocal for a check.')} ${tr('Top up before it starts so the coins can be held.')}',
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not save the campaign. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _topUp() async {
    final need = (_cost ?? 0) - _coins;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TopUpScreen(api: widget.api, home: widget.home, suggest: math.max(need.ceil(), 10))));
    try {
      final h = await widget.api.home();
      if (mounted) setState(() => _coins = numOf(((h['balances'] as Map?) ?? const {})['available'] ?? h['coins']));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final rule = _rule;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(title: tr(widget.existing == null ? 'Create campaign' : 'Edit campaign'), onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
            if ('${widget.existing?['review_note'] ?? ''}'.isNotEmpty && widget.existing?['stage'] == 'changes_requested')
              Container(
                key: const ValueKey('ad-review-note'),
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: const Color(0xFFFFF4E0), borderRadius: BorderRadius.circular(14)),
                child: Text('${tr('OneLocal asked')}: ${widget.existing!['review_note']}', style: inter(13, 600, color: const Color(0xFFB45309))),
              ),
            _label('What is the ad for?'),
            Wrap(spacing: 8, runSpacing: 8, children: [for (final o in objectives) _objectiveChip(o)]),
            const SizedBox(height: 16),
            _label('Where it shows'),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 2.3,
              children: [for (final f in _formats) _formatTile(f)],
            ),
            if (_models.length > 1) ...[
              const SizedBox(height: 12),
              _label('How you pay'),
              Wrap(spacing: 8, runSpacing: 8, children: [for (final m in _models) _modelChip(m)]),
            ],
            const SizedBox(height: 16),
            _mediaBox(),
            const SizedBox(height: 16),
            _label('Title'),
            _field(_title, 'Diwali offer: 20% off sweets', key: 'ad-title', max: 40),
            const SizedBox(height: 10),
            _label('Message (optional)'),
            _field(_message, 'One line under the title', key: 'ad-message', max: 60),
            if (_objective == 'website') ...[
              const SizedBox(height: 10),
              _label('Website link'),
              _field(_website, 'https://yourshop.in', key: 'ad-website', max: 200),
            ],
            if (_objective == 'local' || _format == 'local_area') ...[
              const SizedBox(height: 10),
              _label('Area to show it in'),
              _field(_area, 'Kothrud, Pune · 3 km around the store', key: 'ad-area', max: 80),
            ],
            const SizedBox(height: 16),
            _label('Dates'),
            Row(children: [
              Expanded(child: _dateBox('ad-from', 'From', _from, () => _date(true))),
              const SizedBox(width: 10),
              Expanded(child: _dateBox('ad-to', 'To', _to, () => _date(false))),
            ]),
            if (isBudgetModel(_model) && rule != null) ...[
              const SizedBox(height: 16),
              _label('Most coins it can spend'),
              TextField(
                key: const ValueKey('ad-budget'),
                controller: _budget,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')), LengthLimitingTextInputFormatter(8)],
                onChanged: (_) => setState(() {}),
                style: inter(15, 700),
                decoration: _deco('100'),
              ),
            ],
            const SizedBox(height: 16),
            rule == null ? _noPrice() : _spend(rule),
          ]),
        ),
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: kCardLine))),
            child: Row(children: [
              SizedBox(
                height: 52,
                child: OutlinedButton(
                  key: const ValueKey('ad-draft'),
                  onPressed: _busy ? null : () => _send(draft: true),
                  style: OutlinedButton.styleFrom(side: const BorderSide(color: kCardLine), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                  child: Text(tr('Save draft'), style: inter(14.5, 700)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: FilledButton(
                    key: const ValueKey('ad-create'),
                    onPressed: _busy ? null : _send,
                    style: FilledButton.styleFrom(backgroundColor: kMoneyLime, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    child: _busy
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                        : FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text(tr(rule == null ? 'Request a price' : 'Send for review'), style: inter(16, 800, color: kMoneyDeep)),
                              if (_cost != null) ...[
                                const SizedBox(width: 10),
                                const CoinMark(size: 20),
                                const SizedBox(width: 4),
                                Text(coinText(_cost), style: inter(16, 800, color: kMoneyDeep)),
                              ],
                            ]),
                          ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _label(String t) => Padding(padding: const EdgeInsets.only(bottom: 6, left: 2), child: Text(tr(t), style: inter(13.5, 700, color: kMuted)));

  InputDecoration _deco(String hint) => InputDecoration(
        hintText: tr(hint),
        hintStyle: inter(14.5, 500, color: kMuted),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kCardLine)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kCardLine)),
      );

  Widget _field(TextEditingController c, String hint, {required String key, required int max}) => TextField(
        key: ValueKey(key),
        controller: c,
        inputFormatters: [LengthLimitingTextInputFormatter(max)],
        style: inter(15, 600),
        decoration: _deco(hint),
      );

  Widget _objectiveChip((String, String, IconData) o) {
    final (id, name, icon) = o;
    final on = _objective == id;
    return ChoiceChip(
      key: ValueKey('ad-objective-$id'),
      avatar: Icon(icon, size: 15, color: on ? kMoneyLime : kInk),
      label: Text(tr(name), style: inter(12.5, 700, color: on ? Colors.white : kInk)),
      selected: on,
      showCheckmark: false,
      selectedColor: kMoneyDeep,
      backgroundColor: Colors.white,
      side: BorderSide(color: on ? kMoneyDeep : kCardLine),
      onSelected: (_) => setState(() => _objective = id),
    );
  }

  /// One format: its name, and its price when OneLocal has one switched on ("Price on request" otherwise).
  Widget _formatTile(Map<String, dynamic> f) {
    final id = '${f['id']}';
    final on = _format == id;
    final rules = rulesOf(widget.home, id);
    final price = rules.isEmpty ? tr('Price on request') : '${coinText(rules.first['rate_coins'])} ${tr('coins')} ${modelUnit(rules.first['pricing_model'])}';
    return Material(
      color: on ? kMoneyDeep : Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: ValueKey('ad-format-$id'),
        borderRadius: BorderRadius.circular(16),
        onTap: () => setState(() {
          _format = id;
          _model = _firstModel(id);
          _accept = false;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: on ? kMoneyDeep : kCardLine)),
          child: Row(children: [
            Icon(formatIcon(id), size: 19, color: on ? kMoneyLime : kInk),
            const SizedBox(width: 8),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${f['name'] ?? formatName(id)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13, 800, color: on ? Colors.white : kInk)),
                Text(price, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 600, color: on ? const Color(0xFFB8BCC4) : (rules.isEmpty ? kMuted : const Color(0xFF15803D)))),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _modelChip(String m) {
    final on = _model == m;
    final r = rulesOf(widget.home, _format).where((r) => r['pricing_model'] == m).firstOrNull;
    return ChoiceChip(
      key: ValueKey('ad-model-$m'),
      label: Text('${modelName(m)}${r == null ? ' · ${tr('on request')}' : ' · ${coinText(r['rate_coins'])}'}', style: inter(12.5, 700, color: on ? Colors.white : kInk)),
      selected: on,
      showCheckmark: false,
      selectedColor: kMoneyDeep,
      backgroundColor: Colors.white,
      side: BorderSide(color: on ? kMoneyDeep : kCardLine),
      onSelected: (_) => setState(() {
        _model = m;
        _accept = false;
      }),
    );
  }

  /// The 9:16 frame: + and Photo / Video until something is picked, then the photo itself or the video's name.
  Widget _mediaBox() {
    final d = _media;
    final offShape = !_video && _ratio != null && (_ratio! - 9 / 16).abs() > 0.06;
    final kept = d == null && _uploadedPath != null; // the campaign's photo or video, from before
    return Column(children: [
      Center(
        child: SizedBox(
          width: 200,
          child: AspectRatio(
            aspectRatio: 9 / 16,
            child: Container(
              key: const ValueKey('ad-media-box'),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: d == null && !kept ? Colors.white : kMoneyDeep,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: d == null && !kept ? const Color(0xFFD9DBD5) : kMoneyDeep, width: 1.5),
              ),
              child: d == null && !kept
                  ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Container(
                        width: 54,
                        height: 54,
                        decoration: const BoxDecoration(color: kMoneyLime, shape: BoxShape.circle),
                        child: const Icon(LucideIcons.plus, size: 26, color: kMoneyDeep),
                      ),
                      const SizedBox(height: 10),
                      Text(tr('Add photo or video'), style: inter(14, 800)),
                      Text('9 : 16', style: inter(12.5, 700, color: kMuted)),
                    ])
                  : _video || kept
                      ? Stack(children: [
                          const Positioned.fill(child: MoneyRings(opacity: 0.08)),
                          Center(
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                              Container(
                                width: 56,
                                height: 56,
                                decoration: const BoxDecoration(color: kMoneyLime, shape: BoxShape.circle),
                                child: Icon(_video ? LucideIcons.play : LucideIcons.image, size: 26, color: kMoneyDeep),
                              ),
                              const SizedBox(height: 10),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: Text(d?.name ?? tr('Your saved photo or video'), maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: inter(12.5, 600, color: Colors.white)),
                              ),
                              if (d != null) Text('${(d.bytes.length / (1024 * 1024)).toStringAsFixed(1)} MB', style: inter(11.5, 500, color: const Color(0xFFB8BCC4))),
                            ]),
                          ),
                        ])
                      : Image.memory(d!.bytes, fit: BoxFit.cover, width: double.infinity, height: double.infinity),
            ),
          ),
        ),
      ),
      const SizedBox(height: 10),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _pickButton('ad-pick-photo', LucideIcons.image, 'Photo', () => _pick(false)),
        const SizedBox(width: 8),
        _pickButton('ad-pick-video', LucideIcons.video, 'Video', () => _pick(true)),
      ]),
      if (offShape)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(tr('This photo is not 9:16 (tall). It will be cropped to fit.'), key: const ValueKey('ad-ratio-warning'), style: inter(12.5, 600, color: const Color(0xFFB45309))),
        )
      else
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(tr('Tall, like a phone screen: 1080 × 1920. Photo up to 5 MB, video up to 50 MB.'), textAlign: TextAlign.center, style: inter(12, 500, color: kMuted)),
        ),
    ]);
  }

  Widget _pickButton(String key, IconData icon, String label, VoidCallback onTap) => OutlinedButton.icon(
        key: ValueKey(key),
        onPressed: onTap,
        icon: Icon(icon, size: 16, color: kInk),
        label: Text(tr(label), style: inter(13.5, 700)),
        style: OutlinedButton.styleFrom(backgroundColor: Colors.white, side: const BorderSide(color: kCardLine), shape: const StadiumBorder(), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
      );

  Widget _dateBox(String key, String label, DateTime d, VoidCallback onTap) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: ValueKey(key),
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: kCardLine)),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr(label), style: inter(11.5, 600, color: kMuted)),
                  Text('${dayMonth(isoDay(d))} ${d.year}', style: inter(14.5, 700)),
                ]),
              ),
              const Icon(LucideIcons.calendar, size: 17, color: kMuted),
            ]),
          ),
        ),
      );

  /// No price switched on for this format and way of paying: OneLocal sends one; nothing is held until the shop accepts it.
  Widget _noPrice() => Container(
        key: const ValueKey('ad-no-price'),
        padding: const EdgeInsets.all(16),
        decoration: moneyCard(),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(LucideIcons.messageSquareQuote, size: 20, color: kMoneyDeep),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Price on request'), style: inter(15, 800)),
              const SizedBox(height: 4),
              Text(
                tr('OneLocal has not set a price for this yet. Send your ad: OneLocal checks it and sends you a price. Nothing is held or charged until you accept it.'),
                style: inter(13, 500, color: kMuted, height: 1.35),
              ),
            ]),
          ),
        ]),
      );

  /// What the campaign holds, worked out from OneLocal's active price, and the terms to accept.
  Widget _spend(Map<String, dynamic> rule) {
    final cost = _cost ?? 0, rate = numOf(rule['rate_coins']);
    final short = cost > _coins;
    final how = switch (_model) {
      'per_day' => '$_days ${tr('days')} × ${coinText(rate)} ${tr('coins')}',
      'per_week' => '${(_days / 7).ceil()} ${tr('weeks')} × ${coinText(rate)} ${tr('coins')}',
      'fixed' => tr('One fee for the campaign'),
      'cpc' => '${tr('Up to')} ${rate == 0 ? 0 : (cost / rate).floor()} ${tr('valid clicks')} × ${coinText(rate)}',
      'cpm' => '${tr('Up to')} ${rate == 0 ? 0 : (cost * 1000 / rate).floor()} ${tr('views')}',
      _ => '${tr('Up to')} ${rate == 0 ? 0 : (cost / rate).floor()} ${tr('leads')} × ${coinText(rate)}',
    };
    return Container(
      key: const ValueKey('ad-spend'),
      padding: const EdgeInsets.all(16),
      decoration: moneyCard(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(tr(isBudgetModel(_model) ? 'Budget' : 'Ads spent'), style: inter(15, 800)),
          const SizedBox(width: 8),
          Expanded(
            child: Text('${modelName(_model)} · ${tr('price')} v${rule['version'] ?? 1}', textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 600, color: kMuted)),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Text(how, style: inter(13.5, 500, color: kMuted))),
          const CoinMark(size: 18),
          const SizedBox(width: 4),
          Text(coinText(cost), key: const ValueKey('ad-cost'), style: inter(20, 800)),
        ]),
        Align(alignment: Alignment.centerRight, child: Text('= ${rs((cost * _rupee * 100).round())}', key: const ValueKey('ad-cost-rupees'), style: inter(13, 700, color: kMuted))),
        const Divider(height: 18),
        Row(children: [
          Expanded(child: Text(tr('Your coins'), style: inter(13.5, 500, color: kMuted))),
          Text(coinText(_coins), style: inter(14, 700)),
        ]),
        const SizedBox(height: 2),
        Row(children: [
          Expanded(child: Text(tr(short ? 'You need' : 'Left after this'), style: inter(13.5, 600, color: short ? const Color(0xFFC62828) : kMuted))),
          Text(short ? '${coinText(cost - _coins)} ${tr('more')}' : coinText(_coins - cost), key: const ValueKey('ad-left'), style: inter(14, 800, color: short ? const Color(0xFFC62828) : kInk)),
        ]),
        if (short) ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: Text(tr('You can send it now; the coins are held once you top up.'), style: inter(12, 500, color: kMuted))),
            TextButton(key: const ValueKey('ad-topup'), onPressed: _topUp, child: Text(tr('Top up'), style: inter(13.5, 800, color: kMoneyDeep))),
          ]),
        ],
        const SizedBox(height: 8),
        Text(
          isBudgetModel(_model)
              ? tr('Coins are held now and spent only on valid events; what is left comes back when the campaign ends.')
              : tr('Coins are held now and spent day by day as the ad runs. Days not started come back if you cancel.'),
          style: inter(12, 500, color: kMuted, height: 1.35),
        ),
        if ('${rule['terms'] ?? ''}'.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('${rule['terms']}', key: const ValueKey('ad-terms-text'), style: inter(12, 500, color: kInk, height: 1.35)),
        ],
        const SizedBox(height: 6),
        InkWell(
          key: const ValueKey('ad-terms'),
          onTap: () => setState(() => _accept = !_accept),
          child: Row(children: [
            Checkbox(value: _accept, onChanged: (v) => setState(() => _accept = v ?? false), activeColor: kMoneyDeep),
            Expanded(child: Text(tr('I accept this price and the terms'), style: inter(13.5, 700))),
          ]),
        ),
      ]),
    );
  }
}

// ============================================================================ the coins wallet
class CoinsScreen extends StatefulWidget {
  const CoinsScreen({super.key, required this.api, this.storefront, this.openAds});
  final AdsApi api;
  final StorefrontApi? storefront;

  /// The Ads tile: back to the dashboard when it opened this page, else the dashboard is opened.
  final VoidCallback? openAds;
  @override
  State<CoinsScreen> createState() => _CoinsScreenState();
}

class _CoinsScreenState extends State<CoinsScreen> {
  Map<String, dynamic>? _h;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final h = await widget.api.home();
      if (mounted) {
        setState(() {
          _h = h;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : tr('Could not load your coins.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = _h;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(title: tr('Ad credits'), onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: _error != null && h == null
              ? Center(child: Text(_error!, style: inter(14, 500, color: kMuted)))
              : h == null
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(key: const ValueKey('coins-screen'), padding: const EdgeInsets.fromLTRB(14, 12, 14, 120), children: [
                        _card(h),
                        const SizedBox(height: 12),
                        _split(h),
                        const SizedBox(height: 12),
                        _tiles(),
                        const SizedBox(height: 18),
                        ..._history(h),
                      ]),
                    ),
        ),
      ]),
    );
  }

  Map<String, dynamic> _b(Map<String, dynamic> h) => ((h['balances'] as Map?) ?? {'available': h['coins'], 'pending': h['pending_coins']}).cast<String, dynamic>();

  Widget _card(Map<String, dynamic> h) {
    final b = _b(h);
    final coins = numOf(b['available']), pending = numOf(b['pending']), rupee = _int(h['coin_rupees']).clamp(1, 1000);
    final used = numOf(b['consumed']) + numOf(b['reserved']);
    final share = coins + used == 0 ? 0.0 : (coins / (coins + used)).toDouble();
    return Container(
      decoration: BoxDecoration(color: kMoneyLime, borderRadius: BorderRadius.circular(kMoneyCardRadius)),
      padding: const EdgeInsets.fromLTRB(18, 18, 14, 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('AD CREDITS · AVAILABLE'), style: inter(12, 800, color: const Color(0xFF3F4A12)).copyWith(letterSpacing: 1.2)),
              const SizedBox(height: 8),
              Row(children: [
                const CoinMark(size: 30),
                const SizedBox(width: 8),
                Text(coinText(coins), key: const ValueKey('coins-balance'), style: inter(36, 800, color: kMoneyDeep)),
              ]),
              Text('${tr('worth')} ${rs((coins * rupee * 100).round())} · 1 ${tr('coin')} = ${rs(rupee * 100)}', style: inter(12.5, 600, color: const Color(0xFF3F4A12))),
            ]),
          ),
          Material(
            color: kMoneyDeep,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              key: const ValueKey('coins-topup'),
              borderRadius: BorderRadius.circular(14),
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TopUpScreen(api: widget.api, home: h)));
                if (mounted) _load();
              },
              child: const SizedBox(width: 46, height: 46, child: Icon(LucideIcons.plus, color: kMoneyLime)),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(value: share, minHeight: 8, backgroundColor: const Color(0x33000000), color: kMoneyDeep),
        ),
        const SizedBox(height: 6),
        Text(used == 0 ? tr('Nothing used for ads yet') : '${coinsWord(used)} ${tr('held or spent on ads')}', style: inter(12, 600, color: const Color(0xFF3F4A12))),
        if (pending > 0) ...[
          const SizedBox(height: 6),
          Text('+${coinsWord(pending)} ${tr('waiting for OneLocal to confirm your payment')}', key: const ValueKey('coins-pending'), style: inter(12, 700, color: kMoneyDeep)),
        ],
      ]),
    );
  }

  /// Available (bought and promotional), held, spent, expired and disputed, kept apart (the spec's credit ledger).
  Widget _split(Map<String, dynamic> h) {
    final b = _b(h);
    final available = numOf(b['available']), promo = numOf(b['promotional']);
    final rows = [
      ('coins-bought', 'Bought coins', available - promo, 'Yours to use on any campaign.'),
      ('coins-promo', 'Promotional coins', promo, 'From OneLocal; used first.'),
      ('coins-held', 'Held for campaigns', numOf(b['reserved']), 'Waiting to be spent by booked days or valid clicks.'),
      ('coins-spent', 'Spent', numOf(b['consumed']), 'Delivered days, valid clicks, views or leads.'),
      ('coins-disputed', 'Disputed', numOf(b['disputed']), 'Waiting for OneLocal to decide.'),
      ('coins-expired', 'Expired', numOf(b['expired']), ''),
    ];
    return Container(
      key: const ValueKey('coins-split'),
      decoration: moneyCard(),
      child: Column(children: [
        for (final (i, (key, label, v, hint)) in rows.where((r) => r.$3 != 0 || const ['coins-bought', 'coins-held', 'coins-spent'].contains(r.$1)).indexed) ...[
          if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr(label), style: inter(14, 700)),
                  if (hint.isNotEmpty) Text(tr(hint), style: inter(11.5, 500, color: kMuted)),
                ]),
              ),
              Text(coinText(v), key: ValueKey(key), style: inter(15, 800)),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _tiles() {
    Widget tile(String key, String label, IconData icon, VoidCallback onTap, {bool dark = false}) => Expanded(
          child: Material(
            color: dark ? kMoneyDeep : Colors.white,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              key: ValueKey(key),
              borderRadius: BorderRadius.circular(20),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Icon(icon, size: 22, color: dark ? kMoneyLime : kInk),
                  const SizedBox(width: 10),
                  Expanded(child: Text(tr(label), style: inter(15, 800, color: dark ? Colors.white : kInk))),
                  Icon(LucideIcons.arrowUpRight, size: 18, color: dark ? kMoneyLime : kMuted),
                ]),
              ),
            ),
          ),
        );
    return Row(children: [
      tile('coins-ads', 'Ads', LucideIcons.megaphone, () {
        if (widget.openAds != null) return widget.openAds!();
        Navigator.of(context).maybePop();
      }),
      const SizedBox(width: 10),
      tile('coins-discount', 'Discount %', LucideIcons.badgePercent,
          () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => OffersScreen(api: widget.storefront ?? StorefrontApi()))), dark: true),
    ]);
  }

  List<Widget> _history(Map<String, dynamic> h) {
    final ledger = ((h['ledger'] as List?) ?? const []).cast<Map>();
    return [
      Text(tr('Coin history'), style: inter(17, 800)),
      const SizedBox(height: 8),
      if (ledger.isEmpty)
        Text(tr('Top-ups and campaigns show here.'), style: inter(13.5, 500, color: kMuted))
      else
        Container(
          decoration: moneyCard(),
          child: Column(children: [
            for (final (i, l) in ledger.indexed) ...[
              if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
              _row(l),
            ],
          ]),
        ),
    ];
  }

  Widget _row(Map l) {
    final coins = numOf(l['coins']);
    final pending = l['status'] == 'pending', cancelled = l['status'] == 'cancelled';
    final title0 = '${l['ad_title'] ?? l['note'] ?? ''}';
    // what each line does to the available coins: + in, − out, spent comes out of coins already held
    final (title, icon, sign) = switch (l['kind']) {
      'topup' => ('${tr('Top-up')}${l['ref'] == null ? '' : ' · ${l['ref']}'}', LucideIcons.plus, 1),
      'promo' => ('${tr('Promotional coins')}${'${l['note'] ?? ''}'.isEmpty ? '' : ' · ${l['note']}'}', LucideIcons.gift, 1),
      'reserve' => ('${tr('Held for')}: $title0', LucideIcons.lock, -1),
      'release' => ('${tr('Back from')}: $title0', LucideIcons.undo2, 1),
      'consume' => ('${tr('Spent')}: $title0', LucideIcons.megaphone, 0),
      'expire' => (tr('Expired'), LucideIcons.hourglass, -1),
      'refund' => ('${tr('Back from')}: $title0', LucideIcons.undo2, 1),
      _ => (tr('Adjusted by OneLocal'), LucideIcons.slidersHorizontal, coins >= 0 ? 1 : -1),
    };
    final shown = sign == 0 ? coinText(coins) : '${sign > 0 ? '+' : '-'}${coinText(coins.abs())}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: sign > 0 ? const Color(0xFFF1FAD2) : const Color(0xFFEFF0EC), borderRadius: BorderRadius.circular(11)),
          child: Icon(icon, size: 17, color: kMoneyDeep),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 700)),
            Text(
              [
                dayMonth(l['created_at']?.toString()),
                if (sign == 0) tr('from held coins'),
                if (l['bucket'] == 'promotional' && l['kind'] != 'promo') tr('promotional'),
                if (pending) tr('Waiting for payment check'),
                if (cancelled) tr('Not received'),
              ].join(' · '),
              style: inter(12, 500, color: pending ? const Color(0xFFB45309) : cancelled ? const Color(0xFFC62828) : kMuted),
            ),
          ]),
        ),
        Text(shown,
            style: inter(15, 800, color: cancelled || sign == 0 ? kMuted : sign > 0 ? const Color(0xFF15803D) : kInk)
                .copyWith(decoration: cancelled ? TextDecoration.lineThrough : null)),
      ]),
    );
  }
}


// ============================================================================ top up
class TopUpScreen extends StatefulWidget {
  const TopUpScreen({super.key, required this.api, required this.home, this.suggest});
  final AdsApi api;
  final Map<String, dynamic> home;

  /// Coins to start with (what an ad still needs).
  final int? suggest;
  @override
  State<TopUpScreen> createState() => _TopUpScreenState();
}

class _TopUpScreenState extends State<TopUpScreen> {
  late final int _rupee = _int(widget.home['coin_rupees']).clamp(1, 1000);
  // what an ad still needs, in rupees; otherwise ₹5,000
  late final _amount = TextEditingController(text: '${widget.suggest == null ? 5000 : math.max(widget.suggest!, 10) * _rupee}');
  String _method = 'gpay';
  bool _busy = false;
  String _key = AdsApi.newKey();

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  int get _rupees => int.tryParse(_amount.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  int get _coinsFor => _rupees ~/ _rupee;

  static const _methods = [
    ('gpay', 'GPay', LucideIcons.smartphone, true),
    ('phonepe', 'PhonePe', LucideIcons.smartphone, true),
    ('upi', 'Any UPI', LucideIcons.qrCode, true),
    ('card', 'Card', LucideIcons.creditCard, false),
    ('netbanking', 'Net banking', LucideIcons.landmark, false),
  ];

  Future<void> _pay() async {
    if (_busy) return;
    if (_coinsFor < 10) return showToast(context, '${tr('Top up at least')} ${rs(10 * _rupee * 100)} (10 ${tr('coins')}).');
    setState(() => _busy = true);
    try {
      final r = await widget.api.topUp(_coinsFor, _method, key: _key);
      if (!mounted) return;
      final upi = '${r['upi_id'] ?? ''}';
      if (upi.isEmpty) {
        // OneLocal's UPI ID is not set up yet: the request stays, and the team gets in touch
        await _done(r, opened: false);
        return;
      }
      final opened = await openMoneyLink(upiPayLink(_method, upiId: upi, name: '${r['payee_name'] ?? 'OneLocal'}', amountMinor: _int(r['amount_minor']), note: 'Coins ${r['ref']}'));
      if (!mounted) return;
      await _done(r, opened: opened);
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not start the payment. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _done(Map<String, dynamic> r, {required bool opened}) async {
    _key = AdsApi.newKey();
    setState(() => _busy = false); // the request is in; no spinner behind the message
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Row(children: [const CoinMark(size: 24), const SizedBox(width: 8), Expanded(child: Text('${_coinWord(_int(r['coins']))} ${tr('on the way')}', style: inter(18, 800)))]),
        content: Text(
          opened
              ? '${tr('Once OneLocal sees your payment of')} ${rs(_int(r['amount_minor']))}, ${tr('the coins are added. Reference')}: ${r['ref']}.'
              : '${tr('Your top-up of')} ${rs(_int(r['amount_minor']))} ${tr('is saved (reference')} ${r['ref']}). ${tr('OneLocal will share how to pay and add the coins once paid.')}',
          style: inter(14, 500, height: 1.4),
        ),
        actions: [TextButton(key: const ValueKey('topup-ok'), onPressed: () => Navigator.pop(c), child: Text(tr('OK'), style: inter(14, 800)))],
      ),
    );
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: Column(children: [
          AppHeader(title: tr('Top up coins'), onBack: () => Navigator.of(context).maybePop()),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: moneyCard(),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(tr('Amount'), style: inter(13.5, 700, color: kMuted)),
                  TextField(
                    key: const ValueKey('topup-amount'),
                    controller: _amount,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(7)],
                    onChanged: (_) => setState(() {}),
                    style: inter(34, 800),
                    decoration: InputDecoration(prefixText: '₹ ', prefixStyle: inter(34, 800), border: InputBorder.none, isDense: true),
                  ),
                  Row(children: [
                    const CoinMark(size: 18),
                    const SizedBox(width: 6),
                    Text('= $_coinsFor ${tr('coins')}', key: const ValueKey('topup-coins'), style: inter(15, 800, color: const Color(0xFF15803D))),
                  ]),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final v in const [500, 1000, 2000, 5000])
                      ChoiceChip(
                        key: ValueKey('topup-quick-$v'),
                        label: Text(rs(v * 100), style: inter(13, 700)),
                        selected: _rupees == v,
                        onSelected: (_) => setState(() => _amount.text = '$v'),
                      ),
                  ]),
                ]),
              ),
              const SizedBox(height: 16),
              Text(tr('Pay with'), style: inter(13.5, 700, color: kMuted)),
              const SizedBox(height: 8),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.25,
                children: [for (final m in _methods) _methodTile(m)],
              ),
              const SizedBox(height: 12),
              Text(tr('You pay OneLocal by UPI. The coins show as waiting until OneLocal sees the payment, usually the same day.'), style: inter(12.5, 500, color: kMuted, height: 1.4)),
            ]),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: kCardLine))),
              child: SizedBox(
                width: double.infinity, // the whole bar, not just the label
                height: 52,
                child: FilledButton(
                  key: const ValueKey('topup-pay'),
                  onPressed: _busy ? null : _pay,
                  style: FilledButton.styleFrom(backgroundColor: kMoneyDeep, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                  child: _busy
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: kMoneyLime))
                      : Text('${tr('Make payment')} · ${rs(_rupees * 100)}', style: inter(16, 800, color: kMoneyLime)),
                ),
              ),
            ),
          ),
        ]),
      );

  Widget _methodTile((String, String, IconData, bool) m) {
    final (id, name, icon, ready) = m;
    final on = _method == id;
    return Material(
      color: on ? kMoneyDeep : Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: ValueKey('topup-method-$id'),
        borderRadius: BorderRadius.circular(16),
        onTap: ready ? () => setState(() => _method = id) : () => showToast(context, tr('Card and net banking are coming soon. Pay by UPI for now.')),
        child: Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: on ? kMoneyDeep : kCardLine)),
          child: Opacity(
            opacity: ready ? 1 : 0.45,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 20, color: on ? kMoneyLime : kInk),
              const SizedBox(height: 4),
              Text(tr(name), style: inter(13, 800, color: on ? Colors.white : kInk)),
              if (!ready) Text(tr('Soon'), style: inter(10.5, 600, color: kMuted)),
            ]),
          ),
        ),
      ),
    );
  }
}
