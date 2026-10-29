import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_nav.dart';
import '../home/side_nav.dart';
import 'rst_page_manager.dart';
import 'rst_plans_screen.dart';

/// The restaurant's side menu (Figma section D "restraunt side nav bar" 45:7539). Since 29 Oct 2026 it is the store's side bar: it slides
/// in from the left with the profile, Search the app, the links and Sign out; ☰ and "Show all" on the dashboard open it.
/// A link whose screen is not built (its HomeNav hook unplugged) shows a "Soon" tag and does nothing,
/// instead of looking live and answering with a toast (control rule).
class RestaurantMoreScreen {
  const RestaurantMoreScreen._();

  /// The restaurant's links, in order: the store's ten (founder, 29 Oct 2026: "keep these options, remove the others"). The rest live
  /// elsewhere: KDS and KOT on Orders, table QR codes in the floor's ⋮, timings and phone numbers in Settings, payouts and invoices in
  /// Money, notifications on the bell. The hooks are the ones app_routes.dart plugs; no hook plugged = "Soon".
  /// [reopen] opens the side bar again with Inventory unfolded: Back from an Inventory page lands there, not on the dashboard
  /// (founder, 29 Oct 2026).
  static List<SideNavEntry> links(BuildContext context, {VoidCallback? onReports, VoidCallback? reopen, VoidCallback? reopenPlain}) {
    // every page opened from the side bar comes back to it on Back (founder, 29 Oct 2026: "yes, all of them")
    VoidCallback? back(VoidCallback? go) => go == null
        ? null
        : () {
            go();
            if (reopenPlain != null) whenUncovered(context, reopenPlain);
          };
    VoidCallback? open(HomeRoute? r) => r == null ? null : back(() => r(context));
    final settings = HomeNav.settings ?? HomeNav.setup;
    return [
      SideNavEntry(LucideIcons.qrCode, 'All Orders', open(HomeNav.orderHistory ?? HomeNav.orders)),
      SideNavEntry(LucideIcons.indianRupee, 'Money', open(HomeNav.money)),
      // Inventory folds open (founder, 29 Oct 2026); each row opens its page
      SideNavEntry(LucideIcons.package, 'Inventory', null, children: [
        for (final (icon, label, page) in const [
          (LucideIcons.truck, 'Purchase', 'purchase'),
          (LucideIcons.table, 'Price control', 'prices'),
          (LucideIcons.clipboardCheck, 'Closing stock check', 'closing'),
          (LucideIcons.chefHat, 'Recipe', 'recipes'),
          (LucideIcons.carrot, 'Ingredients', 'ingredients'),
          (LucideIcons.layoutGrid, 'Table management', 'tables'),
        ])
          SideNavEntry(
            icon,
            label,
            HomeNav.inventory == null
                ? null
                : () async {
                    final cameBack = await HomeNav.inventory!(context, page);
                    if (cameBack && context.mounted) reopen?.call();
                  },
          ),
      ]),
      // the restaurant's OneLocal page: readiness, ads and offers, profile, hours, delivery, link and reviews (founder, 29 Oct 2026)
      SideNavEntry(LucideIcons.layoutTemplate, 'Page Manager', back(() => Navigator.of(context).push(RstPageManagerScreen.route()))),
      SideNavEntry(LucideIcons.circleUser, 'Customer', open(HomeNav.customers)),
      // the outlet's name, address and contact (Settings → Outlet info)
      SideNavEntry(LucideIcons.store, 'Business profile', open(HomeNav.outletInfo ?? settings)),
      SideNavEntry(LucideIcons.fileText, 'Reports', back(onReports)),
      SideNavEntry(LucideIcons.users, 'Team', open(HomeNav.team)),
      SideNavEntry(LucideIcons.settings, 'Settings', open(settings)),
      SideNavEntry(LucideIcons.wallet, 'One Local Wallet', open(HomeNav.wallet)),
      SideNavEntry(LucideIcons.circleQuestionMark, 'Help & support', open(HomeNav.support)),
      // the same prices as the store: ₹599 / ₹799 a month, 6 or 12 months (2 free)
      SideNavEntry(LucideIcons.crown, 'Subscription plans', back(() => Navigator.of(context).push(RstPlansScreen.route()))),
    ];
  }

  /// Calls [then] once a page opened on top of [context]'s page is closed again. Watches that page's secondary animation: it runs forward
  /// when a page covers it and back to the start when that page is popped. A link that only switched a tab covers nothing; the watch then
  /// stops once the next frames are drawn.
  static void whenUncovered(BuildContext context, VoidCallback then) {
    final anim = ModalRoute.of(context)?.secondaryAnimation;
    if (anim == null) return;
    var covered = anim.status != AnimationStatus.dismissed;
    var done = false;
    late final AnimationStatusListener listen;
    void stop() {
      if (done) return;
      done = true;
      anim.removeStatusListener(listen);
    }

    listen = (status) {
      if (status == AnimationStatus.forward || status == AnimationStatus.completed) covered = true;
      if (status == AnimationStatus.dismissed && covered) {
        stop();
        if (context.mounted) then();
      }
    };
    anim.addStatusListener(listen);
    // a link that only switched a tab covers nothing: stop watching once the frames after the tap are drawn
    WidgetsBinding.instance.addPostFrameCallback((_) => WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!covered) stop();
        }));
  }

  /// Opens the side bar: the person (Manage account), the outlet under them, Search the app, the links, Sign out.
  /// [openGroups]: folding rows open from the start (Inventory, when coming back from one of its pages).
  static Future<void> open(BuildContext context,
      {required String name, String? email, required String outletName, required VoidCallback onLogout, VoidCallback? onReports, Set<String> openGroups = const {}}) {
    void reopen() => open(context, name: name, email: email, outletName: outletName, onLogout: onLogout, onReports: onReports, openGroups: const {'Inventory'});
    void reopenPlain() => open(context, name: name, email: email, outletName: outletName, onLogout: onLogout, onReports: onReports);
    return showSideNav(context,
        name: name,
        email: email,
        line: outletName,
        entries: links(context, onReports: onReports, reopen: reopen, reopenPlain: reopenPlain),
        onReports: onReports,
        onSignOut: onLogout,
        openGroups: openGroups);
  }
}
