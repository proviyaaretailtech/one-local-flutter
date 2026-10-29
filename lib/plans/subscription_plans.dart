import 'package:flutter/material.dart';

import '../auth/partner_api.dart';
import '../settings/settings_api.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart';

/// OneLocal subscriptions (founder's financial module, 28 Oct 2026): ₹599 a month for the POS only, ₹799 for the POS and selling on
/// OneLocal. Bought for 6 months (no months free) or 12 months (2 months free). No monthly subscription.
enum BillingCycle {
  sixMonths(6, 0),
  twelveMonths(12, 2);

  const BillingCycle(this.months, this.freeMonths);
  final int months, freeMonths;
  int get paidMonths => months - freeMonths;
}

class SubscriptionPlan {
  const SubscriptionPlan({required this.code, required this.name, required this.shortName, required this.perMonth, required this.blurb, required this.includes, required this.excludes});

  /// The application's sell plan: pos_only | pos_and_onelocal.
  final String code;
  final String name;

  /// The tab's and header's name.
  final String shortName;
  final int perMonth;
  final String blurb;
  final List<String> includes, excludes;

  int price(BillingCycle c) => perMonth * c.paidMonths;
  int saving(BillingCycle c) => perMonth * c.freeMonths;

  /// What a month works out to over the whole cycle (₹499 a month for a year of POS only).
  int effectivePerMonth(BillingCycle c) => (price(c) / c.months).round();
}

const kSubscriptionPlans = [
  SubscriptionPlan(
    code: 'pos_only',
    name: 'Purchase POS',
    shortName: 'Purchase POS',
    perMonth: 599,
    blurb: 'Everything you need to run your store from your counter.',
    includes: ['POS billing', 'Catalogue', 'Stock & purchase', 'Reports'],
    excludes: ['OneLocal listing', 'Online orders', 'Delivery & pickup'],
  ),
  SubscriptionPlan(
    code: 'pos_and_onelocal',
    name: 'Sell on OneLocal and Purchase POS',
    shortName: 'POS + OneLocal',
    perMonth: 799,
    blurb: 'Everything you get with Purchase POS, plus reach more customers on OneLocal.',
    includes: ['POS billing', 'Catalogue', 'Stock & purchase', 'Reports', 'OneLocal listing', 'Online orders', 'Delivery & pickup'],
    excludes: [],
  ),
];

SubscriptionPlan? planByCode(String? code) => kSubscriptionPlans.where((p) => p.code == code).firstOrNull;

/// ₹ with Indian grouping: 5990 → ₹5,990; 179700 → ₹1,79,700.
String rupees(int n) {
  final s = n.abs().toString();
  if (s.length <= 3) return '₹$s';
  final last3 = s.substring(s.length - 3);
  var rest = s.substring(0, s.length - 3);
  final groups = <String>[];
  while (rest.length > 2) {
    groups.insert(0, rest.substring(rest.length - 2));
    rest = rest.substring(0, rest.length - 2);
  }
  if (rest.isNotEmpty) groups.insert(0, rest);
  return '₹${groups.join(',')},$last3';
}

/// No payment in the app yet: choosing a plan sends a request the OneLocal team answers to start the subscription.
Future<String> requestSubscription(SettingsApi api, SubscriptionPlan plan, BillingCycle cycle, {required String key, String? current}) async {
  final from = planByCode(current);
  final r = await api.supportCreate(
    message: 'Subscription request: ${plan.name}, ${cycle.months} months, ${rupees(plan.price(cycle))}'
        '${cycle.freeMonths > 0 ? ' (${cycle.freeMonths} months free)' : ''}.${from != null && from.code != plan.code ? ' Moving from ${from.name}.' : ''}',
    topic: 'account',
    idempotencyKey: key,
  );
  return '${r['reference']}';
}

const _green = Color(0xFF1E6B47); // ticks, the chosen duration
const _deep = Color(0xFF173F2E); // the Continue button
const _wash = Color(0xFFEAF5EC); // the plan's header card

/// The plans as tabs at the top (founder's design, 28 Oct 2026): Purchase POS | POS + OneLocal.
class PlanTabs extends StatelessWidget {
  const PlanTabs({super.key, required this.value, required this.onChanged});
  final SubscriptionPlan value;
  final ValueChanged<SubscriptionPlan> onChanged;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: const Color(0xFFE9EAEE), borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          for (final p in kSubscriptionPlans)
            Expanded(
              child: GestureDetector(
                key: ValueKey('tab-${p.code}'),
                onTap: () => onChanged(p),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  decoration: BoxDecoration(
                    color: p == value ? Colors.white : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: p == value ? const [BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 2))] : null,
                  ),
                  child: Text(tr(p.shortName), textAlign: TextAlign.center, style: inter(14, 700, color: p == value ? kInk : kMuted)),
                ),
              ),
            ),
        ]),
      );
}

/// One plan in full: header, price, the duration to choose, what is included and what is not.
class PlanDetail extends StatelessWidget {
  const PlanDetail({super.key, required this.plan, required this.cycle, required this.onCycle, this.current = false, this.recommended = false});
  final SubscriptionPlan plan;
  final BillingCycle cycle;
  final ValueChanged<BillingCycle> onCycle;
  final bool current, recommended;

  @override
  Widget build(BuildContext context) {
    final base = kSubscriptionPlans.first;
    final extras = plan.code == base.code ? const <String>[] : plan.includes.where((f) => !base.includes.contains(f)).toList();
    final shared = plan.includes.where((f) => !extras.contains(f)).toList();
    final otherSaving = cycle == BillingCycle.sixMonths ? plan.saving(BillingCycle.twelveMonths) : 0;
    return Column(key: ValueKey('plan-${plan.code}'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: _wash, borderRadius: BorderRadius.circular(18)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(14)),
            child: Icon(plan.code == 'pos_only' ? Icons.point_of_sale_outlined : Icons.storefront_outlined, color: _green, size: 28),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Text(tr(plan.shortName), style: inter(18, 800, height: 1.2))),
                if (current) const _Tag('Current plan', _deep, Colors.white) else if (recommended) const _Tag('Recommended', Color(0xFFA1FE2F), kInk),
              ]),
              const SizedBox(height: 4),
              Text(tr(plan.blurb), style: inter(13, 400, color: kMuted, height: 1.35)),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 18),
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(rupees(plan.perMonth), style: inter(34, 800, height: 1)),
        Padding(padding: const EdgeInsets.only(bottom: 4, left: 6), child: Text('/${tr('month')}', style: inter(15, 600, color: kMuted))),
      ]),
      const SizedBox(height: 6),
      Text.rich(
        TextSpan(children: [
          TextSpan(text: '${rupees(plan.price(cycle))} ${tr('for')} ${cycle.months} ${tr('months')}', style: inter(13.5, 500, color: kMuted)),
          if (otherSaving > 0) TextSpan(text: ' · ${tr('Save')} ${rupees(otherSaving)} ${tr('with 12 months')}', style: inter(13.5, 700, color: _green)),
          if (cycle.freeMonths > 0) TextSpan(text: ' · ${cycle.freeMonths} ${tr('months free')}', style: inter(13.5, 700, color: _green)),
        ]),
        key: ValueKey('plan-${plan.code}-total'),
      ),
      const SizedBox(height: 18),
      Text(tr('Choose subscription duration'), style: inter(15, 700)),
      const SizedBox(height: 10),
      IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final c in BillingCycle.values) ...[
            if (c != BillingCycle.values.first) const SizedBox(width: 10),
            Expanded(child: _Duration(plan: plan, cycle: c, selected: c == cycle, onTap: () => onCycle(c))),
          ],
        ]),
      ),
      const SizedBox(height: 18),
      const Divider(height: 1, color: kLine),
      const SizedBox(height: 16),
      Text(tr('Included features'), style: inter(15, 700)),
      const SizedBox(height: 8),
      for (final f in shared) _Feature(f, true),
      if (extras.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(tr('Everything in Purchase POS, plus'), style: inter(13, 700, color: kMuted)),
        const SizedBox(height: 6),
        for (final f in extras) _Feature(f, true),
      ],
      if (plan.excludes.isNotEmpty) ...[
        const SizedBox(height: 14),
        const Divider(height: 1, color: kLine),
        const SizedBox(height: 14),
        Text(tr('Not included in this plan'), style: inter(13, 700, color: kMuted)),
        const SizedBox(height: 6),
        for (final f in plan.excludes) _Feature(f, false),
      ],
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0xFFF1F2F4), borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          const Icon(Icons.info_outline, size: 18, color: kMuted),
          const SizedBox(width: 8),
          Expanded(child: Text(tr('Prices are exclusive of taxes. Billed as a lump sum for the selected duration. No monthly plan.'), style: inter(12, 400, color: kMuted, height: 1.35))),
        ]),
      ),
    ]);
  }
}

class _Duration extends StatelessWidget {
  const _Duration({required this.plan, required this.cycle, required this.selected, required this.onTap});
  final SubscriptionPlan plan;
  final BillingCycle cycle;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        key: ValueKey('cycle-${cycle.months}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFF2FAF4) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: selected ? _green : kLine, width: selected ? 2 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('${cycle.months} ${tr('months')}', style: inter(16, 800))),
              Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked, size: 20, color: selected ? _green : const Color(0xFFB4B8BF)),
            ]),
            if (cycle.freeMonths > 0)
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: const Color(0xFFDDF3E2), borderRadius: BorderRadius.circular(999)),
                child: Text('${cycle.freeMonths} ${tr('months free')}', style: inter(11.5, 700, color: _green)),
              ),
            const SizedBox(height: 6),
            Text('${rupees(plan.price(cycle))} ${tr('total')}', style: inter(15, 700)),
            const SizedBox(height: 2),
            Text(
              cycle.freeMonths > 0 ? '${rupees(plan.effectivePerMonth(cycle))}/${tr('month')} (${tr('approx.')})' : '${rupees(plan.perMonth)}/${tr('month')}',
              style: inter(12.5, 500, color: kMuted),
            ),
          ]),
        ),
      );
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, this.bg, this.fg);
  final String text;
  final Color bg, fg;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(tr(text), style: inter(11.5, 700, color: fg)),
      );
}

class _Feature extends StatelessWidget {
  const _Feature(this.text, this.included);
  final String text;
  final bool included;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(included ? Icons.check_circle : Icons.cancel_outlined, size: 18, color: included ? _green : const Color(0xFFC0C4CB)),
          const SizedBox(width: 10),
          Expanded(child: Text(tr(text), style: inter(14, 500, color: included ? kInk : const Color(0xFFA3A7AF)))),
        ]),
      );
}

/// The bar at the bottom: "Continue with 6 months · ₹3,594 →", or what was sent.
class PlanContinueBar extends StatelessWidget {
  const PlanContinueBar({super.key, required this.plan, required this.cycle, required this.onContinue, this.busy = false, this.sent});
  final SubscriptionPlan plan;
  final BillingCycle cycle;
  final VoidCallback onContinue;
  final bool busy;

  /// The request's reference once sent.
  final String? sent;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
        decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: kLine))),
        child: SafeArea(
          top: false,
          child: sent != null
              ? Container(
                  key: const ValueKey('plan-request-sent'),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: kNote, borderRadius: BorderRadius.circular(14)),
                  child: Row(children: [
                    const Icon(Icons.check_circle, color: _green),
                    const SizedBox(width: 10),
                    Expanded(child: Text('${tr('Request sent')} · $sent. ${tr('The OneLocal team will call you to start your subscription.')}', style: inter(13.5, 500, height: 1.35))),
                  ]),
                )
              : FilledButton(
                  key: ValueKey('continue-${plan.code}'),
                  onPressed: busy ? null : onContinue,
                  style: FilledButton.styleFrom(backgroundColor: _deep, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(busy ? '…' : '${tr('Continue with')} ${cycle.months} ${tr('months')} · ${rupees(plan.price(cycle))}', style: inter(15.5, 700, color: Colors.white)),
                    if (!busy) ...[const SizedBox(width: 8), const Icon(Icons.arrow_forward, size: 18, color: Colors.white)],
                  ]),
                ),
        ),
      );
}

/// Side menu → Subscription plans: the two plans as tabs, the store's own plan open first.
class SubscriptionPlansScreen extends StatefulWidget {
  const SubscriptionPlansScreen({super.key, this.current, this.api, this.initial});

  /// The store's plan code, when known (null: read from the server).
  final String? current;

  /// The tab to open on (default: the store's own plan, else Purchase POS).
  final String? initial;
  final SettingsApi? api;
  @override
  State<SubscriptionPlansScreen> createState() => _SubscriptionPlansScreenState();
}

class _SubscriptionPlansScreenState extends State<SubscriptionPlansScreen> {
  late final _api = widget.api ?? SettingsApi();
  late final Future<String?> _current = widget.current != null ? Future.value(widget.current) : PartnerApi().me().then((m) => m.sellPlan).catchError((Object _) => null);
  final _key = 'plan-${DateTime.now().microsecondsSinceEpoch}';
  SubscriptionPlan? _tab;
  var _cycle = BillingCycle.sixMonths;
  bool _busy = false;
  final _sent = <String, String>{}; // plan code → reference

  Future<void> _continue(SubscriptionPlan p, String? current) async {
    setState(() => _busy = true);
    try {
      final ref = await requestSubscription(_api, p, _cycle, key: '$_key-${p.code}-${_cycle.months}', current: current);
      if (mounted) setState(() => _sent[p.code] = ref);
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not reach the server. Check your connection and try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
        future: _current,
        builder: (context, snap) {
          final loading = snap.connectionState != ConnectionState.done;
          final current = snap.data;
          final tab = _tab ?? planByCode(widget.initial) ?? planByCode(current) ?? kSubscriptionPlans.first;
          return Scaffold(
            backgroundColor: kBg,
            appBar: AppBar(backgroundColor: kBg, surfaceTintColor: kBg, title: Text(tr('Subscription plans'), style: inter(18, 700))),
            body: loading
                ? const Center(child: CircularProgressIndicator(color: kLink))
                : ListView(key: const ValueKey('subscription-plans'), padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
                    PlanTabs(value: tab, onChanged: (p) => setState(() => _tab = p)),
                    const SizedBox(height: 16),
                    PlanDetail(
                      plan: tab,
                      cycle: _cycle,
                      onCycle: (c) => setState(() => _cycle = c),
                      current: tab.code == current,
                      recommended: tab.code == 'pos_and_onelocal' && current != tab.code,
                    ),
                  ]),
            bottomNavigationBar: loading ? null : PlanContinueBar(plan: tab, cycle: _cycle, busy: _busy, sent: _sent[tab.code], onContinue: () => _continue(tab, current)),
          );
        },
      );
}
