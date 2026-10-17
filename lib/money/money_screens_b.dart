import 'package:flutter/material.dart';

import '../inventory/inventory_widgets.dart' show kCardLine, kPostedText, kRedText;
import '../ui/theme.dart';
import 'money_api.dart';
import 'money_env.dart';
import 'money_widgets.dart';

// Cashbook, Expenses, Refunds & Adjustments: the money that went out, and the cash in the till. Figma frames "Cashbook", "Expenses", "Money – Refunds & Adjustments".

Future<String?> _pickDay(BuildContext context, String? current) async {
  final now = DateTime.now();
  final d = await showDatePicker(
    context: context,
    initialDate: DateTime.tryParse(current ?? '') ?? now,
    firstDate: now.subtract(const Duration(days: 400)),
    lastDate: now,
  );
  return d == null ? null : isoDay(d);
}

class CashbookScreen extends StatelessWidget {
  const CashbookScreen({super.key, required this.env});
  final MoneyEnv env;
  @override
  Widget build(BuildContext context) => MoneyScreen(
        env: env,
        screen: 'cashbook',
        title: 'Cashbook',
        load: env.api.cashbook,
        body: (c, d) {
          final day = d.s('day');
          final bd = d.m('breakdown');
          final entries = d.l('entries');
          Future<void> record(String dir) async {
            final done = await showMoneyForm(c.context, title: dir == 'in' ? 'Cash In' : 'Cash Out', action: 'Save', fields: [
              const FormFieldSpec('title', 'Description'),
              const FormFieldSpec('amount', 'Amount (₹)', kind: FieldKind.amount),
              FormFieldSpec('category', 'Category', optional: true, initial: dir == 'in' ? 'Sales' : ''),
              const FormFieldSpec('note', 'Note', optional: true),
            ], onSubmit: (v, key) => env.api.recordCash({...v, 'direction': dir, 'entry_date': day}, key));
            if (done) await c.reload();
          }

          return [
            MoneyChips([
              MoneyChip(dayMonth(day, year: true), active: true, onTap: () async {
                final v = await _pickDay(c.context, day);
                if (v != null) c.set({'day': v});
              }),
            ]),
            InvCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Cash balance • ${dayMonth(day, year: true)}', style: inter(13, 600, color: kMuted)),
                const SizedBox(height: 8),
                _Line('Opening balance', money(d.no('opening_minor'), whole: true)),
                _Line('Cash received', money(d.no('received_minor'), whole: true, sign: true), color: kPostedText),
                _Line('Cash paid', money(-(d.no('paid_minor') ?? 0), whole: true), color: kRedText),
                const Divider(height: 20, color: kCardLine),
                Row(children: [
                  Expanded(child: Text('Closing balance', style: inter(15, 700))),
                  Text(money(d.no('closing_minor'), whole: true), style: inter(22, 700)),
                ]),
              ]),
            ),
            if (env.may('record') && d.b('can_record'))
              Row(children: [
                Expanded(child: InvPrimary('Cash In', onPressed: () => record('in'))),
                const SizedBox(width: 10),
                Expanded(child: InvSecondary('Cash Out', onPressed: () => record('out'))),
              ]),
            if (!d.b('started')) const MoneyEmpty('The cashbook starts with its first entry. Add your opening cash with Cash In.'),
            MoneyHeading('Cash entries', pill: '${entries.length + (bd.n('sales_cash_minor') > 0 ? 1 : 0) + (bd.n('cash_refunds_minor') > 0 ? 1 : 0)} entries'),
            if (bd.n('sales_cash_minor') > 0)
              MoneyRow(title: 'Counter sales received', amount: money(bd.no('sales_cash_minor'), sign: true), amountColor: kPostedText, sub: 'Sales • Cash In • from payments'),
            if (bd.n('cash_refunds_minor') > 0)
              MoneyRow(title: 'Cash refunds', amount: money(-bd.n('cash_refunds_minor'), sign: true), amountColor: kRedText, sub: 'Refunds • Cash Out • from refunds'),
            if (entries.isEmpty && bd.n('sales_cash_minor') == 0 && bd.n('cash_refunds_minor') == 0) const MoneyEmpty('No cash entries on this day.'),
            for (final e in entries)
              MoneyRow(
                title: e.s('title'),
                amount: money(e.n('amount_minor') * (e.s('direction') == 'out' ? -1 : 1), sign: true),
                amountColor: e.s('status') == 'voided' ? kMuted : (e.s('direction') == 'out' ? kRedText : kPostedText),
                sub: '#${e.s('no')} • ${e.s('category')} • Cash ${e.s('direction') == 'in' ? 'In' : 'Out'}${e.so('expense_no') == null ? '' : ' • #${e.s('expense_no')}'}',
                status: e.s('status') == 'voided' ? 'voided' : null,
                extra: (d.b('can_void') && env.may('approve') && e.s('status') == 'posted' && e.s('source') == 'manual')
                    ? Align(alignment: Alignment.centerRight, child: TextButton(
                        onPressed: () async {
                          final done = await askReason(c.context, title: 'Void ${e.s('no')}', action: 'Void entry', run: (n, k) => env.api.voidCash(e.s('id'), n, k));
                          if (done) await c.reload();
                        },
                        child: Text('Void', style: inter(13, 600, color: kRedText))))
                    : null,
              ),
            const MoneyFootnote(['Sales cash and cash refunds come from payments and refunds. Cash expenses appear here as well, once.']),
          ];
        },
      );
}

class _Line extends StatelessWidget {
  const _Line(this.k, this.v, {this.color = kInk});
  final String k, v;
  final Color color;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(k, style: inter(14, 400, color: kMuted)), Text(v, style: inter(14, 600, color: color))]),
      );
}

class ExpensesScreen extends StatelessWidget {
  const ExpensesScreen({super.key, required this.env});
  final MoneyEnv env;
  @override
  Widget build(BuildContext context) => MoneyScreen(
        env: env,
        screen: 'expenses',
        title: 'Expenses',
        load: env.api.expenses,
        body: (c, d) {
          final day = d.s('day');
          final rows = d.l('rows');
          final cat = c.q['category'] as String?;
          return [
            MoneyChips([
              MoneyChip(dayMonth(day, year: true), active: true, onTap: () async {
                final v = await _pickDay(c.context, day);
                if (v != null) c.set({'day': v});
              }),
              MoneyChip(cat ?? 'All categories', active: cat != null, onTap: () => chooseFor(c.context, 'Category', [('', 'All categories'), for (final k in d.ls('categories')) (k, k)], cat ?? '', (v) => c.set({'category': v.isEmpty ? null : v}))),
            ]),
            InvCard(
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Total expenses • ${dayMonth(day, year: true)}', style: inter(12.5, 400, color: kMuted)),
                  const SizedBox(height: 4),
                  Text(money(d.no('total_minor'), whole: true), style: inter(26, 700, color: kRedText)),
                ])),
                Text('${d.n('count')} expenses', style: inter(12.5, 400, color: kMuted)),
              ]),
            ),
            if (env.may('record') && d.b('can_record'))
              InvPrimary('Add Expense', onPressed: () async {
                final opts = await _categories(env, d);
                if (!c.context.mounted) return;
                final done = await showMoneyForm(c.context, title: 'Add Expense', action: 'Save expense', fields: [
                  FormFieldSpec('category', 'Category', kind: FieldKind.pick, options: opts),
                  const FormFieldSpec('title', 'Description'),
                  const FormFieldSpec('amount', 'Amount (₹)', kind: FieldKind.amount),
                  const FormFieldSpec('method', 'Payment method', kind: FieldKind.pick, options: [('cash', 'Cash'), ('upi', 'UPI'), ('card', 'Card'), ('bank', 'Bank'), ('other', 'Other')], initial: 'cash'),
                  const FormFieldSpec('note', 'Note', optional: true),
                ], onSubmit: (v, key) => env.api.recordExpense({...v, 'expense_date': day}, key));
                if (done) await c.reload();
              }),
            MoneyHeading('Expenses • ${dayMonth(day, year: true)}'),
            if (rows.isEmpty) const MoneyEmpty('No expenses on this day.'),
            for (final e in rows)
              MoneyRow(
                title: e.s('title'),
                amount: money(-e.n('amount_minor'), whole: true),
                amountColor: e.s('status') == 'voided' ? kMuted : kRedText,
                sub: '#${e.s('no')} • ${e.s('category')} • ${methodLabel(e.so('method'))}',
                status: e.s('status') == 'voided' ? 'voided' : null,
                extra: (d.b('can_void') && env.may('approve') && e.s('status') == 'posted')
                    ? Align(alignment: Alignment.centerRight, child: TextButton(
                        onPressed: () async {
                          final done = await askReason(c.context, title: 'Void ${e.s('no')}', action: 'Void expense', run: (n, k) => env.api.voidExpense(e.s('id'), n, k));
                          if (done) await c.reload();
                        },
                        child: Text('Void', style: inter(13, 600, color: kRedText))))
                    : (e.s('status') == 'voided' && e.so('void_reason') != null ? Text('Voided: ${e.s('void_reason')}', style: inter(12.5, 400, color: kMuted)) : null),
              ),
          ];
        },
      );

  Future<List<(String, String)>> _categories(MoneyEnv env, Facts d) async {
    try {
      final o = await env.api.options();
      return [for (final k in o.ls('categories')) (k, k)];
    } catch (_) {
      return [for (final k in d.ls('categories')) (k, k)];
    }
  }
}

class RefundsScreen extends StatelessWidget {
  const RefundsScreen({super.key, required this.env});
  final MoneyEnv env;
  static const kinds = [('all', 'All activity'), ('refund', 'Refunds'), ('adjustment', 'Adjustments')];
  @override
  Widget build(BuildContext context) => MoneyScreen(
        env: env,
        screen: 'refunds',
        title: 'Refunds & Adjustments',
        defaults: const {'period': 'week', 'kind': 'all'},
        load: env.api.refunds,
        body: (c, d) {
          final w = d.m('window'), ref = d.m('refunded'), rev = d.m('review');
          final rows = d.l('rows');
          final period = c.q['period'] as String, kind = c.q['kind'] as String;
          return [
            tiles2(
              MoneyTile('Refunded', money(ref.no('minor')), sub: '${ref.n('count')} completed refund${ref.n('count') == 1 ? '' : 's'}'),
              MoneyTile('Under review', money(rev.no('minor')), sub: '${rev.n('count')} pending', subColor: kMuted),
            ),
            MoneyChips([
              MoneyChip(rangeLabel(w.so('from'), w.so('to')), onTap: () => chooseFor(c.context, 'Period', periods, period, (v) => c.set({'period': v}))),
              MoneyChip(kinds.firstWhere((k) => k.$1 == kind).$2, active: kind != 'all', onTap: () => chooseFor(c.context, 'Show', kinds, kind, (v) => c.set({'kind': v}))),
            ]),
            MoneyHeading('Refund & adjustment list', pill: '${d.n('total')} records'),
            if (rows.isEmpty) const MoneyEmpty('No refunds or adjustments in this period.'),
            for (final r in rows)
              MoneyRow(
                title: r.so('order_ref') == null ? r.s('ref') : '${r.s('ref')} • ${r.s('order_ref')}',
                amount: money(r.no('amount_minor'), sign: true),
                amountColor: r.n('amount_minor') < 0 ? kRedText : kPostedText,
                sub: '${r.s('reason')} • ${dayMonth(r.so('at'), year: true)}',
                status: r.s('status'),
                extra: r.b('can_decide')
                    ? Row(children: [
                        Expanded(child: InvPrimary('Approve', onPressed: () async {
                          final done = await askReason(c.context, title: 'Approve ${r.s('ref')}', action: 'Approve', hint: 'Note (optional)', run: (n, k) => env.api.decideAdjustment(r.s('id'), 'approve', n, k));
                          if (done) await c.reload();
                        })),
                        const SizedBox(width: 10),
                        Expanded(child: InvSecondary('Reject', onPressed: () async {
                          final done = await askReason(c.context, title: 'Reject ${r.s('ref')}', action: 'Reject', run: (n, k) => env.api.decideAdjustment(r.s('id'), 'reject', n, k));
                          if (done) await c.reload();
                        })),
                      ])
                    : null,
              ),
            MoneyFootnote(const ['Refunds are payments already returned to the customer.', 'An adjustment is a recorded decision: approving it does not change any balance. Rejected and review items are not posted.']),
            if (d.b('can_record') && env.may('record'))
              InvSecondary('Request adjustment', onPressed: () async {
                final done = await showMoneyForm(c.context, title: 'Request adjustment', action: 'Send for review', note: 'Another person with approval rights decides it. Use a minus sign to reduce money.', fields: const [
                  FormFieldSpec('reason', 'Reason'),
                  FormFieldSpec('amount', 'Amount (₹)', kind: FieldKind.signedAmount, hint: '-250 or 80'),
                  FormFieldSpec('kind', 'Kind', kind: FieldKind.pick, options: [('price_correction', 'Price correction'), ('fee_reversal', 'Fee reversal'), ('discount', 'Discount'), ('other', 'Other')], initial: 'other'),
                ], onSubmit: (v, key) => env.api.requestAdjustment(v, key));
                if (done) await c.reload();
              }),
            MoneyCta('Export refunds & adjustments', onPressed: () => exportCsv(c.context, c.api, 'refunds', {'period': period})),
          ];
        },
      );
}
