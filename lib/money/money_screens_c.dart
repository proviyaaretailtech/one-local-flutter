import 'package:flutter/material.dart';

import '../inventory/inventory_widgets.dart' show kCardLine, kPostedText;
import '../ui/theme.dart';
import 'money_api.dart';
import 'money_env.dart';
import 'money_widgets.dart';

// Settlements, Settlement Detail, Payouts, Reports: what the platform owes and has paid the business. Whole-business roles only (settlements:read, payouts:read).
// Figma frames "Money – Settlements", "Settlement Detail", "Money – Payouts", "Money – Reports".

String _monthLabel(String ym) {
  const m = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  final p = ym.split('-');
  return p.length == 2 ? '${m[int.parse(p[1]) - 1]} ${p[0]}' : ym;
}

List<(String, String)> _months() {
  final now = DateTime.now();
  return [
    ('', 'All time'),
    for (var i = 0; i < 6; i++) ...[
      () {
        final d = DateTime(now.year, now.month - i);
        final k = '${d.year}-${d.month.toString().padLeft(2, '0')}';
        return (k, _monthLabel(k));
      }(),
    ],
  ];
}

class SettlementsScreen extends StatelessWidget {
  const SettlementsScreen({super.key, required this.env});
  final MoneyEnv env;
  static const statuses = [('all', 'All status'), ('pending', 'Pending'), ('approved', 'Approved'), ('settled', 'Settled'), ('disputed', 'Disputed')];
  @override
  Widget build(BuildContext context) => MoneyScreen(
        env: env,
        screen: 'settlements',
        title: 'Settlements',
        defaults: const {'status': 'all'},
        load: env.api.settlements,
        body: (c, d) {
          final est = d.m('estimate');
          final last = d.mo('last');
          final rows = d.l('rows');
          final month = (c.q['month'] as String?) ?? '', status = c.q['status'] as String;
          return [
            tiles2(
              MoneyTile('Estimated payout', money(est.no('minor')), sub: est.so('since') == null ? 'Nothing accrued yet' : 'Since ${dayMonth(est.so('since'))} • ${est.n('orders')} orders'),
              MoneyTile('Last settlement', last == null ? '–' : money(last.no('net_minor')), sub: last == null ? 'None paid yet' : 'Paid on ${dayMonth(last.so('paid_on'), year: true)}'),
            ),
            MoneyChips([
              MoneyChip(month.isEmpty ? 'All time' : _monthLabel(month), active: month.isNotEmpty, onTap: () => chooseFor(c.context, 'Month', _months(), month, (v) => c.set({'month': v.isEmpty ? null : v}))),
              MoneyChip(statuses.firstWhere((s) => s.$1 == status).$2, active: status != 'all', onTap: () => chooseFor(c.context, 'Status', statuses, status, (v) => c.set({'status': v}))),
            ]),
            MoneyHeading('Settlement history', pill: '${d.n('total')} cycles'),
            if (rows.isEmpty) const MoneyEmpty('No settlements match these filters.'),
            for (final r in rows)
              MoneyRow(
                title: r.s('ref'),
                amount: money(r.no('net_minor')),
                sub: '${rangeLabel(r.so('period_start'), r.so('period_end'))} • ${r.so('paid_on') != null ? 'Paid ${dayMonth(r.so('paid_on'), year: true)}' : '${r.n('orders')} orders'}',
                status: r.s('status'),
                onTap: () => env.push(c.context, SettlementDetailScreen(env: env, id: r.s('id'))),
              ),
            const MoneyFootnote(['The estimate is based on orders not yet in a settlement.', 'Final payout is confirmed after the cycle closes.']),
            MoneyCta('Download settlement statement', onPressed: () => exportCsv(c.context, c.api, 'settlements', {'period': 'all'})),
          ];
        },
      );
}

class SettlementDetailScreen extends StatelessWidget {
  const SettlementDetailScreen({super.key, required this.env, required this.id});
  final MoneyEnv env;
  final String id;
  @override
  Widget build(BuildContext context) => MoneyScreen(
        env: env,
        screen: 'settlements',
        title: 'Settlement Detail',
        switcher: false,
        load: (_) => env.api.settlement(id),
        body: (c, d) {
          final pay = d.mo('payout');
          final lines = d.l('lines');
          final status = d.s('status');
          return [
            Row(children: [
              Expanded(child: Text(d.s('ref'), style: inter(17, 700))),
              MoneyStatus(status),
            ]),
            Padding(padding: const EdgeInsets.only(top: 4, bottom: 12), child: Text('Period: ${rangeLabel(d.so('period_start'), d.so('period_end'))} ${dayMonth(d.so('period_end'), year: true).split(' ').last}', style: inter(13, 400, color: kMuted))),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: const Color(0xFFEBFAE0), borderRadius: BorderRadius.circular(22)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Net payable amount', style: inter(15, 600, color: kPostedText)),
                const SizedBox(height: 6),
                Text(money(d.no('net_minor'), whole: true), style: inter(34, 700)),
                const SizedBox(height: 4),
                Text('${d.n('orders')} orders${pay?.so('paid_on') != null ? ' • Paid on ${dayMonth(pay!.so('paid_on'), year: true)}' : ''}', style: inter(12.5, 400, color: kPostedText)),
              ]),
            ),
            const SizedBox(height: 12),
            InvCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('SETTLEMENT BREAKDOWN', style: inter(11.5, 700, color: kMuted)),
                const SizedBox(height: 6),
                for (final b in d.l('breakdown'))
                  b.s('kind') == 'total'
                      ? Padding(padding: const EdgeInsets.only(top: 8), child: Column(children: [
                          const Divider(height: 14, color: kCardLine),
                          Row(children: [Expanded(child: Text(b.s('label'), style: inter(15, 700))), Text(money(b.no('minor'), whole: true), style: inter(20, 700, color: kPostedText))]),
                        ]))
                      : Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Expanded(child: Text(b.s('label'), style: inter(14, 400, color: kMuted))),
                            Text(b.s('kind') == 'minus' ? money(-b.n('minor'), whole: true) : money(b.no('minor'), whole: true), style: inter(14, 600, color: b.s('kind') == 'info' ? kMuted : kInk)),
                          ]),
                        ),
              ]),
            ),
            if (pay != null)
              InvCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Payout details', style: inter(15.5, 700)),
                  const SizedBox(height: 8),
                  _kv('Status', statusLook(pay.so('status') ?? 'pending').$1),
                  if (pay.so('paid_on') != null) _kv('Payout date', dayMonth(pay.so('paid_on'), year: true)),
                  _kv('Payment method', 'Bank transfer'),
                  if (pay.so('bank_name') != null) _kv('Bank account', '${pay.s('bank_name')} • •••• ${pay.s('account_last4')}'),
                  if (pay.so('reference') != null) _kv('Payment reference', pay.s('reference')),
                ]),
              ),
            InvCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Order / transaction breakdown', style: inter(15.5, 700)),
                const SizedBox(height: 8),
                if (lines.isEmpty) Text('No orders in this settlement.', style: inter(13, 400, color: kMuted)),
                for (final l in lines)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [Expanded(child: Text('${l.s('ref')} • ${dayMonth(l.so('date'))}', style: inter(14.5, 600))), Text(money(l.no('gross_minor'), whole: true), style: inter(14.5, 700))]),
                      Text('Commission ${money(l.no('commission_minor'), whole: true)} • Restaurant share ${money(l.no('food_due_minor'), whole: true)}', style: inter(12.5, 400, color: kMuted)),
                    ]),
                  ),
              ]),
            ),
            MoneyCta('Download Statement', onPressed: () => env.later(c.context, 'PDF statement')),
          ];
        },
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(k, style: inter(14, 400, color: kMuted)),
          const SizedBox(width: 12),
          Flexible(child: Text(v, textAlign: TextAlign.right, style: inter(14, 600))),
        ]),
      );
}

class PayoutsScreen extends StatelessWidget {
  const PayoutsScreen({super.key, required this.env});
  final MoneyEnv env;
  static const who = [('all', 'All recipients'), ('merchant', 'Business'), ('rider', 'Riders'), ('partner', 'Partners')];
  static const statuses = [('all', 'All status'), ('pending', 'Pending'), ('queued', 'Queued'), ('paid', 'Paid'), ('failed', 'Failed')];
  @override
  Widget build(BuildContext context) => MoneyScreen(
        env: env,
        screen: 'payouts',
        title: 'Payouts',
        defaults: const {'recipient': 'all', 'status': 'all'},
        load: env.api.payouts,
        body: (c, d) {
          final pend = d.m('pending');
          final last = d.mo('last_paid');
          final rows = d.l('rows');
          final month = (c.q['month'] as String?) ?? '', rec = c.q['recipient'] as String, status = c.q['status'] as String;
          final bank = d.mo('bank');
          return [
            tiles2(
              MoneyTile('Pending payouts', money(pend.no('minor')), sub: 'Business ${money(pend.no('merchant_minor'), whole: true)} + riders ${money(pend.no('rider_minor'), whole: true)}'),
              MoneyTile('Last paid', last == null ? '–' : money(last.no('minor')), sub: last == null ? 'None paid yet' : '${dayMonth(last.so('paid_on'))}${bank == null ? '' : ' • Bank transfer'}'),
            ),
            MoneyChips([
              MoneyChip(month.isEmpty ? 'All time' : _monthLabel(month), active: month.isNotEmpty, onTap: () => chooseFor(c.context, 'Month', _months(), month, (v) => c.set({'month': v.isEmpty ? null : v}))),
              MoneyChip(who.firstWhere((s) => s.$1 == rec).$2, active: rec != 'all', onTap: () => chooseFor(c.context, 'Recipient', who, rec, (v) => c.set({'recipient': v}))),
              MoneyChip(statuses.firstWhere((s) => s.$1 == status).$2, active: status != 'all', onTap: () => chooseFor(c.context, 'Status', statuses, status, (v) => c.set({'status': v}))),
            ]),
            MoneyHeading('Payout list', pill: 'Latest ${rows.length}'),
            if (rows.isEmpty) const MoneyEmpty('No payouts match these filters.'),
            for (final r in rows)
              MoneyRow(
                title: '${r.s('payee')} • ${r.s('ref')}',
                amount: money(r.no('amount_minor')),
                sub: '${r.so('account') == null ? methodLabel(r.s('payee_type')) : r.s('account').replaceFirst('bank ', 'Bank • ')} • ${r.so('paid_at') != null ? 'Paid ${dayMonth(r.so('paid_at'), year: true)}' : 'Created ${dayMonth(r.so('created_at'), year: true)}'}',
                status: r.s('status'),
              ),
            const MoneyFootnote(['Payouts are created for each settlement cycle.', 'A pending payout is waiting to be sent; queued means approved.']),
            MoneyCta('Download payout report', onPressed: () => exportCsv(c.context, c.api, 'payouts', {'period': 'all'})),
          ];
        },
      );
}

class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key, required this.env});
  final MoneyEnv env;
  @override
  Widget build(BuildContext context) => MoneyScreen(
        env: env,
        screen: 'reports',
        title: 'Reports',
        defaults: const {'period': 'week'},
        load: env.api.reports,
        body: (c, d) {
          final w = d.m('window'), pay = d.m('payments'), com = d.m('commission');
          final reports = d.l('reports');
          final period = c.q['period'] as String;
          return [
            tiles2(
              MoneyTile('Payments', money(pay.no('minor')), sub: '${pay.n('count')} completed orders'),
              MoneyTile('Commission', money(com.no('minor')), sub: 'Estimated payout ${money(d.no('estimated_payout_minor'), whole: true)}'),
            ),
            MoneyChips([
              MoneyChip(rangeLabel(w.so('from'), w.so('to')), onTap: () => chooseFor(c.context, 'Period', periods, period, (v) => c.set({'period': v}))),
              MoneyChip(periodLabel(period), active: true, onTap: () => chooseFor(c.context, 'Period', periods, period, (v) => c.set({'period': v}))),
            ]),
            MoneyHeading('Downloadable reports', pill: '${reports.length} categories'),
            for (final r in reports)
              MoneyRow(
                title: r.s('title'),
                amount: '↓ ${r.s('format').toUpperCase()}',
                sub: '${r.n('records')} records',
                status: r.b('ready') ? 'ready' : 'failed',
                onTap: r.b('ready') ? () => exportCsv(c.context, c.api, r.s('key'), {'period': period}) : () => showToast(c.context, 'Your role cannot export this report.'),
              ),
            MoneyFootnote(['Reports use the selected date range. CSV is copied to the clipboard; PDF opens in a later release.', 'Generated ${dayMonth(d.so('generated_at'), year: true)}, ${hhmm(d.so('generated_at'))} • all amounts in INR']),
            MoneyCta('Download Money summary', onPressed: () => exportCsv(c.context, c.api, 'payments_commission', {'period': period})),
          ];
        },
      );
}
