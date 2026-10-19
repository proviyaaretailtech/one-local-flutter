import 'package:flutter/material.dart';

import '../customers/customers_screen.dart';
import '../home/home_nav.dart';
import 'account_screen.dart';
import 'wallet_screen.dart';

/// Plugs the side nav's Customer, One Local Wallet and Manage account rows into [HomeNav] (called from app_routes.dart).
void installAccountRoutes() {
  HomeNav.customers = (c) => Navigator.of(c).push(CustomersScreen.route());
  HomeNav.wallet = (c) => Navigator.of(c).push(WalletScreen.route());
  HomeNav.account = (c) => Navigator.of(c).push(ManageAccountScreen.route());
}
