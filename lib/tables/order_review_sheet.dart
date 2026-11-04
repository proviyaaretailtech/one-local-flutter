import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';
import 'table_widgets.dart' show rupees, kLimeBtn, LimeButton, OutlineButtonT;

// The order read back before it goes to the kitchen (founder, 4 Nov 2026: "I want to see it before I send it to kitchen … to cross verify
// the items with the customer"): every dish with how many, its size, add-ons, note and whether it is takeaway, and the total. Send to
// kitchen sends it; Edit order goes back to the dishes with nothing sent.

/// One dish line as the guest ordered it.
class ReviewLine {
  const ReviewLine({required this.name, required this.qty, required this.price, this.size, this.extras = '', this.note, this.takeaway = false});
  final String name;
  final int qty;
  final num price; // one of it, with its size, add-ons and combos
  final String? size, note;
  final String extras; // the add-ons and combos chosen ("2 × Cheese slices · Fries & Coke (combo)")
  final bool takeaway;
}

/// Shows [lines] for [title] ("Table T3", "Takeaway"); true when Send to kitchen is tapped, false or null to go back and edit.
Future<bool> showOrderReview(BuildContext context, {required String title, required List<ReviewLine> lines}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => _Review(title: title, lines: lines),
    ) ==
    true;

class _Review extends StatelessWidget {
  const _Review({required this.title, required this.lines});
  final String title;
  final List<ReviewLine> lines;

  @override
  Widget build(BuildContext context) {
    final units = lines.fold<int>(0, (a, l) => a + l.qty);
    final total = lines.fold<num>(0, (a, l) => a + l.price * l.qty);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.88),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(4)))),
            const SizedBox(height: 14),
            Text('Check the order', key: const ValueKey('review-title'), style: inter(22, 800)),
            const SizedBox(height: 2),
            Text('$title · $units item${units == 1 ? '' : 's'}. Read it back to the guest before it goes to the kitchen.',
                key: const ValueKey('review-for'), style: inter(13.5, 500, color: kMuted)),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: lines.length,
                separatorBuilder: (_, _) => const Divider(height: 1, color: kLine),
                itemBuilder: (_, i) {
                  final l = lines[i];
                  final details = [
                    if (l.size != null && l.size!.isNotEmpty) l.size!,
                    if (l.extras.isNotEmpty) l.extras,
                    if (l.takeaway) 'Takeaway',
                  ];
                  return Padding(
                    key: ValueKey('review-line-$i'),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                        constraints: const BoxConstraints(minWidth: 34),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(color: const Color(0xFFEFFBE0), borderRadius: BorderRadius.circular(8), border: Border.all(color: kLimeBtn)),
                        child: Text('${l.qty}×', textAlign: TextAlign.center, style: inter(14, 800)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(l.name, style: inter(15, 700)),
                          if (details.isNotEmpty) Text(details.join(' · '), style: inter(12.5, 500, color: kMuted)),
                          if (l.note != null && l.note!.trim().isNotEmpty)
                            Text('Note: ${l.note!.trim()}', style: inter(12.5, 600, color: const Color(0xFFB45309))),
                        ]),
                      ),
                      const SizedBox(width: 8),
                      Text(rupees(l.price * l.qty), style: inter(14.5, 700)),
                    ]),
                  );
                },
              ),
            ),
            const Divider(height: 1, color: kLine),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(children: [
                Expanded(child: Text('Total', style: inter(15, 700))),
                Text(rupees(total), key: const ValueKey('review-total'), style: inter(20, 800, color: kLink)),
              ]),
            ),
            Row(children: [
              Expanded(
                child: OutlineButtonT('Edit order', key: const ValueKey('review-edit'), icon: LucideIcons.pencil, height: 48, onPressed: () => Navigator.of(context).pop(false)),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: LimeButton('Send to kitchen', key: const ValueKey('review-send'), icon: LucideIcons.send, height: 48, onPressed: () => Navigator.of(context).pop(true)),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
