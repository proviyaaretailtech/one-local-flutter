import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart';
import '../devices/bill_receipt.dart';
import '../devices/print_service.dart';
import '../ui/theme.dart';
import '../ui/whatsapp.dart';
import 'cart_customer.dart';
import 'pay_screen.dart';
import 'sell_api.dart';
import 'sell_env.dart';
import 'sell_widgets.dart';
import '../ui/i18n.dart';

void _backToTill(BuildContext context) => Navigator.of(context).popUntil((r) => r.isFirst || r.settings.name == 'sell');

/// Figma "448 Transaction Success". Every figure is read from the paid bill the server returned.
class SuccessScreen extends StatelessWidget {
  const SuccessScreen({super.key, required this.env, required this.view, this.customerName, this.customerPhone});
  final SellEnv env;
  final OrderView view;
  final String? customerName, customerPhone; // from the cart: the receipt names the customer

  @override
  Widget build(BuildContext context) {
    final pay = view.payment;
    final cash = '${pay['method']}'.toLowerCase().contains('cash');
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        SellTopBar(title: tr('Payment'), initials: env.initials),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(24, 24, 24, 16), children: [
            TransactionSuccessCard(
              orderNo: view.displayNo,
              amountPaid: (view.bill['total'] as num?) ?? 0,
              method: '${pay['method']}',
              tendered: cash ? pay['tendered'] as num? : null,
              change: (pay['change'] as num?) ?? 0,
              branch: env.branchName,
              when: view.placedAt,
              onNewOrder: () => _backToTill(context),
              // the default receipt printer from Settings → Devices (the print dialog when there is none)
              onPrintReceipt: () => printBill(
                context,
                BillReceipt.fromOrder(view, store: env.storeName, branch: env.branchName, customer: customerName, phone: customerPhone),
              ),
              // beside Print: the paid bill to the customer on WhatsApp, as a short note with its online page (founder, 2 Nov 2026)
              onWhatsApp: () => _whatsapp(context),
              footnote: tr('Use New Order to start the next sale.'),
            ),
          ]),
        ),
        PosBottomNav(active: 'bill', onTap: (id) => env.tab(context, id)),
      ]),
    );
  }

  /// The customer's number: the cart's, else the one saved on the bill.
  String get _phone {
    String digits(Object? v) => (v ?? '').toString().replaceAll(RegExp(r'\D'), '');
    final fromCart = digits(customerPhone);
    return fromCart.isNotEmpty ? fromCart : digits(view.raw['customer_phone']);
  }

  Future<void> _whatsapp(BuildContext context) async {
    var phone = _phone, name = (customerName ?? view.customer).trim();
    if (name == 'Guest' || name == 'Walk-in') name = '';
    if (phone.length < 10) {
      // a walk-in who gave no number: ask for it here
      final r = await askCartCustomer(context, name: name, title: tr('Customer\'s WhatsApp number'));
      if (r == null || !context.mounted) return;
      name = r.$1.trim();
      phone = r.$2.replaceAll(RegExp(r'\D'), '');
      if (phone.length < 10) return showToast(context, 'Add the customer\'s mobile number first.');
    }
    try {
      final link = await env.sell.billLink(view.id);
      if (context.mounted) await env.openUrl(whatsAppLink(phone, billNote(store: env.storeName, name: name, link: link)));
    } catch (e) {
      if (context.mounted) showToast(context, sellErrorText(e));
    }
  }
}

/// The WhatsApp note (founder, 2 Nov 2026): a few friendly lines and the link to the bill's online page, which shows the whole bill
/// and can be printed or saved; the bill itself is not written out in the message.
String billNote({required String store, required String name, required Uri link}) => [
      'Dear ${name.isEmpty ? 'Customer' : name},',
      '',
      'Thank you for shopping at $store! 🛍️',
      'Your bill is ready to view, print or save here:',
      '$link',
      '',
      'See you again soon.',
    ].join('\n');

/// The body of "448 Transaction Success", shared by the store till ([SuccessScreen]) and the restaurant's table bill. The figures are the
/// server's; [tendered] (cash only) shows "Amount Tendered" and "Change Returned".
class TransactionSuccessCard extends StatelessWidget {
  const TransactionSuccessCard({super.key, required this.orderNo, required this.amountPaid, required this.method, this.tendered, this.change = 0, this.branch,
      required this.when, required this.onNewOrder, required this.onPrintReceipt, this.onWhatsApp, this.footnote});
  final String orderNo, method, when;
  final num amountPaid, change;
  final num? tendered;
  final String? branch, footnote;
  final VoidCallback onNewOrder, onPrintReceipt;

  /// Send by WhatsApp beside Print Receipt (the store till); none for a table bill.
  final VoidCallback? onWhatsApp;

  @override
  Widget build(BuildContext context) => OrderCardBox(
        radius: 30,
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        child: Column(children: [
          Container(width: 72, height: 72, decoration: const BoxDecoration(color: kChipGreen, shape: BoxShape.circle), child: const Icon(LucideIcons.check, size: 30, color: Color(0xFF3DB800))),
          const SizedBox(height: 16),
          Text(tr('Transaction Successful'), textAlign: TextAlign.center, style: inter(24, 800, color: const Color(0xFF3DB800))),
          const SizedBox(height: 4),
          Text(tr('Receipt generated and sent to customer queue'), textAlign: TextAlign.center, style: inter(13.5, 400, color: kMuted)),
          const Divider(height: 28, color: kLine),
          KeyValue(tr('Order Number'), orderNo, size: 15),
          KeyValue(tr('Total Amount Paid'), rupees(amountPaid), size: 15),
          KeyValue(tr('Payment Method'), tr(method), size: 15),
          if (tendered != null) ...[KeyValue('Amount Tendered', rupees(tendered!), size: 15), KeyValue('Change Returned', rupees(change), size: 15)],
          if (branch != null) KeyValue('Terminal Branch', branch!, size: 15),
          KeyValue(tr('Date & Time'), when, size: 15),
          const Divider(height: 28, color: kLine),
          DarkCta(label: tr('New Order'), onPressed: onNewOrder),
          const SizedBox(height: 12),
          if (onWhatsApp == null)
            LightCta(label: tr('Print Receipt'), onPressed: onPrintReceipt)
          else
            MediaQuery.sizeOf(context).width < 420
                ? Column(children: [
                    LightCta(label: tr('Print Receipt'), onPressed: onPrintReceipt),
                    const SizedBox(height: 10),
                    LightCta(key: const ValueKey('receipt-whatsapp'), label: tr('Send by WhatsApp'), onPressed: onWhatsApp),
                  ])
                : Row(children: [
                    Expanded(child: LightCta(label: tr('Print Receipt'), onPressed: onPrintReceipt)),
                    const SizedBox(width: 10),
                    Expanded(child: LightCta(key: const ValueKey('receipt-whatsapp'), label: tr('Send by WhatsApp'), onPressed: onWhatsApp)),
                  ]),
          if (footnote != null) ...[const SizedBox(height: 14), Text(footnote!, style: inter(12.5, 400, color: kKicker))],
        ]),
      );
}

/// Figma "449 Transaction Failed" (and its negative frame): what was declined, that nothing was charged, and the way out.
/// The cart is still saved as a held bill, so Retry Payment and Try Another Method open the payment screen on that same bill.
class FailedScreen extends StatefulWidget {
  const FailedScreen({super.key, required this.env, required this.failure});
  final SellEnv env;
  final PaymentFailure failure;
  @override
  State<FailedScreen> createState() => _FailedScreenState();
}

class _FailedScreenState extends State<FailedScreen> {
  bool _busy = false;
  bool _dismissed = false;
  PaymentFailure get f => widget.failure;

  Future<void> _reopen(String method) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final order = await widget.env.orders.get(f.orderId);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => PayScreen(env: widget.env, held: order, method: method)));
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final order = await widget.env.orders.get(f.orderId);
      await widget.env.orders.cancel(f.orderId, reason: 'Payment not collected', version: order.version);
      if (mounted) _backToTill(context);
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final env = widget.env;
    final methodName = {'card': 'Card', 'upi': 'UPI', 'cash': 'Cash', 'online': 'Online'}[f.method] ?? f.method;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        SellTopBar(title: tr('Payment'), initials: env.initials),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(24, 20, 24, 16), children: [
            Text(tr('Transaction Failed'), style: inter(28, 800)),
            const SizedBox(height: 4),
            Text('Order ${f.displayNo}', style: inter(14, 400, color: kMuted)),
            const SizedBox(height: 16),
            if (!_dismissed)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: const Color(0xFFFCE0E0), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFEF4444))),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(LucideIcons.circleX, size: 22, color: Color(0xFFEF4444)),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(f.headline, style: inter(15, 700)), const SizedBox(height: 4), Text(f.detail, style: inter(13, 400, color: kMuted))])),
                  InkWell(onTap: () => setState(() => _dismissed = true), child: const Icon(LucideIcons.x, size: 18, color: kMuted)),
                ]),
              ),
            const SizedBox(height: 14),
            OrderCardBox(
              radius: 22,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$methodName · ${f.displayNo}', style: inter(17, 700)),
                const SizedBox(height: 8),
                DotChip(f.status == 'declined' ? 'Declined' : f.status == 'cancelled' ? 'Cancelled' : 'Failed', bg: const Color(0xFFFCE0E0), fg: kBadText, big: true),
                const SizedBox(height: 10),
                KeyValue('Order ID', f.displayNo, size: 15),
                KeyValue('Amount requested', rupees(f.amountDue), size: 17),
                if (f.code.isNotEmpty || f.message.isNotEmpty) KeyValue('Response code', [f.code, f.message].where((s) => s.isNotEmpty).join(' · '), size: 15),
                const Divider(height: 18, color: kLine),
                KeyValue('Payment status', '${f.status == 'declined' ? 'Declined' : f.status == 'cancelled' ? 'Cancelled' : 'Failed'} · Not charged', size: 15),
              ]),
            ),
            const SizedBox(height: 14),
            Text('This payment was ${f.status}. Your cart is saved; retry with approval or choose another method.', style: inter(14, 400, color: kMuted, height: 1.4)),
            const SizedBox(height: 40),
            DarkCta(label: tr('Retry Payment'), busy: _busy, onPressed: () => _reopen(f.method == 'online' ? 'upi' : f.method)),
            const SizedBox(height: 10),
            LightCta(label: tr('Try Another Method'), onPressed: _busy ? null : () => _reopen('cash')),
            const SizedBox(height: 6),
            UnderLink('Cancel transaction · No payment was collected', onTap: _busy ? null : _cancel),
          ]),
        ),
      ]),
    );
  }
}
