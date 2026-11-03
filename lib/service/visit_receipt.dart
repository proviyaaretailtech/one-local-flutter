import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../devices/bill_receipt.dart';
import '../devices/print_service.dart';
import '../orders/order_widgets.dart';
import '../sell/cart_customer.dart';
import '../ui/theme.dart';
import '../ui/whatsapp.dart';
import 'service_api.dart';
import 'service_widgets.dart';

// The receipt after a service visit is paid (2 Nov 2026): a "Transaction Successful" card like the store's, the printed bill, and the bill's
// online page on WhatsApp, the same /b/<code> link the store sends. Every figure is the server's.

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _when(DateTime t) =>
    '${t.day} ${_months[t.month - 1]} ${t.year}, ${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
String _method(String m) => switch (m) { 'upi' => 'UPI', 'card' => 'Card', 'cash' => 'Cash', _ => m };

/// The last payment of the visit, the one just taken.
SvcData? _lastPayment(AppointmentView a) => a.payments.isEmpty ? null : a.payments.last;

/// When the visit was paid: the last payment, else when it was completed.
String visitPaidAt(AppointmentView a) {
  final t = DateTime.tryParse(_lastPayment(a)?.s('at') ?? '') ?? DateTime.tryParse(a.s('completed_at'));
  return t == null ? '' : _when(t.toLocal());
}

/// The visit's bill as the receipt printer prints it.
BillReceipt visitReceipt(AppointmentView a, {required String store}) {
  final b = a.billData, p = _lastPayment(a);
  final cash = p?.s('method') == 'cash' && p!.n('tendered') > 0;
  return BillReceipt(
    store: store,
    billNo: a.m('order').s('display_no').isEmpty ? a.displayNo : a.m('order').s('display_no'),
    when: visitPaidAt(a),
    customer: a.customer,
    phone: a.customerPhone,
    payment: p == null ? '' : _method(p.s('method')),
    lines: [
      for (final l in [...a.lines, ...a.extras]) (name: l.s('name'), qty: l.n('qty'), amount: l.b('covered') ? 0 : l.n('amount')),
    ],
    subtotal: b.n('subtotal'),
    gst: b.n('gst_amount'),
    gstPct: b.n('gst_pct'),
    serviceCharge: b.n('service_charge'),
    discount: b.n('discount'),
    roundOff: b.n('round_off'),
    total: b.n('total'),
    paid: b.n('paid'),
    tendered: cash ? p.n('tendered') : null,
    change: cash ? p.n('tendered') - p.n('amount') : 0,
  );
}

/// The WhatsApp note for a service bill: a few lines and the link to the bill's online page (the bill is not written out in the message).
/// Neutral words, for every kind of service: at the shop, at the customer's place or online.
String visitNote({required String business, required String name, required Uri link}) => [
      'Dear ${name.isEmpty ? 'Customer' : name},',
      '',
      'Thank you for choosing $business.',
      'Your bill is here, ready to view, print or save:',
      '$link',
      '',
      'We look forward to seeing you again.',
    ].join('\n');

/// The paid visit: amount, method, cash and change, Print Receipt and Send by WhatsApp. Done goes back to the visit.
class ServiceReceiptScreen extends StatelessWidget {
  const ServiceReceiptScreen({super.key, required this.api, required this.visit, this.business = '', this.onNavigate, this.openUrl, this.printer});
  final ServiceApi api;
  final AppointmentView visit;
  final String business;
  final ValueChanged<String>? onNavigate;

  /// Opens the WhatsApp link (tests pass a fake).
  final Future<bool> Function(Uri url)? openUrl;

  /// Prints the bill (tests pass a fake); the default receipt printer from Settings → Devices otherwise.
  final Future<void> Function(BuildContext context, BillReceipt bill)? printer;

  String get _store => business.isNotEmpty ? business : visit.location;

  Future<void> _whatsapp(BuildContext context) async {
    var phone = visit.customerPhone.replaceAll(RegExp(r'\D'), ''), name = visit.customer.trim();
    if (phone.length < 10) {
      // booked without a number: ask for it here
      final r = await askCartCustomer(context, name: name, title: 'Customer\'s WhatsApp number');
      if (r == null || !context.mounted) return;
      name = r.$1.trim();
      phone = r.$2.replaceAll(RegExp(r'\D'), '');
      if (phone.length < 10) return showToast(context, 'Add the customer\'s mobile number first.');
    }
    try {
      final link = await api.billLink(visit.m('order').s('id'));
      final opened = await (openUrl ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication))(whatsAppLink(phone, visitNote(business: _store, name: name, link: link)));
      if (!opened && context.mounted) showToast(context, 'Could not open WhatsApp.');
    } on ServiceApiException catch (e) {
      if (context.mounted) showToast(context, e.message);
    } catch (_) {
      if (context.mounted) showToast(context, 'Could not make the bill link. Check the connection and try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _lastPayment(visit);
    final cash = p?.s('method') == 'cash' && p!.n('tendered') > 0;
    final bill = visitReceipt(visit, store: _store);
    return ServicePage(
      title: 'Payment received',
      subtitle: '${visit.displayNo} · ${visit.customer}',
      business: business,
      onNavigate: onNavigate,
      body: [
        OrderCardBox(
          radius: 30,
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
          child: Column(children: [
            Container(width: 72, height: 72, decoration: const BoxDecoration(color: kChipGreen, shape: BoxShape.circle), child: const Icon(LucideIcons.check, size: 30, color: Color(0xFF3DB800))),
            const SizedBox(height: 16),
            Text('Transaction Successful', textAlign: TextAlign.center, style: inter(24, 800, color: const Color(0xFF3DB800))),
            const SizedBox(height: 4),
            Text('The visit is paid and closed.', textAlign: TextAlign.center, style: inter(13.5, 400, color: kMuted)),
            const Divider(height: 28, color: kLine),
            KeyValue('Bill Number', bill.billNo, size: 15),
            KeyValue('Amount Paid', svcRupees(p?.n('amount') ?? visit.billData.n('paid')), size: 15),
            KeyValue('Payment Method', p == null ? 'Prepaid' : _method(p.s('method')), size: 15),
            if (cash) ...[KeyValue('Amount Tendered', svcRupees(p.n('tendered')), size: 15), KeyValue('Change Returned', svcRupees(bill.change), size: 15)],
            KeyValue('Date & Time', bill.when, size: 15),
            const Divider(height: 28, color: kLine),
            DarkCta(label: 'Done', onPressed: () => Navigator.of(context).pop(visit)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: LightCta(label: 'Print Receipt', onPressed: () => (printer ?? printBill)(context, bill))),
              const SizedBox(width: 10),
              Expanded(child: LightCta(key: const ValueKey('receipt-whatsapp'), label: 'Send by WhatsApp', onPressed: () => _whatsapp(context))),
            ]),
          ]),
        ),
      ],
    );
  }
}
