import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';
import 'adjustment_screen.dart';
import 'audit_screen.dart';
import 'forecast_screen.dart';
import 'inventory_api.dart';
import 'inventory_widgets.dart';
import 'receiving_screen.dart';
import 'stock_detail_screen.dart';
import 'stock_list_screen.dart';
import 'transfer_screen.dart';

/// What every section H screen shares: the API and the ways out of the section (other bottom-bar tabs, the linked order, Items, bell).
class InvEnv {
  InvEnv({InventoryApi? api, this.onNavigate, this.onOpenOrder, this.onItems, this.onBell}) : api = api ?? InventoryApi();
  final InventoryApi api;

  /// Bottom-bar tabs this section does not own: 'home', 'item', 'bill', 'online'.
  final ValueChanged<String>? onNavigate;

  /// Opens a linked order (Movement Detail "Open Linked Transaction").
  final void Function(BuildContext context, String orderId)? onOpenOrder;
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

/// Figma "Inventory Dashboard": stock overview, needs attention, quick actions, tools and planning for one store.
class InventoryDashboard extends StatefulWidget {
  const InventoryDashboard({super.key, required this.env});
  final InvEnv env;

  /// The section's entry route (the bottom-bar "Stock" tab returns here).
  static Route<void> route(InvEnv env) =>
      MaterialPageRoute(settings: const RouteSettings(name: InvEnv.dashboardRoute), builder: (_) => InventoryDashboard(env: env));

  @override
  State<InventoryDashboard> createState() => _InventoryDashboardState();
}

class _InventoryDashboardState extends State<InventoryDashboard> {
  InvEnv get env => widget.env;
  Facts? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await env.api.dashboard();
      if (!mounted) return;
      setState(() {
        _d = d;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _go(Widget screen) async {
    await env.push(context, screen);
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) => InvScaffold(
        env: env,
        onRefresh: _load,
        children: [
          InvLoad<Facts>(data: _d, error: _error, onRetry: _load, builder: _body),
        ],
      );

  List<Widget> _body(Facts d) {
    final c = d.m('counts');
    final at = d.t('snapshot_at');
    final low = d.m('low'), exp = d.m('expiry'), dmg = d.m('damaged'), dis = d.m('discrepancies');
    final head = d.mo('headline');
    final repl = d.l('replenishment');
    final fc = d.mo('forecast');
    final pos = d.m('positioning');
    return [
      InvTitle('Inventory Dashboard',
          subtitle: [if (at != null) '${dayMonth(at, year: true)} · ${hm(at)} snapshot', d.m('location').s('name'), '${qty(c.n('total'))} items'].join(' · ')),
      InvSection('Stock Overview', note: '${qty(c.n('healthy'))} healthy · filters may overlap'),
      InvTiles([
        _tap(InvStatTile(qty(c.n('total')), 'Total items'), () => _go(StockListScreen(env: env))),
        _tap(InvStatTile(qty(c.n('low')), 'Low Stock', color: kAmberText), () => _go(StockListScreen(env: env, filter: 'low'))),
        _tap(InvStatTile(qty(c.n('critical')), 'Critical', color: kRedText), () => _go(StockListScreen(env: env, filter: 'critical'))),
      ]),
      const SizedBox(height: 4),
      const InvSection('Needs Attention'),
      InvCard(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        margin: const EdgeInsets.only(bottom: 6),
        child: Column(children: [
          _attention(LucideIcons.triangleAlert, kAmberBgH, kAmberText, 'Low stock · ${qty(low.n('count'))} items',
              low.l('top').map((t) => '${t.s('name')} ${units(t.n('available'), t.s('unit'))}').join(' · '), low.n('count'), kAmberBgH, kAmberText,
              () => _go(StockListScreen(env: env, filter: 'low'))),
          _attention(LucideIcons.clock, kRedBgH, kRedText, 'Expiry risks · next 7 days',
              exp.l('top').map((t) => '${t.s('name')} ${_expires(t.t('expiry_date'))}').join(' · '), exp.n('count'), kRedBgH, kRedText,
              () => _go(StockListScreen(env: env, filter: 'near_expiry'))),
          _attention(LucideIcons.circleX, kRedBgH, kRedText, 'Damaged stock quarantined',
              dmg.l('top').map((t) => '${qty(t.n('units'))}u ${t.s('name')}${t.so('bin_code') == null ? '' : ' ${t.s('bin_code')}'}').join(' · '), dmg.n('count'), kRedBgH, kRedText,
              dmg.l('top').isEmpty ? null : () => _go(StockDetailScreen(env: env, itemId: dmg.l('top').first.s('id')))),
          _attention(LucideIcons.fileText, kGreyBg, kMuted, 'Outstanding discrepancies', dis.l('items').map(_discrepancy).join(' · '), dis.n('count'), kGreyBg, kInk,
              dis.l('items').isEmpty ? null : () => _openDoc(dis.l('items').first), last: true),
        ]),
      ),
      if (head != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 4),
          child: Text(
              '${head.s('name')}: ${units(head.n('available'), head.s('unit'))}${head.no('stock_days') == null ? '' : ' · ${qty(head.n('stock_days'))} days cover'}'
              '${head.n('inbound') > 0 ? ' · ${qty(head.n('inbound'))} inbound' : ''}${head.t('eta') == null ? '' : ', ETA ${dayMonth(head.t('eta')!)}'}.',
              style: inter(13, 400, color: kMuted, height: 1.45)),
        ),
      const InvSection('Quick Actions'),
      _grid([
        _QuickTile(icon: LucideIcons.package, label: 'Receive Stock', dark: true, onTap: () => _go(ReceivingScreen(env: env))),
        _QuickTile(icon: LucideIcons.archive, label: 'View Inventory', onTap: () => _go(StockListScreen(env: env))),
        _QuickTile(icon: LucideIcons.move, label: 'Transfer Stock', onTap: () => _go(TransferScreen(env: env))),
        _QuickTile(icon: LucideIcons.slidersVertical, label: 'Stock Adjustment', onTap: () => _go(AdjustmentScreen(env: env))),
        _QuickTile(icon: LucideIcons.clipboardCheck, label: 'Start Stock Audit', onTap: () => _go(AuditScreen(env: env))),
      ]),
      const InvSection('Inventory Tools'),
      _grid([
        _ToolTile(icon: LucideIcons.calendar, iconColor: kRedText, label: 'Expiry', onTap: () => _go(StockListScreen(env: env, filter: 'near_expiry'))),
        _ToolTile(icon: LucideIcons.bookmark, label: 'Reservations', onTap: () => env.later(context, 'Reservations')),
        _ToolTile(icon: LucideIcons.building, label: 'Warehouse', onTap: () => env.later(context, 'Warehouse')),
        _ToolTile(icon: LucideIcons.mapPin, label: 'Locations', onTap: () => env.later(context, 'Locations')),
        _ToolTile(icon: LucideIcons.layers, label: 'Batch / Lot Tracking', onTap: () => env.later(context, 'Batch / lot tracking')),
        _ToolTile(icon: LucideIcons.activity, label: 'Movement History', onTap: () => env.later(context, 'Movement history')),
      ], tool: true),
      const InvSection('Planning'),
      InvCard(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: Column(children: [
          _plan(LucideIcons.shoppingCart, kGreenIconBg, kPostedText, 'Replenishment',
              repl.isEmpty ? 'Nothing to reorder now' : repl.take(2).map((r) => '${_short(r.s('name'))} ${qty(r.n('suggest'))}u ${r.b('urgent') ? 'urgent' : 'suggested'}').join(' · '),
              () => env.later(context, 'Replenishment')),
          _plan(LucideIcons.trendingUp, kBlueIconBg, kBlueIcon, 'Inventory Forecast',
              fc == null ? 'No recent sales to project from' : '${_short(fc.s('name'))} ${qty(fc.n('end_stock'))}u end-stock${fc.b('shortfall_at_plus20') ? ' · +20% demand = shortfall' : ''}',
              () => _go(ForecastScreen(env: env, itemId: fc?.s('id')))),
          _plan(LucideIcons.circleAlert, kAmberBgH, kAmberText, 'Stock Risk', '${qty(c.n('critical'))} critical · ${qty(c.n('low'))} low · review expiry separately',
              () => _go(StockListScreen(env: env, filter: 'critical'))),
          _plan(LucideIcons.chartNoAxesColumn, kGreyBg, kInk, 'Inventory Positioning',
              '${qty(pos.n('free'))} free · ${qty(pos.n('inbound'))} inbound · ${qty(pos.n('total'))} nominal total', () => env.later(context, 'Inventory positioning'),
              last: true),
        ]),
      ),
      InvFootnote(at: at),
    ];
  }

  Widget _tap(Widget child, VoidCallback onTap) => Semantics(button: true, child: InkWell(borderRadius: BorderRadius.circular(18), onTap: onTap, child: child));

  static String _short(String name) => name.split(' ').first;

  static String _expires(DateTime? d) {
    if (d == null) return '';
    return d.isBefore(DateUtils.dateOnly(DateTime.now())) ? 'expired ${dayMonth(d)}' : 'expires ${dayMonth(d)}';
  }

  static String _discrepancy(Facts x) {
    final no = x.s('doc_no');
    if (x.s('doc_type') == 'audit') return '$no ${signed(x.n('variance'))}u ${x.s('status') == 'draft' ? 'draft' : 'in review'}';
    return '$no ${qty(x.n('rejected'))} rejects unposted';
  }

  void _openDoc(Facts x) => _go(x.s('doc_type') == 'audit' ? AuditScreen(env: env, documentId: x.s('id')) : ReceivingScreen(env: env, documentId: x.s('id')));

  Widget _attention(IconData icon, Color iconBg, Color iconFg, String title, String sub, num count, Color badgeBg, Color badgeFg, VoidCallback? onTap, {bool last = false}) =>
      Semantics(
        button: onTap != null,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: Color(0xFFF0F1EC)))),
            child: Row(children: [
              Container(width: 34, height: 34, decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(10)), child: Icon(icon, size: 18, color: iconFg)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: inter(15, 600)),
                  if (sub.isNotEmpty) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12.5, 400, color: kMuted)),
                ]),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
                decoration: BoxDecoration(color: badgeBg, borderRadius: BorderRadius.circular(999)),
                child: Text(qty(count), style: inter(12, 700, color: badgeFg)),
              ),
            ]),
          ),
        ),
      );

  Widget _plan(IconData icon, Color bg, Color fg, String title, String sub, VoidCallback onTap, {bool last = false}) => Semantics(
        button: true,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: Color(0xFFF0F1EC)))),
            child: Row(children: [
              Container(width: 40, height: 40, decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)), child: Icon(icon, size: 20, color: fg)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: inter(15.5, 600)),
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12.5, 400, color: kMuted)),
                ]),
              ),
              const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
            ]),
          ),
        ),
      );

  Widget _grid(List<Widget> tiles, {bool tool = false}) {
    final rows = <Widget>[];
    for (var i = 0; i < tiles.length; i += 3) {
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var j = i; j < i + 3; j++) ...[if (j > i) const SizedBox(width: 9), Expanded(child: j < tiles.length ? tiles[j] : const SizedBox())],
          ]),
        ),
      ));
    }
    return Column(children: rows);
  }
}

class _QuickTile extends StatelessWidget {
  const _QuickTile({required this.icon, required this.label, required this.onTap, this.dark = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool dark;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: Material(
          color: dark ? kPrimary : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: dark ? kPrimary : kCardLine)),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 6),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 22, color: dark ? kLimeH : kInk),
                const SizedBox(height: 10),
                Text(label, textAlign: TextAlign.center, style: inter(13.5, 600, color: dark ? kLimeH : kInk)),
              ]),
            ),
          ),
        ),
      );
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.icon, required this.label, required this.onTap, this.iconColor = kInk});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color iconColor;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: kCardLine)),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 20, color: iconColor),
                const SizedBox(height: 8),
                Text(label, style: inter(13.5, 600)),
              ]),
            ),
          ),
        ),
      );
}
