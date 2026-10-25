import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import 'prices_common.dart' show loadAllStock;
import 'stock_env.dart';
import 'stock_kit.dart';

/// Alerts (J.106): everything that needs a look, in one list — low stock, expiry, products not selling, and counts or deliveries
/// that do not match. Each alert says what is wrong and opens the tab that fixes it.
class StockAlertsScreen extends StatefulWidget {
  const StockAlertsScreen({super.key, required this.env, this.itemId});
  final StockEnv env;
  final String? itemId;
  @override
  State<StockAlertsScreen> createState() => _StockAlertsScreenState();
}

/// One alert: its kind (low / expiry / no_sale / mismatch), the product or document, what is wrong, and where to fix it.
typedef _Alert = ({String kind, String title, String line, String action, String page, String? itemId, bool urgent});

class _StockAlertsScreenState extends State<StockAlertsScreen> {
  StockEnv get env => widget.env;
  List<_Alert>? _alerts;
  String? _error;
  String _show = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final stock = (await loadAllStock(env.api)).items;
      final dash = await env.api.dashboard();
      if (!mounted) return;
      setState(() {
        _alerts = _build(stock, dash);
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : 'Could not load alerts. Pull down to try again.');
    }
  }

  List<_Alert> _build(List<Facts> stock, Facts dash) {
    String u(Facts it, num n) => units(n, it.s('unit').isEmpty ? 'unit' : it.s('unit'));
    final out = <_Alert>[];
    for (final it in stock) {
      final status = it.s('status'), id = it.s('id');
      if (status == 'out' || status == 'critical' || status == 'low') {
        out.add((
          kind: 'low',
          title: it.s('name'),
          line: status == 'out' ? 'Out of stock' : 'Only ${u(it, it.n('available'))} left${it.no('stock_days') == null ? '' : ' · lasts about ${qty(it.n('stock_days'))} days'}',
          action: 'Reorder',
          page: StockPage.reorder,
          itemId: id,
          urgent: status != 'low',
        ));
      }
      final days = it.no('expiry_days');
      if (days != null && days <= 7) {
        out.add((
          kind: 'expiry',
          title: it.s('name'),
          line: days < 0 ? 'Expired — do not sell' : days == 0 ? 'Expires today — sell first' : 'Expires in ${days.round()} days — sell first',
          action: days < 0 ? 'Throw away' : 'See product',
          page: days < 0 ? StockPage.adjust : StockPage.item,
          itemId: id,
          urgent: days <= 2,
        ));
      }
      // in stock but nothing sold lately: no daily demand means no "lasts about" figure
      if (it.n('available') > 0 && it.no('stock_days') == null && status != 'out') {
        out.add((kind: 'no_sale', title: it.s('name'), line: '${u(it, it.n('available'))} in stock, no sales lately', action: 'See movements', page: StockPage.movements, itemId: id, urgent: false));
      }
    }
    for (final d in dash.m('discrepancies').l('items')) {
      final audit = d.s('doc_type') == 'audit';
      out.add((
        kind: 'mismatch',
        title: d.s('doc_no'),
        line: audit ? 'Count differs from the app by ${signed(d.n('variance'))}' : '${qty(d.n('rejected'))} units damaged or rejected in a delivery',
        action: audit ? 'Fix it in Adjust' : 'Open Purchase',
        page: audit ? StockPage.adjust : StockPage.receive,
        itemId: null,
        urgent: false,
      ));
    }
    out.sort((a, b) => (a.urgent == b.urgent) ? 0 : (a.urgent ? -1 : 1));
    return out;
  }

  static const _labels = {'low': 'Low stock', 'expiry': 'Expiry', 'no_sale': 'Not selling', 'mismatch': 'Mismatch'};
  static const _icons = {'low': LucideIcons.trendingDown, 'expiry': LucideIcons.calendarClock, 'no_sale': LucideIcons.moon, 'mismatch': LucideIcons.scale};

  @override
  Widget build(BuildContext context) {
    final all = _alerts;
    final shown = all == null ? const <_Alert>[] : _show == 'all' ? all : all.where((a) => a.kind == _show).toList();
    int n(String k) => all?.where((a) => a.kind == k).length ?? 0;
    return StockScaffold(
      env: env,
      title: 'Alerts',
      line: 'Things that need a look. Tap one to fix it.',
      onRefresh: _load,
      children: [
        InvChips(
          items: [('all', 'All', all?.length), for (final k in _labels.keys) (k, _labels[k]!, n(k))],
          active: _show,
          onTap: (k) => setState(() => _show = k),
        ),
        const SizedBox(height: 14),
        if (_error != null && all == null)
          StockEmpty('Alerts could not load', _error!, icon: LucideIcons.cloudOff, action: 'Try again', onAction: _load)
        else if (all == null)
          const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
        else if (shown.isEmpty)
          const StockEmpty('All clear', 'Nothing needs a look here right now.', icon: LucideIcons.circleCheck)
        else
          for (final a in shown) _card(a),
      ],
    );
  }

  Widget _card(_Alert a) => InvCard(
        key: ValueKey('alert-${a.kind}-${a.itemId ?? a.title}'),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: a.urgent ? kRedBgH : kAmberBgH, borderRadius: BorderRadius.circular(12)),
            child: Icon(_icons[a.kind], size: 18, color: a.urgent ? kRedText : kAmberText),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_labels[a.kind]!.toUpperCase(), style: inter(11, 700, color: a.urgent ? kRedText : kAmberText)),
              Text(a.title, style: inter(15, 700)),
              Text(a.line, style: inter(13, 400, color: kMuted, height: 1.35)),
              const SizedBox(height: 6),
              InkWell(
                onTap: () => env.open(context, a.page, itemId: a.itemId),
                child: Text('${a.action} ›', style: inter(13.5, 700, color: kLink)),
              ),
            ]),
          ),
        ]),
      );
}
