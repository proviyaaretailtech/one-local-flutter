import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../ui/theme.dart';

/// Veg / non-veg / egg mark (the square-with-dot used on Indian menus).
class FoodTypeMark extends StatelessWidget {
  const FoodTypeMark(this.type, {super.key});
  final String type;
  @override
  Widget build(BuildContext context) {
    final c = switch (type) { 'non_veg' => const Color(0xFFB42318), 'egg' => const Color(0xFFDC8A00), _ => const Color(0xFF12B76A) };
    return Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(border: Border.all(color: c, width: 1.4), borderRadius: BorderRadius.circular(3)),
      child: Container(width: 6, height: 6, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
    );
  }
}

/// A dish photo, or a quiet placeholder when there is none (or it fails to load).
class DishPhoto extends StatelessWidget {
  const DishPhoto({super.key, required this.urls, this.height = 96, this.width});
  final List<String> urls;
  final double height;
  final double? width;
  @override
  Widget build(BuildContext context) {
    final ph = Container(
      height: height,
      width: width,
      decoration: BoxDecoration(color: const Color(0xFFF1F1EC), borderRadius: BorderRadius.circular(14)),
      child: Icon(LucideIcons.utensils, color: kMuted, size: height > 100 ? 40 : 24),
    );
    if (urls.isEmpty) return ph;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Image.network(urls.first, height: height, width: width ?? double.infinity, fit: BoxFit.cover, errorBuilder: (_, _, _) => ph),
    );
  }
}

class SlotTile extends StatelessWidget {
  const SlotTile({super.key, required this.title, required this.subtitle, required this.selected, this.onTap});
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? kNote : Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: selected ? kLink : kFieldBorder, width: selected ? 1.6 : 1),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(title, style: inter(14, selected ? 700 : 500, color: selected ? const Color(0xFF2E8B00) : kInk)),
              Text(subtitle, style: inter(11, 400, color: kMuted)),
            ]),
          ),
        ),
      );
}

/// "Apply to Channels" from the Figma frame, shown greyed with a Coming soon tag. The switches do nothing and send nothing.
class ChannelsComingSoon extends StatelessWidget {
  const ChannelsComingSoon({super.key});
  static const channels = ['All Channels', 'Zomato only', 'Swiggy only', 'Dine-in QR'];
  @override
  Widget build(BuildContext context) => Opacity(
        key: const ValueKey('channels-coming-soon'),
        opacity: 0.5,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text('Apply to Channels', style: inter(16, 700)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: const Color(0xFFE5E7EB), borderRadius: BorderRadius.circular(20)),
              child: Text('Coming soon', style: inter(11, 600, color: kMuted)),
            ),
          ]),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
            child: Column(children: [
              for (final c in channels)
                ListTile(
                  dense: true,
                  enabled: false,
                  title: Text(c, style: inter(14, 500)),
                  trailing: Switch(value: false, onChanged: null, key: ValueKey('channel-$c')),
                ),
            ]),
          ),
        ]),
      );
}

class MenuError extends StatelessWidget {
  const MenuError({super.key, required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(kPadX),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(error is PartnerApiException ? (error as PartnerApiException).message : 'Could not load the menu.', textAlign: TextAlign.center, style: inter(14, 500)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: Text('Try again', style: inter(14, 600))),
          ]),
        ),
      );
}

/// `Edit menu for <outlet> ▾`. Kept small and separate so the shared outlet header (outlets-multi branch) can replace it on merge.
/// The menu is business-wide; the outlet only decides whose clock "orderable now" uses.
class MenuOutletPicker extends StatelessWidget {
  const MenuOutletPicker({super.key, required this.name, required this.outlets, required this.selectedId, required this.onPicked});
  final String name;
  final List<Map<String, dynamic>> outlets;
  final String? selectedId;
  final ValueChanged<String> onPicked;

  Future<void> _open(BuildContext context) async {
    if (outlets.length < 2) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(kPadX, 20, kPadX, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Edit menu for', style: inter(15, 600)),
            Text('The menu is the same at every outlet; the outlet sets the clock for serving times.', style: inter(12, 400, color: kMuted)),
            const SizedBox(height: 8),
            for (final o in outlets)
              ListTile(
                title: Text('${o['name']}', style: inter(14, 500)),
                trailing: o['id'] == selectedId ? const Icon(LucideIcons.check, color: kLink) : null,
                onTap: () => Navigator.pop(ctx, '${o['id']}'),
              ),
          ]),
        ),
      ),
    );
    if (picked != null) onPicked(picked);
  }

  @override
  Widget build(BuildContext context) => InkWell(
        key: const ValueKey('menu-outlet'),
        onTap: () => _open(context),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('EDIT MENU FOR', style: inter(11, 600, color: kMuted)),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: Text(name, overflow: TextOverflow.ellipsis, style: inter(18, 700))),
            if (outlets.length > 1) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(LucideIcons.chevronDown, size: 18, color: kInk)),
          ]),
        ]),
      );
}

/// How many of a dish the kitchen can still make, from its recipe and the ingredients in stock (0605: menu_can_make):
/// "200 can be made" (red at 0, orange under 10); "Stock not counted" when the recipe's ingredients were never stocked; "No recipe yet".
class CanMakeLabel extends StatelessWidget {
  const CanMakeLabel({super.key, required this.hasRecipe, required this.count, this.size = 12.5});
  final bool hasRecipe;
  final int? count;
  final double size;
  @override
  Widget build(BuildContext context) {
    final n = count;
    final (text, color) = !hasRecipe
        ? ('No recipe yet', kMuted)
        : n == null
            ? ('Stock not counted', kMuted)
            : ('$n can be made', n == 0 ? const Color(0xFFB42318) : n < 10 ? const Color(0xFFC2410C) : const Color(0xFF2E7D32));
    return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(size, 600, color: color));
  }
}
