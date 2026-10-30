import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/i18n.dart';
import 'home_nav.dart';

/// One place or action of the store app that the side menu's search can open: what it is called, where it lives, the words people
/// might type for it, and how to open it.
class AppAction {
  const AppAction(this.icon, this.title, this.where, this.words, this.open);
  final IconData icon;
  final String title, where, words;
  final VoidCallback open;

  /// Every typed word must appear in the title, the place or the words (any order, any case).
  bool matches(String query) {
    // the names in the app's language too, so Hindi and Hinglish words find them
    final hay = '$title $where $words ${tr(title)} ${tr(where)}'.toLowerCase();
    return query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(hay.contains);
  }

  /// Title matches first, then the rest, in list order.
  int rank(String query) {
    final q = query.toLowerCase().trim();
    return title.toLowerCase().contains(q) || tr(title).toLowerCase().contains(q) ? 0 : 1;
  }
}

/// Every action of the store app the side menu's search can open (founder, 26 Oct 2026: "any action in the application should be
/// searchable"). Built from the app's open-hooks; one that is not plugged in is left out. [onReports] opens Reports.
List<AppAction> appActions(BuildContext context, {VoidCallback? onReports}) {
  final list = <AppAction>[];
  void add(IconData icon, String title, String where, String words, VoidCallback? open) {
    if (open != null) list.add(AppAction(icon, title, where, words, open));
  }

  VoidCallback? route(HomeRoute? r) => r == null ? null : () => r(context);
  VoidCallback? stock(String page) => HomeNav.stockPage == null ? null : () => HomeNav.stockPage!(context, page);
  VoidCallback? bill(String page) => HomeNav.billPage == null ? null : () => HomeNav.billPage!(context, page);
  VoidCallback? money(String screen) => HomeNav.moneyScreen == null ? null : () => HomeNav.moneyScreen!(context, screen);

  // the bottom bar
  add(LucideIcons.house, 'Home', 'Dashboard', 'dashboard today sales summary start', route(HomeNav.home));
  add(LucideIcons.receiptText, 'Bill', 'New sale', 'bill sale sell billing pos checkout counter new bill customer bill', route(HomeNav.bill));
  add(LucideIcons.package, 'Products', 'Item', 'catalogue products items list grid categories maal saman', route(HomeNav.items));
  add(LucideIcons.zap, 'Quick add product', 'Item → Products', 'add new product item create naya product photo barcode price', route(HomeNav.quickAdd));
  add(LucideIcons.shoppingBag, 'Online orders', 'Orders', 'online orders new orders accept onelocal app delivery pickup', route(HomeNav.orders));
  add(LucideIcons.qrCode, 'All orders', 'Orders', 'order history all orders past orders', route(HomeNav.orderHistory));

  // Item → Stock
  add(LucideIcons.boxes, 'Stock management', 'Item → Stock', 'stock inventory update stock price mrp cost quantity store app on off', route(HomeNav.stock));
  add(LucideIcons.slidersHorizontal, 'Adjust stock', 'Item → Stock', 'adjust correct stock damage damaged loss throw away write off quarantine', stock('adjust'));
  add(LucideIcons.arrowLeftRight, 'Transfer stock', 'Item → Stock', 'transfer move stock backroom shelf another store', stock('transfer'));
  add(LucideIcons.history, 'Stock history', 'Item → Stock', 'movements history stock in out ledger', stock('movements'));
  add(LucideIcons.clipboardCheck, 'Count stock', 'Item → Stock', 'count audit physical count stock check ginti', stock('count'));
  add(LucideIcons.bellRing, 'Stock alerts', 'Item → Stock', 'alerts low stock expiry expiring not selling mismatch', stock('alerts'));
  add(LucideIcons.trendingDown, 'Low stock', 'Item → Stock', 'low stock running out out of stock khatam', stock('low'));
  add(LucideIcons.tag, 'Shelf labels', 'Item → Stock', 'labels price tag shelf label print barcode sticker', stock('shelf_labels'));
  add(LucideIcons.packageCheck, 'Putaway', 'Item → Purchase', 'putaway put away place stock backroom shelf after delivery', stock('putaway'));

  // Item → Purchase
  add(LucideIcons.truck, 'Purchase', 'Item → Purchase', 'purchase buy suppliers purchase orders kharid', route(HomeNav.grn));
  add(LucideIcons.packageOpen, 'Receive delivery', 'Item → Purchase', 'receive delivery goods arrived count delivery grn receiving maal aaya', stock('receive'));
  add(LucideIcons.shoppingCart, 'Reorder / buy again', 'Item → Purchase', 'reorder buy again new purchase order supplier order suggestions', stock('reorder'));

  // the Bill's own pages
  add(LucideIcons.layers, 'Open carts', 'Bill', 'open carts parked held bills hold', bill('carts'));
  add(LucideIcons.history, 'Bill history', 'Bill', 'history past bills sales today', bill('history'));
  add(LucideIcons.undo2, 'Returns & refunds', 'Bill', 'return refund wapas exchange', bill('returns'));
  add(LucideIcons.fileText, 'Invoices', 'Bill', 'invoice receipt reprint share bill copy', bill('receipts'));
  add(LucideIcons.wallet, 'Cash shift', 'Bill', 'cash shift open close drawer cash counter galla', bill('shift'));

  // Money
  add(LucideIcons.indianRupee, 'Money', 'Money', 'money finance paisa hisab', route(HomeNav.money));
  add(LucideIcons.creditCard, 'Payments', 'Money', 'payments upi card cash received collections', money('payments'));
  add(LucideIcons.arrowRightLeft, 'Transactions', 'Money', 'transactions all money in out', money('transactions'));
  add(LucideIcons.bookOpen, 'Cashbook', 'Money', 'cashbook cash in out balance', money('cashbook'));
  add(LucideIcons.receipt, 'Expenses', 'Money', 'expenses kharcha rent salary bills spend', money('expenses'));
  add(LucideIcons.landmark, 'Settlements', 'Money', 'settlement onelocal payout commission', money('settlements'));
  add(LucideIcons.banknote, 'Payouts', 'Money', 'payouts bank transfer paid pending', money('payouts'));
  add(LucideIcons.undo, 'Refunds', 'Money', 'refunds money back', money('refunds'));
  add(LucideIcons.chartColumn, 'Money reports', 'Money', 'reports gst tax sales report finance', money('reports'));

  // the rest of the side menu
  add(LucideIcons.scanBarcode, 'Barcodes', 'Side menu', 'barcode make generate create custom code sticker loose weigh weight plu kg label print', route(HomeNav.barcodes));
  add(LucideIcons.images, 'Product photos', 'Side menu', 'photos images pictures media pool standard share offer approve product photo', route(HomeNav.productPhotos));
  add(LucideIcons.circleUser, 'Customers', 'Side menu', 'customers grahak contacts credit khata', route(HomeNav.customers));
  add(LucideIcons.fileText, 'Reports', 'Side menu', 'reports sales analytics best sellers', onReports);
  add(LucideIcons.users, 'Team', 'Side menu', 'team staff users roles invite cashier manager employee', route(HomeNav.team));
  add(LucideIcons.settings, 'Settings', 'Side menu', 'settings preferences store timings language', route(HomeNav.settings ?? HomeNav.setup));
  add(LucideIcons.mapPinned, 'Delivery area & charges', 'Settings → Orders & delivery', 'delivery distance radius km fee minimum order free delivery', route(HomeNav.deliverySettings));
  add(LucideIcons.layoutDashboard, 'Page Manager', 'Side menu', 'page manager business profile shop page online store storefront onelocal page how customers see banner theme colours publish details logo hours delivery offers ads promote', route(HomeNav.businessProfile ?? HomeNav.storefront));
  add(LucideIcons.megaphone, 'Ads', 'Page Manager', 'ads advertise promote boost visibility customers nearby', route(HomeNav.businessProfile ?? HomeNav.storefront));
  add(LucideIcons.layoutTemplate, 'Store page', 'Page Manager', 'store page builder sections banner categories products deals preview publish theme', route(HomeNav.storefront));
  add(LucideIcons.wallet, 'OneLocal Wallet', 'Side menu', 'wallet balance', route(HomeNav.wallet));
  add(LucideIcons.bell, 'Notifications', 'Banner', 'notifications alerts messages announcements', route(HomeNav.notifications));
  add(LucideIcons.circleQuestionMark, 'Help & support', 'Side menu', 'help support complaint ticket contact problem', route(HomeNav.support));
  add(LucideIcons.user, 'Manage account', 'Profile', 'account profile name phone password sign in', route(HomeNav.account));
  return list;
}

/// The actions that match [query], title matches first.
List<AppAction> searchActions(List<AppAction> all, String query) {
  if (query.trim().isEmpty) return const [];
  final hits = all.where((a) => a.matches(query));
  return [...hits.where((a) => a.rank(query) == 0), ...hits.where((a) => a.rank(query) != 0)];
}
