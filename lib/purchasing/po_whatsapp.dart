import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../home/home_nav.dart';
import '../inventory/inventory_api.dart' show Facts;
import '../inventory/inventory_widgets.dart' show dayMonth;
import '../ui/theme.dart' show showToast;
import '../ui/whatsapp.dart';
import 'purchasing_api.dart';
import 'purchasing_widgets.dart' show money, unitWord;

// A purchase order goes to the supplier on WhatsApp (founder, 1 Nov 2026): from this store by name, asking for the items, numbered, with
// their quantities, rates and amounts, the order's total, and by when. Suppliers are not on OneLocal, so WhatsApp is how the order reaches them.

/// Tests replace how the WhatsApp link is opened.
Future<bool> Function(Uri uri) openPoWhatsApp = (u) => launchUrl(u, mode: LaunchMode.externalApplication);

/// One item, two lines: "1. Dettol Soap 125g", then "   17 pc × ₹45        ₹765" (a line without a rate shows its quantity only).
List<String> _item(int i, Facts l) {
  final qty = l.n('ordered_qty'), rate = l.no('unit_cost_minor');
  final amount = '${waQty(qty)} ${unitWord(l.s('unit'))}'.trimRight();
  return [
    '${i + 1}. ${l.s('name')}',
    rate == null || rate <= 0 ? '   $amount' : waPair('   $amount × ${money(rate)}', money(rate * qty)),
  ];
}

/// The message: hello to the supplier, who is ordering, the items as a table (name; quantity × rate, amount) with the total under it,
/// the delivery date when there is one, and thanks. The table sits in ``` so WhatsApp shows it in fixed-width text, its columns lined up.
String poWhatsAppMessage(PurchaseOrder po, {String? store}) {
  final shop = (store ?? HomeNav.storeName ?? '').trim();
  final supplier = po.supplierName.trim();
  final expected = po.t('expected_delivery');
  final total = po.totals.no('ordered_total_minor') ?? po.totals.no('estimated_minor');
  return [
    supplier.isEmpty ? 'Hello,' : 'Hello $supplier,',
    '',
    shop.isEmpty ? 'We would like to order these items:' : 'This is $shop. We would like to order these items:',
    '',
    '*Purchase order ${po.number}*',
    '```',
    for (final (i, l) in po.lines.indexed) ..._item(i, l),
    if (total != null && total > 0) ...[waRule, waPair('TOTAL', money(total))],
    '```',
    '',
    if (expected != null) 'Please deliver by ${dayMonth(expected)}.',
    'Kindly confirm the order and the delivery date.',
    '',
    'Thank you,',
    if (shop.isNotEmpty) shop,
  ].join('\n');
}

/// Opens WhatsApp with the order written out, to the supplier's saved number (the order's, else the supplier list's), and notes on the order
/// that it was sent. With no number, WhatsApp opens for the person to choose the chat.
Future<void> sendPoOnWhatsApp(BuildContext context, PurchasingApi api, PurchaseOrder po, {Future<bool> Function(Uri uri)? openUrl}) async {
  var phone = (po.supplierPhone ?? '').replaceAll(RegExp(r'\D'), '');
  if (phone.length < 10) {
    try {
      final s = (await api.suppliers()).where((s) => s.s('id') == po.m('supplier').s('id'));
      phone = s.isEmpty ? '' : s.first.s('phone').replaceAll(RegExp(r'\D'), '');
    } catch (_) {}
  }
  final opened = await (openUrl ?? openPoWhatsApp)(whatsAppLink(phone, poWhatsAppMessage(po)));
  if (!opened) {
    if (context.mounted) showToast(context, 'WhatsApp could not be opened.');
    return;
  }
  if (phone.length >= 10) {
    try {
      await api.send(po.id, channel: 'whatsapp', to: phone.substring(phone.length - 10));
    } catch (_) {} // the order still went; only the note of it failed
  }
}
