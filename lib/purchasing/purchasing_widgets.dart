import 'package:flutter/material.dart';

import '../inventory/inventory_api.dart';
import '../inventory/inventory_widgets.dart';
import '../ui/theme.dart';
import 'purchasing_api.dart';

/// Paise as rupees in Indian grouping: `₹3,600`, `₹3,632.50` (whole amounts drop the paise unless [fixed]).
String money(num? minor, {bool fixed = false}) {
  final v = (minor ?? 0).round();
  final neg = v < 0;
  final abs = v.abs();
  final rupees = abs ~/ 100, paise = abs % 100;
  final digits = rupees.toString();
  final grouped = digits.length <= 3
      ? digits
      : '${digits.substring(0, digits.length - 3).replaceAllMapped(RegExp(r'(\d)(?=(\d\d)+$)'), (m) => '${m[1]},')},${digits.substring(digits.length - 3)}';
  final tail = (paise == 0 && !fixed) ? '' : '.${paise.toString().padLeft(2, '0')}';
  return '${neg ? '-' : ''}₹$grouped$tail';
}

/// A quantity with at least one decimal, at most three: `10.0`, `18.5`, `0.125`.
String qty1(num? v) {
  final n = v ?? 0;
  var s = n.toStringAsFixed(3);
  s = s.replaceFirst(RegExp(r'0+$'), '');
  if (s.endsWith('.')) s += '0';
  return s;
}

/// "kg" for `kg`, "units" for the generic `unit`.
String unitWord(String unit) => unit == 'unit' ? 'units' : unit;

/// Order status chip: the device lifecycle's own words. "Pending" = awaiting approval, "In progress" = partly received.
(String, Color, Color) poLook(String s) => switch (s) {
      'Draft' => ('Draft', kGreyBg, kMuted),
      'Pending' => ('Pending approval', kAmberBgH, kAmberText),
      'Approved' => ('Approved', kBlueIconBg, kBlueIcon),
      'Partially Received' => ('In progress', kBlueIconBg, kBlueIcon),
      'Received' => ('Received', kMintBg, kPostedText),
      'Cancelled' => ('Cancelled', kRedSoft, kRedText),
      _ => (s, kGreyBg, kMuted),
    };

/// Line tag: "Approved" (accepted covers what was ordered, nothing rejected) or "Discrepancy"; nothing while no goods arrived.
(String, Color, Color)? tagLook(String? t) => switch (t) {
      'approved' => ('Approved', kMintBg, kPostedText),
      'discrepancy' => ('Discrepancy', kAmberBgH, kAmberText),
      _ => null,
    };

class PoChip extends StatelessWidget {
  const PoChip(this.label, {super.key, required this.bg, required this.fg});
  final String label;
  final Color bg, fg;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(label, style: inter(12.5, 600, color: fg)),
      );
}

/// The order header card: "PO-1042 · ABC Foods", status chip, "Received 10 Sep 2026" (or when it is expected).
class PoHeaderCard extends StatelessWidget {
  const PoHeaderCard(this.po, {super.key, this.onTap});
  final PurchaseOrder po;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final (label, bg, fg) = poLook(po.status);
    final received = po.t('received_at'), expected = po.t('expected_delivery');
    final when = po.status == 'Received' && received != null
        ? 'Received ${dayMonth(received, year: true)}'
        : expected != null
            ? '${po.overdue ? 'Overdue · expected' : 'Expected'} ${dayMonth(expected, year: true)}'
            : '';
    return InvCard(
      onTap: onTap,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${po.number} · ${po.supplierName}', style: inter(18, 700)),
            if (when.isNotEmpty) ...[const SizedBox(height: 6), Text(when, style: inter(14.5, 400, color: po.overdue ? kRedText : kMuted))],
          ]),
        ),
        const SizedBox(width: 8),
        PoChip(label, bg: bg, fg: fg),
      ]),
    );
  }
}

/// All the items of an order in one card (founder, 29 Oct 2026: not a card per product): each row is the item, how many at what
/// price and GST, and the line amount; once goods arrive, what was accepted and rejected. The totals close the card: what the order
/// comes to while nothing has arrived, then the accepted goods as the server computed them.
class PoItemsCard extends StatelessWidget {
  const PoItemsCard(this.po, {super.key});
  final PurchaseOrder po;

  static String _pct(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  Widget _row(Facts line) {
    final u = unitWord(line.s('unit'));
    final tag = tagLook(line.so('tag'));
    final ordered = line.n('ordered_qty'), received = line.n('received_qty'), rejected = line.n('rejected_qty');
    final cost = line.n('unit_cost_minor');
    final lot = line.so('lot_code'), exp = line.t('expiry_date');
    Widget pill(String text, Color bg, Color fg) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
          child: Text(text, style: inter(12, 600, color: fg)),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(line.s('name'), style: inter(15.5, 700))),
          const SizedBox(width: 10),
          Text(money((ordered * cost).round(), fixed: true), style: inter(15, 700)),
        ]),
        const SizedBox(height: 3),
        Text('${qty1(ordered)} $u × ${money(cost, fixed: true)} · GST ${_pct(line.n('gst_pct'))}%', style: inter(13, 400, color: kMuted)),
        if (received > 0 || tag != null) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            pill('${qty1(line.n('accepted_qty'))} $u accepted', kMintBg, kPostedText),
            if (rejected > 0) pill('${qty1(rejected)} $u rejected', kAmberBgH, kAmberText),
            if (ordered - line.n('accepted_qty') - rejected > 0) pill('${qty1(ordered - line.n('accepted_qty') - rejected)} $u not received', kGreyBg, kMuted),
            if (tag != null && tag.$1 == 'Discrepancy') pill(tag.$1, tag.$2, tag.$3),
          ]),
        ],
        if (lot != null || exp != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text([if (lot != null) 'Lot $lot', if (exp != null) 'Exp ${dayMonth(exp)}'].join(' · '), style: inter(12.5, 400, color: kMuted)),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lines = po.lines;
    final arrived = lines.any((l) => l.n('received_qty') > 0);
    Widget total(String k, String v, {bool big = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Text(k, style: big ? inter(16.5, 800) : inter(14, 500, color: kMuted))),
            Text(v, style: big ? inter(21, 800, color: kPostedText) : inter(14.5, 600)),
          ]),
        );
    final List<Widget> sums;
    if (arrived) {
      final t = po.totals;
      final rates = <num>{for (final l in lines) if (l.n('tax_minor') > 0) l.n('gst_pct')}.toList()..sort();
      sums = [
        total('Subtotal accepted goods', money(t.n('subtotal_minor'), fixed: true)),
        total(rates.isEmpty ? 'Tax total' : 'Tax total · GST ${rates.map(_pct).join('% + ')}%', money(t.n('tax_minor'), fixed: true)),
        total('Purchase total', money(t.n('total_minor'), fixed: true), big: true),
      ];
    } else {
      // nothing has come yet: what the order comes to, from the ordered quantities
      final sub = lines.fold<num>(0, (s, l) => s + l.n('ordered_qty') * l.n('unit_cost_minor'));
      final gst = lines.fold<num>(0, (s, l) => s + l.n('ordered_qty') * l.n('unit_cost_minor') * l.n('gst_pct') / 100);
      sums = [
        total('Order value', money(sub.round(), fixed: true)),
        total('GST', money(gst.round(), fixed: true)),
        total('Order total', money((sub + gst).round(), fixed: true), big: true),
      ];
    }
    return InvCard(
      key: const ValueKey('po-items'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('Items · ${lines.length}', style: inter(16, 800))),
          Text(arrived ? 'Ordered · accepted' : 'Ordered', style: inter(12.5, 600, color: kMuted)),
        ]),
        for (final (i, l) in lines.indexed) ...[
          if (i > 0) const Divider(height: 1, color: kCardLine),
          _row(l),
        ],
        Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(14)),
          child: Column(children: sums),
        ),
      ]),
    );
  }
}
