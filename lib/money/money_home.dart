import 'package:flutter/material.dart';

import '../api/rpc_client.dart';
import '../ui/theme.dart';
import 'money_env.dart';
import 'money_screens_a.dart';
import 'money_screens_b.dart';
import 'money_screens_c.dart';
import 'money_widgets.dart';

/// Builds one Money screen by key.
Widget moneyScreenFor(MoneyEnv env, String key) => switch (key) {
      'payments' => PaymentsScreen(env: env),
      'transactions' => TransactionsScreen(env: env),
      'invoices' => InvoicesScreen(env: env),
      'cashbook' => CashbookScreen(env: env),
      'expenses' => ExpensesScreen(env: env),
      'settlements' => SettlementsScreen(env: env),
      'payouts' => PayoutsScreen(env: env),
      'refunds' => RefundsScreen(env: env),
      'reports' => ReportsScreen(env: env),
      _ => MoneyOverview(env: env),
    };

/// Entry of the bottom bar's Money tab: asks the server what this person may open, then shows the first screen it allows. A person with no money
/// permission sees a plain sentence instead of a screen that would only be refused.
class MoneyHome extends StatefulWidget {
  const MoneyHome({super.key, required this.env});
  final MoneyEnv env;

  static Route<void> route(MoneyEnv env) => MaterialPageRoute(settings: const RouteSettings(name: MoneyEnv.homeRoute), builder: (_) => MoneyHome(env: env));

  @override
  State<MoneyHome> createState() => _MoneyHomeState();
}

class _MoneyHomeState extends State<MoneyHome> {
  String? error;
  bool denied = false;

  @override
  void initState() {
    super.initState();
    widget.env.screenFor = moneyScreenFor;
    _go();
  }

  Future<void> _go() async {
    setState(() {
      error = null;
      denied = false;
    });
    try {
      final o = await widget.env.api.options();
      final screens = o.ls('screens');
      widget.env.allowed = screens;
      widget.env.can = o.m('can');
      if (!mounted) return;
      if (screens.isEmpty) {
        setState(() => denied = true);
      } else {
        Navigator.of(context).pushReplacement(MaterialPageRoute(settings: const RouteSettings(name: MoneyEnv.homeRoute), builder: (_) => moneyScreenFor(widget.env, screens.first)));
      }
    } on RpcException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = 'Could not reach the server. Check your connection and try again.');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(backgroundColor: kBg, elevation: 0, foregroundColor: kInk, title: Text('Money', style: inter(18, 700))),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: denied
                ? Text('Your role does not include the money screens. Ask the owner if you need them.', textAlign: TextAlign.center, style: inter(15, 400, color: kMuted))
                : error != null
                    ? Column(mainAxisSize: MainAxisSize.min, children: [Text(error!, textAlign: TextAlign.center, style: inter(14, 400, color: kMuted)), const SizedBox(height: 12), InvSecondary('Try again', onPressed: _go)])
                    : const CircularProgressIndicator(color: kInk),
          ),
        ),
      );
}
