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

/// Order status chip: "Pending" (nothing received), "In progress" (some received), "Received"; cancelled as "Cancelled".
(String, Color, Color) poLook(String s) => switch (s) {
      'open' => ('Pending', kGreyBg, kMuted),
      'partial' => ('In progress', kBlueIconBg, kBlueIcon),
      'received' => ('Received', kMintBg, kPostedText),
      'cancelled' => ('Cancelled', kRedSoft, kRedText),
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
    final when = po.status == 'received' && received != null
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

/// One line of an order as the goods receipt note shows it: ordered / received / accepted / rejected, price, GST, lot, expiry, tag.
class PoLineCard extends StatelessWidget {
  const PoLineCard(this.line, {super.key, required this.supplier});
  final Facts line;
  final String supplier;
  @override
  Widget build(BuildContext context) {
    final u = unitWord(line.s('unit'));
    final tag = tagLook(line.so('tag'));
    final rejected = line.n('rejected_qty');
    final lot = line.so('lot_code'), exp = line.t('expiry_date');
    return InvCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(line.s('name'), style: inter(18, 700))),
          if (tag != null) PoChip(tag.$1, bg: tag.$2, fg: tag.$3),
        ]),
        const SizedBox(height: 2),
        Text(supplier, style: inter(14, 400, color: kMuted)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: Text('${qty1(line.n('ordered_qty'))} $u ordered', style: inter(14, 400, color: kMuted))),
          Expanded(child: Text('${qty1(line.n('received_qty'))} $u received', style: inter(14, 400, color: kMuted))),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: Text('${qty1(line.n('accepted_qty'))} $u accepted', style: inter(14.5, 600, color: kPostedText))),
          Expanded(child: Text('${qty1(rejected)} $u rejected', style: inter(14.5, 600, color: rejected > 0 ? kAmberText : kMuted))),
        ]),
        const Divider(height: 22, color: kCardLine),
        Row(children: [
          Expanded(flex: 4, child: Text('${money(line.n('unit_cost_minor'), fixed: true)} / ${line.s('unit') == 'unit' ? 'unit' : line.s('unit')}', style: inter(14, 400, color: kMuted))),
          Expanded(flex: 3, child: Text('GST ${_pct(line.n('gst_pct'))}%', style: inter(14, 400, color: kMuted))),
          Expanded(flex: 4, child: Text(lot ?? '—', textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 400, color: kMuted))),
        ]),
        if (exp != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Exp ${dayMonth(exp)}', style: inter(13, 400, color: kMuted))),
      ]),
    );
  }

  static String _pct(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}

/// "Subtotal accepted goods / Tax total · GST 5% + 12% / GRN total".
class PoTotalsCard extends StatelessWidget {
  const PoTotalsCard(this.po, {super.key});
  final PurchaseOrder po;
  @override
  Widget build(BuildContext context) {
    final t = po.totals;
    final rates = <num>{for (final l in po.lines) if (l.n('tax_minor') > 0) l.n('gst_pct')}.toList()..sort();
    final taxLabel = rates.isEmpty ? 'Tax total' : 'Tax total · GST ${rates.map((r) => r == r.roundToDouble() ? r.toInt().toString() : r.toString()).join('% + ')}%';
    Widget row(String k, String v, {bool big = false, Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(child: Text(k, style: big ? inter(18, 700) : inter(14.5, 400, color: kMuted))),
            Text(v, style: big ? inter(24, 700, color: color ?? kInk) : inter(15.5, 600)),
          ]),
        );
    return InvCard(
      child: Column(children: [
        row('Subtotal accepted goods', money(t.n('subtotal_minor'), fixed: true)),
        row(taxLabel, money(t.n('tax_minor'), fixed: true)),
        const Divider(height: 18, color: kCardLine),
        row('GRN total', money(t.n('total_minor'), fixed: true), big: true, color: kPostedText),
      ]),
    );
  }
}
