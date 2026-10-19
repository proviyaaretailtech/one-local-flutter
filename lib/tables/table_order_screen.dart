import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart';
import '../inventory/inventory_widgets.dart';
import '../ui/theme.dart';
import 'actions_screen.dart';
import 'bill_api.dart';
import 'bill_pay_screen.dart';
import 'bill_widgets.dart' show billRouteName;
import 'guest_orders.dart';
import 'merge_screen.dart';
import 'table_widgets.dart';
import 'tables_api.dart';
import 'take_order_screens.dart';

/// Figma "Table T12 Order" (screen-order-detail): the open order of a table: status banner, items with kitchen status, operational timeline, subtotal,
/// Add Items, Send KOT, Print KOT, Change Table, Merge Table, Generate Bill. Which buttons work comes from the server (`can`); the ones it
/// switches off say why. Add Items opens Add dishes and Send KOT sends the held dishes (0485); Generate Bill uses the order status move.
/// switches off say why. Send KOT and Generate Bill use the existing order status move; the database checks the transition.
/// Generate Bill then opens the restaurant Checkout ("Bill and pay", 0550); once a bill is generated the button reads Take Payment.
class TableOrderScreen extends StatefulWidget {
  const TableOrderScreen({super.key, required this.env, required this.tableId, this.bill});
  final TablesEnv env;
  final String tableId;
  final BillApi? bill;
  @override
  State<TableOrderScreen> createState() => _TableOrderScreenState();
}

class _TableOrderScreenState extends State<TableOrderScreen> {
  Facts? _d;
  String? _error;
  bool _busy = false;
  final _guests = GlobalKey<GuestOrdersPanelState>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.env.api.orderView(widget.tableId);
      if (mounted) {
        setState(() {
          _d = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = sayError(e));
    }
    _guests.currentState?.reload();
  }

  Future<void> _handToGuest() async {
    await Navigator.of(context).push(GuestHostScreen.route(widget.env, widget.tableId));
    if (mounted) _load();
  }

  Future<bool> _move(Set<String> from, String to, String done) async {
    final d = _d!;
    var ok = false;
    setState(() => _busy = true);
    try {
      for (final o in d.l('orders').where((o) => from.contains(o.s('status')))) {
        await widget.env.api.setOrderStatus(o.s('id'), to, expectedUpdatedAt: o.so('updated_at'));
      }
      ok = true;
      if (mounted) showToast(context, done);
    } catch (e) {
      if (mounted) showToast(context, sayError(e));
    }
    if (mounted) setState(() => _busy = false);
    await _load();
    return ok;
  }

  /// Checkout for this table. "Back to tables" / "New Order" there answer 'tables': this screen then closes too, back to the floor.
  Future<void> _openBill() async {
    final r = await Navigator.of(context).push(MaterialPageRoute(
        settings: const RouteSettings(name: billRouteName), builder: (_) => BillPayScreen(env: widget.env, tableId: widget.tableId, bill: widget.bill ?? BillApi())));
    if (!mounted) return;
    if (r == 'tables') {
      Navigator.of(context).maybePop();
    } else {
      await _load();
    }
  }

  // Send KOT: the held dishes become a new KOT (tbl_kot_send). One key per tap, kept for a retry of that tap.
  String? _sendKey;
  Future<void> _sendHeld() async {
    final label = 'Table ${_d!.m('table').s('label')}';
    setState(() => _busy = true);
    try {
      final r = await widget.env.api.sendHeld(widget.tableId, key: _sendKey ??= TablesApi.newKey());
      _sendKey = null;
      if (mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SentToKitchenScreen(env: widget.env, tableLabel: label, kot: r.m('kot'))));
    } catch (e) {
      if (mounted) showToast(context, sayError(e));
    }
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  void _off(String key) => showToast(context, _d?.m('unavailable').so(key) ?? 'Not available right now.');

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final t = d?.m('table');
    final can = d?.m('can');
    final status = d?.mo('status');
    final items = d?.l('items') ?? const <Facts>[];
    final area = t?.so('area_name');
    OutlineButtonT btn(String label, String key, VoidCallback run) => OutlineButtonT(label, height: 56, enabledLook: can?.b(key) ?? false, onPressed: _busy ? null : () => can?.b(key) == true ? run() : _off(key));
    return TablesPage(
      env: widget.env,
      title: 'Table ${t?.s('label') ?? ''} Order',
      subtitle: t == null ? ' ' : [if (area != null && area.isNotEmpty) area, pax(t.n('seats'))].join(' • '),
      back: true,
      onRefresh: _load,
      children: [
        if (d == null && _error == null) tablesLoading(),
        if (_error != null) TablesError(_error!, onRetry: _load),
        if (d != null) ...[
          GuestOrdersPanel(key: _guests, env: widget.env, tableId: widget.tableId, onChanged: _load),
          if (status == null) Padding(padding: const EdgeInsets.all(24), child: Center(child: Text('No open order on this table.', style: inter(15, 400, color: kMuted)))),
          if (status != null)
            Container(
              height: 64,
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(color: kAvailBg, borderRadius: BorderRadius.circular(16), border: Border.all(color: kAvailBorder, width: 1.6)),
              child: Row(children: [
                Container(width: 40, height: 40, decoration: const BoxDecoration(color: kTableDot, shape: BoxShape.circle)),
                const SizedBox(width: 14),
                Text(status.s('label'), key: const ValueKey('order-banner'), style: inter(19, 700, color: kPostedText)),
              ]),
            ),
          for (final i in items)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(i.s('name'), style: inter(19, 600)),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(color: kBlueIconBg, borderRadius: BorderRadius.circular(8)),
                      child: Text(i.s('status_label'), style: inter(15, 500, color: kResText)),
                    ),
                  ]),
                ),
                Text('${qty(i.n('qty'))}x', style: inter(18, 500, color: kMuted)),
                const SizedBox(width: 18),
                Text(rupees(i.n('line_total')), style: inter(21, 700)),
              ]),
            ),
          if (d.l('timeline').isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 4, bottom: 16),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: kLine)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('OPERATIONAL TIMELINE', style: inter(17, 700, color: kMuted)),
                const SizedBox(height: 10),
                for (final e in d.l('timeline'))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text('• ${e.t('at') == null ? '' : '${clock12Padded(e.t('at')!)} — '}${e.s('message')}', style: inter(16, 400, color: kMuted)),
                  ),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(children: [
              Expanded(child: Text('Subtotal Amount:', style: inter(19, 500, color: kMuted))),
              Text(rupees(d.no('subtotal')), key: const ValueKey('order-subtotal'), style: inter(26, 700)),
            ]),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _limeOrOutline('Add Items', 'add_items', can, () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AddDishesScreen(env: widget.env, tableId: widget.tableId, tableLabel: 'Table ${t!.s('label')}')));
              if (mounted) _load();
            })),
            const SizedBox(width: 8),
            Expanded(child: btn('Send KOT', 'send_kot', _sendHeld)),
            const SizedBox(width: 8),
            Expanded(child: btn('Print KOT', 'print_kot', () {})),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: btn('Change Table', 'change_table', () => runTransfer(context, widget.env, from: t!, bill: d.no('subtotal'), then: _load))),
            const SizedBox(width: 8),
            Expanded(child: btn('Merge Table', 'merge_table', () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => MergeScreen(env: widget.env, startTableId: widget.tableId)));
              if (mounted) _load();
            })),
            const SizedBox(width: 8),
            Expanded(
              child: can?.b('generate_bill') != true && d.l('orders').any((o) => o.s('status') == 'awaiting_payment')
                  ? LimeButton('Take Payment', key: const ValueKey('take-payment'), height: 56, busy: _busy, onPressed: _openBill)
                  : LimeButton('Generate Bill', height: 56, busy: _busy, onPressed: can?.b('generate_bill') == true
                      ? () async {
                          if (await _move({'in_billing', 'sent_to_kitchen', 'ready', 'delivered'}, 'awaiting_payment', 'Bill generated.') && mounted) await _openBill();
                        }
                      : () => _off('generate_bill')),
            ),
          ]),
          const SizedBox(height: 8),
          // "Hand to guest": the guest orders on this phone with the table's published menu (0561, guest_staff_place)
          OutlineButtonT('Hand to guest', key: const ValueKey('hand-to-guest'), icon: LucideIcons.smartphone, dark: true, height: 56, onPressed: _busy ? null : _handToGuest),
        ],
      ],
    );
  }

  Widget _limeOrOutline(String label, String key, Facts? can, VoidCallback run) => LimeButton(label, height: 56, onPressed: can?.b(key) == true ? run : () => _off(key));
}
