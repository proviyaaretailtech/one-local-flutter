import 'package:flutter/material.dart';

import 'auth/auth_repository.dart';
import 'auth/partner_api.dart';
import 'backoffice/low_stock_screen.dart';
import 'home/control_centre_screen.dart';
import 'home/home_nav.dart';
import 'orders/cart_screen.dart';
import 'orders/orders_home.dart';
import 'setup/setup_api.dart';
import 'setup/setup_flow.dart';

/// Connects the sections to each other. Each section only knows its own screens; this file plugs
/// workspace setup (C), the control centre (D), orders (E) and low stock (J) into the [HomeNav] hooks.
void installRoutes() {
  HomeNav.home = (c) => Navigator.of(c).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const ControlCentreScreen()), (r) => r.isFirst);
  HomeNav.orders = HomeNav.orderHistory = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => OrdersHome(onNavigate: (id) => _tab(c, id))));
  HomeNav.bill = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => CartScreen(onNavigate: (id) => _tab(c, id))));
  HomeNav.lowStock = (c) => Navigator.of(c).push(MaterialPageRoute(
      builder: (_) => LowStockScreen(onNavigate: (id) => _tab(c, id), onItems: () => HomeNav.go(c, HomeNav.items, 'Items'), onViewItem: HomeNav.stockItem)));
  HomeNav.setup = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => SetupEntry(onFinished: (ctx) => HomeNav.home!(ctx))));
}

/// Bottom-bar tabs of the order screens that belong to other sections.
void _tab(BuildContext context, String id) => switch (id) {
      'money' => HomeNav.go(context, HomeNav.money, 'Money'),
      'item' => HomeNav.go(context, HomeNav.items, 'Items'),
      'bill' => HomeNav.go(context, HomeNav.bill, 'Bill'),
      'stock' => HomeNav.go(context, HomeNav.stock, 'Stock'),
      _ => HomeNav.go(context, null, 'Online orders'),
    };

/// "Continue to store": an owner or admin whose workspace setup is not finished goes to setup first
/// (Figma: finish setup before using the merchant tools); everyone else goes to the control centre.
/// The server decides who may run setup; a refusal (staff, not yet approved) means "go to the control centre".
Future<void> openWorkspace(BuildContext context, {AuthRepository? auth, SetupApi? setupApi}) async {
  bool needsSetup = false;
  try {
    needsSetup = !(await (setupApi ?? SetupApi()).get()).completed;
  } on PartnerApiException {
    needsSetup = false;
  } catch (_) {
    needsSetup = false; // offline: the control centre shows its own retry
  }
  if (!context.mounted) return;
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => needsSetup ? SetupEntry(api: setupApi, onFinished: (ctx) => HomeNav.home!(ctx)) : ControlCentreScreen(auth: auth),
  ));
}
