import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'service_api.dart';
import 'service_menu.dart';
import 'service_widgets.dart';

/// Figma 85 "Packages" and 86 "Memberships": prepaid plans sold to one customer. A plan's price is a catalogue item; selling one is an
/// ordinary paid order and gives that customer credits, which a booking spends. Every figure is the server's.
class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key, required this.api, required this.kind, this.business = '', this.onNavigate});
  final ServiceApi api;
  final String kind; // package | membership
  final String business;
  final ValueChanged<String>? onNavigate;
  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  PlanListData? _d;
  String? _error;
  String _q = '', _status = '';
  int _seq = 0;
  bool get _pkg => widget.kind == 'package';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mine = ++_seq;
    try {
      final d = await widget.api.plans(widget.kind, q: _q, status: _status.isEmpty ? null : _status);
      if (mounted && mine == _seq) setState(() { _d = d; _error = null; });
    } catch (e) {
      if (mounted && mine == _seq) setState(() => _error = e.toString());
    }
  }

  Future<void> _edit([SvcData? plan]) async {
    final d = _d;
    if (d == null) return;
    final saved = await Navigator.of(context).push<SvcData>(MaterialPageRoute(builder: (_) => PlanEditScreen(api: widget.api, kind: widget.kind, plan: plan, services: d.services, business: widget.business)));
    if (saved != null && mounted) _load();
  }

  Future<void> _tap(SvcData p) async {
    final canSell = p.s('status') == 'active';
    final pick = await showOrderSheet<String>(context, title: p.s('name'), body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (canSell) ...[DarkCta(label: 'Sell to a customer', onPressed: () => Navigator.pop(ctx, 'sell')), const SizedBox(height: 8)],
          if (_d?.canEdit == true) LightCta(label: 'Edit ${_pkg ? 'package' : 'membership'}', onPressed: () => Navigator.pop(ctx, 'edit')),
          if (!canSell) ...[const SizedBox(height: 8), Text('Make it active to sell it.', style: inter(13, 400, color: kMuted))],
        ]));
    if (!mounted || pick == null) return;
    if (pick == 'edit') return _edit(p);
    await _sell(p);
  }

  Future<void> _sell(SvcData p) async {
    final name = TextEditingController(), phone = TextEditingController();
    final ok = await showOrderSheet<bool>(context, title: 'Sell ${p.s('name')}', body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(key: const ValueKey('sell-name'), controller: name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(hintText: 'Customer name')),
          const SizedBox(height: 10),
          TextField(key: const ValueKey('sell-phone'), controller: phone, keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]')), LengthLimitingTextInputFormatter(16)], decoration: const InputDecoration(hintText: 'Mobile number (the credits belong to it)')),
          const SizedBox(height: 8),
          Text('One customer only. Unused credits are not refunded.', style: inter(12.5, 400, color: kMuted)),
          const SizedBox(height: 14),
          DarkCta(label: 'Next: payment', onPressed: () => Navigator.pop(ctx, true)),
        ]));
    if (ok != true || !mounted) return;
    var digits = phone.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 12 && digits.startsWith('91')) digits = digits.substring(2);
    if (name.text.trim().isEmpty || digits.length != 10) {
      showToast(context, 'Enter the customer\'s name and 10-digit mobile number.');
      return;
    }
    final pay = await pickPayment(context, title: 'Collect ${svcRupees(p.n('price'))} + GST', amount: p.n('price'));
    if (pay == null || !mounted) return;
    try {
      final e = await widget.api.sell(key: ServiceApi.newKey(), planId: p.s('id'), customerName: name.text.trim(), customerPhone: digits, method: pay.$1, tendered: pay.$2);
      if (mounted) showToast(context, '${e.name} sold to ${name.text.trim()}.');
      _load();
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (e) {
      if (mounted) showToast(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return ServicePage(
      title: _pkg ? 'Packages' : 'Memberships',
      subtitle: _pkg ? 'Bundles with prepaid service usage' : 'Recurring care plans · Renewed per customer',
      business: widget.business,
      onMenu: () => showServiceMenu(context, widget.api, business: widget.business, onNavigate: widget.onNavigate, current: _pkg ? 'packages' : 'memberships'),
      onNavigate: widget.onNavigate,
      onRefresh: _load,
      error: _error,
      onRetry: _load,
      body: d == null
          ? null
          : [
              if (!_pkg) ...[
                Row(children: [
                  Expanded(child: _tile('Active members', '${d.activeMembers}', '+${d.joinedThisMonth} this month')),
                  const SizedBox(width: 12),
                  Expanded(child: _tile('Monthly recurring', svcRupees(d.monthlyRecurring), 'Before GST')),
                ]),
                const SizedBox(height: 16),
              ],
              SvcSearch(hint: _pkg ? 'Search packages...' : 'Search membership plans...', fieldKey: const ValueKey('plan-search'), onChanged: (v) {
                _q = v;
                _load();
              }),
              const SizedBox(height: 14),
              if (_pkg)
                SvcChips(options: const [('', 'All packages'), ('active', 'Active'), ('draft', 'Draft')], selected: _status, onSelect: (v) {
                  _status = v;
                  _load();
                }),
              if (d.plans.isEmpty) OrderCardBox(child: Text(_q.isEmpty && _status.isEmpty ? 'None yet. Create the first one below.' : 'Nothing matches.', style: inter(14, 400, color: kMuted))),
              for (final p in d.plans) _pkg ? _package(p) : _membership(p),
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 4, 0, 16),
                child: Text(
                    _pkg ? 'Credits are redeemed only against included services. Unused credits expire at the end of validity.' : 'Prices exclude GST. Travel fees and replacement materials are billed separately for on-location jobs.',
                    style: inter(15, 400, color: kMuted, height: 1.45)),
              ),
              if (d.canEdit) DarkCta(label: _pkg ? '+ Create package' : '+ Create membership', onPressed: () => _edit()),
            ],
    );
  }

  Widget _tile(String label, String value, String note) => OrderCardBox(
        radius: 18,
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: inter(14, 400, color: kMuted)),
          const SizedBox(height: 8),
          Text(value, style: inter(28, 800)),
          const SizedBox(height: 6),
          Text(note, style: inter(13, 400, color: kLink)),
        ]),
      );

  Widget _chip(SvcData p) => Align(alignment: Alignment.centerLeft, child: svcStatus(p.s('status_label'), p.s('status') == 'active' ? 'good' : p.s('status') == 'paused' ? 'warn' : 'info'));

  Widget _package(SvcData p) => SvcCard(title: p.s('name'), onTap: () => _tap(p), children: [
        _chip(p),
        const SizedBox(height: 8),
        for (final it in p.l('items')) SvcLine(it.s('name'), qty: '${it.i('qty')}×', amount: svcRupees(it.n('amount'))),
        const Divider(height: 22, color: kLine),
        Row(children: [Expanded(child: Text('Package price', style: inter(18, 700))), Text(svcRupees(p.n('price')), style: inter(28, 800))]),
        const SizedBox(height: 6),
        SvcKV('Validity', '${p.i('validity_days')} days from purchase', labelWidth: 120),
        SvcKV('Usage limit', p.s('usage_note').isNotEmpty ? p.s('usage_note') : '${p.l('items').fold<int>(0, (a, it) => a + it.i('qty'))} visits · 1 credit per service', labelWidth: 120),
        if (p.n('savings') > 0) SvcKV('Savings', '${svcRupees(p.n('savings'))} vs individual prices', labelWidth: 120),
        if (p.s('exclusions').isNotEmpty) SvcKV('Exclusions', p.s('exclusions'), labelWidth: 120),
      ]);

  Widget _membership(SvcData p) {
    final per = p.s('period') == 'year' ? 'year' : 'month';
    final credits = p.l('items').map((it) => '${it.i('qty')} ${it.s('name').toLowerCase()}').join(' + ');
    return SvcCard(title: '${p.s('name')} · ${svcRupees(p.n('price'))} / $per', onTap: () => _tap(p), children: [
      _chip(p),
      const SizedBox(height: 8),
      SvcKV('Service credits', credits.isEmpty ? 'None' : '$credits / $per', labelWidth: 120),
      if (p.s('benefits').isNotEmpty) SvcKV('Benefits', p.s('benefits'), labelWidth: 120),
      if (p.n('discount_pct') > 0)
        SvcKV('Discount', '${p.n('discount_pct').toStringAsFixed(p.n('discount_pct') % 1 == 0 ? 0 : 1)}% off ${(p.so('discount_category') ?? 'other services').toLowerCase()}', labelWidth: 120),
      SvcKV('Validity', per == 'month' ? '${p.i('validity_days')}-day billing cycle' : '${p.i('validity_days')} days from activation', labelWidth: 120),
      if (p.s('credit_rules').isNotEmpty) SvcKV('Credit rules', p.s('credit_rules'), labelWidth: 120),
      if (p.s('renewal_note').isNotEmpty) SvcKV('Renewal', p.s('renewal_note'), labelWidth: 120),
    ]);
  }
}

/// Create or edit a package or membership (behind "+ Create package / membership").
class PlanEditScreen extends StatefulWidget {
  const PlanEditScreen({super.key, required this.api, required this.kind, this.plan, required this.services, this.business = ''});
  final ServiceApi api;
  final String kind, business;
  final SvcData? plan;
  final List<SvcData> services;
  @override
  State<PlanEditScreen> createState() => _PlanEditScreenState();
}

class _PlanEditScreenState extends State<PlanEditScreen> {
  late final p = widget.plan;
  late final _name = TextEditingController(text: p?.s('name') ?? '');
  late final _price = TextEditingController(text: p == null ? '' : p!.n('price').toString());
  late final _validity = TextEditingController(text: p == null ? (widget.kind == 'package' ? '90' : '30') : '${p!.i('validity_days')}');
  late final _usage = TextEditingController(text: p?.s('usage_note') ?? '');
  late final _excl = TextEditingController(text: p?.s('exclusions') ?? '');
  late final _benefits = TextEditingController(text: p?.s('benefits') ?? '');
  late final _discount = TextEditingController(text: p == null ? '0' : p!.n('discount_pct').toString());
  late final _discCat = TextEditingController(text: p?.so('discount_category') ?? '');
  late final _rules = TextEditingController(text: p?.s('credit_rules') ?? (widget.kind == 'membership' ? 'No rollover · Member only' : ''));
  late final _renewal = TextEditingController(text: p?.s('renewal_note') ?? '');
  late String _status = p?.s('status') ?? 'draft';
  late String _period = p?.so('period') ?? 'month';
  late final Map<String, int> _qty = {for (final it in p?.l('items') ?? <SvcData>[]) it.s('service_id'): it.i('qty')};
  String? _key;
  bool _busy = false;

  Future<void> _save() async {
    final price = num.tryParse(_price.text.trim());
    if (_name.text.trim().length < 2 || price == null) {
      showToast(context, 'Enter the name and the price.');
      return;
    }
    setState(() => _busy = true);
    _key ??= ServiceApi.newKey();
    try {
      final saved = await widget.api.savePlan({
        'id': p?.s('id'),
        'kind': widget.kind,
        'name': _name.text.trim(),
        'price': price,
        'status': _status,
        'validity_days': int.tryParse(_validity.text.trim()),
        if (widget.kind == 'membership') 'period': _period,
        'usage_note': _usage.text.trim(),
        'exclusions': _excl.text.trim(),
        'benefits': _benefits.text.trim(),
        'discount_pct': num.tryParse(_discount.text.trim()) ?? 0,
        'discount_category': _discCat.text.trim().isEmpty ? null : _discCat.text.trim(),
        'credit_rules': _rules.text.trim(),
        'renewal_note': _renewal.text.trim(),
        'items': [for (final e in _qty.entries) if (e.value > 0) {'service_id': e.key, 'qty': e.value}],
      }, key: _key!);
      if (mounted) Navigator.of(context).pop(saved);
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
      if (e.status < 500) _key = null;
    } catch (e) {
      if (mounted) showToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _f(String label, TextEditingController c, {TextInputType keyboard = TextInputType.text}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: inter(13, 600, color: kMuted)),
          const SizedBox(height: 6),
          TextField(key: ValueKey('plan-$label'), controller: c, keyboardType: keyboard, onChanged: (_) => _key = null),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final pkg = widget.kind == 'package';
    return ServicePage(
      title: '${p == null ? 'Create' : 'Edit'} ${pkg ? 'package' : 'membership'}',
      subtitle: pkg ? 'Prepaid services for one customer' : 'A care plan for one customer',
      business: widget.business,
      body: [
        SvcCard(children: [
          _f('Name', _name),
          _f('Price (₹, before GST)', _price, keyboard: TextInputType.number),
          if (!pkg)
            SvcChips(options: const [('month', 'Monthly'), ('year', 'Yearly')], selected: _period, onSelect: (v) => setState(() {
                  _period = v;
                  _validity.text = v == 'year' ? '365' : '30';
                  _key = null;
                })),
          _f('Validity (days)', _validity, keyboard: TextInputType.number),
          SvcChips(options: const [('draft', 'Draft'), ('active', 'Active'), ('paused', 'Paused')], selected: _status, onSelect: (v) => setState(() {
                _status = v;
                _key = null;
              })),
        ]),
        SvcCard(title: 'Included services', children: [
          if (widget.services.isEmpty) Text('Add services to the catalogue first.', style: inter(14, 400, color: kMuted)),
          for (final s in widget.services)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: Text('${s.s('name')} · ${svcRupees(s.n('price'))}', style: inter(14.5, 500))),
                QtyStepper(
                  name: s.s('name'),
                  qty: _qty[s.s('id')] ?? 0,
                  onMinus: () => setState(() {
                    _qty[s.s('id')] = ((_qty[s.s('id')] ?? 0) - 1).clamp(0, 50);
                    _key = null;
                  }),
                  onPlus: () => setState(() {
                    _qty[s.s('id')] = ((_qty[s.s('id')] ?? 0) + 1).clamp(0, 50);
                    _key = null;
                  }),
                ),
              ]),
            ),
        ]),
        SvcCard(title: 'Rules shown to staff', children: [
          if (pkg) ...[_f('Usage limit', _usage), _f('Exclusions', _excl)],
          if (!pkg) ...[_f('Benefits', _benefits), _f('Discount % on other services', _discount, keyboard: TextInputType.number), _f('Discount applies to category', _discCat), _f('Renewal', _renewal)],
          _f('Credit rules', _rules),
        ]),
        DarkCta(label: 'Save', busy: _busy, onPressed: _busy ? null : _save),
      ],
    );
  }
}
