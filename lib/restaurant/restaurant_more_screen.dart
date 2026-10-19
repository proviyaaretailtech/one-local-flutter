import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_nav.dart';
import '../home/home_widgets.dart';
import '../ui/theme.dart';

/// Figma section D "restraunt side nav bar" (45:7539): the restaurant's More page, opened from ☰ and
/// from "Show all" on the dashboard. Outlet card, 16 quick links, Logout.
/// A link whose screen is not built (its HomeNav hook unplugged) shows a "Soon" tag and does nothing,
/// instead of looking live and answering with a toast (control rule).
class RestaurantMoreScreen extends StatelessWidget {
  const RestaurantMoreScreen({super.key, required this.outletName, this.outletLine, required this.onLogout});
  final String outletName;
  final String? outletLine;
  final VoidCallback onLogout;

  static Route<void> route({required String outletName, String? outletLine, required VoidCallback onLogout}) =>
      MaterialPageRoute(builder: (_) => RestaurantMoreScreen(outletName: outletName, outletLine: outletLine, onLogout: onLogout));

  @override
  Widget build(BuildContext context) {
    // (icon, label, hook). The hooks are the same ones the rest of the app plugs in app_routes.dart.
    // A Money link opens that Money screen; no hook plugged = "Soon".
    HomeRoute? moneyAt(String screen) => HomeNav.moneyScreen == null ? null : (c) => HomeNav.moneyScreen!(c, screen);
    final settings = HomeNav.settings ?? HomeNav.setup;
    final links = <(IconData, String, HomeRoute?)>[
      (LucideIcons.clock, 'Outlet timings', settings),
      (LucideIcons.info, 'Outlet info', HomeNav.setup),
      (LucideIcons.phone, 'Phone numbers', settings),
      (LucideIcons.users, 'Manage staff', HomeNav.team),
      (LucideIcons.star, 'Feedback', HomeNav.reviews),
      (LucideIcons.user, 'OneLocal manager', HomeNav.storefront),
      (LucideIcons.house, 'Delivery settings', HomeNav.deliverySettings),
      (LucideIcons.fileText, 'Order history', HomeNav.orderHistory ?? HomeNav.orders),
      (LucideIcons.chefHat, 'Kitchen display', HomeNav.kitchen), // KDS; replaces "Share feedback" (founder, 2026-10-20)
      (LucideIcons.creditCard, 'Payout', moneyAt('payouts')),
      (LucideIcons.circleQuestionMark, 'Customer support', HomeNav.support),
      (LucideIcons.bell, 'Notifications', HomeNav.notifications),
      (LucideIcons.file, 'Invoices', moneyAt('invoices')),
      // No tax screen exists yet (Money has no GST view): stays "Soon".
      (LucideIcons.chartPie, 'Taxes', null),
      (LucideIcons.coffee, 'Menu', HomeNav.items),
      // Fees and charges are the commission lines of each settlement.
      (LucideIcons.list, 'Fees & charges', moneyAt('settlements')),
    ];
    final initial = outletName.trim().isEmpty ? 'O' : outletName.trim()[0].toUpperCase();
    return Scaffold(
      key: const ValueKey('restaurant-more'),
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        leading: _Circle(icon: LucideIcons.chevronLeft, label: 'Back', onTap: () => Navigator.maybePop(context)),
        title: Text('More', style: inter(18, 700)),
        actions: [_Circle(icon: LucideIcons.user, label: 'Account', onTap: null), const SizedBox(width: 12)],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            // Outlet card.
            Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: HomeNav.setup == null ? null : () => HomeNav.setup!(context),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
                  child: Row(children: [
                    Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: const Color(0xFFFFE4DC), borderRadius: BorderRadius.circular(10)),
                      child: Text(initial, style: inter(18, 700, color: const Color(0xFFEF5A3C))),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(outletName, style: inter(15, 700), maxLines: 1, overflow: TextOverflow.ellipsis),
                        if (outletLine != null && outletLine!.isNotEmpty) Text(outletLine!, style: inter(12, 400, color: kMuted)),
                      ]),
                    ),
                    const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 22),
            Text('Quick links', style: inter(16, 700)),
            const SizedBox(height: 14),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 4,
              mainAxisSpacing: 14,
              crossAxisSpacing: 8,
              childAspectRatio: 0.72,
              children: [for (final (icon, label, hook) in links) _QuickLink(icon: icon, label: label, open: hook == null ? null : () => hook(context))],
            ),
            const SizedBox(height: 28),
            OutlinedButton.icon(
              key: const ValueKey('restaurant-logout'),
              onPressed: onLogout,
              icon: const Icon(LucideIcons.power, size: 18, color: kRed),
              label: Text('Logout', style: inter(14, 600, color: kRed)),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                side: const BorderSide(color: kRed),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                backgroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Circle extends StatelessWidget {
  const _Circle({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Center(
        child: Semantics(
          button: true,
          label: label,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(color: kBg, shape: BoxShape.circle),
              child: Icon(icon, size: 18, color: kInk),
            ),
          ),
        ),
      );
}

class _QuickLink extends StatelessWidget {
  const _QuickLink({required this.icon, required this.label, required this.open});
  final IconData icon;
  final String label;
  final VoidCallback? open;
  @override
  Widget build(BuildContext context) {
    final soon = open == null;
    return Semantics(
      button: true,
      enabled: !soon,
      label: soon ? '$label, coming soon' : label,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: open,
        child: Column(children: [
          Stack(clipBehavior: Clip.none, children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: kLine)),
              child: Icon(icon, size: 22, color: soon ? kMuted : kInk),
            ),
            if (soon)
              Positioned(
                right: -6,
                top: -6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: const Color(0xFFFEF0C7), borderRadius: BorderRadius.circular(8)),
                  child: Text('Soon', style: inter(8, 700, color: const Color(0xFFB54708))),
                ),
              ),
          ]),
          const SizedBox(height: 6),
          Text(label, style: inter(11, 500, color: soon ? kMuted : kInk), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }
}
