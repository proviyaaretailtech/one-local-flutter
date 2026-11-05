import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../money/money_flow.dart' show MoneyFlowScreen;
import '../money/money_style.dart';
import '../money/money_transfer.dart' show MoneyTransferScreen;
import '../account/wallet_api.dart';
import '../account/wallet_screen.dart';
import '../ads/ads_api.dart';
import '../ads/ads_screens.dart' show AdsHomeScreen, CoinMark, creditPlain;
import '../money/store_money.dart' show AdsCommissionScreen, StoreMoneyApi, rs, dayMonth, kAccountIcons, kMoneyGreen, kMoneyRed;
import '../orders/order_widgets.dart' show OrderCardBox;
import '../ui/motion.dart' show showOlDialog;
import '../ui/theme.dart';
import '../auth/partner_api.dart' show PartnerApiException;
import 'bills_screen.dart';
import 'service_api.dart';
import 'service_widgets.dart';

/// Money for a service business (founder, 2 Nov 2026: "replicate the money section from store POS … make it service specific"). The store's
/// wallet in its look (cash drawer + UPI + bank, with Money in, Money out and Transfer, from the same `smoney_*` books), then what is
/// service-only: money from services split by bookings, jobs, bills made here and packages, offline / online and how it was paid
/// (`svc_money_split`); the cash drawer, where cash from services goes; and the customers who still owe on a bill.
class ServiceMoneyScreen extends StatefulWidget {
  const ServiceMoneyScreen({super.key, this.api, this.moneyApi, this.walletApi, this.adsApi, this.onNavigate});
  final ServiceApi? api;
  final StoreMoneyApi? moneyApi;
  final WalletApi? walletApi;
  final AdsApi? adsApi;
  final ValueChanged<String>? onNavigate;
  @override
  State<ServiceMoneyScreen> createState() => _ServiceMoneyScreenState();
}

class _ServiceMoneyScreenState extends State<ServiceMoneyScreen> {
  late final ServiceApi _api = widget.api ?? ServiceApi();
  late final StoreMoneyApi _money = widget.moneyApi ?? StoreMoneyApi();
  Map<String, dynamic>? _home, _register;
  MoneySplitData? _split;
  BillListData? _dues;
  String? _error;
  String _period = 'today';
  num? _onelocalWallet; // what OneLocal owes the business from online bookings (rupees)
  int? _adCoins; // ad coins (1 coin = ₹10)
  String _part = 'cash';

  @override
  void initState() {
    super.initState();
    _load();
    _loadOnelocal();
  }

  /// The OneLocal wallet and the ad coins, as on the store's Money (founder, 4 Nov 2026: the credits and commission section). A card that
  /// cannot load shows a dash; its own screen says why.
  Future<void> _loadOnelocal() async {
    try {
      final w = await (widget.walletApi ?? WalletApi()).overview();
      if (mounted) setState(() => _onelocalWallet = w.unsettledDue + w.onTheWay);
    } catch (_) {}
    await _loadCoins();
  }

  Future<void> _loadCoins() async {
    try {
      final h = await (widget.adsApi ?? AdsApi()).home();
      if (mounted) setState(() => _adCoins = (h['coins'] as num?)?.round());
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await Future.wait([_money.home(), _api.moneySplit(), _money.register(), _api.bills(filter: 'due')]);
      if (!mounted) return;
      setState(() {
        _home = r[0] as Map<String, dynamic>;
        _split = r[1] as MoneySplitData;
        _register = r[2] as Map<String, dynamic>;
        _dues = r[3] as BillListData;
      });
    } on ServiceApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on PartnerApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load money. Check the connection and try again.');
    }
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  Map<String, dynamic> get _shop => ((_home?['shop'] as Map?) ?? const {}).cast<String, dynamic>();

  @override
  Widget build(BuildContext context) {
    final h = _home, s = _split, r = _register, d = _dues;
    return ServicePage(
      title: 'Money',
      subtitle: 'Your wallet, money from services, cash and dues',
      onRefresh: _load,
      onNavigate: widget.onNavigate,
      error: _error,
      onRetry: _load,
      body: h == null || s == null || r == null || d == null
          ? null
          : [
              _wallet(h),
              const SizedBox(height: 12),
              _onelocalCards(),
              const SizedBox(height: 12),
              _fromServices(s),
              const SizedBox(height: 16),
              MoneyPills(
                keyPrefix: 'money-part',
                options: [('cash', 'Cash drawer'), ('dues', 'Customers owe ${svcRupees(s.due)}')],
                selected: _part,
                onSelect: (id) => setState(() => _part = id),
              ),
              const SizedBox(height: 10),
              if (_part == 'dues') _duesPart(d) else _cashPart(r, h['can_record'] == true),
            ],
    );
  }

  // ------------------------------------------------------------------------------------------------ OneLocal wallet and credits
  /// As the store's: the OneLocal wallet (lime strip, dark body: what OneLocal owes you from online bookings), then Ad credits (coins, to
  /// promote your business) and Discount credits (against OneLocal's commission).
  Widget _onelocalCards() {
    Future<void> open(String key) async {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => key == 'ad-credits' ? AdsHomeScreen(api: widget.adsApi) : const AdsCommissionScreen()));
      if (mounted) _loadCoins();
    }

    Widget credit(String key, String title, String sub, IconData icon, {required bool dark}) {
      final bg = dark ? kMoneyDeep : kMoneyLime, fg = dark ? Colors.white : kMoneyDeep, soft = dark ? const Color(0xFFB8BCC4) : const Color(0xFF3F4A12);
      return Expanded(
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(kMoneyCardRadius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey(key),
            onTap: () => open(key),
            child: Stack(children: [
              if (dark) const Positioned.fill(child: MoneyRings(opacity: 0.06)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 14, 14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(color: dark ? kMoneyDeepSoft : kMoneyDeep, borderRadius: BorderRadius.circular(11)),
                      child: Icon(icon, size: 17, color: kMoneyLime),
                    ),
                    const Spacer(),
                    Icon(LucideIcons.arrowUpRight, size: 18, color: fg),
                  ]),
                  const SizedBox(height: 12),
                  Text(title, style: inter(13, 700, color: soft)),
                  const SizedBox(height: 2),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: key == 'ad-credits'
                        ? Row(mainAxisSize: MainAxisSize.min, children: [
                            const CoinMark(size: 22),
                            const SizedBox(width: 6),
                            Text(_adCoins == null ? '—' : creditPlain(_adCoins), key: const ValueKey('ad-credits-coins'), style: inter(26, 800, color: fg)),
                          ])
                        : Text(rs(0), style: inter(26, 800, color: fg)),
                  ),
                  const SizedBox(height: 2),
                  Text(sub, style: inter(11.5, 500, color: soft)),
                ]),
              ),
            ]),
          ),
        ),
      );
    }

    return Column(children: [
      Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('onelocal-wallet'),
          borderRadius: BorderRadius.circular(kMoneyCardRadius),
          onTap: () => Navigator.of(context).push(WalletScreen.route(api: widget.walletApi)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(kMoneyCardRadius),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                color: kMoneyLime,
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
                child: Row(children: [
                  const Icon(LucideIcons.store, size: 16, color: kMoneyDeep),
                  const SizedBox(width: 8),
                  Expanded(child: Text('OneLocal wallet', style: inter(13.5, 800, color: kMoneyDeep))),
                  Text('From your online bookings', style: inter(11.5, 600, color: kMoneyDeep)),
                ]),
              ),
              Container(
                color: kMoneyDeep,
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Due to you', style: inter(12, 500, color: const Color(0xFFB8BCC4))),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(_onelocalWallet == null ? '—' : rs(_onelocalWallet! * 100), key: const ValueKey('onelocal-wallet-amount'),
                            style: inter(26, 800, color: Colors.white)),
                      ),
                    ]),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(color: kMoneyDeepSoft, borderRadius: BorderRadius.circular(40)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('View', style: inter(12.5, 700, color: kMoneyLime)),
                      const SizedBox(width: 4),
                      const Icon(LucideIcons.arrowUpRight, size: 14, color: kMoneyLime),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
      const SizedBox(height: 12),
      IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          credit('ad-credits', 'Ad credits', 'To promote your business', LucideIcons.megaphone, dark: false),
          const SizedBox(width: 12),
          credit('discount-credits', 'Discount credits', 'Discount against commission', LucideIcons.badgePercent, dark: true),
        ]),
      ),
    ]);
  }

  // ------------------------------------------------------------------------------------------------ the wallet (as the store's)
  Widget _wallet(Map<String, dynamic> h) {
    final accounts = (h['accounts'] as List? ?? const []).cast<Map>();
    final canRecord = h['can_record'] == true;
    return MoneyDarkCard(
      child: Column(children: [
        Text('Your wallet balance', style: inter(13.5, 500, color: const Color(0xFFB8BCC4))),
        const SizedBox(height: 6),
        FittedBox(fit: BoxFit.scaleDown, child: Text(rs(h['total_minor'] as num?), key: const ValueKey('money-total'), style: inter(34, 800, color: Colors.white))),
        const SizedBox(height: 10),
        Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 6, children: [
          for (final a in accounts)
            Container(
              key: ValueKey('account-${a['key']}'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(color: kMoneyDeepSoft, borderRadius: BorderRadius.circular(40)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(kAccountIcons[a['key']] ?? LucideIcons.wallet, size: 12, color: kMoneyLime),
                const SizedBox(width: 5),
                Text('${a['name']} ${rs(a['balance_minor'] as num?)}', style: inter(11.5, 600, color: Colors.white)),
              ]),
            ),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          _action('Money in', LucideIcons.arrowDownToLine, 'money-in', () => _flow('in', h)),
          const SizedBox(width: 10),
          _action('Money out', LucideIcons.arrowUpFromLine, 'money-out', () => _flow('out', h)),
          const SizedBox(width: 10),
          _action('Transfer', LucideIcons.arrowLeftRight, 'money-transfer', canRecord ? () => _open(MoneyTransferScreen(api: _money, shop: _shop)) : null, lime: true),
        ]),
      ]),
    );
  }

  void _flow(String direction, Map<String, dynamic> h) => _open(MoneyFlowScreen(
        shop: _shop,
        api: _money,
        direction: direction,
        canRecord: h['can_record'] == true,
        canVoid: h['can_void'] == true,
      ));

  Widget _action(String label, IconData icon, String key, VoidCallback? onTap, {bool lime = false}) => Expanded(
        child: Opacity(
          opacity: onTap == null ? 0.45 : 1,
          child: Material(
            color: lime ? kMoneyLime : kMoneyDeepSoft,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              key: ValueKey(key),
              borderRadius: BorderRadius.circular(18),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(color: lime ? kMoneyDeep : const Color(0xFF3A3F47), borderRadius: BorderRadius.circular(11)),
                    child: Icon(icon, size: 17, color: lime ? kMoneyLime : Colors.white),
                  ),
                  const SizedBox(height: 6),
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 700, color: lime ? kMoneyDeep : Colors.white)),
                ]),
              ),
            ),
          ),
        ),
      );

  // ------------------------------------------------------------------------------------------------ money from services (service-only)
  static const _kinds = [
    ('bookings', 'Bookings', Color(0xFF16A34A)),
    ('jobs', 'Jobs', Color(0xFF2563EB)),
    ('bills', 'Bills made here', Color(0xFF7C3AED)),
    ('packages', 'Packages & memberships', Color(0xFFD97706)),
  ];

  Widget _fromServices(MoneySplitData s) {
    final p = _period == 'month' ? s.month : s.today;
    final total = p.n('total');
    final online = p.n('online'), offline = p.n('offline');
    return Container(
      key: const ValueKey('money-services'),
      padding: const EdgeInsets.all(14),
      decoration: moneyCard(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('From your services', style: inter(15, 800))),
          MoneyPills(keyPrefix: 'money-period', options: const [('today', 'Today'), ('month', 'Month')], selected: _period, onSelect: (v) => setState(() => _period = v)),
        ]),
        const SizedBox(height: 8),
        InkWell(
          key: const ValueKey('money-services-total'),
          onTap: () => _open(BillsScreen(api: _api, filter: _period == 'month' ? 'paid' : 'today')),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(svcRupees(total), style: inter(26, 800)),
            const SizedBox(width: 6),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(_period == 'month' ? 'taken this month' : 'taken today', style: inter(12.5, 500, color: kMuted)),
            ),
            const Spacer(),
            const Padding(padding: EdgeInsets.only(bottom: 6), child: Icon(LucideIcons.chevronRight, size: 16, color: kMuted)),
          ]),
        ),
        const SizedBox(height: 8),
        // one bar split by kind, then the kinds
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 8,
            child: total <= 0
                ? Container(color: kLine)
                : Row(children: [
                    for (final (id, _, c) in _kinds)
                      if (p.n(id) > 0) Expanded(flex: (p.n(id) * 100 / total).round().clamp(1, 100), child: Container(color: c)),
                  ]),
          ),
        ),
        const SizedBox(height: 8),
        for (final (id, label, c) in _kinds)
          Padding(
            key: ValueKey('money-kind-$id'),
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(child: Text(label, style: inter(13, 500, color: kMuted))),
              Text(svcRupees(p.n(id)), style: inter(13.5, 700)),
            ]),
          ),
        const Divider(height: 18),
        Row(children: [
          Expanded(child: _pair('Offline (in the POS)', offline, key: 'money-offline')),
          Expanded(child: _pair('Online (customer app)', online, key: 'money-online')),
        ]),
        const SizedBox(height: 8),
        Text(
          'Cash ${svcRupees(p.n('cash'))} · UPI ${svcRupees(p.n('upi'))} · Card/other ${svcRupees(p.n('card'))}'
          '${p.n('refunds') > 0 ? ' · refunds ${svcRupees(p.n('refunds'))}' : ''}',
          key: const ValueKey('money-methods'),
          style: inter(12, 500, color: kMuted),
        ),
      ]),
    );
  }

  Widget _pair(String label, num v, {required String key}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: inter(11.5, 500, color: kMuted)),
        Text(svcRupees(v), key: ValueKey(key), style: inter(15, 800)),
      ]);

  // ------------------------------------------------------------------------------------------------ the cash drawer
  Widget _cashPart(Map<String, dynamic> r, bool canRecord) {
    final closed = r['closed'] as Map?;
    Widget kv(String k, num? v, {bool bold = false, Color? color, String sign = ''}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Text(k, style: inter(13.5, bold ? 700 : 500, color: bold ? kInk : kMuted))),
            Text('$sign${rs(v)}', style: inter(bold ? 17 : 14, bold ? 800 : 700, color: color ?? kInk)),
          ]),
        );
    return Container(
      key: const ValueKey('cash-register'),
      padding: const EdgeInsets.all(14),
      decoration: moneyCard(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Cash drawer · ${dayMonth('${r['day']}')}', style: inter(15, 800)),
        const SizedBox(height: 6),
        kv('Opening cash', r['opening_minor'] as num?),
        kv('Cash from services', r['sales_minor'] as num?, sign: '+ ', color: kMoneyGreen),
        kv('Other cash in', r['cash_in_minor'] as num?, sign: '+ ', color: kMoneyGreen),
        kv('Cash refunds', r['refunds_minor'] as num?, sign: '− ', color: kMoneyRed),
        kv('Cash paid out', r['cash_out_minor'] as num?, sign: '− ', color: kMoneyRed),
        const Divider(height: 18),
        kv('Should be in the drawer', r['expected_minor'] as num?, bold: true),
        const SizedBox(height: 10),
        if (closed != null)
          Container(
            key: const ValueKey('day-closed'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: kNote, borderRadius: BorderRadius.circular(12)),
            child: Text(
              'Closed by ${closed['by'] ?? ''} · counted ${rs(closed['counted_minor'] as num?)}'
              '${(closed['difference_minor'] as num? ?? 0) == 0 ? ' · matched' : ' · ${(closed['difference_minor'] as num) > 0 ? 'extra' : 'short'} ${rs((closed['difference_minor'] as num).abs())}'}',
              style: inter(13, 600),
            ),
          )
        else if (canRecord)
          FilledButton(
            key: const ValueKey('close-day'),
            onPressed: () => _closeDay(r),
            style: FilledButton.styleFrom(backgroundColor: kMoneyDeep, padding: const EdgeInsets.symmetric(vertical: 13), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            child: Text('Close day · count the cash', style: inter(14.5, 700, color: Colors.white)),
          ),
      ]),
    );
  }

  Future<void> _closeDay(Map<String, dynamic> r) async {
    final c = TextEditingController();
    final counted = await showOlDialog<num>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Close day', style: inter(18, 700)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Should be in the drawer: ${rs(r['expected_minor'] as num?)}', style: inter(14, 600)),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('close-counted'),
            controller: c,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: const InputDecoration(labelText: 'Cash you counted', prefixText: '₹ '),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Not now', style: inter(14, 600))),
          TextButton(key: const ValueKey('close-confirm'), onPressed: () => Navigator.pop(ctx, num.tryParse(c.text.trim())), child: Text('Close day', style: inter(14, 700))),
        ],
      ),
    );
    if (counted == null || !mounted) return;
    try {
      final done = await _money.closeDay((counted * 100).round());
      if (!mounted) return;
      final diff = ((done['closed'] as Map?)?['difference_minor'] as num?) ?? 0;
      showToast(context, diff == 0 ? 'Day closed. The cash matches.' : 'Day closed. ${diff > 0 ? 'Extra' : 'Short'} ${rs(diff.abs())}.');
      _load();
    } on PartnerApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not close the day. Try again.');
    }
  }

  // ------------------------------------------------------------------------------------------------ customers who owe (unpaid service bills)
  Widget _duesPart(BillListData d) {
    if (d.bills.isEmpty) return OrderCardBox(child: Text('Nobody owes you right now. Every bill is paid.', style: inter(14, 400, color: kMuted)));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final b in d.bills)
        Container(
          key: ValueKey('due-bill-${b.id}'),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: moneyCard(),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(b.customer.isEmpty ? 'Walk-in customer' : b.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 700)),
                Text([b.displayNo, if (b.title.isNotEmpty) b.title, if (b.dateLabel.isNotEmpty) b.dateLabel].join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 400, color: kMuted)),
              ]),
            ),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(svcRupees(b.due), style: inter(15, 800, color: kMoneyRed)),
              TextButton(
                key: ValueKey('collect-${b.id}'),
                onPressed: () => _open(BillDetailScreen(api: _api, id: b.id, onNavigate: widget.onNavigate)),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                child: Text('Collect', style: inter(13, 700, color: kLink)),
              ),
            ]),
          ]),
        ),
    ]);
  }
}
