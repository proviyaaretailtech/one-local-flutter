import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../customers/customer_widgets.dart';
import '../home/home_widgets.dart' show kLime, rupees;
import '../ui/theme.dart';
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
  const WalletScreen({super.key, this.api});
  final WalletApi? api;
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

  Widget _tile(String label, num amount, {String? foot, Key? key}) => Expanded(
        child: Container(
          key: key,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: inter(11.5, 500, color: kMuted)),
            const SizedBox(height: 4),
            Text(rupees(amount), style: inter(17, 700)),
            if (foot != null) ...[const SizedBox(height: 2), Text(foot, style: inter(10.5, 400, color: kMuted))],
          ]),
        ),
      );

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
                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
                    // the dark band: money on the way to the bank
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(color: kPrimary, borderRadius: BorderRadius.circular(20)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          const Icon(LucideIcons.wallet, size: 20, color: kLime),
                          const SizedBox(width: 8),
                          Text(o.business, style: inter(13, 500, color: Colors.white70)),
                        ]),
                        const SizedBox(height: 12),
                        Text('On the way to your bank', style: inter(12.5, 500, color: Colors.white70)),
                        const SizedBox(height: 2),
                        Text(rupees(o.onTheWay), key: const ValueKey('wallet-on-the-way'), style: inter(30, 800, color: Colors.white)),
                        const SizedBox(height: 6),
                        Text('Approved weekly settlements One Local is transferring to you.', style: inter(11.5, 400, color: Colors.white60)),
                      ]),
                    ),
                    const SizedBox(height: 10),
                    Row(children: [
                      _tile('Earned, not yet settled', o.unsettledDue,
                          key: const ValueKey('wallet-unsettled'),
                          foot: '${o.unsettledOrders} order${o.unsettledOrders == 1 ? '' : 's'} · commission ${rupees(o.unsettledCommission)}'),
                      const SizedBox(width: 8),
                      _tile('Paid to your bank', o.paid, key: const ValueKey('wallet-paid')),
                    ]),
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
                    const CwaSection('Movements'),
                    if (_moves.isEmpty) Text('No settlements or payouts yet. Your first One Local orders are settled weekly.', style: inter(13, 400, color: kMuted)),
                    for (final m in _moves)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: CwaCard(
                          onTap: m.settlementId.isEmpty
                              ? null
                              : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettlementScreen(api: _api, id: m.settlementId))),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                          child: Row(children: [
                            Container(
                              width: 34,
                              height: 34,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(color: m.isIn ? const Color(0xFFEBFAE0) : const Color(0xFFF3F4F6), shape: BoxShape.circle),
                              child: Icon(m.isIn ? LucideIcons.arrowDownLeft : LucideIcons.landmark, size: 17, color: kInk),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(m.label, style: inter(13.5, 600), maxLines: 1, overflow: TextOverflow.ellipsis),
                                Text('${cwaDate(m.at)} · ${_status(m)}', style: inter(11.5, 400, color: m.noTransferRecord || m.status == 'failed' ? kError : kMuted)),
                              ]),
                            ),
                            Text('${m.isIn ? '+' : '−'}${rupees(m.amount)}', style: inter(14, 700, color: m.isIn ? const Color(0xFF15803D) : kInk)),
                          ]),
                        ),
                      ),
                    if (_next != null)
                      TextButton(onPressed: _more ? null : _loadMore, child: Text('Show more', style: inter(14, 600, color: kLink))),
                  ]),
                ),
        ),
      ]),
    );
  }
}

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
