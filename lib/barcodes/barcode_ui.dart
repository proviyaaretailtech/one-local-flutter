import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/app_header.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'barcodes_api.dart';

// The look of the Barcodes section (founder's mock-ups, 30 Oct 2026): a big page title under the banner, white cards with soft borders,
// lime buttons with dark text, small green tags.

const kBcLime = Color(0xFFB9F04F);
const kBcDeep = Color(0xFF1F6F3A);
const kBcMint = Color(0xFFEEF6E6);
const kBcBorder = Color(0xFFE6E9E1);

/// One page of the section: the banner, the page's title and line, its content, and a button pinned at the bottom.
class BcPage extends StatelessWidget {
  const BcPage({super.key, required this.title, this.subtitle, required this.children, this.bottom, this.trailing, this.scroll = true});
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final Widget? bottom, trailing;
  final bool scroll;

  @override
  Widget build(BuildContext context) {
    final head = [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr(title), style: inter(24, 800, height: 1.15)),
            if (subtitle != null) ...[const SizedBox(height: 6), Text(tr(subtitle!), style: inter(13, 500, color: kMuted, height: 1.4))],
          ]),
        ),
        ?trailing,
      ]),
      const SizedBox(height: 18),
    ];
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(title: tr('Barcodes'), back: true),
        Expanded(
          child: scroll
              ? ListView(padding: const EdgeInsets.fromLTRB(16, 6, 16, 20), children: [...head, ...children])
              : Padding(padding: const EdgeInsets.fromLTRB(16, 6, 16, 0), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...head, ...children])),
        ),
        if (bottom != null) SafeArea(top: false, child: Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 12), child: bottom)),
      ]),
    );
  }
}

/// A white card with a soft border.
class BcCard extends StatelessWidget {
  const BcCard({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.color = Colors.white, this.onTap, this.border});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  final VoidCallback? onTap;
  final Color? border;
  @override
  Widget build(BuildContext context) => Material(
        color: color,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: border ?? kBcBorder)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
      );
}

/// The section's main button: lime with dark text.
class BcCta extends StatelessWidget {
  const BcCta({super.key, required this.label, required this.onPressed, this.busy = false, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 52,
        width: double.infinity,
        child: FilledButton(
          onPressed: busy ? null : onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: kBcLime,
            foregroundColor: kInk,
            disabledBackgroundColor: kBcLime.withValues(alpha: 0.45),
            disabledForegroundColor: kInk.withValues(alpha: 0.45),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 0,
          ),
          child: busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: kInk))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
                  Text(tr(label), style: inter(15, 800)),
                ]),
        ),
      );
}

/// The quieter button: white with a green outline.
class BcOutline extends StatelessWidget {
  const BcOutline({super.key, required this.label, required this.onPressed, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 52,
        width: double.infinity,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: kBcDeep,
            side: const BorderSide(color: kBcDeep, width: 1.2),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
            Text(tr(label), style: inter(15, 800, color: kBcDeep)),
          ]),
        ),
      );
}

/// The product's photo in a rounded square (a package when it has none).
class BcThumb extends StatelessWidget {
  const BcThumb(this.url, {super.key, this.size = 48});
  final String? url;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: const Color(0xFFF3F4EF), borderRadius: BorderRadius.circular(size * 0.25)),
        clipBehavior: Clip.antiAlias,
        child: url == null || url!.isEmpty
            ? Icon(LucideIcons.package, size: size * 0.45, color: kMuted)
            : Image.network(url!, fit: BoxFit.cover, errorBuilder: (_, _, _) => Icon(LucideIcons.package, size: size * 0.45, color: kMuted)),
      );
}

/// A small rounded tag.
class BcTag extends StatelessWidget {
  const BcTag(this.text, {super.key, this.bg = kBcMint, this.fg = kBcDeep});
  final String text;
  final Color bg, fg;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
        child: Text(tr(text), style: inter(11, 700, color: fg)),
      );
}

/// Where the item's code came from, as a tag.
String sourceLabel(BcItem i) => i.barcode == null
    ? 'No barcode'
    : switch (i.barcodeSource) {
        'generated' => 'Generated',
        'linked' => 'Linked',
        'custom' => 'Custom',
        _ => 'Product',
      };

Widget sourceTag(BcItem i) => i.barcode == null ? const BcTag('No barcode', bg: Color(0xFFFFF4E5), fg: Color(0xFFB45309)) : BcTag(sourceLabel(i));
Widget unitTag(BcItem i) => BcTag(i.loose ? 'Loose' : 'Piece', bg: const Color(0xFFF3F4EF), fg: kMuted);

/// "₹90/kg · Sold loose" or "₹28/pack".
String priceLine(BcItem i, String Function(num) money) => i.loose ? '${money(i.price)}/kg · ${tr('Sold loose')}' : '${money(i.price)}/${tr('pack')}';

/// How many labels to print (founder, 31 Oct 2026: not just one): − count +, 0 = none, up to 500. [keyPrefix]-less, -more, -value.
class LabelCountStepper extends StatelessWidget {
  const LabelCountStepper({super.key, required this.value, required this.onChanged, this.keyPrefix = 'labels', this.hint, this.enabled = true});
  final int value;
  final ValueChanged<int> onChanged;
  final String keyPrefix;
  final String? hint;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    Widget btn(String id, IconData icon, int to) => Material(
          color: Colors.white,
          shape: const CircleBorder(side: BorderSide(color: kBcBorder)),
          child: InkWell(
            key: ValueKey('$keyPrefix-$id'),
            customBorder: const CircleBorder(),
            onTap: enabled && to >= 0 && to <= 500 ? () => onChanged(to) : null,
            child: SizedBox(width: 40, height: 40, child: Icon(icon, size: 18, color: kInk)),
          ),
        );
    return Row(children: [
      const Icon(LucideIcons.printer, size: 18, color: kInk),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Labels to print'), style: inter(14, 700)),
          Text(tr(hint ?? (value == 0 ? 'No label will be printed.' : 'Printed when it is saved.')), style: inter(11.5, 500, color: kMuted)),
        ]),
      ),
      btn('less', LucideIcons.minus, value - 1),
      SizedBox(width: 44, child: Text('$value', key: ValueKey('$keyPrefix-value'), textAlign: TextAlign.center, style: inter(17, 800))),
      btn('more', LucideIcons.plus, value + 1),
    ]);
  }
}
