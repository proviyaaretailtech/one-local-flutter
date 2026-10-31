import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../ui/app_header.dart';
import '../ui/theme.dart';
import '../ui/i18n.dart';

/// Header of the till screens (Figma): menu or back button, the "O" mark, title and the staff initials.
class SellTopBar extends StatelessWidget {
  const SellTopBar({super.key, this.title = 'OneLocal POS', this.onMenu, this.onBack, this.initials = 'RP', this.action});
  final String title, initials;
  final VoidCallback? onMenu, onBack;
  final Widget? action;
  // The shared banner (back, store name over the page's name, bell, ☰); the till's own name is its tab's, "Bill".
  @override
  Widget build(BuildContext context) =>
      AppHeader(title: title == 'OneLocal POS' || title == 'OneLocal' ? 'Bill' : title, onBack: onBack, onMenu: onMenu, trailing: action);
}

/// Page title and the line under it ("Transaction History" / "OneLocal · Latur Main Branch").
class SellTitle extends StatelessWidget {
  const SellTitle(this.title, {super.key, this.sub});
  final String title;
  final String? sub;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: inter(26, 800)),
        if (sub != null) ...[const SizedBox(height: 4), Text(sub!, style: inter(14, 400, color: kMuted))],
      ]);
}

/// Rounded search field (Figma: white, grey border, magnifier).
class SellSearchField extends StatelessWidget {
  const SellSearchField({super.key, required this.controller, required this.hint, this.onChanged, this.onSubmitted, this.leading = LucideIcons.search, this.onClear, this.trailing});
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged, onSubmitted;
  final IconData leading;
  final VoidCallback? onClear;

  /// A button at the right end (the Bill's barcode scanner).
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Container(
        height: 46,
        padding: EdgeInsets.only(left: 14, right: trailing == null ? 14 : 4),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: const Color(0xFFDADCD5))),
        child: Row(children: [
          Icon(leading, size: 18, color: kMuted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              textInputAction: TextInputAction.search,
              style: inter(14, 400),
              decoration: InputDecoration(border: InputBorder.none, isCollapsed: true, hintText: hint, hintStyle: inter(14, 400, color: kMuted)),
            ),
          ),
          if (onClear != null)
            InkWell(onTap: onClear, customBorder: const CircleBorder(), child: const Padding(padding: EdgeInsets.all(4), child: Icon(LucideIcons.x, size: 16, color: kMuted))),
          ?trailing,
        ]),
      );
}

/// Lime pill for the selected filter, white pill for the others (Figma "All / Customer Returns / Supplier Returns").
class FilterPills extends StatelessWidget {
  const FilterPills({super.key, required this.options, required this.selected, required this.onSelect});
  final List<(String, String)> options;
  final String selected;
  final ValueChanged<String> onSelect;
  @override
  Widget build(BuildContext context) => Row(children: [
        for (final (id, label) in options) ...[
          Expanded(
            child: Semantics(
              button: true,
              selected: id == selected,
              label: label,
              child: Material(
                color: id == selected ? const Color(0xFFA5FF2D) : Colors.white,
                shape: StadiumBorder(side: BorderSide(color: id == selected ? const Color(0xFFA5FF2D) : const Color(0xFFDADCD5))),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () => onSelect(id),
                  child: SizedBox(height: 38, child: Center(child: ExcludeSemantics(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13, id == selected ? 800 : 500, color: id == selected ? kInk : kMuted))))),
                ),
              ),
            ),
          ),
          if (id != options.last.$1) const SizedBox(width: 8),
        ],
      ]);
}

/// Centred message with an icon and up to two buttons: empty, error and loading-failed states.
class StateCard extends StatelessWidget {
  const StateCard({super.key, required this.icon, required this.title, required this.body, this.primary, this.onPrimary, this.secondary, this.onSecondary, this.danger = false});
  final IconData icon;
  final String title, body;
  final String? primary, secondary;
  final VoidCallback? onPrimary, onSecondary;
  final bool danger;
  @override
  Widget build(BuildContext context) => OrderCardBox(
        padding: const EdgeInsets.all(20),
        radius: 22,
        child: Column(children: [
          Container(width: 52, height: 52, decoration: BoxDecoration(color: danger ? kBadBg : kChipGreen, shape: BoxShape.circle), child: Icon(icon, size: 22, color: danger ? kBadText : kGreenText)),
          const SizedBox(height: 14),
          Text(title, textAlign: TextAlign.center, style: inter(18, 700)),
          const SizedBox(height: 6),
          Text(body, textAlign: TextAlign.center, style: inter(13, 400, color: kMuted, height: 1.4)),
          if (primary != null) ...[const SizedBox(height: 16), DarkCta(label: primary!, onPressed: onPrimary)],
          if (secondary != null) ...[const SizedBox(height: 10), LightCta(label: secondary!, onPressed: onSecondary)],
        ]),
      );
}

/// Grey skeleton rows while a list loads.
class SkeletonRows extends StatelessWidget {
  const SkeletonRows({super.key, this.count = 4});
  final int count;
  @override
  Widget build(BuildContext context) => OrderCardBox(
        child: Column(children: [
          for (var i = 0; i < count; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Container(width: 36, height: 36, decoration: const BoxDecoration(color: Color(0xFFEEF0EB), shape: BoxShape.circle)),
                const SizedBox(width: 12),
                Expanded(child: Container(height: 12, decoration: BoxDecoration(color: const Color(0xFFEEF0EB), borderRadius: BorderRadius.circular(6)))),
                const SizedBox(width: 24),
                Container(width: 40, height: 12, decoration: BoxDecoration(color: const Color(0xFFEEF0EB), borderRadius: BorderRadius.circular(6))),
              ]),
            ),
        ]),
      );
}

/// Text of an error the way the person should read it.
String sellErrorText(Object e) {
  final s = e.toString();
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}

/// Where the bottom bar's other tabs lead (Money, Item, Online order, Stock are other sections).
typedef SellNavigate = void Function(String tab);

/// Menu sheet that leads to the F screens that have no tab of their own.
Future<String?> showSellMenu(BuildContext context) => showOrderSheet<String>(
      context,
      title: tr('Sell'),
      body: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        for (final (id, label, icon) in const [
          ('sell', 'New sale', LucideIcons.shoppingCart),
          ('carts', 'Open carts', LucideIcons.layers),
          ('history', 'Order history', LucideIcons.history),
          ('returns', 'Returns & refunds', LucideIcons.undo2),
          ('receipts', 'Invoices & receipts', LucideIcons.receiptText),
          ('shift', 'Cash shift', LucideIcons.wallet),
          ('daily', 'Daily operations', LucideIcons.calendarClock),
        ])
          ListTile(contentPadding: EdgeInsets.zero, leading: Icon(icon, color: kInk), title: Text(label, style: inter(15, 600)), onTap: () => Navigator.pop(ctx, id)),
      ]),
    );

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// 9 Oct 2026
String fmtDay(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

/// 2026-10-09 (what the server takes for a date)
String isoDay(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
