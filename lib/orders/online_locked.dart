import 'package:flutter/material.dart';

import '../auth/partner_api.dart';
import '../plans/subscription_plans.dart';
import '../settings/settings_api.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'order_widgets.dart';

/// The store's plan, read once per sign-in from the server (`me`): pos_only | pos_and_onelocal | onelocal_app, or null.
class StorePlan {
  static Future<String?>? _plan;

  static Future<String?> get() => _plan ??= PartnerApi().me().then((m) => m.sellPlan).catchError((Object _) => null);

  /// Tests set the plan; signing out forgets it.
  static void set(String? plan) => _plan = Future.value(plan);
  static void reset() => _plan = null;
}

/// Online orders, unless the store is on POS only (founder, 28 Oct 2026): then the tab offers the OneLocal subscription instead.
class OnlineOrdersGate extends StatelessWidget {
  const OnlineOrdersGate({super.key, required this.child, this.onMenu});
  final Widget child;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
        future: StorePlan.get(),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Scaffold(backgroundColor: kBg, body: Center(child: CircularProgressIndicator(color: kLink)));
          return snap.data == 'pos_only' ? OnlineLockedScreen(onMenu: onMenu) : child;
        },
      );
}

/// "Start selling on OneLocal": what the subscription adds, and a request the OneLocal team answers to start it.
class OnlineLockedScreen extends StatefulWidget {
  const OnlineLockedScreen({super.key, this.onMenu, this.api});
  final VoidCallback? onMenu;
  final SettingsApi? api;
  @override
  State<OnlineLockedScreen> createState() => _OnlineLockedScreenState();
}

class _OnlineLockedScreenState extends State<OnlineLockedScreen> {
  late final _api = widget.api ?? SettingsApi();
  final _key = 'upgrade-${DateTime.now().microsecondsSinceEpoch}';
  bool _busy = false;
  String? _sent;
  var _cycle = BillingCycle.sixMonths;
  static final _upgrade = planByCode('pos_and_onelocal')!;

  Future<void> _request() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // no payment in the app yet: the request reaches the OneLocal team, who start the subscription
      final ref = await requestSubscription(_api, _upgrade, _cycle, key: '$_key-${_cycle.months}', current: 'pos_only');
      if (mounted) setState(() => _sent = ref);
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not reach the server. Check your connection and try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _perk(IconData icon, String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 40, height: 40, decoration: BoxDecoration(color: kNote, borderRadius: BorderRadius.circular(12)), child: Icon(icon, size: 20, color: kInk)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr(title), style: inter(15, 600)),
              const SizedBox(height: 2),
              Text(tr(body), style: inter(13, 400, color: kMuted, height: 1.35)),
            ]),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: Column(children: [
          OrdersTopBar(title: tr('Online orders'), onMenu: widget.onMenu),
          Expanded(
            child: ListView(key: const ValueKey('online-locked'), padding: const EdgeInsets.fromLTRB(16, 18, 16, 24), children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Color(0xFFEAFBD6), Color(0xFFFFFFFF)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFC9EF9B)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(Icons.lock_outline, size: 18, color: kMuted),
                    const SizedBox(width: 6),
                    Text(tr('Not in your plan · Purchase POS'), style: inter(12.5, 600, color: kMuted)),
                  ]),
                  const SizedBox(height: 10),
                  Text(tr('Start selling on OneLocal'), style: inter(26, 800, height: 1.1)),
                  const SizedBox(height: 8),
                  Text(tr('Get orders from customers near you on the OneLocal app, right here next to your POS.'), style: inter(14, 400, color: kMuted, height: 1.45)),
                ]),
              ),
              const SizedBox(height: 20),
              _perk(Icons.storefront_outlined, 'Your shop on the OneLocal app', 'Customers nearby find you, see your items and prices, and order.'),
              _perk(Icons.notifications_active_outlined, 'Orders on this screen', 'Accept, pack and hand over online orders beside your counter sales.'),
              _perk(Icons.delivery_dining_outlined, 'Delivery or pickup', 'Delivery partners or customer pickup, your choice per order.'),
              _perk(Icons.sync_outlined, 'One stock for both', 'Online and counter sales come off the same stock, so nothing is sold twice.'),
              const SizedBox(height: 8),
              const SizedBox(height: 4),
              PlanDetail(plan: _upgrade, cycle: _cycle, onCycle: (c) => setState(() => _cycle = c), recommended: true),
              const SizedBox(height: 4),
              Center(
                child: TextButton(
                  key: const ValueKey('online-all-plans'),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SubscriptionPlansScreen(current: 'pos_only'))),
                  child: Text(tr('Compare all plans'), style: inter(14, 600, color: kLink)),
                ),
              ),
            ]),
          ),
          PlanContinueBar(plan: _upgrade, cycle: _cycle, busy: _busy, sent: _sent, onContinue: _request),
        ]),
      );
}
