import 'dart:async';

import 'package:flutter/material.dart';

import '../inventory/inventory_api.dart';
import '../inventory/inv_env.dart';
import '../inventory/inventory_widgets.dart';
import '../ui/theme.dart';
import 'po_create_screen.dart';
import 'po_grn_screen.dart';
import 'purchasing_api.dart';
import 'purchasing_widgets.dart';

/// Figma "Purchase History": search, status chips (All Orders / Open / Pending / Received), due chips (All / Open / Overdue), "+ New Order",
/// and every order with its lines and totals. The server filters and counts; the app only draws.
class PoHistoryScreen extends StatefulWidget {
  const PoHistoryScreen({super.key, required this.env});
  final PurEnv env;

  static const route = '/purchasing';
  static Route<void> pageRoute(PurEnv env) => MaterialPageRoute(settings: const RouteSettings(name: route), builder: (_) => PoHistoryScreen(env: env));

  @override
  State<PoHistoryScreen> createState() => _PoHistoryScreenState();
}

class _PoHistoryScreenState extends State<PoHistoryScreen> {
  PurEnv get env => widget.env;
  final _search = TextEditingController();
  Timer? _debounce;
  String _status = 'all', _due = 'all';
  Facts? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await env.api.orders(status: _status, due: _due, q: _search.text);
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

  void _filter(void Function() change) {
    setState(change);
    _load();
  }

  Future<void> _new() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PoCreateScreen(env: env)));
    if (mounted) _load();
  }

  Future<void> _open(PurchaseOrder po) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PoGrnScreen(env: env, orderId: po.id)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final open = _d?.n('open_count').toInt();
    return InvScaffold(env: env.inv, onRefresh: _load, children: [
      const InvTitle('Purchase History'),
      if (open != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Align(alignment: Alignment.centerLeft, child: PoChip('Open $open ${open == 1 ? 'order' : 'orders'}', bg: kMintBg, fg: kPostedText))),
      InvInput(
        controller: _search,
        hint: 'Search orders...',
        onChanged: (_) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 350), _load);
        },
      ),
      const SizedBox(height: 10),
      InvChips(
        items: const [('all', 'All Orders', null), ('open', 'Open', null), ('pending', 'Pending', null), ('received', 'Received', null)],
        active: _status,
        onTap: (id) => _filter(() => _status = id),
      ),
      InvChips(
        items: const [('all', 'All', null), ('open', 'Open', null), ('overdue', 'Overdue', null)],
        active: _due,
        onTap: (id) => _filter(() => _due = id),
      ),
      Row(children: [
        Expanded(child: InvPrimary('+ New Order', onPressed: _new)),
        const SizedBox(width: 10),
        Expanded(child: InvSecondary('More Filters', onPressed: () => showToast(context, 'More filters open in a later release.'))),
      ]),
      InvLoad<Facts>(data: _d, error: _error, onRetry: _load, builder: _orders),
    ]);
  }

  List<Widget> _orders(Facts d) {
    final orders = d.l('orders').map((f) => PurchaseOrder(f.raw)).toList();
    if (orders.isEmpty) return [InvCard(child: Text('No purchase orders match.', style: inter(14.5, 400, color: kMuted)))];
    return [
      for (final po in orders) ...[
        PoHeaderCard(po, onTap: () => _open(po)),
        for (final l in po.lines) PoLineCard(l, supplier: po.supplierName),
        PoTotalsCard(po),
      ],
    ];
  }
}
