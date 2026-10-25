import 'package:flutter/material.dart';

import 'stock_env.dart';
import 'stock_routes.dart';
import 'update_stock_screen.dart';

/// The Stock page (bottom bar "Stock", side menu "Stock management"): Stock Management — stock, prices and where each product is
/// sold. The other stock screens open from their buttons elsewhere (see [StockPage]).
class StockHomeScreen extends StatelessWidget {
  const StockHomeScreen({super.key, required this.env, this.itemId});
  final StockEnv env;
  final String? itemId;

  static Route<void> route(StockEnv env) =>
      MaterialPageRoute(settings: const RouteSettings(name: stockHomeRoute), builder: (_) => StockHomeScreen(env: env));

  @override
  Widget build(BuildContext context) => UpdateStockScreen(env: env, itemId: itemId);
}
