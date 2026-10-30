import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/i18n.dart';
import '../ui/theme.dart';

// MRP-based or store-based pricing (founder, 31 Oct 2026): everywhere a product's price is set, the shopkeeper first says which it is.
//   MRP-based   packed goods with a printed MRP. The MRP can always be edited; the selling price starts at the MRP and may be lower,
//               never higher.
//   Store-based the store's own price (loose, homemade, local goods), no printed MRP: type the selling price, or cost + markup %, with
//               the margin shown. The database keeps that price as the MRP too, so everything that needs an MRP (stock, labels) has one.

enum PriceBasis { mrp, store }

const _measured = {'kg', 'g', 'l', 'ml'};

/// The item's saved basis; for an item saved before there was one, a guess: sold by weight or volume is store-based, the rest MRP-based.
PriceBasis priceBasisOf(Object? saved, {String unit = 'pc'}) => switch (saved) {
      'mrp' => PriceBasis.mrp,
      'store' => PriceBasis.store,
      _ => _measured.contains(unit) ? PriceBasis.store : PriceBasis.mrp,
    };

/// The basis a newly chosen selling unit suggests (until the person picks one themselves).
PriceBasis basisForUnit(String unit) => _measured.contains(unit) ? PriceBasis.store : PriceBasis.mrp;

/// Markup on cost, in % (25 for cost ₹40, price ₹50); null without a cost.
double? markupPct(num? cost, num? price) => cost == null || price == null || cost <= 0 ? null : (price - cost) / cost * 100;

/// The selling price from cost + markup %, to the paisa.
num priceFromMarkup(num cost, num pct) => (cost * (1 + pct / 100) * 100).round() / 100;

/// "25" or "12.5": a markup as typed.
String pctText(num v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

/// The two choices, side by side: MRP-based (printed MRP) and Store-based (own price). Keys `<keyPrefix>-mrp` / `<keyPrefix>-store`.
class PriceBasisPicker extends StatelessWidget {
  const PriceBasisPicker({super.key, required this.value, required this.onChanged, this.keyPrefix = 'price-basis', this.compact = false});
  final PriceBasis value;
  final ValueChanged<PriceBasis>? onChanged;
  final String keyPrefix;

  /// Two small chips (inside a list row) instead of two cards.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    Widget option(PriceBasis b, String title, String line, IconData icon) {
      final on = value == b;
      if (compact) {
        return Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ChoiceChip(
            key: ValueKey('$keyPrefix-${b.name}'),
            label: Text(tr(title), style: inter(12, on ? 700 : 500)),
            selected: on,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            selectedColor: const Color(0xFFD2F64B),
            backgroundColor: Colors.white,
            side: BorderSide(color: on ? const Color(0xFFB9E33A) : const Color(0xFFE2E4DE)),
            onSelected: onChanged == null ? null : (_) => onChanged!(b),
          ),
        );
      }
      return Expanded(
        child: Material(
          color: on ? const Color(0xFFF1FAE8) : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: on ? const Color(0xFF6CC72B) : const Color(0xFFE2E4DE), width: on ? 1.6 : 1),
          ),
          child: InkWell(
            key: ValueKey('$keyPrefix-${b.name}'),
            borderRadius: BorderRadius.circular(14),
            onTap: onChanged == null ? null : () => onChanged!(b),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(icon, size: 16, color: on ? const Color(0xFF2F8A0B) : kMuted),
                  const SizedBox(width: 6),
                  Expanded(child: Text(tr(title), style: inter(13.5, 800, color: on ? kInk : kMuted))),
                  Icon(on ? LucideIcons.circleCheck : LucideIcons.circle, size: 16, color: on ? const Color(0xFF2F8A0B) : const Color(0xFFC9CCC4)),
                ]),
                const SizedBox(height: 3),
                Text(tr(line), style: inter(11.5, 500, color: kMuted, height: 1.3)),
              ]),
            ),
          ),
        ),
      );
    }

    final mrp = option(PriceBasis.mrp, 'MRP-based', 'Packed goods with a printed MRP', LucideIcons.tag);
    final store = option(PriceBasis.store, 'Store-based', 'Your own price: loose, homemade, local', LucideIcons.store);
    return compact ? Row(mainAxisSize: MainAxisSize.min, children: [mrp, store]) : Row(children: [mrp, const SizedBox(width: 8), store]);
  }
}
