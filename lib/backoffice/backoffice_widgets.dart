import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart' show kDark, kLime;
import '../ui/theme.dart';
import '../outlets/outlet_header.dart';

// Section J colours, read from the exported frames (assets/figma_ref_j). Shared tokens come from ui/theme.dart and section E.
const kBoRed = Color(0xFFDC2626);
const kBoRedBg = Color(0xFFFEE2E2);
const kBoAmber = Color(0xFFD97706);
const kBoAmberBg = Color(0xFFFEF3C7);
const kBoCardLine = Color(0xFFE5E7EB);
const kBoTile = Color(0xFFF3F4F6);

/// Top bar of the back-office screens: the shared outlet header.
class BackofficeTopBar extends StatelessWidget {
  const BackofficeTopBar({super.key, required this.initials, this.onMenu, this.onItems});
  final String initials;
  final VoidCallback? onMenu, onItems;
  // the outlet header (specs/outlets-multi) is the top bar of the back-office screens;
  // [initials] shows until the server answers; [onItems] is no longer drawn
  @override
  Widget build(BuildContext context) => OutletHeader(title: 'Back office', onMenu: onMenu, rounded: true, initials: initials);
}

/// OneLocal wordmark, breadcrumb, page title and the snapshot line.
class BackofficeHeader extends StatelessWidget {
  const BackofficeHeader({super.key, required this.title, required this.snapshotLine});
  final String title;
  final String snapshotLine;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Figma draws the wordmark all in ink here (the sign-in screens use the lime "Local").
        const Padding(
          padding: EdgeInsets.only(left: 3, top: 10),
          child: SizedBox(
            width: 108,
            height: 20,
            child: ColorFiltered(colorFilter: ColorFilter.mode(kInk, BlendMode.srcIn), child: FittedBox(alignment: Alignment.centerLeft, child: BrandLogo())),
          ),
        ),
        const SizedBox(height: 11),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Stock Management / Inventory', style: inter(10.5, 400, color: kMuted)),
            const SizedBox(height: 2),
            Text(title, style: inter(18.5, 700)),
            const SizedBox(height: 2),
            Text(snapshotLine, style: inter(10, 400, color: kMuted)),
          ]),
        ),
      ]);
}

/// "Urgent" (red on pink) or "Low Stock" (amber on cream).
class LevelBadge extends StatelessWidget {
  const LevelBadge({super.key, required this.critical});
  final bool critical;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: critical ? kBoRedBg : kBoAmberBg, borderRadius: BorderRadius.circular(999)),
        child: Text(critical ? 'Urgent' : 'Low Stock', style: inter(10, 700, color: critical ? kBoRed : kBoAmber)),
      );
}

/// Grey square with a box icon.
class ItemTile extends StatelessWidget {
  const ItemTile({super.key});
  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: kBoTile, borderRadius: BorderRadius.circular(9)),
        child: const Icon(LucideIcons.box, size: 20, color: kMuted),
      );
}

/// White rounded card of the back-office lists.
class BoCard extends StatelessWidget {
  const BoCard({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: kBoCardLine)),
        child: child,
      );
}

/// Amber note about stock already on its way.
class InboundBox extends StatelessWidget {
  const InboundBox({super.key, required this.title, required this.body});
  final String title, body;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        decoration: BoxDecoration(color: kBoAmberBg, borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: inter(10, 600, color: kBoAmber)),
          const SizedBox(height: 2),
          Text(body, style: inter(9.5, 400, height: 1.35)),
        ]),
      );
}

/// Grey label left, dark value right (card rows).
class BoRow extends StatelessWidget {
  const BoRow(this.k, this.v, {super.key});
  final String k, v;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(k, style: inter(10, 400, color: kMuted))),
          Text(v, style: inter(10, 400)),
        ]),
      );
}

/// Full-width lime call to action with dark bold label.
class LimeCta extends StatelessWidget {
  const LimeCta({super.key, required this.label, required this.onPressed, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onPressed == null ? 0.55 : 1,
        child: Material(
          color: kLime,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: busy ? null : onPressed,
            child: SizedBox(
              height: 44,
              width: double.infinity,
              child: Center(
                child: busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: kDark))
                    : Text(label, style: inter(13.5, 700, color: kDark)),
              ),
            ),
          ),
        ),
      );
}

/// Dark full-width button inside a card ("View Item").
class DarkCardButton extends StatelessWidget {
  const DarkCardButton({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Material(
        color: kDark,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: SizedBox(height: 32, width: double.infinity, child: Center(child: Text(label, style: inter(11.5, 600, color: Colors.white)))),
        ),
      );
}

// ---------------------------------------------------------------- formatting (display only)

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _two(int n) => n.toString().padLeft(2, '0');

/// "05 Oct 2026, 10:30" style parts.
String boDate(DateTime d) => '${_two(d.day)} ${_months[d.month - 1]} ${d.year}';
String boDay(DateTime d) => '${_two(d.day)} ${_months[d.month - 1]}';
String boTime(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

/// "05 Oct 2026 · 10:30 snapshot · Latur Main Branch" (location left out when organisation-wide).
String snapshotLine(DateTime? at, String? location) =>
    [if (at != null) '${boDate(at)} · ${boTime(at)} snapshot', location ?? 'All locations'].join(' · ');

/// Footnote under the call to action.
String snapshotFootnote(DateTime? at) => '${at == null ? '' : '${boDate(at)}, ${boTime(at)} snapshot. '}Drafts do not change posted stock.';

/// 3 / 0.5 / 2.25 — trims trailing zeros.
String qty(num v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

/// "3 units", "1.5 kg".
String withUnit(num v, String unit) => '${qty(v)} $unit';

/// The short unit of the inbound line ("15u"): first letter of the unit.
String shortUnit(String unit) => unit.isEmpty ? '' : unit.substring(0, 1);

/// "0.5 days cover · 15u inbound · ETA 06 Oct", or null when there is no cover or inbound to show (Figma shows the box only then).
/// Cover alone is shown only with stock on its way: the amber box is about inbound stock.
String? inboundTitle({num? daysCover, num? inboundQty, DateTime? inboundEta, required String unit}) {
  if (inboundQty == null || inboundQty <= 0) return null;
  return [
    if (daysCover != null) '${qty(daysCover)} days cover',
    '${qty(inboundQty)}${shortUnit(unit)} inbound',
    if (inboundEta != null) 'ETA ${boDay(inboundEta)}',
  ].join(' · ');
}

/// Initials from a person's name ("Rahul Sharma" -> "RS").
String initialsOf(String? name) {
  final parts = (name ?? '').trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '';
  return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
}
