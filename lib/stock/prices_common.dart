import 'package:flutter/material.dart';

import '../auth/partner_api.dart';
import '../inventory/inventory_api.dart';
import 'stock_kit.dart';

/// Helpers shared by the Stock & Prices pages (Stock Management, Low stock, Reorder).

/// Every stock row of the store, page by page (the server sends at most 50 at a time), with the counts of the first page.
Future<({List<Facts> items, Facts first})> loadAllStock(InventoryApi api, {String filter = 'all', String q = ''}) async {
  final first = await api.stock(filter: filter, q: q, pageSize: 50);
  final items = [...first.l('items')];
  final total = first.n('total').toInt();
  for (var page = 2; items.length < total && page <= 20; page++) {
    final next = await api.stock(filter: filter, q: q, page: page, pageSize: 50);
    final rows = next.l('items');
    if (rows.isEmpty) break;
    items.addAll(rows);
  }
  return (items: items, first: first);
}

/// The server's own sentence when it refused, else a plain one.
String stockError(Object e, [String fallback = 'Could not load this. Check the connection and try again.']) => e is PartnerApiException ? e.message : fallback;

/// ₹ from paise: "₹40", "₹0.42".
String rupeesOf(num? minor) {
  if (minor == null) return '—';
  final r = minor / 100;
  return r == r.roundToDouble() ? '₹${r.toInt()}' : '₹${r.toStringAsFixed(2)}';
}

/// Days of stock left, in words: "6 days", "Half a day", "No stock", "—" when the server cannot tell (no sales yet).
String coverText(Facts it) {
  if (it.n('available') <= 0) return 'No stock';
  final d = it.no('stock_days');
  if (d == null) return 'No sales yet';
  if (d < 1) return 'Under a day';
  return d == d.roundToDouble() ? '${d.toInt()} ${d == 1 ? 'day' : 'days'}' : '${d.toStringAsFixed(1)} days';
}

/// Expiry in words: "Expired", "Today", "In 4 days", "—".
String expiryText(Facts it) {
  final d = it.no('expiry_days');
  if (d == null) return '—';
  if (d < 0) return 'Expired';
  if (d == 0) return 'Today';
  return 'In ${d.toInt()} ${d == 1 ? 'day' : 'days'}';
}

/// "12 pc" with the item's unit.
String unitsOf(Facts it, String key) => '${qty(it.n(key))} ${it.s('unit').isEmpty ? 'units' : it.s('unit')}';

/// A thin bar for days of stock left on a 0-14 day scale (red under 2 days, amber under 7).
class CoverBar extends StatelessWidget {
  const CoverBar(this.days, {super.key});
  final num? days;
  @override
  Widget build(BuildContext context) {
    final d = days ?? 0;
    final color = d < 2 ? kRedText : d < 7 ? kAmberText : kPostedText;
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: LinearProgressIndicator(value: (d / 14).clamp(0.02, 1.0).toDouble(), minHeight: 7, color: color, backgroundColor: kGreyBg),
    );
  }
}

/// Two outlined buttons side by side under a card.
class TwoButtons extends StatelessWidget {
  const TwoButtons(this.a, this.onA, this.b, this.onB, {super.key});
  final String a, b;
  final VoidCallback? onA, onB;
  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(child: InvSecondary(a, onPressed: onA, textSize: 14)),
        const SizedBox(width: 10),
        Expanded(child: InvSecondary(b, onPressed: onB, textSize: 14)),
      ]);
}
