import 'package:flutter/material.dart';

import '../inventory/inventory_api.dart';
import '../inventory/inventory_widgets.dart';
import '../ui/theme.dart';
import 'floor_screen.dart';
import 'table_order_screen.dart';
import 'table_widgets.dart';
import '../ui/motion.dart';

/// Figma "Table 12 Actions" (screen-actions-modal): Dine-In • Occupied • Bill Amount • Waiter, Open Existing Order, Transfer Table.
/// Transfer asks for the destination on the same grid, then "Confirm Table Transfer?" with Cancel / Confirm Transfer.
class ActionsScreen extends StatefulWidget {
  const ActionsScreen({super.key, required this.env, required this.tableId});
  final TablesEnv env;
  final String tableId;
  @override
  State<ActionsScreen> createState() => _ActionsScreenState();
}

class _ActionsScreenState extends State<ActionsScreen> {
  Facts? _v;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await widget.env.api.view(widget.tableId);
      if (mounted) {
        setState(() {
          _v = v;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = sayError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    final t = v?.m('table');
    final allowed = v?.ls('allowed') ?? const <String>[];
    final waiter = v?.so('waiter');
    final sub = v == null
        ? null
        : [
            'Dine-In',
            v.s('status') == 'occupied' ? 'Occupied' : tableLook(v.s('status')).$1[0] + tableLook(v.s('status')).$1.substring(1).toLowerCase(),
            'Bill Amount ${rupees(v.no('bill_total'))}',
            if (waiter != null && waiter.isNotEmpty) 'Waiter: $waiter',
          ].join(' • ');
    return TablesPage(
      env: widget.env,
      title: 'Table ${t?.s('label') ?? ''} Actions',
      subtitle: sub ?? ' ',
      back: true,
      onRefresh: _load,
      children: [
        if (v == null && _error == null) tablesLoading(),
        if (_error != null) TablesError(_error!, onRetry: _load),
        if (v != null) ...[
          if (allowed.contains('open_order'))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Material(
                color: kAvailBg,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: kAvailBorder, width: 2)),
                child: InkWell(
                  key: const ValueKey('action-open-order'),
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TableOrderScreen(env: widget.env, tableId: widget.tableId))),
                  child: Container(height: 62, alignment: Alignment.center, child: Text('Open Existing Order', style: inter(18, 700, color: kPostedText))),
                ),
              ),
            ),
          if (allowed.contains('transfer')) OutlineButtonT('Transfer Table', height: 62, onPressed: () => runTransfer(context, widget.env, from: t!, bill: v.no('bill_total'), then: _load)),
          if (allowed.isEmpty || (!allowed.contains('open_order') && !allowed.contains('transfer')))
            Padding(padding: const EdgeInsets.only(top: 12), child: Text('Nothing to do on this table right now.', style: inter(14, 400, color: kMuted))),
        ],
      ],
    );
  }
}

/// Transfer flow shared by the actions screen and the order screen ("Change Table"): choose the destination on the grid, confirm, move.
/// Returns true when the orders moved. [then] runs after a successful move.
Future<bool> runTransfer(BuildContext context, TablesEnv env, {required Facts from, num? bill, Future<void> Function()? then}) async {
  final nav = Navigator.of(context);
  final dest = await nav.push<Facts>(MaterialPageRoute(builder: (_) => FloorScreen(env: env, pickFor: from.s('id'), pickTitle: 'Transfer ${from.s('label')} to…')));
  if (dest == null || !context.mounted) return false;
  final yes = await showOlDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text('Confirm Table Transfer?', style: inter(22, 700)),
      content: Text(
        'You are about to transfer an order (${rupees(bill)}) from Table ${from.s('label')} to Table ${dest.s('label')}. '
        '${dest.s('status') == 'occupied' ? 'All existing open orders on Table ${dest.s('label')} will be consolidated.' : ''}',
        style: inter(16, 400, color: kMuted, height: 1.45),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      actions: [
        SizedBox(width: 120, child: OutlineButtonT('Cancel', height: 48, onPressed: () => Navigator.pop(ctx, false))),
        SizedBox(width: 190, child: LimeButton('Confirm Transfer', height: 48, onPressed: () => Navigator.pop(ctx, true))),
      ],
    ),
  );
  if (yes != true || !context.mounted) return false;
  try {
    final r = await env.api.transfer(from.s('id'), dest.s('id'));
    if (context.mounted) showToast(context, 'Moved ${r.n('moved_orders').toInt()} order${r.n('moved_orders') == 1 ? '' : 's'} to Table ${dest.s('label')}.');
    if (then != null) await then();
    return true;
  } catch (e) {
    if (context.mounted) showToast(context, sayError(e));
    return false;
  }
}
