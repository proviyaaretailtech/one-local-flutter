import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart';
import '../sell/sell_widgets.dart';
import '../ui/theme.dart';
import 'shift_api.dart';

/// Founder Correct Flow S6.5 "Refund not allowed": says why a refund or a return cannot be given on this bill, in the database's words
/// (above what was paid, outside the return days, needs a manager, not paid in full ...), with the figures it used. Nothing is changed.
class RefundBlockedScreen extends StatelessWidget {
  const RefundBlockedScreen({super.key, required this.check, this.initials = 'RP'});
  final RefundCheck check;
  final String initials;

  static const _icons = {
    'over_paid': LucideIcons.circleDollarSign,
    'outside_return_days': LucideIcons.calendarX,
    'needs_manager': LucideIcons.userLock,
    'not_paid_in_full': LucideIcons.wallet,
    'online_order': LucideIcons.globe,
    'cancelled': LucideIcons.ban,
    'nothing_taken': LucideIcons.wallet,
  };

  @override
  Widget build(BuildContext context) {
    final c = check;
    final what = c.purpose == 'return' ? 'Return' : 'Refund';
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        SellTopBar(onBack: () => Navigator.maybePop(context), initials: initials),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(24, 24, 24, 16), children: [
            OrderCardBox(
              radius: 30,
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              child: Column(children: [
                Container(width: 72, height: 72, decoration: const BoxDecoration(color: kBadBg, shape: BoxShape.circle), child: const Icon(LucideIcons.circleSlash, size: 30, color: kBadText)),
                const SizedBox(height: 16),
                Text('$what not allowed', textAlign: TextAlign.center, style: inter(24, 800, color: kBadText)),
                const SizedBox(height: 4),
                Text('Bill ${c.displayNo}', textAlign: TextAlign.center, style: inter(13.5, 400, color: kMuted)),
                const Divider(height: 28, color: kLine),
                for (final (code, message) in c.reasons)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: const BoxDecoration(color: kBadBg, shape: BoxShape.circle),
                        child: Icon(_icons[code] ?? LucideIcons.info, size: 17, color: kBadText),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(message, style: inter(14, 500, height: 1.4))),
                    ]),
                  ),
                const Divider(height: 16, color: kLine),
                KeyValue('Bill total', rupees(c.total), size: 14),
                KeyValue('Paid', rupees(c.taken), size: 14),
                if (c.refunded > 0) KeyValue('Already refunded', '−${rupees(c.refunded)}', size: 14, valueColor: kBadText),
                KeyValue('Can still be refunded', rupees(c.refundableLeft), size: 14),
                if (c.purpose == 'return') KeyValue('Return window', '${c.returnDays} days · paid ${c.daysSincePaid} ${c.daysSincePaid == 1 ? 'day' : 'days'} ago', size: 14),
                const SizedBox(height: 18),
                DarkCta(label: 'Back to the bill', onPressed: () => Navigator.maybePop(context)),
                if (c.reasons.any((r) => r.$1 == 'needs_manager')) ...[
                  const SizedBox(height: 12),
                  Text('A manager can sign in on this phone, or give the refund from their own.', textAlign: TextAlign.center, style: inter(12.5, 400, color: kKicker)),
                ],
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}
