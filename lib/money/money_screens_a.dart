import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_widgets.dart' show InvDotChip, kGreenIconBg, kPostedText, kRedText, kCardLine;
import '../ui/theme.dart';
import 'money_api.dart';
import 'money_env.dart';
import 'money_widgets.dart';

// Overview, Payments, Transactions, Invoices: the money that came in. Figma frames "Money – Overview", "Money – Payments", "Transactions", "Invoices".

class MoneyOverview extends StatelessWidget {
  const MoneyOverview({super.key, required this.env});
  final MoneyEnv env;
  @override
  Widget build(BuildContext context) => MoneyScreen(
        env: env,
        screen: 'overview',
        title: 'Overview',
        defaults: const {'period': 'week'},
        load: env.api.overview,
        body: (c, d) {
          final w = d.m('window');
          final pay = d.m('payments'), cash = d.m('cash');
          final payouts = d.mo('payouts'), com = d.mo('commission'), next = d.mo('next_settlement');
          final change = pay.no('change_pct');
          final period = (c.q['period'] ?? 'week') as String;
          return [
            tiles2(
              MoneyTile('Available balance', cash.b('started') ? money(cash.no('minor')) : '–', sub: cash.b('started') ? 'Cashbook • on hand' : 'Cashbook not started'),
              payouts != null
                  ? MoneyTile('Pending payouts', money(payouts.no('pending_minor')), sub: 'Merchant ${money(payouts.no('merchant_minor'), whole: true)} + riders ${money(payouts.no('rider_minor'), whole: true)}')
                  : MoneyTile('Awaiting capture', money(d.m('awaiting').no('minor')), sub: '${d.m('awaiting').n('count')} pending payment'),
            ),
            MoneyChips([
              MoneyChip(rangeLabel(w.so('from'), w.so('to')), onTap: () => chooseFor(context, 'Period', periods, period, (v) => c.set({'period': v}))),
              MoneyChip(periodLabel(period), active: true, onTap: () => chooseFor(context, 'Period', periods, period, (v) => c.set({'period': v}))),
            ]),
            InvCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('Payments trend', style: inter(15, 700))),
                  if (change != null) Text('${change >= 0 ? '+' : '−'}${change.abs()}%', style: inter(13, 600, color: change >= 0 ? kPostedText : kRedText)),
                ]),
                const SizedBox(height: 10),
                SizedBox(height: 70, width: double.infinity, child: CustomPaint(painter: _Trend([for (final p in pay.l('trend')) p.n('minor').toDouble()]))),
                const SizedBox(height: 4),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(dayMonth(w.so('from')), style: inter(11.5, 400, color: kMuted)),
                  Text(dayMonth(w.so('to')), style: inter(11.5, 400, color: kMuted)),
                ]),
              ]),
            ),
            MoneyHeading('Money summary', pill: '${pay.n('count')} payments'),
            MoneyRow(
              title: 'Payments received',
              amount: money(pay.no('minor')),
              sub: '${rangeLabel(w.so('from'), w.so('to'))} • ${pay.n('count')} payments',
              trailing: const InvDotChip('Received', bg: kGreenIconBg, fg: kPostedText),
            ),
            if (com != null)
              MoneyRow(
                title: 'Commission earned',
                amount: money(com.no('minor')),
                sub: '${com.no('rate_bps') == null ? 'Commission' : '${(com.n('rate_bps') / 100).toStringAsFixed(com.n('rate_bps') % 100 == 0 ? 0 : 1)}% of net order value'} • this period',
                trailing: const InvDotChip('Earned', bg: kGreenIconBg, fg: kPostedText),
              ),
            if (next != null) MoneyFootnote(['Next settlement estimate: ${money(next.no('estimate_minor'))} from ${next.n('orders')} orders. Final payout is confirmed after the cycle closes.']),
            MoneyCta('Download summary', onPressed: () => exportCsv(c.context, c.api, 'payments', {'period': period})),
          ];
        },
      );
}

class _Trend extends CustomPainter {
  _Trend(this.values);
  final List<double> values;
  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final max = values.reduce((a, b) => a > b ? a : b);
    final paint = Paint()..color = kPostedText..strokeWidth = 2..style = PaintingStyle.stroke..strokeJoin = StrokeJoin.round;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = values.length == 1 ? size.width / 2 : size.width * i / (values.length - 1);
      final y = max <= 0 ? size.height - 1 : size.height - 1 - (size.height - 4) * values[i] / max;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_Trend old) => old.values != values;
}

class PaymentsScreen extends StatelessWidget {
  const PaymentsScreen({super.key, required this.env});
  final MoneyEnv env;
  static const methods = [('all', 'All methods'), ('cash', 'Cash'), ('upi', 'UPI'), ('card', 'Card'), ('wallet', 'Wallet'), ('online', 'Online'), ('due', 'On account'), ('other', 'Other')];
  static const statuses = [('all', 'All status'), ('paid', 'Paid'), ('pending', 'Pending'), ('failed', 'Failed'), ('review', 'Needs refund')];
  @override
  Widget build(BuildContext context) => MoneyScreen(
        env: env,
        screen: 'payments',
        title: 'Payments',
        defaults: const {'period': 'week', 'method': 'all', 'status': 'all'},
        load: env.api.payments,
        body: (c, d) {
          final w = d.m('window'), rec = d.m('received'), aw = d.m('awaiting');
          final rows = d.l('rows');
          final period = c.q['period'] as String, method = c.q['method'] as String, status = c.q['status'] as String;
          return [
            tiles2(
              MoneyTile('Received', money(rec.no('minor')), sub: '${rec.n('count')} successful payments'),
              MoneyTile('Awaiting capture', money(aw.no('minor')), sub: '${aw.n('count')} pending payment', subColor: kMuted),
            ),
            MoneyChips([
              MoneyChip(rangeLabel(w.so('from'), w.so('to')), onTap: () => chooseFor(c.context, 'Period', periods, period, (v) => c.set({'period': v}))),
              MoneyChip(methods.firstWhere((m) => m.$1 == method).$2, active: method != 'all', onTap: () => chooseFor(c.context, 'Method', methods, method, (v) => c.set({'method': v}))),
              MoneyChip(statuses.firstWhere((m) => m.$1 == status).$2, active: status != 'all', onTap: () => chooseFor(c.context, 'Status', statuses, status, (v) => c.set({'status': v}))),
            ]),
            MoneyHeading('Recent payments', pill: '${rows.length} of ${d.n('total')}'),
            if (rows.isEmpty) const MoneyEmpty('No payments match this period and filters.'),
            for (final r in rows)
              MoneyRow(
                title: '${r.s('ref')} • ${r.s('order_ref')}',
                amount: money(r.no('amount_minor')),
                sub: '${methodLabel(r.so('method'))} • ${dayMonth(r.so('at'))}, ${hhmm(r.so('at'))}',
                status: r.s('status'),
              ),
            MoneyMore(shown: rows.length, total: d.n('total').toInt(), ctx: c),
            const MoneyFootnote(['Received total excludes pending payments.', 'Showing the latest records for this period.']),
            MoneyCta('Export payments', onPressed: () => exportCsv(c.context, c.api, 'payments', {'period': period})),
          ];
        },
      );
}

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key, required this.env});
  final MoneyEnv env;
  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  static const types = [('all', 'All types'), ('payment', 'Payments'), ('refund', 'Refunds'), ('expense', 'Expenses'), ('cash', 'Cash entries'), ('party', 'Party ledger')];
  final search = TextEditingController();
  int _bump = 0;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final env = widget.env;
    return MoneyScreen(
      key: ValueKey(_bump),
      env: env,
      screen: 'transactions',
      title: 'Transactions',
      defaults: const {'period': 'all', 'type': 'all'},
      load: env.api.transactions,
      body: (c, d) {
        final rows = d.l('rows');
        final party = d.mo('party');
        final type = c.q['type'] as String, period = c.q['period'] as String;
        final w = d.m('window');
        return [
          TextField(
            controller: search,
            textInputAction: TextInputAction.search,
            onSubmitted: (v) => c.set({'q': v.trim()}),
            style: inter(15, 400),
            decoration: InputDecoration(
              hintText: 'Transaction ID or description',
              hintStyle: inter(15, 400, color: kMuted),
              prefixIcon: const Icon(LucideIcons.search, size: 18, color: kMuted),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: kCardLine)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: kInk)),
            ),
          ),
          const SizedBox(height: 10),
          MoneyChips([
            MoneyChip(period == 'all' ? 'All dates' : rangeLabel(w.so('from'), w.so('to')), active: period != 'all', menu: true, icon: LucideIcons.calendar, onTap: () => chooseFor(c.context, 'Dates', periods, period, (v) => c.set({'period': v}))),
            MoneyChip(types.firstWhere((t) => t.$1 == type).$2, active: type != 'all', menu: true, onTap: () => chooseFor(c.context, 'Type', types, type, (v) => c.set({'type': v}))),
            MoneyChip(c.q['party'] == null ? 'All parties' : c.q['party'] as String, active: c.q['party'] != null, menu: true, onTap: () => chooseFor(c.context, 'Party', [('', 'All parties'), for (final p in d.ls('parties')) (p, p)], (c.q['party'] as String?) ?? '', (v) => c.set({'party': v.isEmpty ? null : v, 'type': v.isEmpty ? type : 'party'}))),
          ]),
          if (party != null)
            MoneyRow(
              title: 'Balance with ${party.s('name')}',
              amount: money(party.n('balance_minor').abs()),
              sub: '${party.n('count')} ledger entries • gave ${money(party.no('gave_minor'), whole: true)}, got ${money(party.no('got_minor'), whole: true)}',
              extra: Text(party.n('balance_minor') > 0 ? 'To receive. Ledger balance, not cash on hand.' : party.n('balance_minor') < 0 ? 'To pay. Ledger balance, not cash on hand.' : 'Settled. Ledger balance, not cash on hand.', style: inter(12.5, 400, color: kMuted)),
            ),
          MoneyHeading('Ledger', pill: '${rows.length} of ${d.n('total')}'),
          if (rows.isEmpty) const MoneyEmpty('No transactions match these filters.'),
          for (final r in rows)
            MoneyRow(
              title: r.s('title'),
              amount: money(r.n('amount_minor') * (r.s('direction') == 'out' ? -1 : 1), sign: true),
              amountColor: r.s('direction') == 'out' ? kRedText : kPostedText,
              sub: '${r.s('ref')} • ${dayMonth(r.so('day'), year: true)}${r.so('method') == null ? '' : ' • ${methodLabel(r.so('method'))}'}',
              status: r.s('status'),
            ),
          MoneyMore(shown: rows.length, total: d.n('total').toInt(), ctx: c),
          if (env.may('record'))
            MoneyCta('Add party entry', onPressed: () async {
              final done = await showMoneyForm(c.context, title: 'Party entry', action: 'Save', note: 'Money you gave to or got from a person. It is a ledger balance, not cash on hand.', fields: const [
                FormFieldSpec('party_name', 'Name'),
                FormFieldSpec('direction', 'You gave or got', kind: FieldKind.pick, options: [('gave', 'You gave'), ('got', 'You got')], initial: 'gave'),
                FormFieldSpec('amount', 'Amount (₹)', kind: FieldKind.amount),
                FormFieldSpec('note', 'Note', optional: true),
              ], onSubmit: (v, key) => env.api.recordParty(v, key));
              if (done) {
                setState(() => _bump++);
              }
            }),
        ];
      },
    );
  }
}

class InvoicesScreen extends StatelessWidget {
  const InvoicesScreen({super.key, required this.env});
  final MoneyEnv env;
  static const kinds = [('all', 'All'), ('sales', 'Sales'), ('purchases', 'Purchases')];
  static const pays = [('all', 'Payment: All'), ('paid', 'Paid'), ('pending', 'Pending'), ('partial', 'Partially paid'), ('overdue', 'Overdue')];
  @override
  Widget build(BuildContext context) {
    final search = TextEditingController();
    return MoneyScreen(
      env: env,
      screen: 'invoices',
      title: 'Invoices',
      subtitle: 'Sales and purchase invoices in one place',
      defaults: const {'period': 'all', 'kind': 'all', 'payment': 'all'},
      load: env.api.invoices,
      body: (c, d) {
        final rows = d.l('rows');
        final kind = c.q['kind'] as String, pay = c.q['payment'] as String, period = c.q['period'] as String;
        return [
          TextField(
            controller: search,
            onSubmitted: (v) => c.set({'q': v.trim()}),
            style: inter(15, 400),
            decoration: InputDecoration(
              hintText: 'Invoice number, customer or supplier',
              hintStyle: inter(15, 400, color: kMuted),
              prefixIcon: const Icon(LucideIcons.search, size: 18, color: kMuted),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: kCardLine)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: kInk)),
            ),
          ),
          const SizedBox(height: 10),
          MoneyChips([for (final k in kinds) MoneyChip(k.$2, active: kind == k.$1, onTap: () => c.set({'kind': k.$1}))]),
          MoneyChips([
            MoneyChip(period == 'all' ? 'All dates' : periodLabel(period), active: period != 'all', menu: true, icon: LucideIcons.calendar, onTap: () => chooseFor(c.context, 'Dates', periods, period, (v) => c.set({'period': v}))),
            MoneyChip(pays.firstWhere((p) => p.$1 == pay).$2, active: pay != 'all', menu: true, onTap: () => chooseFor(c.context, 'Payment', pays, pay, (v) => c.set({'payment': v}))),
          ]),
          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('${d.n('total')} invoices • Newest first', style: inter(13, 400, color: kMuted))),
          if (rows.isEmpty) const MoneyEmpty('No invoices match these filters.'),
          for (final r in rows)
            InvCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(r.s('ref'), style: inter(16, 700))),
                  Text(r.s('kind') == 'sales' ? 'Sales' : 'Purchase', style: inter(13, 500, color: kMuted)),
                ]),
                const SizedBox(height: 4),
                Text('${r.s('party_label')}: ${r.s('party')}', style: inter(14.5, 500)),
                const SizedBox(height: 4),
                Row(children: [
                  Expanded(child: Text(dayMonth(r.so('day'), year: true), style: inter(13, 400, color: kMuted))),
                  MoneyStatus(r.s('status')),
                ]),
                const Divider(height: 22, color: kCardLine),
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Total amount', style: inter(12, 400, color: kMuted)),
                    Text(money(r.no('total_minor'), whole: true), style: inter(21, 700)),
                    if (r.s('status') == 'partial' || r.s('status') == 'overdue') Text('Paid ${money(r.no('paid_minor'), whole: true)}', style: inter(12, 400, color: kMuted)),
                  ])),
                  if (r.s('kind') == 'purchases' && r.s('status') != 'paid' && env.may('record'))
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: SizedBox(width: 132, child: InvSecondary('Record payment', textSize: 13.5, onPressed: () async {
                        final left = r.n('total_minor') - r.n('paid_minor');
                        final done = await showMoneyForm(c.context, title: 'Pay ${r.s('party')}', action: 'Record payment', note: 'Still owed on ${r.s('ref')}: ${money(left)}', fields: [
                          FormFieldSpec('amount', 'Amount (₹)', kind: FieldKind.amount, initial: (left / 100).toStringAsFixed(left % 100 == 0 ? 0 : 2)),
                          const FormFieldSpec('method', 'Method', kind: FieldKind.pick, options: [('bank', 'Bank'), ('cash', 'Cash'), ('upi', 'UPI'), ('card', 'Card'), ('other', 'Other')], initial: 'bank'),
                        ], onSubmit: (v, key) => env.api.payInvoice({'invoice_id': r.s('id'), ...v}, key));
                        if (done) await c.reload();
                      })),
                    ),
                  SizedBox(width: 120, child: InvSecondary('Download', color: kPostedText, onPressed: () => env.later(c.context, 'PDF download'))),
                ]),
              ]),
            ),
          MoneyMore(shown: rows.length, total: d.n('total').toInt(), ctx: c),
        ];
      },
    );
  }
}
