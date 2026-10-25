import 'package:flutter/material.dart';

import '../inventory/inv_env.dart';
import '../inventory/inventory_widgets.dart';
import '../inventory/receiving_screen.dart';
import '../ui/theme.dart';
import 'purchasing_api.dart';
import 'purchasing_widgets.dart';

/// Figma "Goods Receipt Note": one purchase order with what was ordered, received, accepted and rejected per line, tax and the GRN total.
/// "Confirm Receipt & Update Stock" starts (or reopens) the receipt draft for the order and hands over to section H's receiving screen, which
/// carries rejects, lots, expiry, review and posting. This screen never posts stock itself, and section G's approval gate still applies.
class PoGrnScreen extends StatefulWidget {
  const PoGrnScreen({super.key, required this.env, required this.orderId});
  final PurEnv env;
  final String orderId;
  @override
  State<PoGrnScreen> createState() => _PoGrnScreenState();
}

class _PoGrnScreenState extends State<PoGrnScreen> {
  PurEnv get env => widget.env;
  PurchaseOrder? _po;
  String? _error;
  bool _busy = false;
  late String _key = PurchasingApi.newKey();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final po = await env.api.order(widget.orderId);
      if (!mounted) return;
      setState(() {
        _po = po;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _confirm() async {
    setState(() => _busy = true);
    try {
      final r = await env.api.receive(widget.orderId, key: _key);
      _key = PurchasingApi.newKey();
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReceivingScreen(env: env.inv, documentId: r.s('document_id'))));
      await _load();
    } catch (e) {
      if (mounted) showToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _act(String action, String done) async {
    setState(() => _busy = true);
    try {
      final po = await env.api.act(widget.orderId, action);
      if (!mounted) return;
      setState(() => _po = po);
      showToast(context, done);
    } catch (e) {
      if (mounted) showToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => InvScaffold(env: env.inv, onRefresh: _load, children: [
        const InvTitle('Goods Receipt Note'),
        InvLoad<PurchaseOrder>(data: _po, error: _error, onRetry: _load, builder: _body),
      ]);

  List<Widget> _body(PurchaseOrder po) {
    final discrepancy = po.lines.any((l) => l.so('tag') == 'discrepancy');
    final draft = po.openReceipt;
    return [
      if (discrepancy) const Padding(padding: EdgeInsets.only(bottom: 10), child: Align(alignment: Alignment.centerLeft, child: PoChip('Discrepancy', bg: kRedBgH, fg: kRedText))),
      PoHeaderCard(po),
      for (final l in po.lines) PoLineCard(l, supplier: po.supplierName),
      PoTotalsCard(po),
      if (draft != null) InvNote('A receipt (${draft.s('doc_no')}) is waiting in ${draft.s('status') == 'review' ? 'purchase review' : 'draft'}. Stock changes only when it is posted.'),
      if (po.canReceive) InvPrimary('Confirm Receipt & Update Stock', busy: _busy, onPressed: _confirm),
      if (po.status == 'Pending' && !po.can('approve') && po.can('reject')) InvNote('You raised this order and it is above ${money(po.n('self_approval_limit_minor'))}: someone else approves it.'),
      if (po.status == 'Draft' || po.status == 'Pending') InvNote(po.status == 'Draft' ? 'A draft is not sent for approval yet.' : 'Waiting for approval. Goods can be received once it is approved.'),
      if (po.can('submit')) InvSecondary('Submit for approval', onPressed: _busy ? null : () => _act('submit', 'Submitted for approval.')),
      if (po.can('approve')) InvPrimary('Approve order', busy: _busy, onPressed: () => _act('approve', 'Approved.')),
      if (po.can('reject')) InvSecondary('Reject', onPressed: _busy ? null : () => _act('reject', 'Rejected.')),
      if (po.can('cancel')) InvSecondary('Cancel order', onPressed: _busy ? null : () => _act('cancel', 'Order cancelled.')),
    ];
  }
}
