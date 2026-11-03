import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_nav.dart';
import '../home/home_widgets.dart' show BarTab;
import '../home/side_nav.dart';
import 'manage_screen.dart';
import 'bookings_screen.dart';
import 'catalogue_screen.dart';
import 'bills_screen.dart';
import 'service_api.dart';
import 'service_media.dart';
import 'service_money.dart';

// The Service POS frame (founder's sketch, 2 Nov 2026), common to every kind of service: the bottom bar and the side menu. It looks like
// the store POS (same floating bar and side nav); only the tabs and rows are the service's own.

/// The service bottom bar: Home · Service catalogue · Bill (the centre action) · Bookings, then Ol, the guide, in the last slot (founder,
/// 3 Nov 2026; Service management moved to the side menu and to Ol).
const kServiceTabs = [
  BarTab('Home', LucideIcons.house),
  BarTab('Catalogue', LucideIcons.layoutList),
  BarTab('Bill', LucideIcons.receiptText, hero: true),
  BarTab('Bookings', LucideIcons.calendarDays),
];

/// The first screen of a service bar tab. [home] is the shared dashboard; [onNavigate] switches tabs for screens that ask to.
/// Catalogue, Bill and Bookings are the rebuilt screens (2 Nov 2026).
Widget? serviceTabRoot(String label, {required Widget home, required ValueChanged<String> onNavigate, ServiceApi? api}) {
  final a = api ?? ServiceApi();
  return switch (label) {
    'Home' => home,
    'Catalogue' => ServiceCatalogueScreen(api: a, onNavigate: onNavigate),
    'Bill' => BillsScreen(api: a, onNavigate: onNavigate),
    'Bookings' => BookingsScreen(api: a, onNavigate: onNavigate),
    _ => null,
  };
}

/// The bar tab an older service screen means when it asks to go somewhere ('home', 'item', 'bill' from the store's bar ids).
String? serviceTabFor(String id) => switch (id) {
      'home' => 'Home',
      'item' || 'catalogue' => 'Catalogue',
      'bill' || 'calendar' || 'bookings' => 'Bookings', // a service's old Bill tab was its calendar
      _ => null,
    };

/// The service side menu (founder's sketch): Profile & manage account (the top of the menu), Service management, Money, Media, Company
/// details, Team management, Support, Sign out. Same look as the store's side nav.
Future<void> showServiceSideNav(BuildContext context, {required String name, String? email, required VoidCallback onSignOut}) {
  VoidCallback? hook(HomeRoute? r) => r == null ? null : () => r(context);
  return showSideNav(
    context,
    name: name,
    email: email,
    entries: [
      // Service management (founder, 3 Nov 2026): off the bottom bar, where Ol now sits; hours, slots and who works when
      SideNavEntry(LucideIcons.slidersHorizontal, 'Service management', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ManageScreen(api: ServiceApi())))),
      // Money, as in the store's side nav (founder, 2 Nov 2026): the service's own wallet, money from services, cash drawer and dues
      SideNavEntry(LucideIcons.wallet, 'Money', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ServiceMoneyScreen()))),
      // Media, as the store's Media manager (2 Nov 2026): the business's service photos and standard media
      SideNavEntry(LucideIcons.images, 'Media', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ServiceMediaScreen()))),
      SideNavEntry(LucideIcons.building2, 'Company details', hook(HomeNav.outletInfo)),
      SideNavEntry(LucideIcons.users, 'Team management', hook(HomeNav.team)),
      SideNavEntry(LucideIcons.circleQuestionMark, 'Support', hook(HomeNav.support)),
    ],
    onSignOut: onSignOut,
  );
}
