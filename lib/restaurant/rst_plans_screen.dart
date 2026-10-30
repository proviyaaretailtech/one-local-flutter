import 'dart:math';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/net_guard.dart';
import '../api/rpc_client.dart';
import '../settings/settings_api.dart';
import '../ui/theme.dart';

/// Subscription plans for the restaurant POS (founder, 29 Oct 2026: "keep the same amount" as the store): ₹599 a month for the POS only,
/// ₹799 for the POS and selling on OneLocal, bought for 6 months or for 12 months with 2 months free. No monthly plan, no payment in the app
/// yet: Continue sends a request (a support request, topic account) that the OneLocal team answers to start the subscription.
enum PlanCycle {
  sixMonths(6, 0),
  twelveMonths(12, 2);

  const PlanCycle(this.months, this.freeMonths);
  final int months, freeMonths;
  int get paidMonths => months - freeMonths;
}

class RstPlan {
  const RstPlan({required this.code, required this.name, required this.perMonth, required this.blurb, required this.icon, required this.includes, this.plus = const [], this.excludes = const []});

  /// The business's sell plan: pos_only | pos_and_onelocal.
  final String code;
  final String name;
  final int perMonth;
  final String blurb;
  final IconData icon;
  final List<String> includes, plus, excludes;

  int price(PlanCycle c) => perMonth * c.paidMonths;
  int saving(PlanCycle c) => perMonth * c.freeMonths;
  int effectivePerMonth(PlanCycle c) => (price(c) / c.months).round();
}

const _pos = ['POS billing & tables', 'Menu & recipes', 'Kitchen display & KOT', 'Stock & purchase', 'Reports'];
const _online = ['OneLocal listing', 'Online orders', 'Delivery & pickup'];
const kRstPlans = [
  RstPlan(code: 'pos_only', name: 'Purchase POS', perMonth: 599, blurb: 'Everything you need to run your restaurant from your counter.', icon: LucideIcons.calculator, includes: _pos, excludes: _online),
  RstPlan(
    code: 'pos_and_onelocal',
    name: 'POS + OneLocal',
    perMonth: 799,
    blurb: 'Everything you get with Purchase POS, plus reach more customers on OneLocal.',
    icon: LucideIcons.store,
    includes: _pos,
    plus: _online,
  ),
];

/// ₹ with Indian grouping: 5990 → ₹5,990.
String planRupees(int n) {
  final s = n.toString();
  if (s.length <= 3) return '₹$s';
  return '₹${s.substring(0, s.length - 3).replaceAllMapped(RegExp(r'(\d)(?=(\d\d)+$)'), (m) => '${m[1]},')},${s.substring(s.length - 3)}';
}

const _green = Color(0xFF1E6B47), _deep = Color(0xFF173F2E), _wash = Color(0xFFEAF5EC);

class RstPlansScreen extends StatefulWidget {
  const RstPlansScreen({super.key, this.settings, this.rpc, this.current});
  final SettingsApi? settings;
  final RpcClient? rpc;

  /// Tests set the current plan; otherwise the business's own (`org_sell_plan`).
  final String? current;

  static Route<void> route() => MaterialPageRoute(builder: (_) => const RstPlansScreen());
  @override
  State<RstPlansScreen> createState() => _RstPlansScreenState();
}

class _RstPlansScreenState extends State<RstPlansScreen> {
  late final SettingsApi _settings = widget.settings ?? SettingsApi(rpc: widget.rpc);
  String? _current;
  bool _loaded = false, _busy = false;
  String? _tab;
  PlanCycle _cycle = PlanCycle.twelveMonths;
  final _sent = <String, String>{}; // plan + months → the request's reference
  // 16 random bytes (1 << 32 is 0 on the web, so no single big nextInt)
  final _key = 'plan-${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  @override
  void initState() {
    super.initState();
    if (widget.current != null) {
      _current = widget.current;
      _loaded = true;
    } else {
      _loadCurrent();
    }
  }

  Future<void> _loadCurrent() async {
    try {
      final r = await (widget.rpc ?? RpcClient()).callMap('org_sell_plan');
      _current = r['plan'] as String?;
    } catch (_) {
      // no current plan shown; the plans still are
    }
    if (mounted) setState(() => _loaded = true);
  }

  RstPlan get _plan => kRstPlans.firstWhere((p) => p.code == (_tab ?? _current ?? 'pos_only'), orElse: () => kRstPlans.first);

  Future<void> _continue() async {
    final p = _plan;
    final from = kRstPlans.where((x) => x.code == _current).firstOrNull;
    setState(() => _busy = true);
    try {
      final r = await _settings.supportCreate(
        message: 'Subscription request (restaurant POS): ${p.name}, ${_cycle.months} months, ${planRupees(p.price(_cycle))}'
            '${_cycle.freeMonths > 0 ? ' (${_cycle.freeMonths} months free)' : ''}.${from != null && from.code != p.code ? ' Moving from ${from.name}.' : ''}',
        topic: 'account',
        idempotencyKey: '$_key-${p.code}-${_cycle.months}',
      );
      if (!mounted) return;
      setState(() => _sent['${p.code}-${_cycle.months}'] = '${r['reference'] ?? ''}');
      showToast(context, 'Request sent. The OneLocal team will call you to start ${p.name}.');
    } catch (e) {
      if (mounted) showToast(context, errorSentence(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = _plan;
    final sent = _sent['${p.code}-${_cycle.months}'];
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        surfaceTintColor: kBg,
        leading: IconButton(key: const ValueKey('plans-back'), icon: const Icon(LucideIcons.arrowLeft, color: kInk), onPressed: () => Navigator.of(context).maybePop()),
        title: Text('Subscription plans', style: inter(19, 800)),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(key: const ValueKey('plans-list'), padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              // the two plans as a segmented switch
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(color: const Color(0xFFE6E8E4), borderRadius: BorderRadius.circular(16)),
                child: Row(children: [
                  for (final x in kRstPlans)
                    Expanded(
                      child: GestureDetector(
                        key: ValueKey('plan-tab-${x.code}'),
                        onTap: () => setState(() => _tab = x.code),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          decoration: BoxDecoration(
                            color: x.code == p.code ? Colors.white : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: x.code == p.code ? const [BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 2))] : null,
                          ),
                          child: Text(x.name, textAlign: TextAlign.center, style: inter(14.5, 700, color: x.code == p.code ? kInk : kMuted)),
                        ),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: _wash, borderRadius: BorderRadius.circular(18)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(width: 54, height: 54, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)), child: Icon(p.icon, color: _green, size: 26)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(p.name, style: inter(19, 800))),
                        if (p.code == _current)
                          Container(
                            key: const ValueKey('plan-current'),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: _deep, borderRadius: BorderRadius.circular(20)),
                            child: Text('Current plan', style: inter(12, 700, color: Colors.white)),
                          ),
                      ]),
                      const SizedBox(height: 4),
                      Text(p.blurb, style: inter(13.5, 500, color: kMuted, height: 1.35)),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 18),
              Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Text(planRupees(p.perMonth), key: const ValueKey('plan-per-month'), style: inter(36, 800)),
                const SizedBox(width: 6),
                Text('/month', style: inter(15, 500, color: kMuted)),
              ]),
              const SizedBox(height: 4),
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: _cycle == PlanCycle.twelveMonths ? '${planRupees(p.price(_cycle))} for 12 months · ' : '${planRupees(p.price(_cycle))} for 6 months · '),
                  TextSpan(
                    text: _cycle == PlanCycle.twelveMonths ? '2 months free' : 'Save ${planRupees(p.saving(PlanCycle.twelveMonths))} with 12 months',
                    style: inter(13.5, 700, color: _green),
                  ),
                ]),
                key: const ValueKey('plan-summary'),
                style: inter(13.5, 500, color: kMuted),
              ),
              const SizedBox(height: 20),
              Text('Choose subscription duration', style: inter(15.5, 700)),
              const SizedBox(height: 10),
              IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final c in PlanCycle.values) ...[
                    if (c != PlanCycle.values.first) const SizedBox(width: 12),
                    Expanded(child: _duration(p, c)),
                  ],
                ]),
              ),
              const SizedBox(height: 18),
              const Divider(color: kLine),
              const SizedBox(height: 10),
              Text('Included features', style: inter(15.5, 700)),
              const SizedBox(height: 6),
              for (final f in p.includes) _feature(f, true),
              if (p.plus.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Everything in Purchase POS, plus', style: inter(14, 600, color: kMuted)),
                const SizedBox(height: 4),
                for (final f in p.plus) _feature(f, true),
              ],
              if (p.excludes.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Divider(color: kLine),
                const SizedBox(height: 10),
                Text('Not included in this plan', style: inter(14, 600, color: kMuted)),
                const SizedBox(height: 4),
                for (final f in p.excludes) _feature(f, false),
              ],
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: const Color(0xFFECEEEA), borderRadius: BorderRadius.circular(14)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(LucideIcons.info, size: 18, color: kMuted),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Prices are exclusive of taxes. Billed as a lump sum for the selected duration. No monthly plan.', style: inter(12.5, 500, color: kMuted, height: 1.4))),
                ]),
              ),
            ]),
      bottomNavigationBar: !_loaded
          ? null
          : SafeArea(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: sent != null
                    ? Container(
                        key: const ValueKey('plan-sent'),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(color: _wash, borderRadius: BorderRadius.circular(16)),
                        child: Row(children: [
                          const Icon(LucideIcons.circleCheck, color: _green),
                          const SizedBox(width: 10),
                          Expanded(child: Text('Request sent${sent.isEmpty ? '' : ' · $sent'}. The OneLocal team will call you to start it.', style: inter(13.5, 600))),
                        ]),
                      )
                    : FilledButton(
                        key: const ValueKey('plan-continue'),
                        style: FilledButton.styleFrom(backgroundColor: _deep, minimumSize: const Size.fromHeight(56), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                        onPressed: _busy ? null : _continue,
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Flexible(child: Text(_busy ? '…' : 'Continue with ${_cycle.months} months · ${planRupees(p.price(_cycle))}', overflow: TextOverflow.ellipsis, style: inter(15.5, 700, color: Colors.white))),
                          const SizedBox(width: 8),
                          const Icon(LucideIcons.arrowRight, color: Colors.white, size: 18),
                        ]),
                      ),
              ),
            ),
    );
  }

  Widget _duration(RstPlan p, PlanCycle c) {
    final on = c == _cycle;
    return Material(
      color: on ? _wash : Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        key: ValueKey('plan-cycle-${c.months}'),
        borderRadius: BorderRadius.circular(18),
        onTap: () => setState(() => _cycle = c),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: on ? _green : kLine, width: on ? 2 : 1)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('${c.months} months', style: inter(17, 800))),
              Icon(on ? LucideIcons.circleCheck : LucideIcons.circle, color: on ? _green : kMuted, size: 22),
            ]),
            if (c.freeMonths > 0) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(color: const Color(0xFFD7F0DD), borderRadius: BorderRadius.circular(20)),
                child: Text('${c.freeMonths} months free', style: inter(11.5, 700, color: _green)),
              ),
            ],
            const SizedBox(height: 8),
            Text('${planRupees(p.price(c))} total', key: ValueKey('plan-total-${c.months}'), style: inter(15, 800)),
            Text(c.freeMonths > 0 ? '${planRupees(p.effectivePerMonth(c))}/month (approx.)' : '${planRupees(p.perMonth)}/month', style: inter(12, 500, color: kMuted)),
          ]),
        ),
      ),
    );
  }

  Widget _feature(String f, bool yes) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Icon(yes ? LucideIcons.circleCheck : LucideIcons.circleX, size: 22, color: yes ? _green : const Color(0xFFB9BCC2)),
          const SizedBox(width: 12),
          Text(f, style: inter(15, 500, color: yes ? kInk : const Color(0xFF9CA3AF))),
        ]),
      );
}
