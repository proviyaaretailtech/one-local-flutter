import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../account/wallet_api.dart';
import '../account/wallet_screen.dart';
import '../ads/ads_api.dart';
import '../ads/ads_screens.dart';
import '../api/rpc_client.dart';
import '../auth/partner_api.dart';
import '../onboarding/document_picker.dart';
import '../orders/online_locked.dart';
import '../ui/app_header.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'money_flow.dart';
import 'money_style.dart';
import 'money_transfer.dart';
import '../ui/motion.dart';

// Store Money (founder's sketches, 28 Oct 2026): the wallet balance (cash drawer + UPI + bank, the shop's own money) with Money in, Money out
// and Transfer; on the POS + OneLocal plan, the OneLocal wallet and the ad and discount credits; then the cash register and dues.

/// The store money calls (`smoney_*`, C:\onelocal\hosted_store_money_2026-10-28.sql and hosted_money_redesign_2026-10-28.sql).
class StoreMoneyApi {
  StoreMoneyApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _http = client ?? http.Client(),
        _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final http.Client _http;
  final RpcClient _rpc;
  static final _rand = Random.secure();
  static String newKey() => 'sm-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _call(String fn, Map<String, Object?> args, {String? key}) async {
    try {
      return await _rpc.callMap(fn, {...args}..removeWhere((_, v) => v == null), key);
    } on RpcException catch (e) {
      throw PartnerApiException(e.status, e.message);
    }
  }

  Future<Map<String, dynamic>> home() => _call('smoney_home', {});
  Future<List<Map<String, dynamic>>> entries({String? from, String? to, String direction = 'all', String method = 'all', String q = ''}) async =>
      ((await _call('smoney_entries', {'from': from, 'to': to, 'direction': direction, 'method': method == 'all' ? null : method, 'q': q.trim().isEmpty ? null : q.trim()}))['entries']
                  as List? ??
              const [])
          .cast<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
  Future<Map<String, dynamic>> record(Map<String, Object?> body, {required String key}) => _call('smoney_record', body, key: key);
  Future<Map<String, dynamic>> voidEntry(String id, String reason) => _call('smoney_void', {'id': id, 'reason': reason});
  Future<Map<String, dynamic>> register({String? day}) => _call('smoney_register', {'day': day});
  Future<Map<String, dynamic>> closeDay(int countedMinor, {String? day}) => _call('smoney_close_day', {'counted_minor': countedMinor, 'day': day});
  Future<Map<String, dynamic>> dues() => _call('smoney_dues', {});

  /// Saved contacts (name, phone, UPI ID) and people money was recorded with who are not saved yet.
  Future<Map<String, dynamic>> contacts({String q = ''}) => _call('smoney_contacts', {'q': q.trim().isEmpty ? null : q.trim()});
  Future<Map<String, dynamic>> saveContact({String? id, required String name, String phone = '', String upiId = ''}) =>
      _call('smoney_contact_save', {'id': id, 'name': name, 'phone': phone, 'upi_id': upiId});

  /// Sends a proof photo to a signed slot under the business's folder; the path goes on the entry when it is saved.
  Future<String> uploadProof(PickedDocument d) async {
    final slot = await _call('smoney_proof_slot', {'content_type': d.contentType, 'size': d.bytes.length});
    final put = await _http
        .put(Uri.parse(slot['upload_url'] as String), headers: {'Content-Type': d.contentType, 'x-upsert': 'true'}, body: d.bytes)
        .timeout(const Duration(seconds: 120));
    if (put.statusCode >= 300) throw PartnerApiException(put.statusCode, tr('Could not upload the photo. Try again.'));
    return slot['path'] as String;
  }

  /// A 5-minute link to an entry's proof photo.
  Future<String> proofLink(String id) async => (await _call('smoney_proof_link', {'id': id}))['url'] as String;
}

String rs(num? minor) {
  final v = (minor ?? 0).round();
  final neg = v < 0;
  final abs = v.abs();
  final rupees = abs ~/ 100, paise = abs % 100;
  final d = rupees.toString();
  final grouped = d.length <= 3 ? d : '${d.substring(0, d.length - 3).replaceAllMapped(RegExp(r'(\d)(?=(\d\d)+$)'), (m) => '${m[1]},')},${d.substring(d.length - 3)}';
  return '${neg ? '-' : ''}₹$grouped${paise == 0 ? '' : '.${paise.toString().padLeft(2, '0')}'}';
}

String isoDay(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
const _mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String dayMonth(String? iso) {
  final d = DateTime.tryParse(iso ?? '');
  return d == null ? '' : '${d.day.toString().padLeft(2, '0')} ${_mon[d.month - 1]}';
}

const kMoneyGreen = Color(0xFF15803D), kMoneyRed = Color(0xFFC62828);
const kAccountNames = {'cash': 'Cash drawer', 'upi': 'UPI', 'bank': 'Bank'};
const kAccountIcons = {'cash': LucideIcons.wallet, 'upi': LucideIcons.smartphone, 'bank': LucideIcons.landmark};

/// How money moved: the word, and the icon.
const kMethodNames = {'cash': 'Cash', 'upi': 'UPI', 'gpay': 'GPay', 'phonepe': 'PhonePe', 'card': 'Card', 'bank': 'Bank', 'online': 'Online'};
const kMethodIcons = {
  'cash': LucideIcons.banknote,
  'upi': LucideIcons.smartphone,
  'gpay': LucideIcons.smartphone,
  'phonepe': LucideIcons.smartphone,
  'card': LucideIcons.creditCard,
  'bank': LucideIcons.landmark,
  'online': LucideIcons.globe,
};

/// What each kind of transaction is called, and which way the money goes (founder, 28 Oct 2026: income from sales of goods first, and Other on
/// both sides, with what it was written in).
const kMoneyIn = [
  ('goods_sale', 'Income (sales of goods)'),
  ('sale', 'Sale / POS collection'),
  ('other_income', 'Manual income'),
  ('due_received', 'Customer paid due'),
  ('owner_in', 'Capital infusion'),
  ('partner_topup', 'Partner top-up'),
  ('aggregator_settlement', 'Aggregator settlement'),
  ('other_in', 'Other'),
];
const kMoneyOut = [
  ('expense', 'Expense'),
  ('purchase', 'Purchase / raw material'),
  ('supplier_payment', 'Supplier payment'),
  ('salary', 'Salary / wages'),
  ('owner_out', 'Owner withdrawal'),
  ('refund', 'Refund to customer'),
  ('other_out', 'Other'),
];
const kOtherKinds = {'other_in', 'other_out'};

/// An entry's type as the owner reads it: for Other, what they typed.
String entryType(Map e) {
  final custom = '${e['category'] ?? ''}'.trim();
  return kOtherKinds.contains(e['kind']) && custom.isNotEmpty ? custom : tr(kindWord('${e['kind']}'));
}
const kExpenseHeads = ['Rent', 'Electricity', 'Transport', 'Packaging', 'Repairs', 'Tea & snacks', 'Other'];
String kindWord(String k) => switch (k) {
      'sales' => 'Sales',
      'transfer' || 'transfer_in' || 'transfer_out' => 'Account transfer',
      'cash_difference' => 'Cash difference at close',
      _ => [...kMoneyIn, ...kMoneyOut].where((e) => e.$1 == k).map((e) => e.$2).firstOrNull ?? k,
    };

/// The store's Money tab: the wallet balance with Money in, Money out and Transfer; the OneLocal cards on the POS + OneLocal plan; the cash
/// register and dues below.
class StoreMoneyScreen extends StatefulWidget {
  const StoreMoneyScreen({super.key, this.api, this.walletApi, this.adsApi, this.plan, this.today});
  final StoreMoneyApi? api;
  final WalletApi? walletApi;
  final AdsApi? adsApi;

  /// Tests set the plan; otherwise the store's own ([StorePlan]).
  final String? plan;

  /// Tests fix "today".
  final DateTime? today;
  @override
  State<StoreMoneyScreen> createState() => _StoreMoneyScreenState();
}

class _StoreMoneyScreenState extends State<StoreMoneyScreen> {
  late final StoreMoneyApi _api = widget.api ?? StoreMoneyApi();
  Map<String, dynamic>? _home;
  String? _error;
  String? _plan;
  num? _onelocalWallet; // what OneLocal owes the store (rupees), on the POS + OneLocal plan
  int? _adCoins; // the shop's ad coins (1 coin = ₹10), on the same plan
  String _part = 'register';
  int _reload = 0; // bumps the section below after a change

  bool get _sellsOnline => _plan == 'pos_and_onelocal';

  @override
  void initState() {
    super.initState();
    _load();
    _loadPlan();
  }

  Future<void> _loadPlan() async {
    final plan = widget.plan ?? await StorePlan.get();
    if (!mounted) return;
    setState(() => _plan = plan);
    if (plan != 'pos_and_onelocal') return;
    try {
      final w = await (widget.walletApi ?? WalletApi()).overview();
      if (mounted) setState(() => _onelocalWallet = w.unsettledDue + w.onTheWay);
    } catch (_) {
      // the card shows a dash; the wallet screen says why
    }
    await _loadCoins();
  }

  Future<void> _loadCoins() async {
    try {
      final h = await (widget.adsApi ?? AdsApi()).home();
      if (mounted) setState(() => _adCoins = (h['coins'] as num?)?.round());
    } catch (_) {} // the card shows a dash; Ads says why
  }

  Future<void> _load() async {
    try {
      final h = await _api.home();
      if (mounted) {
        setState(() {
          _home = h;
          _error = null;
          _reload++;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : tr('Could not load money. Check your connection.'));
    }
  }

  Future<void> _open(Widget screen) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => screen));
    if (changed == true && mounted) _load();
    if (mounted) _load(); // an entry may have been saved before the screen closed
  }

  Map<String, dynamic> get _shop => ((_home?['shop'] as Map?) ?? const {}).cast<String, dynamic>();

  void _flow(String direction) => _open(MoneyFlowScreen(
        shop: _shop,
        api: _api,
        direction: direction,
        canRecord: _home?['can_record'] == true,
        canVoid: _home?['can_void'] == true,
        today: widget.today,
      ));

  Future<void> _entry({required String direction, String? kind, Map<String, dynamic>? bill, String? party}) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => MoneyEntryScreen(api: _api, direction: direction, kind: kind, bill: bill, party: party, shop: _shop),
    ));
    if (saved == true && mounted) _load();
  }

  /// A button inside the dark card: a soft dark square (lime for Transfer), the label under it.
  Widget _action(String label, IconData icon, String key, VoidCallback? onTap, {bool lime = false}) => Expanded(
        child: Opacity(
          opacity: onTap == null ? 0.45 : 1,
          child: Material(
            color: lime ? kMoneyLime : kMoneyDeepSoft,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              key: ValueKey(key),
              borderRadius: BorderRadius.circular(20),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Column(children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(color: lime ? kMoneyDeep : const Color(0xFF3A3F47), borderRadius: BorderRadius.circular(12)),
                    child: Icon(icon, size: 19, color: lime ? kMoneyLime : Colors.white),
                  ),
                  const SizedBox(height: 8),
                  Text(tr(label), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12.5, 700, color: lime ? kMoneyDeep : Colors.white)),
                ]),
              ),
            ),
          ),
        ),
      );

  Widget _wallet(Map<String, dynamic> h) {
    final accounts = (h['accounts'] as List? ?? const []).cast<Map>();
    final canRecord = h['can_record'] == true;
    return MoneyDarkCard(
      child: Column(children: [
        Text(tr('Your wallet balance'), style: inter(13.5, 500, color: const Color(0xFFB8BCC4))),
        const SizedBox(height: 6),
        FittedBox(fit: BoxFit.scaleDown, child: Text(rs(h['total_minor'] as num?), key: const ValueKey('money-total'), style: inter(38, 800, color: Colors.white))),
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
                Text('${tr('${a['name']}')} ${rs(a['balance_minor'] as num?)}', style: inter(11.5, 600, color: Colors.white)),
              ]),
            ),
        ]),
        const SizedBox(height: 18),
        Row(children: [
          _action('Money in', LucideIcons.arrowDownToLine, 'money-in', () => _flow('in')),
          const SizedBox(width: 10),
          _action('Money out', LucideIcons.arrowUpFromLine, 'money-out', () => _flow('out')),
          const SizedBox(width: 10),
          _action('Transfer', LucideIcons.arrowLeftRight, 'money-transfer', canRecord ? () => _open(MoneyTransferScreen(api: _api, shop: _shop)) : null, lime: true),
        ]),
      ]),
    );
  }

  /// The POS + OneLocal plan: the OneLocal wallet (lime strip, dark body: what OneLocal owes the store), then the ad and discount credits.
  Widget _onelocalCards() {
    // Ad credits open the Ads section, in coins (founder, 29 Oct 2026); Discount credits are still to come
    Future<void> open(String key) async {
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => key == 'ad-credits' ? AdsHomeScreen(api: widget.adsApi) : const AdsCommissionScreen()));
      if (mounted) _loadCoins();
    }
    // as strong as the cards above (founder, 28 Oct 2026): Ad credits on lime, Discount credits on dark, each with an icon badge and View
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
                  Text(tr(title), style: inter(13, 700, color: soft)),
                  const SizedBox(height: 2),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: key == 'ad-credits'
                        ? Row(mainAxisSize: MainAxisSize.min, children: [
                            const CoinMark(size: 22),
                            const SizedBox(width: 6),
                            Text(_adCoins == null ? '—' : '${_adCoins!}', key: const ValueKey('ad-credits-coins'), style: inter(26, 800, color: fg)),
                            const SizedBox(width: 4),
                            Text(tr('coins'), style: inter(13, 700, color: soft)),
                          ])
                        : Text(rs(0), style: inter(26, 800, color: fg)),
                  ),
                  const SizedBox(height: 2),
                  Text(tr(sub), style: inter(11.5, 500, color: soft)),
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
                  Expanded(child: Text(tr('OneLocal wallet'), style: inter(13.5, 800, color: kMoneyDeep))),
                  Text(tr('From your online orders'), style: inter(11.5, 600, color: kMoneyDeep)),
                ]),
              ),
              Container(
                color: kMoneyDeep,
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(tr('Due to you'), style: inter(12, 500, color: const Color(0xFFB8BCC4))),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(_onelocalWallet == null ? '—' : rs(_onelocalWallet! * 100), key: const ValueKey('onelocal-wallet-amount'), style: inter(26, 800, color: Colors.white)),
                      ),
                    ]),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(color: kMoneyDeepSoft, borderRadius: BorderRadius.circular(40)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(tr('View'), style: inter(12.5, 700, color: kMoneyLime)),
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
          credit('ad-credits', 'Ad credits', 'To promote your shop', LucideIcons.megaphone, dark: false),
          const SizedBox(width: 12),
          credit('discount-credits', 'Discount credits', 'Discount against commission', LucideIcons.badgePercent, dark: true),
        ]),
      ),
    ]);
  }

  Widget _parts() => MoneyPills(
        keyPrefix: 'money-part',
        options: [('register', tr('Cash register')), ('dues', tr('Dues'))],
        selected: _part,
        onSelect: (id) => setState(() => _part = id),
      );

  @override
  Widget build(BuildContext context) {
    final h = _home;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(title: tr('Money'), onBack: Navigator.of(context).canPop() ? () => Navigator.of(context).maybePop() : null),
        Expanded(
          child: _error != null && h == null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kMuted))))
              : h == null
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(key: const ValueKey('store-money'), padding: const EdgeInsets.fromLTRB(14, 12, 14, 28), children: staggered([
                        _wallet(h),
                        if (_sellsOnline) ...[const SizedBox(height: 12), _onelocalCards()],
                        const SizedBox(height: 18),
                        _parts(),
                        const SizedBox(height: 12),
                        switch (_part) {
                          'dues' => _DuesPart(
                              key: ValueKey('dues-$_reload'),
                              api: _api,
                              onPay: (kind, bill, party) => _entry(direction: kind == 'due_received' ? 'in' : 'out', kind: kind, bill: bill, party: party),
                            ),
                          _ => _RegisterPart(key: ValueKey('register-$_reload'), api: _api, canRecord: h['can_record'] == true, onChanged: _load),
                        },
                      ])),
                    ),
        ),
      ]),
    );
  }
}

/// Discount credits (POS + OneLocal plan): still to come; ad credits are coins in the Ads section.
class AdsCommissionScreen extends StatelessWidget {
  const AdsCommissionScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: Column(children: [
          AppHeader(title: tr('Discount credits'), onBack: () => Navigator.of(context).maybePop()),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(LucideIcons.megaphone, size: 40, color: kMoneyGreen),
                  const SizedBox(height: 12),
                  Text(tr('Coming soon'), style: inter(20, 800)),
                  const SizedBox(height: 6),
                  Text(tr('The discount credits that lower your OneLocal commission will show here.'),
                      textAlign: TextAlign.center, style: inter(14, 500, color: kMuted)),
                ]),
              ),
            ),
          ),
        ]),
      );
}

// ------------------------------------------------------------------------------------------------------------------- cash register
class _RegisterPart extends StatefulWidget {
  const _RegisterPart({super.key, required this.api, required this.canRecord, required this.onChanged});
  final StoreMoneyApi api;
  final bool canRecord;
  final VoidCallback onChanged;
  @override
  State<_RegisterPart> createState() => _RegisterPartState();
}

class _RegisterPartState extends State<_RegisterPart> {
  Map<String, dynamic>? _r;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.register();
      if (mounted) {
        setState(() {
          _r = r;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : tr('Could not load the cash register.'));
    }
  }

  Future<void> _close() async {
    final c = TextEditingController();
    final counted = await showOlDialog<num>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Close day'), style: inter(18, 700)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${tr('Should be in the drawer')}: ${rs(_r?['expected_minor'] as num?)}', style: inter(14, 600)),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('close-counted'),
            controller: c,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: InputDecoration(labelText: tr('Cash you counted'), prefixText: '₹ '),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Not now'), style: inter(14, 600))),
          TextButton(key: const ValueKey('close-confirm'), onPressed: () => Navigator.pop(ctx, num.tryParse(c.text.trim())), child: Text(tr('Close day'), style: inter(14, 700))),
        ],
      ),
    );
    if (counted == null || !mounted) return;
    try {
      final r = await widget.api.closeDay((counted * 100).round());
      if (!mounted) return;
      setState(() => _r = r);
      final diff = ((r['closed'] as Map?)?['difference_minor'] as num?) ?? 0;
      showToast(context, diff == 0 ? tr('Day closed. The cash matches.') : '${tr('Day closed.')} ${diff > 0 ? tr('Extra') : tr('Short')} ${rs(diff.abs())}.');
      widget.onChanged();
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not close the day. Try again.'));
    }
  }

  Widget _kv(String k, num? v, {bool bold = false, Color? color, String sign = ''}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Expanded(child: Text(tr(k), style: inter(14, bold ? 700 : 500, color: bold ? kInk : kMuted))),
          Text('$sign${rs(v)}', style: inter(bold ? 18 : 14.5, bold ? 800 : 700, color: color ?? kInk)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final r = _r;
    if (_error != null && r == null) return Text(_error!, style: inter(13.5, 500, color: kMuted));
    if (r == null) return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()));
    final closed = r['closed'] as Map?;
    return Container(
      key: const ValueKey('cash-register'),
      padding: const EdgeInsets.all(16),
      decoration: moneyCard(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${tr('Cash drawer')} · ${dayMonth('${r['day']}')}', style: inter(15.5, 800)),
        const SizedBox(height: 8),
        _kv('Opening cash', r['opening_minor'] as num?),
        _kv('Cash sales', r['sales_minor'] as num?, sign: '+ ', color: kMoneyGreen),
        _kv('Other cash in', r['cash_in_minor'] as num?, sign: '+ ', color: kMoneyGreen),
        _kv('Cash refunds', r['refunds_minor'] as num?, sign: '− ', color: kMoneyRed),
        _kv('Cash paid out', r['cash_out_minor'] as num?, sign: '− ', color: kMoneyRed),
        const Divider(height: 20),
        _kv('Should be in the drawer', r['expected_minor'] as num?, bold: true),
        const SizedBox(height: 10),
        if (closed != null)
          Container(
            key: const ValueKey('day-closed'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: kNote, borderRadius: BorderRadius.circular(12)),
            child: Text(
              '${tr('Closed by')} ${closed['by'] ?? ''} · ${tr('counted')} ${rs(closed['counted_minor'] as num?)}'
              '${(closed['difference_minor'] as num? ?? 0) == 0 ? ' · ${tr('matched')}' : ' · ${(closed['difference_minor'] as num) > 0 ? tr('extra') : tr('short')} ${rs((closed['difference_minor'] as num).abs())}'}',
              style: inter(13.5, 600),
            ),
          )
        else if (widget.canRecord)
          FilledButton(
            key: const ValueKey('close-day'),
            onPressed: _close,
            style: FilledButton.styleFrom(backgroundColor: kPrimary, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            child: Text(tr('Close day · count the cash'), style: inter(15, 700, color: Colors.white)),
          ),
      ]),
    );
  }
}

// ------------------------------------------------------------------------------------------------------------------- dues
class _DuesPart extends StatefulWidget {
  const _DuesPart({super.key, required this.api, required this.onPay});
  final StoreMoneyApi api;
  final void Function(String kind, Map<String, dynamic>? bill, String? party) onPay;
  @override
  State<_DuesPart> createState() => _DuesPartState();
}

class _DuesPartState extends State<_DuesPart> {
  Map<String, dynamic>? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.dues();
      if (mounted) {
        setState(() {
          _d = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : tr('Could not load dues.'));
    }
  }

  Widget _card(String title, String sub, num? due, String action, VoidCallback onTap, Key key) => Container(
        key: key,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: moneyCard(),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: inter(14.5, 700)),
              if (sub.isNotEmpty) Text(sub, style: inter(12, 400, color: kMuted)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(rs(due), style: inter(15, 800)),
            TextButton(onPressed: onTap, style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero), child: Text(tr(action), style: inter(13, 700, color: kLink))),
          ]),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (_error != null && d == null) return Text(_error!, style: inter(13.5, 500, color: kMuted));
    if (d == null) return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()));
    final customers = (d['customers'] as List? ?? const []).cast<Map>();
    final suppliers = (d['suppliers'] as List? ?? const []).cast<Map>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Customers who owe you'), style: inter(15, 800)),
      const SizedBox(height: 6),
      if (customers.isEmpty)
        Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(tr('Nobody owes you right now.'), style: inter(13, 500, color: kMuted)))
      else
        for (final c in customers)
          _card('${c['party']}', '', c['due_minor'] as num?, 'Got paid', () => widget.onPay('due_received', null, '${c['party']}'), ValueKey('due-customer-${c['party']}')),
      const SizedBox(height: 10),
      Text(tr('Supplier bills to pay'), style: inter(15, 800)),
      const SizedBox(height: 6),
      if (suppliers.isEmpty)
        Text(tr('No unpaid supplier bills.'), style: inter(13, 500, color: kMuted))
      else
        for (final s in suppliers)
          _card(
            '${s['supplier']}',
            [if ('${s['invoice_no'] ?? ''}'.isNotEmpty) '${tr('Invoice')} ${s['invoice_no']}', if (s['invoice_date'] != null) dayMonth('${s['invoice_date']}'),
              if ((s['paid_minor'] as num? ?? 0) > 0) '${tr('paid')} ${rs(s['paid_minor'] as num?)}'].join(' · '),
            s['due_minor'] as num?,
            'Pay',
            () => widget.onPay('supplier_payment', s.cast<String, dynamic>(), null),
            ValueKey('due-bill-${s['receipt_document_id']}'),
          ),
    ]);
  }
}
