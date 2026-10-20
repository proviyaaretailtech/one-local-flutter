import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/app_tab_bar.dart';
import '../ui/theme.dart';

// Section D tokens, read from the exported Figma frames (assets/figma_ref_d, 2x PNG, colours sampled).
const kNavy = Color(0xFF111827); // header band, bottom bar, dark pill
const kNavyTile = Color(0xFF1F2937); // stat tiles on the header band
const kLime = Color(0xFFA1FE2F); // "Store Open", avatar, centre bar button, button text on dark
const kLimeCta = Color(0xFF65E600); // hub "Get deeper insights", highlighted bar
const kHubBg = Color(0xFFF7F5F0);
const kAmber = Color(0xFFF59E0B);
const kAmberBg = Color(0xFFFFFBEB);
const kAmberInk = Color(0xFF92400E);
const kRed = Color(0xFFEF4444);
const kRedInk = Color(0xFFB91C1C);
const kRedBg = Color(0xFFFEE2E2);
const kGreenDot = Color(0xFF3DB800);
const kUp = Color(0xFF10B981);
const kSoftTile = Color(0xFFF7F8FA);

/// Indian grouping for rupees: ₹3,42,800. Paise shown only when present (₹270.44).
String rupees(num v) {
  final neg = v < 0;
  final abs = v.abs();
  final whole = abs.truncate();
  final paise = ((abs - whole) * 100).round();
  final s = whole.toString();
  String grouped;
  if (s.length <= 3) {
    grouped = s;
  } else {
    final head = s.substring(0, s.length - 3);
    final tail = s.substring(s.length - 3);
    final parts = <String>[];
    for (var i = head.length; i > 0; i -= 2) {
      parts.insert(0, head.substring(i - 2 < 0 ? 0 : i - 2, i));
    }
    grouped = '${parts.join(',')},$tail';
  }
  return '${neg ? '-' : ''}₹$grouped${paise == 0 ? '' : '.${paise.toString().padLeft(2, '0')}'}';
}

/// "1,248" style counts.
String count(num v) => rupees(v).substring(1);

const _months = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];

/// "5 OCT" (caps) or "5 Oct".
String dayLabel(DateTime d, {bool caps = true}) {
  final m = _months[d.month - 1];
  return '${d.day} ${caps ? m : '${m[0]}${m.substring(1).toLowerCase()}'}';
}

/// "just now", "2 min ago", "3 h ago", "2 days ago" between [at] and [now].
String ago(DateTime at, DateTime now) {
  final mins = now.difference(at).inMinutes;
  if (mins < 1) return 'just now';
  if (mins < 60) return '$mins min ago';
  if (mins < 48 * 60) return '${mins ~/ 60} h ago';
  return '${mins ~/ (24 * 60)} days ago';
}

/// Small coloured dot.
class Dot extends StatelessWidget {
  const Dot(this.color, {super.key, this.size = 8});
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

/// Section title row: "Active orders  [• 8 active]          View all".
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.badge, this.action, this.onAction});
  final String title;
  final Widget? badge;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: Row(children: [
          Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 700))),
          if (badge != null) ...[const SizedBox(width: 12), badge!],
        ]),
      ),
      const SizedBox(width: 12),
      if (action != null)
        InkWell(
          onTap: onAction,
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(action!, style: inter(12, 600))),
        ),
    ]);
  }
}

/// Grey rounded tag ("5 OCT", "• 8 active").
class GreyTag extends StatelessWidget {
  const GreyTag(this.label, {super.key, this.dot});
  final String label;
  final Color? dot;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFF1F2F4), borderRadius: BorderRadius.circular(14)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (dot != null) ...[Dot(dot!), const SizedBox(width: 8)],
          Text(label, style: inter(dot == null ? 9.5 : 11, dot == null ? 600 : 500, color: const Color(0xFF4B5563))),
        ]),
      );
}

/// White rounded card, 1px border (dashboard cards).
class HomeCard extends StatelessWidget {
  const HomeCard({super.key, required this.child, this.padding = const EdgeInsets.all(12), this.radius = 16, this.onTap});
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: const BorderSide(color: kLine)),
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      );
}

/// Honest empty state inside a card: nothing is invented when a source has no data.
class EmptyNote extends StatelessWidget {
  const EmptyNote(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(text, style: inter(10.5, 400, color: kMuted, height: 1.45)),
      );
}

/// Dark full-width button with lime label (Figma "Restock critical items", "Review stock closing & item data").
class LimeOnDarkButton extends StatelessWidget {
  const LimeOnDarkButton({super.key, required this.label, required this.onPressed, this.height = 32});
  final String label;
  final VoidCallback? onPressed;
  final double height;
  @override
  Widget build(BuildContext context) => Material(
        color: kPrimary,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onPressed,
          child: Container(
            height: height,
            alignment: Alignment.center,
            child: Text(label, style: inter(12, 600, color: kLime)),
          ),
        ),
      );
}

/// One tab of the floating bottom bar. [hero] is the raised lime centre action.
class BarTab {
  const BarTab(this.label, this.icon, {this.hero = false});
  final String label;
  final IconData icon;
  final bool hero;
}

const kStoreTabs = [
  BarTab('Home', LucideIcons.house),
  BarTab('Item', LucideIcons.archive),
  BarTab('Bill', LucideIcons.receiptText, hero: true),
  BarTab('Online order', LucideIcons.shoppingBag),
  BarTab('Stock', LucideIcons.boxes),
];

const kHubTabs = [
  BarTab('Home', LucideIcons.house),
  BarTab('Menu', LucideIcons.bookOpenText),
  BarTab('Bill', LucideIcons.receiptText, hero: true),
  BarTab('Orders', LucideIcons.shoppingBag),
  BarTab('Stock', LucideIcons.boxes),
];

/// Floating navy bar, radius 40, five tabs, the centre one a lime tile (Figma bottom nav in both frames).
/// With [current], that tab is the filled lime tile (as on the Stock bar) and the centre action, when it is not
/// the current tab, keeps only a lime outline, so it stands out without looking selected.
class FloatingTabBar extends StatelessWidget {
  const FloatingTabBar({super.key, required this.tabs, required this.onTap, this.current});
  final List<BarTab> tabs;
  final ValueChanged<String> onTap;
  final String? current;
  // The app's one bottom bar ([AppTabBar]); tabs are keyed by label ('tab-Home').
  @override
  Widget build(BuildContext context) => AppTabBar(
        tabs: [for (final t in tabs) AppTab(t.label, t.label, t.icon, primary: t.hero)],
        active: current,
        onTap: onTap,
      );
}
