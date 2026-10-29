import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../customers/customer_widgets.dart';
import '../home/home_widgets.dart' show rupees;
import '../ui/app_header.dart' show shortStoreName;
import '../ui/theme.dart';
import '../auth/partner_api.dart';
import '../settings/settings_api.dart';
import '../money/money_style.dart';
import 'wallet_api.dart';

String _status(WalletMovement m) {
  if (m.noTransferRecord) return 'Paid · no transfer record';
  return switch ('${m.kind}:${m.status}') {
    'settlement:approved' => 'Approved',
    'settlement:paid' => 'Paid',
    'settlement:disputed' => 'Disputed',
    'payout:pending' || 'payout:approved' => 'On the way',
    'payout:paid' => m.reference == null ? 'Paid' : 'Paid · ${m.reference}',
    'payout:failed' => 'Failed',
    _ => m.status,
  };
}

/// Side nav "One Local Wallet": what One Local owes the business for its One Local orders, what is on the way to the bank, what has
/// been paid, and every settlement and payout. Read only; every number is the database's (settlements, payouts, commission ledger).
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key, this.api, this.settings});
  final WalletApi? api;

  /// Where Request withdrawal goes (tests replace it).
  final SettingsApi? settings;
  static Route<void> route({WalletApi? api}) => MaterialPageRoute(builder: (_) => WalletScreen(api: api));
  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  late final WalletApi _api = widget.api ?? WalletApi();
  WalletOverview? _o;
  final _moves = <WalletMovement>[];
  int? _next;
  String? _error;
  bool _more = false;
  String _tab = 'settlements'; // Settlements | Ledger | Withdrawals

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final o = await _api.overview();
      if (!mounted) return;
      setState(() {
        _o = o;
        _moves
          ..clear()
          ..addAll(o.movements.items);
        _next = o.movements.nextOffset;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _loadMore() async {
    if (_next == null || _more) return;
    setState(() => _more = true);
    try {
      final p = await _api.movements(offset: _next!);
      if (!mounted) return;
      setState(() {
        _moves.addAll(p.items);
        _next = p.nextOffset;
      });
    } catch (e) {
      if (mounted) showToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _more = false);
    }
  }

  /// Request withdrawal (founder, 28 Oct 2026, from the restaurant wallet): One Local settles weekly on its own, so this asks the
  /// One Local team (a support request) to pay out early; nothing is moved from the app.
  Future<void> _requestWithdrawal(WalletOverview o) async {
    final available = o.unsettledDue + o.onTheWay;
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Request withdrawal', style: inter(18, 800)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Available: ${rupees(available)}', style: inter(15, 700)),
          const SizedBox(height: 6),
          Text('One Local pays your settlement every week. This asks the team to pay it out sooner, to your settlement bank account.', style: inter(13, 400, color: kMuted)),
          const SizedBox(height: 10),
          TextField(key: const ValueKey('wallet-withdraw-note'), controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'Note (optional)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text('Not now', style: inter(14, 600))),
          TextButton(key: const ValueKey('wallet-withdraw-send'), onPressed: () => Navigator.pop(c, true), child: Text('Send request', style: inter(14, 800, color: kLink))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final r = await (widget.settings ?? SettingsApi()).supportCreate(
        message: 'Payout request from the One Local Wallet: ${rupees(available)} (${o.business}).${note.text.trim().isEmpty ? '' : ' Note: ${note.text.trim()}'}',
        topic: 'account',
        idempotencyKey: 'wallet-withdraw-${DateTime.now().millisecondsSinceEpoch}',
      );
      if (mounted) showToast(context, 'Request sent (${r['reference'] ?? 'received'}). The One Local team will confirm the payout.');
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : 'Could not send the request. Try again.');
    }
  }

  /// A figure card in Money's look: lime, or dark with rings.
  Widget _figure(IconData icon, String label, num amount, {required bool dark, String? foot, Key? key}) {
    final fg = dark ? Colors.white : kMoneyDeep, soft = dark ? const Color(0xFFB8BCC4) : const Color(0xFF3F4A12);
    return Expanded(
      child: Container(
        key: key,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: dark ? kMoneyDeep : kMoneyLime, borderRadius: BorderRadius.circular(kMoneyCardRadius)),
        child: Stack(children: [
          if (dark) const Positioned.fill(child: MoneyRings(opacity: 0.06)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 14, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(color: dark ? kMoneyDeepSoft : kMoneyDeep, borderRadius: BorderRadius.circular(11)),
                child: Icon(icon, size: 17, color: kMoneyLime),
              ),
              const SizedBox(height: 12),
              Text(label, style: inter(13, 700, color: soft)),
              const SizedBox(height: 2),
              FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(rupees(amount), style: inter(24, 800, color: fg))),
              if (foot != null) ...[const SizedBox(height: 2), Text(foot, maxLines: 2, style: inter(11, 500, color: soft))],
            ]),
          ),
        ]),
      ),
    );
  }

  /// The rows as a small table: a header line, then one line per movement.
  Widget _table(List<String> heads, List<WalletMovement> rows, Widget Function(WalletMovement) row, String empty) => Container(
        decoration: moneyCard(),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            color: const Color(0xFFF7F8FA),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              for (final (i, h) in heads.indexed)
                Expanded(
                  flex: i == 1 ? 3 : 2,
                  child: Text(h.toUpperCase(), textAlign: i == heads.length - 1 ? TextAlign.right : TextAlign.left, style: inter(10, 700, color: kMuted).copyWith(letterSpacing: 0.6)),
                ),
            ]),
          ),
          if (rows.isEmpty)
            Padding(padding: const EdgeInsets.all(22), child: Text(empty, textAlign: TextAlign.center, style: inter(13, 500, color: kMuted)))
          else
            for (final (i, m) in rows.indexed) ...[if (i > 0) const Divider(height: 1, color: kLine), row(m)],
        ]),
      );

  Widget _chip(String text, {required bool good, bool bad = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: bad ? const Color(0xFFFDECEC) : good ? const Color(0xFF7ED321) : const Color(0xFFF1F2F4),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(10.5, 700, color: bad ? kError : good ? kInk : kMuted)),
      );

  Widget _line(WalletMovement m, {required Widget middle, required Widget end}) => InkWell(
        onTap: m.settlementId.isEmpty ? null : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettlementScreen(api: _api, id: m.settlementId))),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(
              flex: 2,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.at == null ? '—' : '${m.at!.toLocal().day.toString().padLeft(2, '0')} ${_mon[m.at!.toLocal().month - 1]}', style: inter(12.5, 600)),
                if (m.at != null)
                  Text('${m.at!.toLocal().hour.toString().padLeft(2, '0')}:${m.at!.toLocal().minute.toString().padLeft(2, '0')}', style: inter(10.5, 400, color: kMuted)),
              ]),
            ),
            Expanded(flex: 3, child: middle),
            Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: end)),
          ]),
        ),
      );

  Widget _amount(WalletMovement m) =>
      Text('${m.isIn ? '+' : '−'}${rupees(m.amount)}', style: inter(13.5, 800, color: m.isIn ? const Color(0xFF15803D) : kInk));

  Widget _part(List<WalletMovement> moves) => switch (_tab) {
        'ledger' => _table(['Date', 'Details', 'Amount'], moves, (m) => _line(m,
            middle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _chip(m.isIn ? 'credit' : 'debit', good: m.isIn),
              const SizedBox(height: 3),
              Text(m.label, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(11.5, 500, color: kMuted)),
            ]),
            end: _amount(m)), 'No movements yet.'),
        'withdrawals' => _table(['Date', 'Status', 'Amount'], moves.where((m) => m.kind == 'payout').toList(), (m) => _line(m,
            middle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Bank transfer', style: inter(12.5, 600)),
              Text(_status(m), maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(11, 500, color: m.status == 'failed' ? kError : kMuted)),
            ]),
            end: Text(rupees(m.amount), style: inter(13.5, 800))), 'No withdrawals yet'),
        _ => _table(['Date', 'Settlement', 'Payout'], moves.where((m) => m.kind == 'settlement').toList(), (m) => _line(m,
            middle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m.label, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(12, 600)),
              const SizedBox(height: 3),
              _chip(_status(m), good: m.status == 'paid', bad: m.noTransferRecord || m.status == 'disputed'),
            ]),
            end: _amount(m)), 'No settlements yet'),
      };

  @override
  Widget build(BuildContext context) {
    final o = _o;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        const CwaTopBar(title: 'One Local Wallet'),
        Expanded(
          child: o == null
              ? Center(child: _error != null ? CwaLoadError(message: _error!, onRetry: _load) : const CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(14, 10, 14, 24), children: [
                    // Money's look (founder, 28 Oct 2026): the dark card with rings for the balance, then a lime and a dark card
                    MoneyDarkCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          const Icon(LucideIcons.wallet, size: 15, color: kMoneyLime),
                          const SizedBox(width: 6),
                          // too long for the line: the initials, as on the banner
                          Expanded(
                            child: LayoutBuilder(builder: (context, c) {
                              final style = inter(13, 600, color: const Color(0xFFB8BCC4));
                              final p = TextPainter(text: TextSpan(text: o.business, style: style), maxLines: 1, textDirection: TextDirection.ltr, textScaler: MediaQuery.textScalerOf(context))
                                ..layout(maxWidth: double.infinity);
                              return Text(p.width <= c.maxWidth ? o.business : shortStoreName(o.business),
                                  key: const ValueKey('wallet-business'), maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
                            }),
                          ),
                        ]),
                        const SizedBox(height: 14),
                        Row(children: [
                          Expanded(child: Text('Available balance', style: inter(13.5, 500, color: const Color(0xFFB8BCC4)))),
                          Text('Settled weekly', style: inter(11.5, 600, color: kMoneyLime)),
                        ]),
                        const SizedBox(height: 2),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(rupees(o.unsettledDue + o.onTheWay), key: const ValueKey('wallet-available'), style: inter(36, 800, color: Colors.white)),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          key: const ValueKey('wallet-on-the-way'),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(color: kMoneyDeepSoft, borderRadius: BorderRadius.circular(40)),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(LucideIcons.lock, size: 12, color: kMoneyLime),
                            const SizedBox(width: 5),
                            Flexible(child: Text('On the way to your bank  ', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 600, color: const Color(0xFFB8BCC4)))),
                            Text(rupees(o.onTheWay), style: inter(11.5, 800, color: Colors.white)),
                          ]),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            key: const ValueKey('wallet-withdraw'),
                            onPressed: () => _requestWithdrawal(o),
                            style: FilledButton.styleFrom(backgroundColor: kMoneyLime, padding: const EdgeInsets.symmetric(vertical: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                              Text('Request withdrawal', style: inter(15, 800, color: kMoneyDeep)),
                              const SizedBox(width: 8),
                              const Icon(LucideIcons.arrowDownToLine, size: 18, color: kMoneyDeep),
                            ]),
                          ),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 12),
                    IntrinsicHeight(
                      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        _figure(LucideIcons.trendingUp, 'Not yet settled', o.unsettledDue,
                            dark: false,
                            key: const ValueKey('wallet-unsettled'),
                            foot: '${o.unsettledOrders} order${o.unsettledOrders == 1 ? '' : 's'} · commission ${rupees(o.unsettledCommission)}'),
                        const SizedBox(width: 12),
                        _figure(LucideIcons.landmark, 'Paid to your bank', o.paid, dark: true, key: const ValueKey('wallet-paid'), foot: 'All payouts so far'),
                      ]),
                    ),
                    if (o.unsettledNote.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(4, 8, 4, 0), child: Text(o.unsettledNote, style: inter(11.5, 400, color: kMuted))),
                    if (o.owedToOneLocal > 0)
                      _Notice(key: const ValueKey('wallet-owed'), tone: kError, text: 'You owe One Local ${rupees(o.owedToOneLocal)}. It is taken from your next settlement.'),
                    if (o.failedTransfers > 0)
                      _Notice(tone: kError, text: '${o.failedTransfers} bank transfer${o.failedTransfers == 1 ? '' : 's'} failed. One Local operations will retry; check your settlement account in Settings.'),
                    if (o.settledWithoutTransferRecord > 0)
                      _Notice(
                          key: const ValueKey('wallet-no-record'),
                          tone: const Color(0xFFB54708),
                          text: '${o.settledWithoutTransferRecord} settlement${o.settledWithoutTransferRecord == 1 ? ' is' : 's are'} marked paid without a bank transfer record, so '
                              '${o.settledWithoutTransferRecord == 1 ? 'it is' : 'they are'} not counted in "Paid to your bank".'),
                    const SizedBox(height: 16),
                    MoneyPills(
                      keyPrefix: 'wallet-tab',
                      options: const [('settlements', 'Settlements'), ('ledger', 'Ledger'), ('withdrawals', 'Withdrawals')],
                      selected: _tab,
                      onSelect: (id) => setState(() => _tab = id),
                    ),
                    const SizedBox(height: 10),
                    _part(_moves),
                    if (_next != null)
                      TextButton(onPressed: _more ? null : _loadMore, child: Text('Show more', style: inter(14, 600, color: kLink))),
                  ]),
                ),
        ),
      ]),
    );
  }
}

const _mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.tone, required this.text});
  final Color tone;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: tone.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: tone.withValues(alpha: 0.3))),
        child: Text(text, style: inter(12.5, 500, color: tone)),
      );
}

/// One weekly settlement: the figures that make up the net, the transfer, and every order in it (traceable to the Order ID).
class SettlementScreen extends StatefulWidget {
  const SettlementScreen({super.key, required this.api, required this.id});
  final WalletApi api;
  final String id;
  @override
  State<SettlementScreen> createState() => _SettlementScreenState();
}

class _SettlementScreenState extends State<SettlementScreen> {
  SettlementView? _s;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final s = await widget.api.settlement(widget.id);
      if (mounted) setState(() => _s = s);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        CwaTopBar(title: s == null ? 'Settlement' : 'Settlement ${cwaDate(s.from)} – ${cwaDate(s.to)}'),
        Expanded(
          child: s == null
              ? Center(child: _error != null ? CwaLoadError(message: _error!, onRetry: _load) : const CircularProgressIndicator())
              : ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
                  CwaCard(
                    child: Column(children: [
                      CwaRow('Food due to you', rupees(s.figure('food_due'))),
                      if (s.figure('clawback') > 0) CwaRow('Refunds taken back', '−${rupees(s.figure('clawback'))}'),
                      CwaRow('One Local commission', '−${rupees(s.figure('commission'))}'),
                      CwaRow('GST on commission', '−${rupees(s.figure('commission_gst'))}'),
                      if (s.figure('debt_in') > 0) CwaRow('Owed from last week', '−${rupees(s.figure('debt_in'))}'),
                      const Divider(color: kLine),
                      CwaRow('Net to your bank', rupees(s.figure('net')), strong: true),
                      if (s.figure('debt_out') > 0) CwaRow('Carried to next week (you owe)', rupees(s.figure('debt_out'))),
                      CwaRow('Status', s.status[0].toUpperCase() + s.status.substring(1)),
                    ]),
                  ),
                  const CwaSection('Transfer'),
                  if (s.payouts.isEmpty) Text('No bank transfer recorded for this settlement.', style: inter(13, 400, color: kMuted)),
                  for (final p in s.payouts)
                    CwaCard(child: CwaRow('${p['status']}'.toUpperCase(), '${rupees(p['amount'] as num? ?? 0)}${p['reference'] == null ? '' : ' · ${p['reference']}'}')),
                  CwaSection('Orders (${s.lines.length})'),
                  for (final l in s.lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: CwaCard(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(l.orderNumber.isEmpty ? 'Order' : l.orderNumber, style: inter(13.5, 600)),
                              Text('Bill ${rupees(l.gross)} · commission ${rupees(l.commission)}${l.paymentMode.isEmpty ? '' : ' · ${l.paymentMode.toUpperCase()}'}',
                                  style: inter(11.5, 400, color: kMuted)),
                            ]),
                          ),
                          Text(rupees(l.foodDue), style: inter(14, 600)),
                        ]),
                      ),
                    ),
                ]),
        ),
      ]),
    );
  }
}
