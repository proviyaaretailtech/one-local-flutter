import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/net_guard.dart';
import '../ui/app_tab_bar.dart';
import '../ui/i18n.dart';
import '../ui/app_header.dart';
import '../ui/theme.dart';
import '../ui/mobile_input.dart';
import '../outlets/outlet_header.dart';
import 'inventory_api.dart';
import '../ui/motion.dart';

// Section H tokens, sampled from the exported frames (assets/figma_ref_h, 2x PNG). Shared tokens (kBg, kInk, kMuted, kLine, kPrimary) come from ui/theme.dart.
const kNavyH = Color(0xFF111827); // dark buttons, bottom bar
const kLimeH = Color(0xFFA1FE2F); // active chip, active tab, text on dark buttons
const kLimeBadge = Color(0xFF91E42A); // count badge inside an active chip
const kLimeSoftH = Color(0xFFF1FFE0); // info banner
const kGreenIconBg = Color(0xFFEBFAE0);
const kBlueIconBg = Color(0xFFDBEAFE);
const kBlueIcon = Color(0xFF3B82F6);
const kAmberText = Color(0xFFD97706);
const kAmberBgH = Color(0xFFFEF3C7);
const kRedText = Color(0xFFDC2626);
const kRedBgH = Color(0xFFFEE2E2);
const kRedSoft = Color(0xFFFEF2F2);
const kGreyBg = Color(0xFFF3F4F6);
const kMintBg = Color(0xFFF3FBF8);
const kGreenText = Color(0xFF10A36F);
const kPostedText = Color(0xFF2F9E00);
const kCardLine = Color(0xFFE7E8E3);

/// Indian grouping for counts and units: 1,248 / 0.5 / -2. Display only.
String qty(num? v) {
  if (v == null) return '–';
  final neg = v < 0;
  final a = v.abs();
  final whole = a.truncate();
  final frac = a - whole;
  final s = whole.toString();
  String g;
  if (s.length <= 3) {
    g = s;
  } else {
    final tail = s.substring(s.length - 3);
    var head = s.substring(0, s.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) parts.insert(0, head);
    g = '${parts.join(',')},$tail';
  }
  var f = frac == 0 ? '' : frac.toStringAsFixed(2).substring(1).replaceFirst(RegExp(r'0+$'), '');
  if (f == '.') f = '';
  return '${neg ? '−' : ''}$g$f';
}

/// "−6" / "+12" with a real minus sign.
String signed(num v) => v > 0 ? '+${qty(v)}' : qty(v);

/// "12 units" / "1 unit" / "2.5 kg".
String units(num? v, [String unit = 'unit']) {
  if (v == null) return '–';
  if (unit == 'unit' || unit.isEmpty) return '${qty(v)} ${v.abs() == 1 ? 'unit' : 'units'}';
  return '${qty(v)} $unit';
}

const _mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "05 Oct" / "05 Oct 2026".
String dayMonth(DateTime d, {bool year = false}) => '${d.day.toString().padLeft(2, '0')} ${_mon[d.month - 1]}${year ? ' ${d.year}' : ''}';

/// "10:15".
String hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// "05 Oct 2026, 10:15".
String stamp(DateTime d) => '${dayMonth(d, year: true)}, ${hm(d)}';

/// Status chip text and colours (Figma "Healthy", "Low", "Critical", "Out of Stock", "Near Expiry").
(String, Color, Color) statusLook(String s) => switch (s) {
      'healthy' => ('Healthy', kMintBg, kGreenText),
      'low' => ('Low', kGreyBg, kInk),
      'critical' => ('Critical', kRedSoft, kRedText),
      'out' => ('Out of Stock', kRedSoft, kRedText),
      'near_expiry' => ('Near Expiry', kGreyBg, kInk),
      _ => (s, kGreyBg, kInk),
    };

/// Document status chip ("• Draft", "• Unposted", "• Review", "• Posted").
(String, Color, Color) docLook(String type, String s) => switch (s) {
      'draft' => (type == 'receipt' ? 'Unposted' : 'Draft', kGreyBg, kMuted),
      'review' => (type == 'receipt' ? 'To check' : 'Review', kGreyBg, kMuted),
      'awaiting_approval' => ('Awaiting approval', kAmberBgH, kAmberText),
      'in_transit' => ('In transit', kBlueIconBg, kBlueIcon),
      'posted' => (type == 'receipt' ? 'Completed' : 'Posted', kMintBg, kPostedText),
      'completed' => ('Completed', kMintBg, kPostedText),
      'cancelled' => ('Cancelled', kRedSoft, kRedText),
      _ => (s, kGreyBg, kMuted),
    };

/// Top bar of every section H screen: menu, OneLocal wordmark, dark "Items" pill with a camera, bell. White, rounded at the bottom.
class InvTopBar extends StatelessWidget {
  const InvTopBar({super.key, this.title = 'Money', this.onMenu, this.onItems, this.onBell});
  final String title;
  final VoidCallback? onMenu, onItems, onBell;
  // The shared banner: back, store name over the page's name, the Items scan button, bell, ☰ (used by the Money section).
  @override
  Widget build(BuildContext context) => AppHeader(
        title: title,
        onMenu: onMenu,
        onBell: onBell,
        trailing: Semantics(
          button: true,
          label: tr('Items'),
          excludeSemantics: true,
          child: IconButton(onPressed: onItems, icon: const Icon(LucideIcons.camera, size: 22, color: kInk)),
        ),
      );
}

/// Floating dark bottom bar: Money, Item, Bill, Online order, Stock. The active tab is a lime tile with its label inside.
class InvBottomNav extends StatelessWidget {
  const InvBottomNav({super.key, this.active = 'item', required this.onTap}); // stock and purchase live in Item
  final String active;
  final ValueChanged<String> onTap;
  static const tabs = [
    ('home', 'Home', LucideIcons.house),
    ('item', 'Item', LucideIcons.archive),
    ('bill', 'Bill', LucideIcons.receiptText),
    ('online', 'Online order', LucideIcons.shoppingBag),
    ('slot', '', LucideIcons.circle), // the store's kept, empty slot (Stock is in Item now)
  ];
  // The app's one bottom bar ([AppTabBar]); tabs keep their 'inv-tab-…' keys.
  @override
  Widget build(BuildContext context) => AppTabBar(
        tabs: [for (final (id, label, icon) in tabs) AppTab(id, label, icon, primary: id == 'bill')],
        active: active,
        onTap: onTap,
        keyPrefix: 'inv-tab-',
      );
}

/// Page scaffold: top bar, scrolling body with 14pt sides, floating bottom bar, pull to refresh.
class InvPage extends StatelessWidget {
  const InvPage({super.key, required this.children, required this.onTab, this.onRefresh, this.onMenu, this.onItems, this.onBell});
  final List<Widget> children;
  final ValueChanged<String> onTab;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onMenu, onItems, onBell;
  @override
  Widget build(BuildContext context) {
    Widget list = ListView(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 24),
      children: staggered(children), // sections build in one after another (lib/ui/motion.dart)
    );
    if (onRefresh != null) list = RefreshIndicator(onRefresh: onRefresh!, child: list);
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        // the outlet header (specs/outlets-multi) replaces InvTopBar on every section H screen
        OutletHeader(title: tr('Stock'), onMenu: onMenu),   // ☰: the screen's menu, else the side menu (AppHeader)
        Expanded(child: list),
      ]),
      bottomNavigationBar: InvBottomNav(onTap: onTab),
    );
  }
}

/// Screen title and subtitle ("Inventory Dashboard" / "05 Oct 2026 · 10:30 snapshot · …").
class InvTitle extends StatelessWidget {
  const InvTitle(this.title, {super.key, this.subtitle, this.crumb, this.onCrumb, this.trailing});
  final String title;
  final String? subtitle, crumb;
  final VoidCallback? onCrumb;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Semantics(header: true, child: Text(title, style: inter(23, 700))),
              if (crumb != null) ...[
                const SizedBox(height: 4),
                Semantics(
                  button: true,
                  label: 'Back to $crumb',
                  child: InkWell(onTap: onCrumb ?? () => Navigator.of(context).maybePop(), child: ExcludeSemantics(child: Text('‹ $crumb', style: inter(13.5, 400, color: kMuted)))),
                ),
              ],
              if (subtitle != null) ...[const SizedBox(height: 4), Text(subtitle!, style: inter(13.5, 400, color: kMuted, height: 1.35))],
            ]),
          ),
          ?trailing,
        ]),
      );
}

/// "Quick Actions" style section heading with an optional right note.
class InvSection extends StatelessWidget {
  const InvSection(this.title, {super.key, this.note});
  final String title;
  final String? note;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Row(children: [
          Expanded(child: Semantics(header: true, child: Text(title, style: inter(17.5, 700)))),
          if (note != null) Text(note!, style: inter(12, 400, color: kMuted)),
        ]),
      );
}

/// White rounded card.
class InvCard extends StatelessWidget {
  const InvCard({super.key, required this.child, this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 14), this.margin = const EdgeInsets.only(bottom: 10), this.onTap});
  final Widget child;
  final EdgeInsets padding, margin;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22), border: Border.all(color: kCardLine)),
      child: child,
    );
    return Padding(
      padding: margin,
      child: onTap == null ? box : Material(color: Colors.transparent, child: InkWell(borderRadius: BorderRadius.circular(22), onTap: onTap, child: box)),
    );
  }
}

/// Card heading with a subtitle and an optional chip on the right.
class InvCardHead extends StatelessWidget {
  const InvCardHead(this.title, {super.key, this.subtitle, this.chip});
  final String title;
  final String? subtitle;
  final Widget? chip;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: inter(16.5, 700)),
              if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, style: inter(12.5, 400, color: kMuted))],
            ]),
          ),
          if (chip != null) ...[const SizedBox(width: 8), chip!],
        ]),
      );
}

/// Pill with a dot ("• Posted", "• Draft", "• −2 units").
class InvDotChip extends StatelessWidget {
  const InvDotChip(this.label, {super.key, required this.bg, required this.fg});
  final String label;
  final Color bg, fg;
  factory InvDotChip.doc(String type, String status) {
    final (t, bg, fg) = docLook(type, status);
    return InvDotChip(t, bg: bg, fg: fg);
  }
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
          const SizedBox(width: 7),
          Text(tr(label), style: inter(12.5, 600, color: fg)),
        ]),
      );
}

/// Small status label without a dot (stock cards).
class InvStatusChip extends StatelessWidget {
  const InvStatusChip(this.status, {super.key});
  final String status;
  @override
  Widget build(BuildContext context) {
    final (t, bg, fg) = statusLook(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(t, style: inter(11.5, 600, color: fg)),
    );
  }
}

/// Number tile ("142 / Total items", "84 / Available units").
class InvStatTile extends StatelessWidget {
  const InvStatTile(this.value, this.label, {super.key, this.color = kInk, this.big = true});
  final String value, label;
  final Color color;
  final bool big;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: kCardLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(big ? 27 : 23, 700, color: color)),
          const SizedBox(height: 4),
          Text(tr(label), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12.5, 400, color: kMuted)),
        ]),
      );
}

/// A row of equal tiles with 10pt gaps.
class InvTiles extends StatelessWidget {
  const InvTiles(this.tiles, {super.key});
  final List<Widget> tiles;
  @override
  Widget build(BuildContext context) => Row(children: [
        for (var i = 0; i < tiles.length; i++) ...[if (i > 0) const SizedBox(width: 9), Expanded(child: tiles[i])],
      ]);
}

/// Label left, value right ("Reserved (Active Carts)    8 units").
class InvKV extends StatelessWidget {
  const InvKV(this.k, this.v, {super.key, this.valueColor = kInk, this.onTap, this.bold = true});
  final String k, v;
  final Color valueColor;
  final VoidCallback? onTap;
  final bool bold;
  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Flexible(child: Text(k, style: inter(13.5, 400, color: kMuted))),
        const SizedBox(width: 10),
        Flexible(child: Text(v, textAlign: TextAlign.right, style: inter(13.5, bold ? 600 : 400, color: valueColor))),
      ]),
    );
    return onTap == null ? row : Semantics(button: true, child: InkWell(onTap: onTap, child: row));
  }
}

/// Grey explanation under a card's rows.
class InvNote extends StatelessWidget {
  const InvNote(this.text, {super.key, this.color = kMuted});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(text, style: inter(13, 400, color: color, height: 1.45)),
      );
}

/// Row of filter chips; the active one is lime. A count is shown in a small badge.
class InvChips extends StatelessWidget {
  const InvChips({super.key, required this.items, required this.active, required this.onTap, this.wrap = false});
  final List<(String id, String label, num? count)> items;
  final String active;
  final ValueChanged<String> onTap;
  final bool wrap;
  @override
  Widget build(BuildContext context) {
    final chips = [
      for (final (id, label, count) in items)
        Semantics(
          button: true,
          selected: id == active,
          child: InkWell(
            key: ValueKey('chip-$id'),
            borderRadius: BorderRadius.circular(999),
            onTap: () => onTap(id),
            child: Container(
              padding: EdgeInsets.fromLTRB(13, 7, count == null ? 13 : 7, 7),
              decoration: BoxDecoration(
                color: id == active ? kLimeH : Colors.white,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: id == active ? kLimeH : kLine),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(tr(label), style: inter(13, id == active ? 700 : 500)),
                if (count != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: id == active ? kLimeBadge : kGreyBg, borderRadius: BorderRadius.circular(999)),
                    child: Text(qty(count), style: inter(10.5, 600, color: id == active ? kInk : kMuted)),
                  ),
                ],
              ]),
            ),
          ),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Wrap(spacing: 8, runSpacing: 8, children: chips),
    );
  }
}

/// Dark full-width button with lime text ("View Movements", "Submit for Approval").
class InvPrimary extends StatelessWidget {
  const InvPrimary(this.label, {super.key, required this.onPressed, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Semantics(
          button: true,
          enabled: onPressed != null && !busy,
          child: Material(
            color: onPressed == null ? const Color(0xFF4B5563) : kNavyH,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: busy ? null : onPressed,
              child: Container(
                height: 50,
                alignment: Alignment.center,
                child: busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kLimeH))
                    : Text(tr(label), textAlign: TextAlign.center, style: inter(16, 600, color: kLimeH)),
              ),
            ),
          ),
        ),
      );
}

/// White outlined button ("View Lots", "Save Draft").
class InvSecondary extends StatelessWidget {
  const InvSecondary(this.label, {super.key, required this.onPressed, this.color = kInk, this.textSize = 15});
  final String label;
  final VoidCallback? onPressed;
  final Color color;
  final double textSize;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Semantics(
          button: true,
          enabled: onPressed != null,
          child: Material(
            color: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFFD9DBD5), width: 1.2)),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onPressed,
              child: Container(height: 46, alignment: Alignment.center, child: Text(tr(label), textAlign: TextAlign.center, maxLines: 1, style: inter(textSize, 600, color: onPressed == null ? kMuted : color))),
            ),
          ),
        ),
      );
}

/// Field label above a box ("Product", "Location / lot").
class InvLabel extends StatelessWidget {
  const InvLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(top: 6, bottom: 6), child: Text(text, style: inter(12.5, 600, color: const Color(0xFF4B5563))));
}

/// Tappable box showing the current choice with a small chevron ("Shelf A-01 / CC-A ⌄").
class InvPickBox extends StatelessWidget {
  const InvPickBox({super.key, required this.value, this.onTap, this.chevron = true, this.semantic});
  final String value;
  final VoidCallback? onTap;
  final bool chevron;
  final String? semantic;
  @override
  Widget build(BuildContext context) => Semantics(
        button: onTap != null,
        label: semantic,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFD9DBD5))),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: value),
                if (chevron && onTap != null) TextSpan(text: ' ⌄', style: inter(12, 500)),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: inter(15, 400),
            ),
          ),
        ),
      );
}

/// Text / number box in the same style as [InvPickBox].
class InvInput extends StatelessWidget {
  const InvInput({super.key, required this.controller, this.number = false, this.hint, this.onChanged, this.label, this.prefixIcon, this.suffix, this.mobile = false});

  /// A mobile number: +91 in front, 10 digits.
  final bool mobile;
  final TextEditingController controller;
  final bool number;
  final String? hint, label;
  final ValueChanged<String>? onChanged;
  final IconData? prefixIcon;

  /// A button at the end of the box (for example "Scan a barcode").
  final Widget? suffix;
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 46,
        child: TextField(
          controller: controller,
          onChanged: onChanged,
          keyboardType: mobile ? TextInputType.phone : number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
          inputFormatters: mobile ? mobileFormatters : number ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))] : null,
          style: inter(15, 400),
          decoration: InputDecoration(
            hintText: hint,
            prefixText: mobile ? kMobilePrefix : null,
            prefixStyle: inter(15, 600),
            labelText: null,
            semanticCounterText: label,
            hintStyle: inter(15, 400, color: kMuted),
            prefixIcon: prefixIcon == null ? null : Icon(prefixIcon, size: 18, color: kMuted),
            suffixIcon: suffix,
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFD9DBD5))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kInk)),
          ),
        ),
      );
}

/// Number box with − and + ("24  −      +").
class InvStepper extends StatelessWidget {
  const InvStepper({super.key, required this.value, required this.onChanged, this.min = 0, this.label = 'quantity'});
  final num value;
  final ValueChanged<num> onChanged;
  final num min;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
        height: 46,
        padding: const EdgeInsets.only(left: 14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFD9DBD5))),
        child: Row(children: [
          SizedBox(width: 40, child: Text(qty(value), style: inter(15, 400))),
          Semantics(
            button: true,
            label: 'Decrease $label',
            child: InkWell(onTap: value - 1 < min ? null : () => onChanged(value - 1), child: Padding(padding: const EdgeInsets.all(10), child: Text('–', style: inter(16, 500)))),
          ),
          const SizedBox(width: 70),
          Semantics(
            button: true,
            label: 'Increase $label',
            child: InkWell(onTap: () => onChanged(value + 1), child: Padding(padding: const EdgeInsets.all(10), child: Text('+', style: inter(16, 500)))),
          ),
        ]),
      );
}

/// Lime info banner with an (i) and a close cross ("Current availability stays 84").
class InvInfoBanner extends StatelessWidget {
  const InvInfoBanner({super.key, required this.title, required this.body, this.onClose});
  final String title, body;
  final VoidCallback? onClose;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
        decoration: BoxDecoration(color: kLimeSoftH, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFDDF3C6))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(LucideIcons.info, size: 18, color: kBlueIcon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: inter(14.5, 600)),
              const SizedBox(height: 4),
              Text(body, style: inter(13, 400, color: kMuted, height: 1.45)),
            ]),
          ),
          if (onClose != null)
            Semantics(button: true, label: tr('Dismiss'), child: InkWell(onTap: onClose, child: const Padding(padding: EdgeInsets.all(2), child: Icon(LucideIcons.x, size: 16, color: kMuted)))),
        ]),
      );
}

/// "Illustrative records • 05 Oct 2026, 10:30 snapshot. Drafts do not change posted stock." — here the snapshot is the server's.
class InvFootnote extends StatelessWidget {
  const InvFootnote({super.key, this.at});
  final DateTime? at;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 8),
        child: Text('${at == null ? 'Live records' : 'Live records • ${stamp(at!)} snapshot'}. Drafts do not change posted stock.',
            style: inter(12.5, 400, color: kMuted, height: 1.45)),
      );
}

/// Progress bar (location allocations, count progress).
class InvBar extends StatelessWidget {
  const InvBar({super.key, required this.fraction, this.color = kLimeH});
  final double fraction;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        height: 8,
        margin: const EdgeInsets.only(top: 6, bottom: 4),
        decoration: BoxDecoration(color: const Color(0xFFF1F2EE), borderRadius: BorderRadius.circular(99)),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: fraction.clamp(0, 1).toDouble(),
          child: Container(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(99))),
        ),
      );
}

/// Loading / error / content switch with a retry.
class InvLoad<T> extends StatelessWidget {
  const InvLoad({super.key, required this.data, required this.error, required this.onRetry, required this.builder});
  final T? data;
  final String? error;
  final VoidCallback onRetry;
  final List<Widget> Function(T data) builder;
  @override
  Widget build(BuildContext context) {
    if (data != null) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: builder(data as T));
    if (error != null) {
      return InvCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Could not load this'), style: inter(15, 600)),
          const SizedBox(height: 6),
          Text(error!, style: inter(13, 400, color: kMuted)),
          const SizedBox(height: 10),
          InvSecondary(tr('Try again'), onPressed: onRetry),
        ]),
      );
    }
    return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kInk)));
  }
}

/// Bottom sheet that returns one of [options] (value, label, subtitle).
Future<T?> pickOne<T>(BuildContext context, String title, List<(T value, String label, String? sub)> options, {T? current}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: inter(18, 700)),
            const SizedBox(height: 8),
            if (options.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(tr('Nothing to choose yet.'), style: inter(14, 400, color: kMuted))),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final (v, label, sub) in options)
                  InkWell(
                    onTap: () => Navigator.pop(ctx, v),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(tr(label), style: inter(15, v == current ? 700 : 500)),
                            if (sub != null) Text(sub, style: inter(12.5, 400, color: kMuted)),
                          ]),
                        ),
                        if (v == current) const Icon(LucideIcons.check, size: 18, color: kLink),
                      ]),
                    ),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    ),
  );
}

/// Bottom sheet asking for a short note; returns null when dismissed.
Future<String?> askNote(BuildContext context, String title, {String hint = '', String action = 'Send'}) {
  final c = TextEditingController();
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: inter(18, 700)),
        const SizedBox(height: 12),
        InvInput(controller: c, hint: hint),
        const SizedBox(height: 12),
        InvPrimary(action, onPressed: () => Navigator.pop(ctx, c.text.trim().isEmpty ? null : c.text.trim())),
      ]),
    ),
  );
}

/// Picks an item from the server's stock list (search by name, SKU or barcode). Returns the item facts.
Future<Facts?> pickItem(BuildContext context, InventoryApi api) => showModalBottomSheet<Facts>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => _ItemPicker(api: api),
    );

class _ItemPicker extends StatefulWidget {
  const _ItemPicker({required this.api});
  final InventoryApi api;
  @override
  State<_ItemPicker> createState() => _ItemPickerState();
}

class _ItemPickerState extends State<_ItemPicker> {
  final _q = TextEditingController();
  List<Facts>? _items;
  String? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mine = ++_seq;
    try {
      final r = await widget.api.stock(q: _q.text, pageSize: 30);
      if (!mounted || mine != _seq) return;
      setState(() {
        _items = r.l('items');
        _error = null;
      });
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() => _error = errorSentence(e));
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 12 + MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Choose a product'), style: inter(18, 700)),
            const SizedBox(height: 12),
            InvInput(controller: _q, hint: tr('Search product name, System Code, barcode'), prefixIcon: LucideIcons.search, onChanged: (_) => _load()),
            const SizedBox(height: 8),
            if (_error != null) Text(_error!, style: inter(13, 400, color: kRedText)),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final it in _items ?? const <Facts>[])
                  InkWell(
                    onTap: () => Navigator.pop(context, it),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(it.s('name'), style: inter(15, 600)),
                            Text('${it.s('sku')} · ${units(it.n('available'), it.s('unit'))} free', style: inter(12.5, 400, color: kMuted)),
                          ]),
                        ),
                        InvStatusChip(it.s('status')),
                      ]),
                    ),
                  ),
              ]),
            ),
          ]),
        ),
      );
}
