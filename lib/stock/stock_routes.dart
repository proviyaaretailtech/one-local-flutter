import 'package:flutter/material.dart';

import 'adjust_screen.dart';
import 'alerts_screen.dart';
import 'labels_screens.dart';
import 'lot_labels_screen.dart';
import 'move_stock_screen.dart';
import '../home/home_nav.dart';
import 'putaway_screen.dart';
import 'reorder_screen.dart';
import 'shelf_labels_screen.dart';
import 'stock_count_screen.dart';
import 'stock_env.dart';
import 'stock_home.dart';
import 'product_page.dart';
import 'stock_movements_screen.dart';
import 'update_stock_screen.dart';

/// The route name of the Stock page: the bottom bar's "Stock" tab goes back to it.
const stockHomeRoute = '/inventory';

/// Opens one stock page on top of the current one (with a back arrow); Stock itself has its own route name.
Future<void> openStockPage(BuildContext context, StockEnv env, String page, {String? itemId}) async {
  if (page == StockPage.home) {
    await Navigator.of(context).push(StockHomeScreen.route(env));
    return;
  }
  // receiving and matching live in Item → Purchase
  if (page == StockPage.receive) return HomeNav.grn?.call(context);
  final Widget screen = switch (page) {
    StockPage.item => ProductPage(env: env, inventoryId: itemId),
    StockPage.movements => StockMovementsScreen(env: env, itemId: itemId),
    StockPage.adjust => AdjustStockScreen(env: env, itemId: itemId),
    StockPage.transfer => MoveStockScreen(env: env, itemId: itemId),
    StockPage.low => StockAlertsScreen(env: env, itemId: itemId, show: 'low'),
    StockPage.reorder => ReorderScreen(env: env, itemId: itemId),
    StockPage.alerts => StockAlertsScreen(env: env, itemId: itemId),
    StockPage.count => StockCountScreen(env: env, itemId: itemId),
    StockPage.productLabels => ProductLabelsScreen(env: env, itemId: itemId),
    StockPage.shelfLabels => ShelfLabelsScreen(env: env, itemId: itemId),
    StockPage.putaway => PutawayScreen(env: env, receiptId: itemId),
    StockPage.lotLabels when itemId != null => LotLabelsScreen(env: env, receiptId: itemId),
    _ => UpdateStockScreen(env: env, itemId: itemId),
  };
  await Navigator.of(context).push(MaterialPageRoute(settings: RouteSettings(name: 'stock/$page'), builder: (_) => screen));
}
