import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'inventory_api.dart';
import 'inventory_widgets.dart';

/// What every section H screen shares: the API and the ways out of the section (other bottom-bar tabs, the linked order, Items, bell).
class InvEnv {
  InvEnv({InventoryApi? api, this.onNavigate, this.onOpenOrder, this.onOpenPurchasing, this.onOpenLowStock, this.onItems, this.onBell}) : api = api ?? InventoryApi();
  final InventoryApi api;

  /// Bottom-bar tabs this section does not own: 'home', 'item', 'bill', 'online'.
  final ValueChanged<String>? onNavigate;

  /// Opens a linked order (Movement Detail "Open Linked Transaction").
  final void Function(BuildContext context, String orderId)? onOpenOrder;

  /// Opens the purchasing screens (Purchase History) from Planning > Replenishment; null keeps the "later release" notice.
  final void Function(BuildContext context)? onOpenPurchasing;

  /// Opens Low Stock (section J, with Purchase Suggestions inside it) from Planning > Stock Risk; null shows the critical stock list.
  final void Function(BuildContext context)? onOpenLowStock;
  final VoidCallback? onItems, onBell;

  static const dashboardRoute = '/inventory';

  void tab(BuildContext context, String id) {
    if (id == 'stock') {
      Navigator.of(context).popUntil((r) => r.settings.name == dashboardRoute || r.isFirst);
    } else if (onNavigate != null) {
      onNavigate!(id);
    } else {
      showToast(context, 'That part of the app is not built yet.');
    }
  }

  void later(BuildContext context, String what) => showToast(context, '$what opens in a later release.');

  Future<T?> push<T>(BuildContext context, Widget screen) => Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => screen));
}

/// Shared page frame for every section H screen.
class InvScaffold extends StatelessWidget {
  const InvScaffold({super.key, required this.env, required this.children, this.onRefresh});
  final InvEnv env;
  final List<Widget> children;
  final Future<void> Function()? onRefresh;
  @override
  Widget build(BuildContext context) => InvPage(
        onTab: (id) => env.tab(context, id),
        onRefresh: onRefresh,
        onItems: env.onItems ?? () => env.tab(context, 'item'),
        onBell: env.onBell ?? () => env.later(context, 'Notifications'),
        children: children,
      );
}

