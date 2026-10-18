import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';
import 'orders_api.dart';

// Section E colours, sampled from the exported frames (assets/figma_ref_e). Shared tokens (kBg, kInk, kMuted, kLine) come from ui/theme.dart.
const kDark = Color(0xFF111827);
const kLime = Color(0xFFA1FE2F);
const kLimeSoft = Color(0xFFF1FFE0);
const kChipGreen = Color(0xFFEBFAE0);
const kGreenText = Color(0xFF287000);
const kKicker = Color(0xFF9CA3AF);
const kSoftField = Color(0xFFF5F5F0);
const kWarnText = Color(0xFFB45309);
const kWarnBg = Color(0xFFFFF7ED);
const kBadText = Color(0xFFDC2626);
const kBadBg = Color(0xFFFEF2F2);
const kExcText = Color(0xFFB42318);
const kExcBg = Color(0xFFFFF1F0);
const kInfoGreyBg = Color(0xFFEEF2F6);
const kWhatsApp = Color(0xFF26AD61);

/// Top bar of every section E screen: menu button, "V" mark, title. White, rounded at the bottom.
class OrdersTopBar extends StatelessWidget {
  const OrdersTopBar({super.key, required this.title, this.onMenu, this.onBack});
  final String title;
  final VoidCallback? onMenu, onBack;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 10, 16, 12),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(bottom: Radius.circular(28))),
      child: Row(children: [
        Semantics(
          button: true,
          label: onBack != null ? 'Back' : 'Menu',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onBack ?? onMenu,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: const Color(0xFFF3F4F1), shape: BoxShape.circle, border: Border.all(color: kLine)),
              child: Icon(onBack != null ? LucideIcons.chevronLeft : LucideIcons.menu, size: 18, color: kInk),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: kChipGreen, shape: BoxShape.circle),
          child: Text('V', style: inter(15, 800, color: kGreenText)),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(title, style: inter(17, 700), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}

/// Small rounded label ("Store Checkout", "Online Order").
class TagChip extends StatelessWidget {
  const TagChip(this.label, {super.key, this.bg = kChipGreen, this.fg = kGreenText});
  final String label;
  final Color bg, fg;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(label, style: inter(11, 700, color: fg)),
      );
}

/// Pill with a dot ("• Paid · Cash", "• Pending").
class DotChip extends StatelessWidget {
  const DotChip(this.label, {super.key, this.bg = const Color(0xFFEEF1EA), this.fg = kInk, this.big = false});
  final String label;
  final Color bg, fg;
  final bool big;
  factory DotChip.status(String status, String label) => switch (status) {
        'completed' => DotChip(label, bg: kLimeSoft, fg: kGreenText, big: true),
        'cancelled' => DotChip(label, bg: kBadBg, fg: kBadText, big: true),
        _ => DotChip(label, bg: kWarnBg, fg: kWarnText, big: true),
      };
  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: big ? 12 : 10, vertical: big ? 6 : 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
          const SizedBox(width: 7),
          Text(label, style: inter(big ? 13 : 12.5, 600, color: fg)),
        ]),
      );
}

/// White rounded card used for every block of the order screens.
class OrderCardBox extends StatelessWidget {
  const OrderCardBox({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.radius = 18});
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(radius), border: Border.all(color: const Color(0xFFECEDE8))),
        child: child,
      );
}

/// "ORDER ITEMS" style caption.
class Kick extends StatelessWidget {
  const Kick(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(), style: inter(11, 700, color: kKicker).copyWith(letterSpacing: 0.3));
}

/// Label left, value right.
class KeyValue extends StatelessWidget {
  const KeyValue(this.k, this.v, {super.key, this.valueColor = kInk, this.keyColor = kMuted, this.size = 13, this.bold = true});
  final String k, v;
  final Color valueColor, keyColor;
  final double size;
  final bool bold;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2.5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(k, style: inter(size, 400, color: keyColor)),
          const SizedBox(width: 12),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: inter(size, bold ? 600 : 400, color: valueColor))),
        ]),
      );
}

/// Order number, channel and customer (top card of every order screen).
class OrderHeaderCard extends StatelessWidget {
  const OrderHeaderCard({super.key, required this.number, required this.channel, required this.subtitle});
  final String number, channel, subtitle;
  @override
  Widget build(BuildContext context) => OrderCardBox(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(number, style: inter(15.5, 800), overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            TagChip(channel),
          ]),
          const SizedBox(height: 4),
          Text(subtitle, style: inter(12.5, 400, color: kMuted)),
        ]),
      );
}

/// Title, payment chip and the two status rows.
class StateHeader extends StatelessWidget {
  const StateHeader({super.key, required this.title, required this.chip, required this.orderStatus, required this.fulfilment, this.danger = false});
  final String title, chip, orderStatus, fulfilment;
  final bool danger;
  @override
  Widget build(BuildContext context) => Column(children: [
        Row(children: [
          Expanded(child: Text(title, style: inter(19, 800, color: danger ? kExcText : kInk))),
          DotChip(chip),
        ]),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Column(children: [KeyValue('Order status', orderStatus, size: 12.5), KeyValue('Fulfillment', fulfilment, size: 12.5)]),
        ),
      ]);
}

/// The state note under the header (info green, warning grey-blue, exception red).
class StateNote extends StatelessWidget {
  const StateNote({super.key, required this.tone, required this.title, required this.body});
  final String tone, title, body;
  @override
  Widget build(BuildContext context) {
    final (bg, border, icon, iconColor) = switch (tone) {
      'bad' => (kExcBg, kExcText, LucideIcons.circleX, kExcText),
      'warn' => (kInfoGreyBg, const Color(0xFFE1E6EC), LucideIcons.triangleAlert, kInk),
      _ => (kLimeSoft, const Color(0xFFDDF3C6), LucideIcons.info, kInk),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14), border: Border.all(color: border, width: tone == 'bad' ? 1.2 : 1)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: iconColor),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: inter(13.5, 600)),
            const SizedBox(height: 4),
            Text(body, style: inter(12.5, 400, color: kMuted, height: 1.45)),
          ]),
        ),
      ]),
    );
  }
}

/// One item line: dot, name, sub-line, quantity badge or stepper, amount.
class ItemLine extends StatelessWidget {
  const ItemLine({super.key, required this.name, required this.sub, required this.amount, this.qtyBadge, this.stepper});
  final String name, sub;
  final num amount;
  final String? qtyBadge;
  final Widget? stepper;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 6), child: Container(width: 5, height: 5, decoration: const BoxDecoration(color: kInk, shape: BoxShape.circle))),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: inter(13.5, 500), overflow: TextOverflow.ellipsis),
              const SizedBox(height: 1),
              Text(sub, style: inter(10.5, 400, color: kMuted)),
            ]),
          ),
          const SizedBox(width: 8),
          ?stepper,
          if (qtyBadge != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: kLimeSoft, borderRadius: BorderRadius.circular(999)),
              child: Text(qtyBadge!, style: inter(11, 700)),
            ),
          SizedBox(width: 64, child: Text(rupees(amount), textAlign: TextAlign.right, style: inter(13.5, 700))),
        ]),
      );
}

/// "− 2 +" pill; the minus becomes a bin at 1.
class QtyStepper extends StatelessWidget {
  const QtyStepper({super.key, required this.qty, required this.onMinus, required this.onPlus, required this.name});
  final int qty;
  final VoidCallback onMinus, onPlus;
  final String name;
  @override
  Widget build(BuildContext context) => Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(color: kLimeSoft, borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _tap(qty <= 1 ? LucideIcons.trash2 : LucideIcons.minus, qty <= 1 ? 'Remove $name' : 'One less $name', onMinus),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Text('$qty', style: inter(11.5, 700))),
          _tap(LucideIcons.plus, 'One more $name', onPlus),
        ]),
      );
  Widget _tap(IconData i, String label, VoidCallback f) => Semantics(
        button: true,
        label: label,
        child: InkWell(onTap: f, child: Padding(padding: const EdgeInsets.all(3), child: Icon(i, size: 11, color: kInk))),
      );
}

/// Small rounded button inside the items card ("Apply Coupon", "Add Tip", "Add Items").
class SmallPill extends StatelessWidget {
  const SmallPill(this.label, {super.key, required this.onTap, this.bg = Colors.white, this.fg = kInk, this.border = kLine});
  final String label;
  final VoidCallback? onTap;
  final Color bg, fg, border;
  @override
  Widget build(BuildContext context) => Material(
        color: bg,
        shape: StadiumBorder(side: BorderSide(color: border)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7), child: Text(label, style: inter(12.5, 600, color: fg))),
        ),
      );
}

/// Bill summary block: subtotal, GST, service charge, discount, total.
class BillSummary extends StatelessWidget {
  const BillSummary({super.key, required this.subtotal, required this.gstPct, required this.gst, required this.serviceCharge, required this.discount, required this.roundOff, required this.total, this.footer});
  final num subtotal, gstPct, gst, serviceCharge, discount, roundOff, total;
  final Widget? footer;
  String _pct(num p) => p == p.roundToDouble() ? '${p.toInt()}' : '$p';
  @override
  Widget build(BuildContext context) => OrderCardBox(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Kick('Bill summary'),
          const SizedBox(height: 8),
          KeyValue('Subtotal', rupees(subtotal), size: 13.5, bold: false, valueColor: kInk),
          KeyValue('GST (${_pct(gstPct)}%)', rupees(gst), size: 13.5, bold: false),
          if (serviceCharge != 0) KeyValue('Service Charge', rupees(serviceCharge), size: 13.5, bold: false),
          if (discount != 0) KeyValue('Discount', '-${rupees(discount)}', size: 13.5, bold: false, keyColor: kGreenText, valueColor: kGreenText),
          if (roundOff != 0) KeyValue('Round off', rupees(roundOff), size: 13.5, bold: false),
          const Divider(height: 18, color: kLine),
          Row(children: [
            Expanded(child: Text('Total Amount', style: inter(14.5, 700))),
            Text(rupees(total), style: inter(22, 800, color: kGreenText)),
          ]),
          if (footer != null) ...[const SizedBox(height: 10), footer!],
        ]),
      );
}

/// Read-only or editable amount field ("₹2,000") with a row of chips under it and the change line.
class TenderBlock extends StatelessWidget {
  const TenderBlock({super.key, required this.label, required this.amountText, required this.chips, required this.changeLabel, required this.changeChip, required this.changeValue, this.field, this.selectedChip});
  final String label, amountText, changeLabel, changeChip, changeValue;
  final List<String> chips;
  final String? selectedChip;
  final Widget? field;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: inter(12.5, 600, color: kMuted)),
        const SizedBox(height: 6),
        field ??
            Container(
              height: 46,
              width: double.infinity,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(color: kSoftField, borderRadius: BorderRadius.circular(999), border: Border.all(color: const Color(0xFFD9DBD3))),
              child: Text(amountText, style: inter(20, 800)),
            ),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final c in chips)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: c == selectedChip ? const Color(0xFFEFF1F4) : kSoftField,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: c == selectedChip ? Colors.transparent : const Color(0xFFDDDFD8)),
              ),
              child: Text(c, style: inter(11.5, c == selectedChip ? 700 : 500, color: c == selectedChip ? kInk : kMuted)),
            ),
        ]),
        const Divider(height: 20, color: kLine),
        Row(children: [
          Expanded(child: Text(changeLabel, style: inter(13.5, 400, color: kMuted))),
          TagChip(changeChip),
          const SizedBox(width: 6),
          Text(changeValue, style: inter(20, 800, color: kGreenText)),
        ]),
      ]);
}

/// Dark rounded CTA with lime text (Figma "Proceed to Checkout", "Complete Payment").
class DarkCta extends StatelessWidget {
  const DarkCta({super.key, required this.label, required this.onPressed, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onPressed == null ? 0.55 : 1,
        child: Material(
          color: kDark,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: busy ? null : onPressed,
            child: SizedBox(
              height: 50,
              width: double.infinity,
              child: Center(
                child: busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kLime))
                    : Text(label, style: inter(16, 600, color: kLime)),
              ),
            ),
          ),
        ),
      );
}

/// White rounded secondary button.
class LightCta extends StatelessWidget {
  const LightCta({super.key, required this.label, required this.onPressed, this.bg = Colors.white, this.fg = kInk, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final Color bg, fg;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Material(
        color: bg,
        shape: StadiumBorder(side: BorderSide(color: bg == Colors.white ? const Color(0xFFDADCD5) : bg)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onPressed,
          child: SizedBox(
            height: 50,
            width: double.infinity,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (icon != null) ...[Icon(icon, size: 20, color: fg), const SizedBox(width: 10)],
              Text(label, style: inter(16, 600, color: fg)),
            ]),
          ),
        ),
      );
}

/// Underlined grey text link under the buttons.
class UnderLink extends StatelessWidget {
  const UnderLink(this.label, {super.key, required this.onTap});
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Center(
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Text(label, style: inter(13, 500, color: kMuted).copyWith(decoration: TextDecoration.underline, decorationColor: kMuted)),
          ),
        ),
      );
}

/// Dark bottom bar: Money, Item, Bill, Online order, Stock. [active] is highlighted; [onTap] gets the tab id.
class PosBottomNav extends StatelessWidget {
  const PosBottomNav({super.key, this.active = 'bill', required this.onTap});
  final String active;
  final ValueChanged<String> onTap;
  static const tabs = [
    ('home', 'Home', LucideIcons.house),
    ('item', 'Item', LucideIcons.archive),
    ('bill', 'Bill', LucideIcons.receiptText),
    ('online', 'Online order', LucideIcons.shoppingBag),
    ('stock', 'Stock', LucideIcons.boxes),
  ];
  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 12, 16, 12), // 12 above: the last button of a page never touches the bar
        child: Container(
          height: 72,
          decoration: BoxDecoration(color: kDark, borderRadius: BorderRadius.circular(30)),
          child: Row(children: [
            for (final (id, label, icon) in tabs)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: id == active,
                  label: label,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => onTap(id),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Container(
                        width: id == active ? 40 : 28,
                        height: id == active ? 36 : 26,
                        decoration: id == active ? BoxDecoration(color: kLime, borderRadius: BorderRadius.circular(10)) : null,
                        child: Icon(icon, size: 20, color: id == active ? kDark : Colors.white),
                      ),
                      const SizedBox(height: 4),
                      ExcludeSemantics(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, id == active ? 700 : 500, color: Colors.white))),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      );
}

/// Bottom sheet frame shared by the order sheets.
Future<T?> showOrderSheet<T>(BuildContext context, {required String title, required Widget Function(BuildContext) body}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: inter(18, 700)),
          const SizedBox(height: 14),
          Flexible(child: body(ctx)),
        ]),
      ),
    ),
  );
}
