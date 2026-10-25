import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import 'stock_env.dart';
import 'stock_kit.dart';

/// Receive (J.100): count a delivery that has arrived, and see the latest deliveries and where each stands. Counting happens in
/// Receiving (shared with Purchase); stock goes up once the delivery is approved.
class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key, required this.env, this.itemId});
  final StockEnv env;
  final String? itemId;
  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  StockEnv get env => widget.env;
  List<Facts>? _docs;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await env.api.documents('receipt', limit: 20);
      if (mounted) {
        setState(() {
          _docs = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : 'Could not load deliveries. Pull down to try again.');
    }
  }

  Future<void> _receive() async {
    final open = env.onOpenReceiving;
    if (open == null) return showToast(context, 'Receiving is not available here.');
    open(context);
  }

  static (String, String) _state(String status) => switch (status) {
        'draft' => ('low', 'Being counted'),
        'review' || 'awaiting_approval' => ('near_expiry', 'Waiting for approval'),
        'posted' || 'completed' => ('healthy', 'In stock'),
        'cancelled' => ('', 'Cancelled'),
        _ => ('', status),
      };

  @override
  Widget build(BuildContext context) {
    final docs = _docs;
    return StockScaffold(
      env: env,
      title: 'Receive stock',
      line: 'When a delivery arrives, count what came and what was damaged. Stock goes up once it is approved.',
      onRefresh: _load,
      children: [
        InvPrimary('Receive a delivery', onPressed: _receive, key: const ValueKey('receive-start')),
        const SizedBox(height: 18),
        Text('Latest deliveries', style: inter(16, 700)),
        const SizedBox(height: 10),
        if (_error != null && docs == null)
          StockEmpty('Deliveries could not load', _error!, icon: LucideIcons.cloudOff, action: 'Try again', onAction: _load)
        else if (docs == null)
          const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
        else if (docs.isEmpty)
          const StockEmpty('No deliveries yet', 'Tap "Receive a delivery" when goods arrive.', icon: LucideIcons.truck)
        else
          for (final d in docs) _card(d),
      ],
    );
  }

  Widget _card(Facts d) {
    final (status, label) = _state(d.s('status'));
    final t = d.m('totals');
    final who = d.s('supplier_name');
    final first = d.s('first_item'), lines = t.n('lines').toInt();
    return InvCard(
      key: ValueKey('receipt-${d.s('id')}'),
      onTap: _receive,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d.s('doc_no'), style: inter(15.5, 700)),
              Text(
                [if (who.isNotEmpty) who, if (d.s('po_ref').isNotEmpty) 'Order ${d.s('po_ref')}', if (d.t('created_at') != null) dayMonth(d.t('created_at')!)].join(' · '),
                style: inter(12.5, 400, color: kMuted),
              ),
            ]),
          ),
          StockStatusChip(status, label: label),
        ]),
        const SizedBox(height: 8),
        if (first.isNotEmpty) StockRow('Products', lines > 1 ? '$first and ${lines - 1} more' : first),
        StockRow('Received', qty(t.n('received'))),
        if (t.n('rejected') > 0) StockRow('Damaged or rejected', qty(t.n('rejected')), color: kRedText),
      ]),
    );
  }
}
