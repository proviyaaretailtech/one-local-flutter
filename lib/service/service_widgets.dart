import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../ui/theme.dart';

/// Top of every Service POS screen (Figma section I): menu button, OneLocal wordmark, initials avatar, then "Service" and "Business · City".
class ServiceTopBar extends StatelessWidget {
  const ServiceTopBar({super.key, this.business = '', this.onMenu, this.onBack, this.initials});
  final String business;
  final VoidCallback? onMenu, onBack;
  final String? initials;
  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: kLine))),
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Row(children: [
              Semantics(
                button: true,
                label: onBack != null ? 'Back' : 'Menu',
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onBack ?? onMenu,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: kBg, shape: BoxShape.circle, border: Border.all(color: kLine)),
                    child: Icon(onBack != null ? LucideIcons.chevronLeft : LucideIcons.menu, size: 20, color: kInk),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const BrandLogo(),
              const Spacer(),
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: kCheck, borderRadius: BorderRadius.circular(12)),
                child: initials == null || initials!.isEmpty ? const Icon(LucideIcons.user, size: 18, color: kInk) : Text(initials!, style: inter(15, 700)),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 24, 10),
            child: Row(children: [
              Text('Service', style: inter(15, 600, color: kLink)),
              const SizedBox(width: 12),
              Expanded(child: Text(business, textAlign: TextAlign.right, overflow: TextOverflow.ellipsis, style: inter(13, 400, color: kMuted))),
            ]),
          ),
        ]),
      );
}

/// Status pill of an appointment: green Confirmed / Completed, amber Deposit pending, red Cancelled / No-show, grey otherwise.
class ApptStatusChip extends StatelessWidget {
  const ApptStatusChip({super.key, required this.label, required this.tone});
  final String label, tone;
  @override
  Widget build(BuildContext context) {
    final (bg, fg, dot) = switch (tone) {
      'good' => (kChipGreen, kGreenText, kLink),
      'warn' => (const Color(0xFFFFF9E3), const Color(0xFFA23F00), const Color(0xFFF59E0B)),
      'bad' => (kBadBg, kBadText, kBadText),
      _ => (kInfoGreyBg, kInk, kMuted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text(label, style: inter(13, 600, color: fg)),
      ]),
    );
  }
}

/// Rounded filter chip (Day / Week / All providers).
class ModeChip extends StatelessWidget {
  const ModeChip(this.label, {super.key, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? kChipGreen : Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: selected ? kLink : kLine),
            ),
            child: ExcludeSemantics(child: Text(label, style: inter(14, selected ? 600 : 400, color: selected ? kInk : kMuted))),
          ),
        ),
      );
}
