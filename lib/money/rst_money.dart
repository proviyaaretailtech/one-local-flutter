import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../account/wallet_api.dart';
import '../account/wallet_screen.dart';
import '../ads/ads_api.dart';
import '../ads/ads_screens.dart' show AdsHomeScreen;
import '../api/net_guard.dart';
import '../ui/app_header.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'rst_money_api.dart';
import 'rst_money_flow.dart';

// Restaurant Money in the store's design (founder, 29 Oct 2026: "keep money built like this for restaurant POS", rebuilt here): the wallet
// balance (cash drawer + UPI + bank) with Money in, Money out and Transfer; the OneLocal wallet and the ad and discount credits; then the
// cash register (with Close day) and dues. Data: `rmoney_*` (0622) over what the restaurant already records.

const kRmDeep = Color(0xFF16181D); // the dark cards
const kRmDeepSoft = Color(0xFF2A2E35); // buttons on a dark card
const kRmLime = Color(0xFFD2F64B); // the main action, highlights
const kRmRadius = 26.0;
const kRmGreen = Color(0xFF15803D), kRmRed = Color(0xFFC62828);

/// "₹1,23,456" or "₹12.50" from paise.
String rs(num? minor) {
  final v = (minor ?? 0).round();
  final abs = v.abs();
  final rupees = abs ~/ 100, paise = abs % 100;
  final d = rupees.toString();
  final grouped = d.length <= 3 ? d : '${d.substring(0, d.length - 3).replaceAllMapped(RegExp(r'(\d)(?=(\d\d)+$)'), (m) => '${m[1]},')},${d.substring(d.length - 3)}';
  return '${v < 0 ? '-' : ''}₹$grouped${paise == 0 ? '' : '.${paise.toString().padLeft(2, '0')}'}';
}

String isoDay(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
const _mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "29 Oct" from "2026-10-29".
String dayMonth(String? iso) {
  final d = DateTime.tryParse(iso ?? '');
  return d == null ? '' : '${d.day} ${_mon[d.month - 1]}';
}

/// A rupee amount typed in a box as paise (null when it is not a positive amount).
int? paiseOf(String text) {
  final a = num.tryParse(text.trim().replaceAll(',', ''));
  return a == null || a <= 0 ? null : (a * 100).round();
}

/// The formatter for a rupee box: digits and one point with up to two decimals.
final rupeeFormatters = <TextInputFormatter>[FilteringTextInputFormatter.allow(RegExp(r'^\d{0,9}(\.\d{0,2})?'))];

/// Faint concentric rings in a dark card's corner.
class RmRings extends StatelessWidget {
  const RmRings({super.key, this.opacity = 0.07});
  final double opacity;
  @override
  Widget build(BuildContext context) => IgnorePointer(child: CustomPaint(painter: _Rings(Colors.white.withValues(alpha: opacity)), size: Size.infinite));
}

class _Rings extends CustomPainter {
  _Rings(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final c = Offset(size.width * 0.92, size.height * 0.12);
    final r0 = max(size.width, size.height) * 0.12;
    for (var i = 0; i < 6; i++) {
      canvas.drawCircle(c, r0 + i * 18, p);
    }
  }

  @override
  bool shouldRepaint(_Rings old) => old.color != color;
}

/// A dark card with rings: the balance cards.
class RmDarkCard extends StatelessWidget {
  const RmDarkCard({super.key, required this.child, this.padding = const EdgeInsets.fromLTRB(18, 20, 18, 18)});
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(kRmRadius),
        child: Container(color: kRmDeep, child: Stack(children: [const Positioned.fill(child: RmRings()), Padding(padding: padding, child: child)])),
      );
}

/// Pill tabs: the selected one dark, the rest white.
class RmPills extends StatelessWidget {
  const RmPills({super.key, required this.options, required this.selected, required this.onSelect, this.keyPrefix = 'pill'});
  final List<(String, String)> options; // (id, label)
  final String selected;
  final ValueChanged<String> onSelect;
  final String keyPrefix;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final (id, label) in options)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              // the highlight moves smoothly from the old pill to the picked one (lib/ui/motion.dart)
              child: AnimatedContainer(
                duration: reduceMotion(context) ? Duration.zero : const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  color: selected == id ? kRmDeep : Colors.white,
                  borderRadius: BorderRadius.circular(40),
                  border: Border.all(color: selected == id ? kRmDeep : kLine),
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    key: ValueKey('$keyPrefix-$id'),
                    borderRadius: BorderRadius.circular(40),
                    onTap: () => onSelect(id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      child: AnimatedDefaultTextStyle(
                        duration: reduceMotion(context) ? Duration.zero : const Duration(milliseconds: 260),
                        style: inter(14, 700, color: selected == id ? Colors.white : kInk),
                        child: Text(label),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      );
}

/// A white rounded card.
BoxDecoration rmCard() => BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 18, offset: Offset(0, 6))],
    );

/// The restaurant's Money page.
class RstMoneyScreen extends StatefulWidget {
  const RstMoneyScreen({super.key, this.api, this.walletApi, this.adsApi, this.today, this.openUrl});
  final RstMoneyApi? api;
  final WalletApi? walletApi;

  /// Ad credits (rupees, 0635): the balance on the card and the ads pages it opens.
  final AdsApi? adsApi;

  /// Tests fix "today".
  final DateTime? today;

  /// Opens a UPI app link (tests pass their own).
  final Future<bool> Function(Uri url)? openUrl;

  static Route<void> route({RstMoneyApi? api}) => MaterialPageRoute(builder: (_) => RstMoneyScreen(api: api));
  @override
  State<RstMoneyScreen> createState() => _RstMoneyScreenState();
}

class _RstMoneyScreenState extends State<RstMoneyScreen> {
  late final RstMoneyApi _api = widget.api ?? RstMoneyApi();
  Map<String, dynamic>? _home;
  String? _error;
  num? _onelocal; // what OneLocal owes the restaurant (rupees)
  num? _adCredits; // ad credits available (rupees, 0635)
  String _part = 'register';
  int _reload = 0; // rebuilds the part below after a change

  @override
  void initState() {
    super.initState();
    _load();
    _loadWallet();
    _loadCredits();
  }

  Future<void> _load() async {
    try {
      final h = await _api.home();
      if (!mounted) return;
      setState(() {
        _home = h;
        _error = null;
        _reload++;
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorSentence(e));
    }
  }

  Future<void> _loadWallet() async {
    try {
      final w = await (widget.walletApi ?? WalletApi()).overview();
      if (mounted) setState(() => _onelocal = w.unsettledDue + w.onTheWay);
    } catch (_) {
      // the card shows a dash; the wallet page says why
    }
  }

  Future<void> _loadCredits() async {
    try {
      final h = await (widget.adsApi ?? AdsApi()).home();
      final b = (h['balances'] as Map?) ?? const {};
      if (mounted) setState(() => _adCredits = (b['available'] ?? h['coins']) as num?);
    } catch (_) {
      // the card shows a dash; Ads says why
    }
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  bool get _canRecord => _home?['can_record'] == true;

  Widget _action(String label, IconData icon, String key, VoidCallback? onTap, {bool lime = false}) => Expanded(
        child: Opacity(
          opacity: onTap == null ? 0.45 : 1,
          child: Material(
            color: lime ? kRmLime : kRmDeepSoft,
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
                    decoration: BoxDecoration(color: lime ? kRmDeep : const Color(0xFF3A3F47), borderRadius: BorderRadius.circular(12)),
                    child: Icon(icon, size: 19, color: lime ? kRmLime : Colors.white),
                  ),
                  const SizedBox(height: 8),
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12.5, 700, color: lime ? kRmDeep : Colors.white)),
                ]),
              ),
            ),
          ),
        ),
      );

  Widget _wallet(Map<String, dynamic> h) {
    final accounts = (h['accounts'] as List? ?? const []).cast<Map>();
    const icons = {'cash': LucideIcons.wallet, 'upi': LucideIcons.smartphone, 'bank': LucideIcons.landmark};
    return RmDarkCard(
      child: Column(children: [
        Text('Your wallet balance', style: inter(13.5, 500, color: const Color(0xFFB8BCC4))),
        const SizedBox(height: 6),
        // the balance counts up (lib/ui/motion.dart)
        FittedBox(fit: BoxFit.scaleDown, child: CountUp((h['total_minor'] as num?) ?? 0, format: rs, textKey: const ValueKey('rm-total'), style: inter(38, 800, color: Colors.white))),
        const SizedBox(height: 10),
        Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 6, children: [
          for (final a in accounts)
            Container(
              key: ValueKey('rm-account-${a['key']}'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(color: kRmDeepSoft, borderRadius: BorderRadius.circular(40)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icons[a['key']] ?? LucideIcons.wallet, size: 12, color: kRmLime),
                const SizedBox(width: 5),
                Text('${a['name']} ${rs(a['balance_minor'] as num?)}', style: inter(11.5, 600, color: Colors.white)),
              ]),
            ),
        ]),
        const SizedBox(height: 18),
        Row(children: [
          _action('Money in', LucideIcons.arrowDownToLine, 'rm-in', () => _open(RstMoneyFlowScreen(api: _api, direction: 'in', canRecord: _canRecord, canVoid: _home?['can_void'] == true, today: widget.today))),
          const SizedBox(width: 10),
          _action('Money out', LucideIcons.arrowUpFromLine, 'rm-out', () => _open(RstMoneyFlowScreen(api: _api, direction: 'out', canRecord: _canRecord, canVoid: _home?['can_void'] == true, today: widget.today))),
          const SizedBox(width: 10),
          _action('Transfer', LucideIcons.arrowLeftRight, 'rm-transfer', _canRecord ? () => _open(RstTransferScreen(api: _api, openUrl: widget.openUrl)) : null, lime: true),
        ]),
      ]),
    );
  }

  /// The OneLocal wallet (what OneLocal owes for app orders), then the ad credits (rupees, 0635: a tap opens Ads) and the discount
  /// credits (not open yet: "Soon").
  Widget _onelocalCards() {
    Widget credit(String key, String title, String value, String sub, IconData icon, {required bool dark, VoidCallback? onTap}) {
      final bg = dark ? kRmDeep : kRmLime, fg = dark ? Colors.white : kRmDeep, soft = dark ? const Color(0xFFB8BCC4) : const Color(0xFF3F4A12);
      return Expanded(
        child: Container(
          key: ValueKey(key),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(kRmRadius)),
          child: Stack(children: [
            if (dark) const Positioned.fill(child: RmRings(opacity: 0.06)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 14, 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(color: dark ? kRmDeepSoft : kRmDeep, borderRadius: BorderRadius.circular(11)),
                    child: Icon(icon, size: 17, color: kRmLime),
                  ),
                  const Spacer(),
                  if (onTap == null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(color: dark ? kRmDeepSoft : kRmDeep.withValues(alpha: .1), borderRadius: BorderRadius.circular(20)),
                      child: Text('Soon', style: inter(10.5, 700, color: fg)),
                    )
                  else
                    Icon(LucideIcons.arrowUpRight, size: 18, color: fg),
                ]),
                const SizedBox(height: 12),
                Text(title, style: inter(13, 700, color: soft)),
                const SizedBox(height: 2),
                FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: inter(26, 800, color: fg))),
                const SizedBox(height: 2),
                Text(sub, style: inter(11.5, 500, color: soft)),
              ]),
            ),
            // on top, so a tap anywhere on the card opens it
            if (onTap != null) Positioned.fill(child: Material(color: Colors.transparent, child: InkWell(key: ValueKey('$key-open'), onTap: onTap))),
          ]),
        ),
      );
    }

    return Column(children: [
      Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('rm-onelocal-wallet'),
          borderRadius: BorderRadius.circular(kRmRadius),
          onTap: () => Navigator.of(context).push(WalletScreen.route(api: widget.walletApi)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(kRmRadius),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                color: kRmLime,
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
                child: Row(children: [
                  const Icon(LucideIcons.store, size: 16, color: kRmDeep),
                  const SizedBox(width: 8),
                  Expanded(child: Text('OneLocal wallet', style: inter(13.5, 800, color: kRmDeep))),
                  Text('From your online orders', style: inter(11.5, 600, color: kRmDeep)),
                ]),
              ),
              Container(
                color: kRmDeep,
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Due to you', style: inter(12, 500, color: const Color(0xFFB8BCC4))),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(_onelocal == null ? '—' : rs(_onelocal! * 100), key: const ValueKey('rm-onelocal-amount'), style: inter(26, 800, color: Colors.white)),
                      ),
                    ]),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(color: kRmDeepSoft, borderRadius: BorderRadius.circular(40)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('View', style: inter(12.5, 700, color: kRmLime)),
                      const SizedBox(width: 4),
                      const Icon(LucideIcons.arrowUpRight, size: 14, color: kRmLime),
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
          credit('rm-ad-credits', 'Ad credits', _adCredits == null ? '—' : rs(_adCredits! * 100), 'To promote your restaurant', LucideIcons.megaphone, dark: false,
              onTap: () async {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AdsHomeScreen(api: widget.adsApi)));
            if (mounted) {
              _loadCredits();
              _loadWallet(); // money moved to ad credits leaves the OneLocal wallet
            }
          }),
          const SizedBox(width: 12),
          credit('rm-discount-credits', 'Discount credits', rs(0), 'Discount against commission', LucideIcons.badgePercent, dark: true),
        ]),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final h = _home;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(title: 'Money', onBack: Navigator.of(context).canPop() ? () => Navigator.of(context).maybePop() : null),
        Expanded(
          child: _error != null && h == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kMuted)),
                      const SizedBox(height: 12),
                      OutlinedButton(onPressed: _load, child: Text('Try again', style: inter(14, 600))),
                    ]),
                  ),
                )
              : h == null
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: () async {
                        await _load();
                        await _loadWallet();
                        await _loadCredits();
                      },
                      child: ListView(key: const ValueKey('rst-money'), padding: const EdgeInsets.fromLTRB(14, 12, 14, 28), children: [
                        Entrance(index: 0, child: _wallet(h)),
                        const SizedBox(height: 12),
                        Entrance(index: 1, child: _onelocalCards()),
                        const SizedBox(height: 18),
                        RmPills(
                          keyPrefix: 'rm-part',
                          options: const [('register', 'Cash register'), ('dues', 'Dues')],
                          selected: _part,
                          onSelect: (id) => setState(() => _part = id),
                        ),
                        const SizedBox(height: 12),
                        // the picked part cross-fades in (lib/ui/motion.dart)
                        SwapFade(
                          child: _part == 'dues'
                              ? RmDuesPart(key: ValueKey('dues-$_reload'), api: _api, canRecord: _canRecord, onChanged: _load)
                              : RmRegisterPart(key: ValueKey('register-$_reload'), api: _api, canRecord: _canRecord, onChanged: _load),
                        ),
                      ]),
                    ),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------------------------------------------------------- cash register
/// Today's cash drawer: opening, cash sales, other cash in, refunds, paid out, what should be in the drawer, and Close day.
class RmRegisterPart extends StatefulWidget {
  const RmRegisterPart({super.key, required this.api, required this.canRecord, required this.onChanged});
  final RstMoneyApi api;
  final bool canRecord;
  final VoidCallback onChanged;
  @override
  State<RmRegisterPart> createState() => _RmRegisterPartState();
}

class _RmRegisterPartState extends State<RmRegisterPart> {
  Map<String, dynamic>? _r;
  String? _error;
  bool _busy = false;

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
      if (mounted) setState(() => _error = errorSentence(e));
    }
  }

  Future<void> _close() async {
    final r = _r!;
    final counted = TextEditingController();
    final paise = await showOlDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Close day · count the cash', style: inter(18, 800)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Should be in the drawer: ${rs(r['expected_minor'] as num?)}', style: inter(13.5, 500, color: kMuted)),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('rm-counted'),
            controller: counted,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: rupeeFormatters,
            decoration: const InputDecoration(labelText: 'Cash you counted', prefixText: '₹ '),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text('Cancel', style: inter(14, 600))),
          TextButton(
            key: const ValueKey('rm-close-save'),
            onPressed: () {
              final a = num.tryParse(counted.text.trim());
              if (a == null || a < 0) return;
              Navigator.pop(c, (a * 100).round());
            },
            child: Text('Close day', style: inter(14, 800, color: kRmGreen)),
          ),
        ],
      ),
    );
    if (paise == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final done = await widget.api.closeDay(paise);
      if (!mounted) return;
      setState(() => _r = done);
      final diff = ((done['closed'] as Map?)?['difference_minor'] as num?) ?? 0;
      showToast(context, diff == 0 ? 'Day closed. The cash matches.' : diff > 0 ? 'Day closed. ${rs(diff)} extra in the drawer.' : 'Day closed. ${rs(-diff)} short.');
      widget.onChanged();
    } catch (e) {
      if (mounted) showToast(context, errorSentence(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    if (r == null) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: rmCard(),
        child: Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kMuted))),
      );
    }
    final closed = (r['closed'] as Map?)?.cast<String, dynamic>();
    Widget line(String label, num? minor, {String sign = '', Color? color, String? key}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(child: Text(label, style: inter(15, 500, color: kMuted))),
            Text('$sign${sign.isEmpty ? '' : ' '}${rs(minor)}', key: key == null ? null : ValueKey(key), style: inter(15, 700, color: color ?? kInk)),
          ]),
        );
    return Container(
      key: const ValueKey('rm-register'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: rmCard(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Cash drawer · ${dayMonth(r['day'] as String?)}', style: inter(17, 800)),
        const SizedBox(height: 10),
        line('Opening cash', r['opening_minor'] as num?, key: 'rm-opening'),
        line('Cash sales', r['cash_sales_minor'] as num?, sign: '+', color: kRmGreen, key: 'rm-cash-sales'),
        line('Other cash in', r['other_in_minor'] as num?, sign: '+', color: kRmGreen),
        line('Cash refunds', r['refunds_minor'] as num?, sign: '–', color: kRmRed),
        line('Cash paid out', r['paid_out_minor'] as num?, sign: '–', color: kRmRed),
        const Divider(height: 22, color: kLine, thickness: 1.2),
        Row(children: [
          Expanded(child: Text('Should be in the drawer', style: inter(16, 800))),
          Text(rs(r['expected_minor'] as num?), key: const ValueKey('rm-expected'), style: inter(20, 800)),
        ]),
        const SizedBox(height: 14),
        if (closed != null)
          Container(
            key: const ValueKey('rm-closed'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFF1F2EE), borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              const Icon(LucideIcons.lock, size: 16, color: kMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Closed · counted ${rs(closed['counted_minor'] as num?)}'
                  '${(closed['difference_minor'] as num? ?? 0) == 0 ? ' · matches' : (closed['difference_minor'] as num) > 0 ? ' · ${rs(closed['difference_minor'] as num)} extra' : ' · ${rs(-(closed['difference_minor'] as num))} short'}',
                  style: inter(13, 600),
                ),
              ),
            ]),
          )
        else if (widget.canRecord)
          FilledButton(
            key: const ValueKey('rm-close-day'),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF0F1E14), minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
            onPressed: _busy ? null : _close,
            child: Text('Close day · count the cash', style: inter(15, 700, color: Colors.white)),
          ),
      ]),
    );
  }
}

// ------------------------------------------------------------------------------------------------------------------- dues
/// Bills put on credit (to collect) and supplier invoices (to pay), each with its button.
class RmDuesPart extends StatefulWidget {
  const RmDuesPart({super.key, required this.api, required this.canRecord, required this.onChanged});
  final RstMoneyApi api;
  final bool canRecord;
  final VoidCallback onChanged;
  @override
  State<RmDuesPart> createState() => _RmDuesPartState();
}

class _RmDuesPartState extends State<RmDuesPart> {
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
      if (mounted) setState(() => _error = errorSentence(e));
    }
  }

  Future<void> _collect(Map<String, dynamic> due) async {
    final saved = await showRmEntrySheet(context,
        api: widget.api, direction: 'in', kind: 'due_received', party: '${due['name'] ?? ''}', reference: '${due['reference'] ?? ''}', amountMinor: due['left_minor'] as num?);
    if (saved && mounted) {
      _load();
      widget.onChanged();
    }
  }

  Future<void> _pay(Map<String, dynamic> due) async {
    final saved = await showRmInvoicePaySheet(context, api: widget.api, invoice: due);
    if (saved && mounted) {
      _load();
      widget.onChanged();
    }
  }

  Widget _row(Map<String, dynamic> due, {required bool collect}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: collect ? const Color(0xFFEFF8D6) : const Color(0xFFFFEDEA), borderRadius: BorderRadius.circular(12)),
            child: Icon(collect ? LucideIcons.userRound : LucideIcons.truck, size: 18, color: collect ? kRmGreen : kRmRed),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${due['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(15, 700)),
              Text(
                [
                  if ('${due['reference'] ?? ''}'.isNotEmpty) '${due['reference']}',
                  if (!collect && due['due_date'] != null) 'due ${dayMonth(due['due_date'] as String?)}',
                ].join(' · '),
                style: inter(12.5, 500, color: kMuted),
              ),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(rs(due['left_minor'] as num?), style: inter(15.5, 800, color: collect ? kRmGreen : kRmRed)),
            if (widget.canRecord)
              TextButton(
                key: ValueKey('rm-${collect ? 'collect' : 'pay'}-${due['reference']}'),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
                onPressed: () => collect ? _collect(due) : _pay(due),
                child: Text(collect ? 'Collect' : 'Pay', style: inter(13, 800, color: kInk)),
              ),
          ]),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (d == null) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: rmCard(),
        child: Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kMuted))),
      );
    }
    final collect = (d['to_collect'] as List? ?? const []).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
    final pay = (d['to_pay'] as List? ?? const []).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
    Widget section(String title, String total, List<Map<String, dynamic>> rows, String empty, {required bool isCollect}) => Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
          decoration: rmCard(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(title, style: inter(16, 800))),
              Text(total, style: inter(16, 800, color: isCollect ? kRmGreen : kRmRed)),
            ]),
            const SizedBox(height: 4),
            if (rows.isEmpty)
              Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Text(empty, style: inter(13.5, 500, color: kMuted)))
            else
              for (final r in rows) _row(r, collect: isCollect),
          ]),
        );
    return Column(key: const ValueKey('rm-dues'), children: [
      section('To collect from customers', rs(d['collect_minor'] as num?), collect, 'No bills on credit.', isCollect: true),
      const SizedBox(height: 12),
      section('To pay suppliers', rs(d['pay_minor'] as num?), pay, 'No supplier bills to pay.', isCollect: false),
    ]);
  }
}
