import 'package:flutter/material.dart';

import 'adjust_screen.dart';
import 'alerts_screen.dart';
import 'labels_screens.dart';
import 'low_stock_view_screen.dart';
import 'move_stock_screen.dart';
import 'receive_screen.dart';
import 'reorder_screen.dart';
import 'stock_count_screen.dart';
import 'stock_env.dart';
import 'stock_home.dart';
import 'product_page.dart';
import 'stock_movements_screen.dart';
import 'update_stock_screen.dart';

/// The route name of the Stock page: the bottom bar's "Stock" tab goes back to it.
const stockHomeRoute = '/inventory';

/// Opens one stock page on top of the current one (with a back arrow); Stock itself has its own route name.
Future<void> openStockPage(BuildContext context, StockEnv env, String page, {String? itemId}) {
  if (page == StockPage.home) return Navigator.of(context).push(StockHomeScreen.route(env));
  final Widget screen = switch (page) {
    StockPage.item => ProductPage(env: env, inventoryId: itemId),
    StockPage.movements => StockMovementsScreen(env: env, itemId: itemId),
    StockPage.receive => ReceiveScreen(env: env, itemId: itemId),
    StockPage.adjust => AdjustStockScreen(env: env, itemId: itemId),
    StockPage.transfer => MoveStockScreen(env: env, itemId: itemId),
    StockPage.low => LowStockViewScreen(env: env, itemId: itemId),
    StockPage.reorder => ReorderScreen(env: env, itemId: itemId),
    StockPage.alerts => StockAlertsScreen(env: env, itemId: itemId),
    StockPage.count => StockCountScreen(env: env, itemId: itemId),
    StockPage.productLabels => ProductLabelsScreen(env: env, itemId: itemId),
    _ => UpdateStockScreen(env: env, itemId: itemId),
  };
  return Navigator.of(context).push(MaterialPageRoute(settings: RouteSettings(name: 'stock/$page'), builder: (_) => screen));
}
