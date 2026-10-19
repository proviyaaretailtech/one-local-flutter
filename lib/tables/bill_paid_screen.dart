import 'package:flutter/material.dart';

import '../inventory/inventory_api.dart';
import '../sell/result_screens.dart' show TransactionSuccessCard;
import '../ui/theme.dart';
import 'bill_api.dart';
import 'bill_pay_screen.dart';
import 'bill_receipt_screen.dart';
import 'bill_widgets.dart';
import 'table_widgets.dart';

/// Step 4: "Transaction Successful", the store's success card ([TransactionSuccessCard], Figma 448) on the restaurant bar. Every figure is
/// the database's answer to the payment (`rst_bill_pay`): order number, amount paid, method, cash tendered and change, the store, the time.
/// New Order goes back to the tables floor (the table now shows Cleaning); Print Receipt opens "Send receipt". When the table still has
/// another open bill, "Next bill on this table" opens it.
class BillPaidScreen extends StatelessWidget {
  const BillPaidScreen({super.key, required this.env, required this.tableId, required this.result, this.bill});
  final TablesEnv env;
  final String tableId;
  final Facts result;
  final BillApi? bill;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final method = r.s('payment_method');
    final paidAt = r.t('paid_at');
    final next = r.so('next_order_id');
    return TablesPage(
      env: env,
      title: 'Payment complete',
      back: false,
      children: [
        TransactionSuccessCard(
          orderNo: r.s('display_no'),
          amountPaid: r.n('order_total'),
          method: methodName(method),
          tendered: r.s('method') == 'cash' ? r.no('tendered') : null,
          change: r.n('change'),
          branch: r.so('location_name'),
          when: paidAt == null ? '' : '${paidAt.day}/${paidAt.month}/${paidAt.year} · ${clock12(paidAt)}',
          onNewOrder: () => backToTables(context),
          onPrintReceipt: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => BillReceiptScreen(env: env, orderId: r.s('order_id'), bill: bill))),
          footnote: r.b('table_settled') ? 'The table is free: it shows Cleaning on the floor, then Available.' : 'This table still has an open bill.',
        ),
        if (next != null) ...[
          const SizedBox(height: 14),
          LimeButton('Next bill on this table', key: const ValueKey('next-bill'), height: 56, onPressed: () {
            Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => BillPayScreen(env: env, tableId: tableId, bill: bill, orderId: next)));
          }),
        ],
        const SizedBox(height: 8),
        Text(
          r.b('replayed') ? 'This payment was already recorded; nothing was charged again.' : '',
          style: inter(13, 400, color: kMuted),
        ),
      ],
    );
  }
}
