import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../inventory/inventory_api.dart';
import '../ui/mobile_input.dart';
import '../ui/theme.dart';
import 'bill_api.dart';
import 'bill_widgets.dart';
import 'table_widgets.dart';

/// Figma Journey 5 "Send receipt" (node 18:811), step 5: Print (the store's counter receipt printer), WhatsApp, SMS, Email, Back to tables.
/// The receipt is the paid bill as the database keeps it (`rst_receipt_view`); each print or send is recorded on the order with the number or
/// address masked (`rst_receipt_log`). WhatsApp, SMS and email open the phone's own app with the receipt text; no printer driver exists yet,
/// so Print copies the text and names the printer.
class BillReceiptScreen extends StatefulWidget {
  const BillReceiptScreen({super.key, required this.env, required this.orderId, this.bill, this.openUrl});
  final TablesEnv env;
  final String orderId;
  final BillApi? bill;
  final Future<bool> Function(Uri)? openUrl;
  @override
  State<BillReceiptScreen> createState() => _BillReceiptScreenState();
}

class _BillReceiptScreenState extends State<BillReceiptScreen> {
  late final BillApi _api = widget.bill ?? BillApi();
  late final Future<bool> Function(Uri) _open = widget.openUrl ?? ((u) => launchUrl(u, mode: LaunchMode.externalApplication));
  Facts? _r;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _api.receipt(widget.orderId);
      if (mounted) {
        setState(() {
          _r = r;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = sayError(e));
    }
  }

  String get _text => billText(_r!, business: _r!.so('business'), table: _r!.so('table_label'), receipt: true);

  Future<String?> _ask(String title, String hint, TextInputType type, String initial) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title, style: inter(18, 700)),
        content: TextField(
          key: const ValueKey('receipt-to'),
          controller: c,
          keyboardType: type,
          inputFormatters: type == TextInputType.phone ? mobileFormatters : null,
          autofocus: true,
          decoration: InputDecoration(hintText: hint, prefixText: type == TextInputType.phone ? kMobilePrefix : null),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          TextButton(key: const ValueKey('receipt-send'), onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Send')),
        ],
      ),
    );
  }

  Future<void> _send(String channel) async {
    final r = _r;
    if (r == null || _busy) return;
    String? to;
    Uri? uri;
    final text = _text;
    switch (channel) {
      case 'print':
        to = r.so('receipt_printer') ?? 'counter printer';
      case 'whatsapp' || 'sms':
        to = await _ask(channel == 'whatsapp' ? 'Send on WhatsApp' : 'Send by SMS', 'Mobile number', TextInputType.phone, localMobile(r.s('customer_phone')));
        if (to == null || to.isEmpty) return;
        var digits = to.replaceAll(RegExp(r'\D'), '');
        if (digits.length == 10) digits = '91$digits';
        uri = channel == 'whatsapp' ? Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(text)}') : Uri(scheme: 'sms', path: '+$digits', queryParameters: {'body': text});
      case 'email':
        to = await _ask('Send by email', 'name@example.com', TextInputType.emailAddress, '');
        if (to == null || to.isEmpty) return;
        uri = Uri(scheme: 'mailto', path: to, query: 'subject=${Uri.encodeComponent('Receipt ${r.s('display_no')}')}&body=${Uri.encodeComponent(text)}');
    }
    setState(() => _busy = true);
    try {
      await _api.logReceipt(widget.orderId, channel, to: to); // the database checks the number / address and keeps it masked
      if (!mounted) return;
      if (uri != null) {
        if (!await _open(uri) && mounted) showToast(context, 'Could not open the app on this phone.');
      } else {
        await Clipboard.setData(ClipboardData(text: text));
        if (mounted) showToast(context, 'Receipt text copied for ${r.so('receipt_printer') ?? 'the counter printer'}. Printers connect in a later release.');
      }
      await _load();
    } catch (e) {
      if (mounted) showToast(context, sayError(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final sent = {for (final s in r?.l('sent') ?? const <Facts>[]) s.s('channel'): s.s('to')};
    String sub(String ch, String fallback) => sent[ch] == null ? fallback : 'Sent · ${sent[ch]}';
    return TablesPage(
      env: widget.env,
      title: 'Send receipt',
      subtitle: r == null ? ' ' : '#${r.s('display_no')} · ${money(r.n('total'))} paid',
      back: true,
      onRefresh: _load,
      children: [
        if (r == null && _error == null) tablesLoading(),
        if (_error != null) TablesError(_error!, onRetry: _load),
        if (r != null) ...[
          Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: kLine)),
            child: Column(children: [
              _row('print', 'P', 'Print', sub('print', r.so('receipt_printer') ?? 'No receipt printer set up'), kAvailBg, kAvailText),
              const Divider(height: 1, color: kLine),
              _row('whatsapp', 'W', 'WhatsApp', sub('whatsapp', r.so('customer_phone') ?? 'Add a number'), kResBg, kResText),
              const Divider(height: 1, color: kLine),
              _row('sms', 'S', 'SMS', sub('sms', 'Text message'), const Color(0xFFFEF3C7), const Color(0xFFB45309)),
              const Divider(height: 1, color: kLine),
              _row('email', 'E', 'Email', sub('email', 'Add an email'), const Color(0xFFF3F4F6), kInk),
            ]),
          ),
          const SizedBox(height: 16),
          DarkLimeButton('Back to tables', key: const ValueKey('back-to-tables'), onPressed: () => backToTables(context)),
        ],
      ],
    );
  }

  Widget _row(String channel, String letter, String title, String sub, Color bg, Color fg) => InkWell(
        key: ValueKey('receipt-$channel'),
        onTap: _busy ? null : () => _send(channel),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(width: 44, height: 44, alignment: Alignment.center, decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)), child: Text(letter, style: inter(17, 700, color: fg))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: inter(17, 700)),
                Text(sub, style: inter(13.5, 400, color: kMuted)),
              ]),
            ),
          ]),
        ),
      );
}
