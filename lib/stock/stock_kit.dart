import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_widgets.dart';
import '../ui/theme.dart';
import 'stock_env.dart';

export '../inventory/inventory_widgets.dart';

/// Every stock page: the app's store banner and bottom bar (same as the rest of the app), a back arrow and a plain title + one line
/// that says what the page is for, then [children]. [actions] sit under the title (small outlined buttons such as Export).
class StockScaffold extends StatelessWidget {
  const StockScaffold({super.key, required this.env, required this.title, this.line, required this.children, this.onRefresh, this.actions = const [], this.bottom});
  final StockEnv env;
  final String title;
  final String? line;
  final List<Widget> children;
  final Future<void> Function()? onRefresh;
  final List<Widget> actions;

  /// A bar fixed above the bottom tabs (Save changes / Reset), when the page has one.
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final page = InvPage(
      onTab: (id) => env.tab(context, id),
      onRefresh: onRefresh,
      onItems: env.inv.onItems ?? () => env.tab(context, 'item'),
      onBell: env.inv.onBell,
      children: [
        // the back arrow is the banner's, just under it
        // an empty title: the page draws its own compact heading (Item → Stock)
        if (title.isNotEmpty) ...[
          Text(title, style: inter(24, 800)),
          if (line != null) ...[const SizedBox(height: 4), Text(line!, style: inter(13.5, 400, color: kMuted, height: 1.35))],
          if (actions.isNotEmpty) ...[const SizedBox(height: 12), Wrap(spacing: 8, runSpacing: 8, children: actions)],
          const SizedBox(height: 16),
        ],
        ...children,
      ],
    );
    if (bottom == null) return page;
    return Column(children: [Expanded(child: page), Material(color: Colors.white, elevation: 8, child: SafeArea(top: false, child: bottom!))]);
  }
}

/// The stock health words people see, from the server's status ids.
String stockStatusLabel(String status) => switch (status) {
      'healthy' => 'Healthy',
      'low' => 'Low',
      'critical' => 'Critical',
      'out' => 'Out of stock',
      'near_expiry' => 'Near expiry',
      'expired' => 'Expired',
      'damaged' => 'Damaged',
      _ => status.isEmpty ? '—' : status[0].toUpperCase() + status.substring(1).replaceAll('_', ' '),
    };

/// A small coloured chip for a stock status (green healthy, amber low / near expiry, red critical / out / expired / damaged).
class StockStatusChip extends StatelessWidget {
  const StockStatusChip(this.status, {super.key, this.label});
  final String status;
  final String? label;
  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (status) {
      'healthy' => (kGreenIconBg, kPostedText),
      'low' || 'near_expiry' => (kAmberBgH, kAmberText),
      'critical' || 'out' || 'expired' || 'damaged' => (kRedBgH, kRedText),
      _ => (kGreyBg, kMuted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(label ?? stockStatusLabel(status), style: inter(12, 700, color: fg)),
    );
  }
}

/// A plain "label · value" row used inside stock cards.
class StockRow extends StatelessWidget {
  const StockRow(this.label, this.value, {super.key, this.color, this.strong = false});
  final String label, value;
  final Color? color;
  final bool strong;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(label, style: inter(13.5, 400, color: kMuted))),
          const SizedBox(width: 12),
          Flexible(child: Text(value, textAlign: TextAlign.right, style: inter(13.5, strong ? 700 : 600, color: color ?? kInk))),
        ]),
      );
}

/// A big number with a small caption (the "84 / Available units" tiles), in a white card.
class StockNumber extends StatelessWidget {
  const StockNumber(this.value, this.caption, {super.key, this.color});
  final String value, caption;
  final Color? color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: kCardLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: inter(26, 800, color: color ?? kInk)),
          const SizedBox(height: 2),
          Text(caption, style: inter(12.5, 400, color: kMuted), maxLines: 2),
        ]),
      );
}

/// Several [StockNumber]s side by side.
class StockNumbers extends StatelessWidget {
  const StockNumbers(this.tiles, {super.key});
  final List<StockNumber> tiles;
  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < tiles.length; i++) ...[if (i > 0) const SizedBox(width: 10), Expanded(child: tiles[i])],
      ]);
}

/// The friendly empty / not-loaded block used by every stock list.
class StockEmpty extends StatelessWidget {
  const StockEmpty(this.title, this.line, {super.key, this.icon = LucideIcons.packageOpen, this.action, this.onAction});
  final String title, line;
  final IconData icon;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: kCardLine)),
        child: Column(children: [
          Icon(icon, size: 30, color: kMuted),
          const SizedBox(height: 10),
          Text(title, textAlign: TextAlign.center, style: inter(16, 700)),
          const SizedBox(height: 4),
          Text(line, textAlign: TextAlign.center, style: inter(13.5, 400, color: kMuted, height: 1.35)),
          if (action != null) ...[const SizedBox(height: 14), InvSecondary(action!, onPressed: onAction)],
        ]),
      );
}

/// A big white row: icon, title, one line, arrow. Used by the section pages and the item page's actions.
class StockPageButton extends StatelessWidget {
  const StockPageButton({super.key, required this.icon, required this.title, required this.line, required this.onTap, this.danger = false});
  final IconData icon;
  final String title, line;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: kCardLine)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
            child: Row(children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: danger ? kRedBgH : kGreenIconBg, borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, size: 20, color: danger ? kRedText : kInk),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: inter(15.5, 700, color: danger ? kRedText : kInk)),
                  const SizedBox(height: 2),
                  Text(line, style: inter(12.5, 400, color: kMuted, height: 1.3)),
                ]),
              ),
              const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
            ]),
          ),
        ),
      );
}
