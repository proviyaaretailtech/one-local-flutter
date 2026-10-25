import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'catalogue_api.dart';
import 'catalogue_format.dart';

/// The pastel tile behind an item. Shows the item's photo when it has one, otherwise a package mark (no stock photos are invented).
class ItemTile extends StatelessWidget {
  const ItemTile(this.item, {super.key, this.size = 52});
  final CatItem item;
  final double size;
  static const _tints = [Color(0xFFE3F1FC), Color(0xFFFDF0DC), Color(0xFFFBF3D0), Color(0xFFFCE9E7), Color(0xFFE9F2FB), Color(0xFFFFF7D6)];
  @override
  Widget build(BuildContext context) {
    final tint = _tints[(item.name.isEmpty ? 0 : item.name.codeUnitAt(0)) % _tints.length];
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(14)),
      child: item.imageUrl != null && item.imageUrl!.isNotEmpty
          ? Image.network(item.imageUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.package, size: 24, color: kMuted))
          : Icon(LucideIcons.package, size: size * 0.45, color: kMuted),
    );
  }
}

/// "● Available · QR ✓"
class StatusLine extends StatelessWidget {
  const StatusLine(this.item, {super.key, this.showQr = true});
  final CatItem item;
  final bool showQr;
  @override
  Widget build(BuildContext context) {
    final text = [statusLabel(item), if (showQr && item.hasBarcode) 'QR ✓'].join(' · ');
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 9, height: 9, decoration: BoxDecoration(color: item.available ? kMuted : kWarnText, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Flexible(child: Text(text, style: inter(13, 400, color: kMuted), overflow: TextOverflow.ellipsis)),
    ]);
  }
}

/// A row of the List view.
class ItemRow extends StatelessWidget {
  const ItemRow(this.item, {super.key, required this.onTap, required this.onMore});
  final CatItem item;
  final VoidCallback onTap, onMore;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Open ${item.name}',
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ItemTile(item),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(item.name, style: inter(17, 600), maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Text('${item.sku} · ${unitSub(item.sellingUnit)}', style: inter(13, 400, color: kMuted)),
                  const SizedBox(height: 4),
                  StatusLine(item),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('${money(item.priceMinor)}/${unitShort(item.sellingUnit)}', style: inter(17, 700)),
                const SizedBox(height: 4),
                if (item.stockQty != null) Text('${qty(item.stockQty!)} ${unitShort(item.sellingUnit)}', style: inter(14, 400, color: kMuted)),
              ]),
              IconButton(tooltip: 'Actions for ${item.name}', onPressed: onMore, icon: const Icon(LucideIcons.ellipsisVertical, size: 20, color: kMuted)),
            ]),
          ),
        ),
      );
}

/// A card of the Grid view.
class ItemGridCard extends StatelessWidget {
  const ItemGridCard(this.item, {super.key, required this.onTap, required this.onMore});
  final CatItem item;
  final VoidCallback onTap, onMore;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Open ${item.name}',
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 4, 14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFECEDE8))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                ItemTile(item, size: 40),
                const Spacer(),
                if (item.hasBarcode) const TagChip('QR ✓', bg: kChipGreen, fg: kGreenText),
                IconButton(tooltip: 'Actions for ${item.name}', visualDensity: VisualDensity.compact, onPressed: onMore, icon: const Icon(LucideIcons.ellipsisVertical, size: 18, color: kMuted)),
              ]),
              const SizedBox(height: 6),
              Text(item.name, style: inter(16, 600), maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 3),
              Text('${item.sku} · ${unitSub(item.sellingUnit)}', style: inter(12.5, 400, color: kMuted)),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Row(children: [
                  Text('${money(item.priceMinor)}/${unitShort(item.sellingUnit)}', style: inter(17, 700)),
                  const Spacer(),
                  if (item.stockQty != null) Text('${qty(item.stockQty!)} ${unitShort(item.sellingUnit)}', style: inter(13, 400, color: kMuted)),
                ]),
              ),
              const SizedBox(height: 6),
              StatusLine(item, showQr: false),
            ]),
          ),
        ),
      );
}

/// "Active Items 340" tile.
/// A count card. With [onTap] it is a filter: tap to show those items (lime when [selected]), with a small arrow so it reads as tappable.
class StatTile extends StatelessWidget {
  const StatTile(this.label, this.value, {super.key, this.onTap, this.selected = false});
  final String label;
  final int value;
  final VoidCallback? onTap;
  final bool selected;
  @override
  Widget build(BuildContext context) => Material(
        color: selected ? kLimeSoft : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: selected ? kLime : const Color(0xFFECEDE8), width: selected ? 1.5 : 1)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: inter(13, selected ? 600 : 400, color: selected ? kInk : kMuted), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Row(children: [
                Expanded(child: Text('$value', style: inter(15, 700))),
                if (onTap != null) Icon(selected ? LucideIcons.check : LucideIcons.chevronRight, size: 15, color: selected ? kInk : kMuted),
              ]),
            ]),
          ),
        ),
      );
}

/// Dark pill button with lime text ("POS Items →", "Edit catalogue details", "Review Exceptions").
class DarkButton extends StatelessWidget {
  const DarkButton(this.label, {super.key, required this.onPressed, this.trailing, this.height = 48, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData? trailing;
  final double height;
  final bool busy;
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onPressed == null ? 0.45 : 1,
        child: Material(
          color: kPrimary,
          borderRadius: BorderRadius.circular(height / 2),
          child: InkWell(
            borderRadius: BorderRadius.circular(height / 2),
            onTap: busy ? null : onPressed,
            child: SizedBox(
              height: height,
              width: double.infinity,
              child: Center(
                child: busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: kLime))
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(label, style: inter(15, 700, color: kLime)),
                        if (trailing != null) ...[const SizedBox(width: 8), Icon(trailing, size: 18, color: kLime)],
                      ]),
              ),
            ),
          ),
        ),
      );
}

/// White pill with a border ("Cancel", "Open Receipt", "Save draft only").
class OutlineButton extends StatelessWidget {
  const OutlineButton(this.label, {super.key, required this.onPressed, this.height = 52, this.color = kInk});
  final String label;
  final VoidCallback? onPressed;
  final double height;
  final Color color;
  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(height / 2), side: const BorderSide(color: Color(0xFFD9DCD6))),
        child: InkWell(
          customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(height / 2)),
          onTap: onPressed,
          child: SizedBox(height: height, width: double.infinity, child: Center(child: Text(label, style: inter(14, 600, color: color)))),
        ),
      );
}

/// A bordered option card in a sheet ("View product details / Open the catalogue record").
class SheetOption extends StatelessWidget {
  const SheetOption(this.title, {super.key, this.subtitle, this.trailing, this.onTap, this.color = kInk, this.fill});
  final String title;
  final String? subtitle;
  final IconData? trailing;
  final VoidCallback? onTap;
  final Color color;
  final Color? fill;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Material(
          color: fill ?? Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: Color(0xFFE3E5DF))),
          child: InkWell(
            customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: inter(15, 600, color: color)),
                    if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, style: inter(13, 400, color: kMuted))],
                  ]),
                ),
                if (trailing != null) Icon(trailing, size: 20, color: color == kInk ? kMuted : color),
              ]),
            ),
          ),
        ),
      );
}

/// Sheet frame with a drag handle, a title and a close button (Figma Action Sheet / About this product).
Future<T?> showCatSheet<T>(BuildContext context, {required String title, String? subtitle, required Widget Function(BuildContext) body}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (ctx) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 10, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFFD9DCE2), borderRadius: BorderRadius.circular(4)))),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Text(title, style: inter(20, 700))),
            IconButton(tooltip: 'Close', onPressed: () => Navigator.of(ctx).pop(), icon: const Icon(LucideIcons.x, size: 20)),
          ]),
          if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle, style: inter(13, 400, color: kMuted))],
          const SizedBox(height: 14),
          body(ctx),
        ]),
      ),
    ),
  );
}

/// Green "+ Add Items" pill and the other lime-filled buttons.
class LimeButton extends StatelessWidget {
  const LimeButton(this.label, {super.key, required this.onPressed, this.height = 46});
  final String label;
  final VoidCallback? onPressed;
  final double height;
  @override
  Widget build(BuildContext context) => Material(
        color: kLime,
        borderRadius: BorderRadius.circular(height / 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(height / 2),
          onTap: onPressed,
          child: SizedBox(height: height, child: Center(child: Text(label, style: inter(14, 700, color: kDark)))),
        ),
      );
}

/// Section headline: "Catalogue" with a count pill, "GRN Dashboard" with a hint line.
class BigTitle extends StatelessWidget {
  const BigTitle(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(child: Text(title, style: inter(26, 800).copyWith(letterSpacing: -0.4))),
        ?trailing,
      ]);
}

/// The empty product-photo spot: a full-width dashed box with a camera, "Tap to add photo". Used by Item creation and Quick add.
class AddPhotoBox extends StatelessWidget {
  const AddPhotoBox({super.key, required this.onTap, this.height = 120});
  final VoidCallback? onTap;
  final double height;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: CustomPaint(
          painter: const _DashedBorder(color: Color(0xFFC9CDC4), radius: 16),
          child: Container(
            height: height,
            width: double.infinity,
            decoration: BoxDecoration(color: const Color(0xFFF8F9F6), borderRadius: BorderRadius.circular(16)),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(LucideIcons.camera, size: 26, color: kMuted),
              const SizedBox(height: 8),
              Text('Tap to add photo', style: inter(14, 500, color: kMuted)),
              const SizedBox(height: 2),
              Text('JPG, PNG or WebP · up to 5 MB', style: inter(11.5, 400, color: const Color(0xFF9CA3AF))),
            ]),
          ),
        ),
      );
}

class _DashedBorder extends CustomPainter {
  const _DashedBorder({required this.color, required this.radius});
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3;
    final outline = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)));
    const dash = 6.0, gap = 4.0;
    for (final m in outline.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += dash + gap) {
        canvas.drawPath(m.extractPath(d, d + dash), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) => old.color != color || old.radius != radius;
}
