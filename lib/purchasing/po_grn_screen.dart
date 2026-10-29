import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/net_guard.dart';
import '../home/home_nav.dart';
import '../inventory/inv_env.dart';
import '../inventory/inventory_widgets.dart';
import '../inventory/receiving_screen.dart';
import '../ui/mobile_input.dart';
import '../ui/theme.dart';
import '../ui/whatsapp_icon.dart';
import 'purchasing_api.dart';
import 'purchasing_widgets.dart';

/// Figma "Goods Receipt Note": one purchase order with what was ordered, received, accepted and rejected per line, tax and the GRN total.
/// "Confirm Receipt & Update Stock" starts (or reopens) the receipt draft for the order and hands over to section H's receiving screen, which
/// carries rejects, lots, expiry, review and posting. This screen never posts stock itself, and section G's approval gate still applies.
/// An approved order can be sent to the supplier on WhatsApp or SMS (0615): the number (the supplier's, when saved) is checked and the send
/// recorded by the database first, then the phone's app opens with the order.
class PoGrnScreen extends StatefulWidget {
  const PoGrnScreen({super.key, required this.env, required this.orderId, this.openUrl});
  final PurEnv env;
  final String orderId;

  /// Opens WhatsApp / the SMS app (tests pass a fake).
  final Future<bool> Function(Uri)? openUrl;
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
      setState(() => _error = errorSentence(e));
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
      if (mounted) showToast(context, errorSentence(e));
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
      if (mounted) showToast(context, errorSentence(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send(PurchaseOrder po, String channel) async {
    final c = TextEditingController(text: localMobile(po.supplierPhone));
    final to = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(channel == 'whatsapp' ? 'Send on WhatsApp' : 'Send by SMS', style: inter(18, 700)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${po.number} to ${po.supplierName}', style: inter(14, 500, color: kMuted)),
          TextField(key: const ValueKey('po-send-to'), controller: c, keyboardType: TextInputType.phone, inputFormatters: mobileFormatters, autofocus: true, decoration: const InputDecoration(hintText: 'Supplier mobile number', prefixText: kMobilePrefix)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          TextButton(key: const ValueKey('po-send-go'), onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Send')),
        ],
      ),
    );
    if (to == null || to.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final next = await env.api.send(po.id, channel: channel, to: to);
      if (!mounted) return;
      setState(() => _po = next);
      var digits = to.replaceAll(RegExp(r'\D'), '');
      if (digits.length == 10) digits = '91$digits';
      final text = Uri.encodeComponent(poText(next, from: HomeNav.storeName));
      final uri = channel == 'whatsapp' ? Uri.parse('https://wa.me/$digits?text=$text') : Uri.parse('sms:+$digits?body=$text');
      final open = widget.openUrl ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication);
      if (!await open(uri) && mounted) showToast(context, channel == 'whatsapp' ? 'WhatsApp could not be opened.' : 'The SMS app could not be opened.');
    } catch (e) {
      if (mounted) showToast(context, errorSentence(e));
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
      if (po.can('send') || po.sent != null) _SendCard(po: po, busy: _busy, onSend: po.can('send') ? (ch) => _send(po, ch) : null),
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

/// The order as the supplier reads it on WhatsApp / SMS: number, who it is from and for, delivery date, each item with quantity and rate,
/// the total with GST, and the note.
String poText(PurchaseOrder po, {String? from}) {
  final due = po.t('expected_delivery');
  final out = <String>[
    'Purchase Order ${po.number}',
    if (from != null && from.trim().isNotEmpty) 'From: ${from.trim()}',
    'To: ${po.supplierName}',
    if (due != null) 'Deliver by: ${dayMonth(due.toLocal(), year: true)}',
    '',
  ];
  var i = 0;
  for (final l in po.lines) {
    i++;
    out.add('$i. ${l.s('name')} - ${qty1(l.n('ordered_qty'))} ${unitWord(l.s('unit'))} @ ${money(l.n('unit_cost_minor'), fixed: true)}');
  }
  out
    ..add('')
    ..add('Total (incl. GST): ${money(po.totals.n('ordered_total_minor'), fixed: true)}');
  final notes = po.so('notes')?.trim() ?? '';
  if (notes.isNotEmpty) out.add('Note: $notes');
  out
    ..add('')
    ..add('Please confirm the order and the delivery time.');
  return out.join('\n');
}

/// "Send to supplier": WhatsApp and SMS buttons, and once sent, when and how (the number masked).
class _SendCard extends StatelessWidget {
  const _SendCard({required this.po, required this.busy, required this.onSend});
  final PurchaseOrder po;
  final bool busy;
  final void Function(String channel)? onSend;

  @override
  Widget build(BuildContext context) {
    final sent = po.sent;
    final at = sent?.t('at')?.toLocal();
    final times = sent?.n('times').toInt() ?? 0;
    Widget button(String channel, String label, Widget icon, Color bg, Color fg) => Expanded(
          child: Material(
            color: bg,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: bg == Colors.white ? const BorderSide(color: kCardLine) : BorderSide.none),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey('po-send-$channel'),
              onTap: busy || onSend == null ? null : () => onSend!(channel),
              child: SizedBox(
                height: 52,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [icon, const SizedBox(width: 8), Text(label, style: inter(15, 700, color: fg))]),
              ),
            ),
          ),
        );
    return InvCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(LucideIcons.send, size: 18, color: kInk),
          const SizedBox(width: 8),
          Expanded(child: Text('Send to supplier', style: inter(17, 700))),
          if (sent != null) PoChip('Sent', key: const ValueKey('po-sent-chip'), bg: const Color(0xFFDCFCE7), fg: const Color(0xFF15803D)),
        ]),
        const SizedBox(height: 4),
        Text(
          sent == null
              ? 'Send ${po.number} to ${po.supplierName}${po.supplierPhone == null ? '' : ' (${po.supplierPhone})'} with every item, rate and the delivery date.'
              : 'Sent on ${sent.s('channel') == 'whatsapp' ? 'WhatsApp' : 'SMS'} to ${sent.s('to')}${at == null ? '' : ' · ${dayMonth(at)} ${_clock(at)}'}${times > 1 ? ' · $times times' : ''}',
          key: const ValueKey('po-send-status'),
          style: inter(14, 400, color: kMuted),
        ),
        if (onSend != null) ...[
          const SizedBox(height: 12),
          Row(children: [
            button('whatsapp', sent == null ? 'WhatsApp' : 'Resend', const WhatsAppIcon(size: 22), kWhatsAppGreen, Colors.white),
            const SizedBox(width: 10),
            button('sms', 'SMS', const Icon(LucideIcons.messageSquareText, size: 20, color: Color(0xFF2563EB)), Colors.white, kInk),
          ]),
        ],
      ]),
    );
  }

  static String _clock(DateTime d) => '${d.hour % 12 == 0 ? 12 : d.hour % 12}:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}
