import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../guest/guest_api.dart';
import '../guest/guest_app.dart';
import '../inventory/inventory_api.dart';
import '../inventory/inventory_widgets.dart';
import '../ui/theme.dart';
import 'table_widgets.dart';

/// Guest orders sent from a table's QR code wait here until a member of staff accepts or declines them (spec D2). Accepting places the real
/// order as the signed-in person (`guest_request_decide` -> `pos_place_order`, placed by guest), so it then shows in Orders and the kitchen
/// like any other order. Declining needs a reason: the guest reads it on their phone.
class GuestOrdersPanel extends StatefulWidget {
  const GuestOrdersPanel({super.key, required this.env, this.tableId, this.onChanged, this.showEmpty = false});
  final TablesEnv env;

  /// One table only (the table order screen); null = the whole store.
  final String? tableId;

  /// After an accept or decline (the host reloads its own view).
  final VoidCallback? onChanged;
  final bool showEmpty;
  @override
  State<GuestOrdersPanel> createState() => GuestOrdersPanelState();
}

class GuestOrdersPanelState extends State<GuestOrdersPanel> {
  Facts? _d;
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    try {
      final d = await widget.env.qrApi.requests(widget.env.api.locationId, tableId: widget.tableId);
      if (mounted) setState(() => _d = d);
    } catch (_) {
      // a role that may not see guest orders, or no connection: the panel stays out of the way
      if (mounted) setState(() => _d = null);
    }
  }

  Future<void> _decide(Facts r, bool accept) async {
    String? reason;
    if (!accept) {
      reason = await _askReason(context);
      if (reason == null) return;
    }
    final id = r.s('id');
    setState(() => _busy.add(id));
    try {
      final res = await widget.env.qrApi.decide(widget.env.api.locationId, id, accept: accept, reason: reason);
      if (mounted) {
        showToast(context, accept ? 'Sent to the kitchen as ${res.m('order').so('display_no') ?? 'a new order'}.' : 'Declined. The guest sees your reason.');
      }
    } catch (e) {
      if (mounted) showToast(context, sayError(e));
    }
    if (mounted) setState(() => _busy.remove(id));
    await reload();
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final waiting = (d?.l('requests') ?? const <Facts>[]).where((r) => r.s('status') == 'waiting').toList();
    if (d == null || (waiting.isEmpty && !widget.showEmpty)) return const SizedBox.shrink();
    final canDecide = d.b('can_decide');
    return Container(
      key: const ValueKey('guest-orders'),
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: kAmberBgH, borderRadius: BorderRadius.circular(16), border: Border.all(color: kBusyBorder.withValues(alpha: 0.5))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(LucideIcons.qrCode, size: 18, color: kAmberText),
          const SizedBox(width: 8),
          Expanded(child: Text(waiting.isEmpty ? 'No guest orders waiting' : waiting.length == 1 ? '1 guest order waiting' : '${waiting.length} guest orders waiting', style: inter(16, 700, color: kAmberText))),
        ]),
        for (final r in waiting)
          Container(
            key: ValueKey('guest-request-${r.s('id')}'),
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(
                    ['Table ${r.m('table').s('label')}', if ((r.so('guest_name') ?? '').isNotEmpty) r.s('guest_name'), '${r.n('minutes_waiting').toInt()} min ago'].join(' · '),
                    style: inter(15, 700),
                  ),
                ),
                Text(rupees(r.n('estimated_total')), style: inter(15, 700)),
              ]),
              const SizedBox(height: 4),
              Text(r.l('lines').map((l) => '${l.n('qty').toInt()} × ${l.s('name')}${(l.so('notes') ?? '').isEmpty ? '' : ' (${l.s('notes')})'}').join(', '), style: inter(14, 400, color: kMuted)),
              if ((r.so('note') ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Note: ${r.s('note')}', style: inter(13.5, 500))),
              if (canDecide) ...[
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: OutlineButtonT('Decline', key: ValueKey('guest-decline-${r.s('id')}'), height: 46, onPressed: _busy.contains(r.s('id')) ? null : () => _decide(r, false))),
                  const SizedBox(width: 10),
                  Expanded(child: LimeButton('Accept', key: ValueKey('guest-accept-${r.s('id')}'), height: 46, busy: _busy.contains(r.s('id')), onPressed: () => _decide(r, true))),
                ]),
              ],
            ]),
          ),
      ]),
    );
  }
}

Future<String?> _askReason(BuildContext context) => askText(
      context,
      dialogKey: const ValueKey('decline-dialog'),
      fieldKey: const ValueKey('decline-reason'),
      confirmKey: const ValueKey('decline-confirm'),
      title: 'Decline this guest order?',
      body: 'The guest sees this reason on their phone.',
      hint: 'For example: the kitchen is closing',
      confirm: 'Decline',
      maxLength: 200,
      valid: (v) => v.trim().isNotEmpty,
    );

/// A small dialog that asks for one line of text; the confirm button works only when [valid] says so. Answers the trimmed text, or null.
Future<String?> askText(BuildContext context,
        {required Key dialogKey, required Key fieldKey, required Key confirmKey, required String title, required String body, String? hint, required String confirm, int? maxLength, required bool Function(String) valid}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _AskText(dialogKey: dialogKey, fieldKey: fieldKey, confirmKey: confirmKey, title: title, body: body, hint: hint, confirm: confirm, maxLength: maxLength, valid: valid),
    );

class _AskText extends StatefulWidget {
  const _AskText({required this.dialogKey, required this.fieldKey, required this.confirmKey, required this.title, required this.body, this.hint, required this.confirm, this.maxLength, required this.valid});
  final Key dialogKey, fieldKey, confirmKey;
  final String title, body, confirm;
  final String? hint;
  final int? maxLength;
  final bool Function(String) valid;
  @override
  State<_AskText> createState() => _AskTextState();
}

class _AskTextState extends State<_AskText> {
  final _ctl = TextEditingController();
  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        key: widget.dialogKey,
        title: Text(widget.title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.body, style: inter(14, 400, color: kMuted)),
          const SizedBox(height: 10),
          TextField(key: widget.fieldKey, controller: _ctl, maxLength: widget.maxLength, autofocus: true, onChanged: (_) => setState(() {}), decoration: InputDecoration(hintText: widget.hint)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(key: widget.confirmKey, onPressed: widget.valid(_ctl.text) ? () => Navigator.of(context).pop(_ctl.text.trim()) : null, child: Text(widget.confirm)),
        ],
      );
}

/// "Hand to guest": the guest screens on the staff phone for one table, with the table's published menu. Sending places the order at once
/// (placed by guest). "Back to staff" returns to the table.
class GuestHostScreen extends StatelessWidget {
  const GuestHostScreen({super.key, required this.gateway});
  final GuestGateway gateway;

  static Route<void> route(TablesEnv env, String tableId, {GuestGateway? gateway}) => MaterialPageRoute(
        fullscreenDialog: true,
        builder: (c) => GuestHostScreen(gateway: gateway ?? StaffGuestGateway(tableId: tableId, locationId: env.api.locationId)),
      );

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,   // the guest holds the phone: only "Back to staff" leaves
        child: GuestApp(gateway: gateway, onExit: () => Navigator.of(context).pop()),
      );
}
