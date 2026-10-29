import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import 'actions_screen.dart';
import 'bill_api.dart';
import 'bill_receipt_popup.dart';
import 'bill_pay_screen.dart';
import 'bill_widgets.dart' show billRouteName;
import 'guest_orders.dart';
import 'merge_screen.dart';
import 'table_widgets.dart';
import 'tables_api.dart';
import 'take_order_screens.dart';

/// Figma "Table T12 Order" (screen-order-detail), reworked 28 Oct 2026: the open order of a table drawn as its printed bill, with the order's actions under it:
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

  late final BillApi _billApi = widget.bill ?? BillApi();
  Facts? _bill; // the table's bill (`rst_bill_view`), drawn as the printed slip
  String? _billError;

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
    try {
      final b = await _billApi.view(widget.tableId);
      if (mounted) {
        setState(() {
          _bill = b;
          _billError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _billError = sayError(e));
    }
    _guests.currentState?.reload();
  }

  /// The bill shown: the one the server names current, else the one awaiting payment, else the oldest.
  Facts? get _billOrder {
    final v = _bill;
    if (v == null) return null;
    final orders = v.l('orders');
    return orders.where((o) => o.s('id') == v.so('current_order_id')).firstOrNull ??
        orders.where((o) => o.s('status') == 'awaiting_payment').firstOrNull ??
        orders.firstOrNull;
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
  Future<void> _openCheckout() async {
    final r = await Navigator.of(context).push(MaterialPageRoute(
        settings: const RouteSettings(name: billRouteName), builder: (_) => BillPayScreen(env: widget.env, tableId: widget.tableId, bill: _billApi)));
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
    final area = t?.so('area_name');
    final billOrder = _billOrder;
    Widget tile(String label, String key, IconData icon, Color tint, VoidCallback run, {Key? k}) => _ActionTile(
          key: k ?? ValueKey('act-$key'),
          label: label,
          icon: icon,
          tint: tint,
          enabled: can?.b(key) ?? false,
          onTap: _busy ? null : () => can?.b(key) == true ? run() : _off(key),
        );
    final billed = can?.b('generate_bill') != true && (d?.l('orders') ?? const <Facts>[]).any((o) => o.s('status') == 'awaiting_payment');
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
          // the bill is the page (founder, 28 Oct 2026); the order's timeline lives in Settings → Activity log
          if (status != null && billOrder != null && _bill != null) BillSlip(key: const ValueKey('order-bill'), view: _bill!, order: billOrder),
          if (status != null && billOrder == null && _billError != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(_billError!, textAlign: TextAlign.center, style: inter(14.5, 500, color: kMuted))),
          const SizedBox(height: 18),
          // Take Payment / Generate Bill first and widest, then the order's other actions as tiles
          _PayButton(
            key: ValueKey(billed ? 'take-payment' : 'generate-bill'),
            label: billed ? 'Take Payment' : 'Generate Bill',
            amount: billed && billOrder != null ? billOrder.n('due') : null,
            enabled: billed || can?.b('generate_bill') == true,
            busy: _busy,
            onTap: billed
                ? _openCheckout
                : can?.b('generate_bill') == true
                    ? () async {
                        if (await _move({'in_billing', 'sent_to_kitchen', 'ready', 'delivered'}, 'awaiting_payment', 'Bill generated.') && mounted) await _openCheckout();
                      }
                    : () => _off('generate_bill'),
          ),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.05,
            children: [
              tile('Add Items', 'add_items', LucideIcons.circlePlus, const Color(0xFF4D9A06), () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AddDishesScreen(env: widget.env, tableId: widget.tableId, tableLabel: 'Table ${t!.s('label')}')));
                if (mounted) _load();
              }),
              tile('Send KOT', 'send_kot', LucideIcons.send, const Color(0xFFEA580C), _sendHeld),
              tile('Print KOT', 'print_kot', LucideIcons.printer, const Color(0xFF2563EB), () {}),
              tile('Change Table', 'change_table', LucideIcons.arrowLeftRight, const Color(0xFF7C3AED), () => runTransfer(context, widget.env, from: t!, bill: d.no('subtotal'), then: _load)),
              tile('Merge Table', 'merge_table', LucideIcons.merge, const Color(0xFF0D9488), () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => MergeScreen(env: widget.env, startTableId: widget.tableId)));
                if (mounted) _load();
              }),
              // "Hand to guest": the guest orders on this phone with the table's published menu (0561, guest_staff_place)
              _ActionTile(key: const ValueKey('hand-to-guest'), label: 'Hand to guest', icon: LucideIcons.smartphone, tint: kInk, enabled: true, onTap: _busy ? null : _handToGuest),
            ],
          ),
        ],
      ],
    );
  }
}

/// The main action under the bill: a lime gradient bar with a soft glow, its icon in a dark badge, and the amount due once billed.
class _PayButton extends StatelessWidget {
  const _PayButton({super.key, required this.label, required this.enabled, required this.busy, required this.onTap, this.amount});
  final String label;
  final bool enabled, busy;
  final VoidCallback onTap;
  final num? amount;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: enabled ? 1 : .5,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(colors: [Color(0xFFA3F03C), Color(0xFF6FD80F)], begin: Alignment.topLeft, end: Alignment.bottomRight),
            boxShadow: enabled ? const [BoxShadow(color: Color(0x5577D81A), blurRadius: 18, offset: Offset(0, 8))] : null,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: busy ? null : onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 18, 12),
                child: Row(children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: kInk, borderRadius: BorderRadius.circular(14)),
                    child: busy
                        ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2.2, color: Color(0xFFA3F03C)))
                        : Icon(label == 'Take Payment' ? LucideIcons.wallet : LucideIcons.receiptText, size: 22, color: const Color(0xFFA3F03C)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: Text(label, style: inter(18, 800, color: kInk))),
                  if (amount != null) Text(rupees(amount), style: inter(18, 800, color: kInk)),
                  const SizedBox(width: 6),
                  const Icon(LucideIcons.chevronRight, size: 20, color: kInk),
                ]),
              ),
            ),
          ),
        ),
      );
}

/// One order action under the bill: a white card with its icon in a tinted circle and the name below; switched-off actions are faded
/// (a tap says why).
class _ActionTile extends StatelessWidget {
  const _ActionTile({super.key, required this.label, required this.icon, required this.tint, required this.enabled, required this.onTap});
  final String label;
  final IconData icon;
  final Color tint;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: enabled ? 1 : .45,
        child: Material(
          color: Colors.white,
          elevation: enabled ? 2 : 0,
          shadowColor: const Color(0x22000000),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: tint.withValues(alpha: .18))),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [tint.withValues(alpha: .2), tint.withValues(alpha: .08)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  ),
                  child: Icon(icon, size: 22, color: tint),
                ),
                const SizedBox(height: 8),
                Text(label, textAlign: TextAlign.center, maxLines: 2, style: inter(13.5, 700)),
              ]),
            ),
          ),
        ),
      );
}
