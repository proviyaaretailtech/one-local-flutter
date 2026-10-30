import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../inventory/inventory_api.dart';
import '../inventory/inventory_widgets.dart' show qty;
import '../ui/mobile_input.dart';
import '../ui/theme.dart';
import '../ui/whatsapp_icon.dart';
import 'bill_api.dart';
import 'bill_paid_screen.dart';
import 'bill_receipt_popup.dart';
import 'bill_split_screen.dart';
import 'bill_widgets.dart';
import 'table_widgets.dart';
import 'tables_api.dart';
import '../ui/motion.dart';
import '../settings/store_qr.dart';

/// Figma "Checkout" (screen-payment.png), step 3 of the restaurant "Bill and pay" journey: the current items of the table (no kitchen note:
/// the kitchen is done by now; founder, 29 Oct 2026), the bill summary, a discount code, the payment method (Cash / Card / UPI-QR / Split Pay), the amount received with the change,
/// Complete Payment, then send the bill on WhatsApp or SMS or print it. Every amount, the coupon, the change and what may be done come from the database (`rst_bill_view`,
/// `rst_bill_pay`). With [part] it takes one guest's part of a split bill (opened from the split screen) and returns the answer to it.
/// Card and UPI are recorded only after the cashier confirms the money arrived; a retried tap re-sends the same key, so it is never paid twice.
class BillPayScreen extends StatefulWidget {
  const BillPayScreen({super.key, required this.env, required this.tableId, this.bill, this.part, this.orderId, this.openUrl});
  final TablesEnv env;
  final String tableId;
  final BillApi? bill;

  /// Opens WhatsApp / the SMS app (tests pass a fake).
  final Future<bool> Function(Uri)? openUrl;

  /// One guest's part (from `rst_bill_split`): id, order_id, label, amount, method.
  final Facts? part;

  /// The bill to take (a table with several open bills); null takes the oldest.
  final String? orderId;

  @override
  State<BillPayScreen> createState() => _BillPayScreenState();
}

class _BillPayScreenState extends State<BillPayScreen> {
  late final BillApi _api = widget.bill ?? BillApi();
  late final Future<bool> Function(Uri) _open = widget.openUrl ?? ((u) => launchUrl(u, mode: LaunchMode.externalApplication));
  Facts? _v;
  String? _error, _payError;
  bool _busy = false;
  late String _method = widget.part?.s('method') ?? 'cash';
  final _received = TextEditingController();
  final _code = TextEditingController();
  String? _payKey; // the key of the tap in flight; kept only when the server gave no answer, so a retry cannot pay twice

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _received.dispose();
    _code.dispose();
    super.dispose();
  }

  Facts? get _order {
    final orders = _v?.l('orders') ?? const <Facts>[];
    final want = widget.part?.s('order_id') ?? widget.orderId;
    if (want != null) {
      for (final o in orders) {
        if (o.s('id') == want) return o;
      }
      return null;
    }
    return orders.isEmpty ? null : orders.first;
  }

  num get _due => widget.part?.n('amount') ?? _order?.n('due') ?? 0;
  Facts? get _activeSplit => _order?.mo('split')?.s('status') == 'active' ? _order!.m('split') : null;

  Future<void> _load() async {
    try {
      final v = await _api.view(widget.tableId);
      if (!mounted) return;
      setState(() {
        _v = v;
        _error = null;
      });
      final o = _order;
      if (o != null) {
        if (_received.text.isEmpty) _received.text = money(_due);
        if (o.so('coupon_code') != null) _code.text = o.s('coupon_code');
      }
    } catch (e) {
      if (mounted) setState(() => _error = sayError(e));
    }
  }

  Future<void> _applyCode() async {
    final o = _order;
    if (o == null) return;
    if (_v?.m('can').b('coupon') != true) return showToast(context, _v?.m('unavailable').so('coupon') ?? 'A discount code cannot be added now.');
    if (_code.text.trim().isEmpty) return showToast(context, 'Enter a discount code.');
    setState(() => _busy = true);
    try {
      await _api.coupon(o.s('id'), _code.text);
      _received.clear();
      await _load();
      if (mounted) showToast(context, 'Discount applied.');
    } catch (e) {
      if (mounted) showToast(context, sayError(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _openSplit() async {
    final o = _order;
    if (o == null) return;
    if (widget.part != null) return showToast(context, 'This is one guest\'s part of a split bill.');
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => BillSplitScreen(env: widget.env, tableId: widget.tableId, orderId: o.s('id'), bill: _api)));
    if (mounted) {
      _received.clear();
      await _load();
    }
  }

  Future<bool> _confirmed(String what) async =>
      await showOlDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Has the $what payment gone through?', style: inter(18, 700)),
          content: Text('Record ${money(_due)} only after the ${what == 'card' ? 'card machine' : 'customer\'s UPI app'} shows it was paid.', style: inter(15, 400, color: kMuted)),
          actions: [
            TextButton(key: const ValueKey('confirm-no'), onPressed: () => Navigator.pop(c, false), child: const Text('Not yet')),
            TextButton(key: const ValueKey('confirm-yes'), onPressed: () => Navigator.pop(c, true), child: const Text('Yes, it is paid')),
          ],
        ),
      ) ??
      false;

  Future<void> _complete() async {
    final o = _order;
    if (o == null) return;
    final can = _v!.m('can');
    if (can.b('pay') != true) return showToast(context, _v!.m('unavailable').so('pay') ?? 'This bill cannot be paid now.');
    if (widget.part == null && _activeSplit != null) return _openSplit();
    if (_method == 'split') return _openSplit();
    num? tendered;
    if (_method == 'cash') {
      tendered = typedAmount(_received.text);
      if (tendered == null || tendered < _due) return setState(() => _payError = 'Enter at least ${money(_due)} received.');
    } else if (!await _confirmed(_method == 'card' ? 'card' : 'UPI')) {
      return;
    }
    setState(() {
      _busy = true;
      _payError = null;
    });
    final key = _payKey ??= BillApi.newKey();
    try {
      final r = await _api.pay(o.s('id'), partId: widget.part?.s('id'), method: _method, tendered: tendered, key: key);
      _payKey = null;
      if (!mounted) return;
      if (r.b('order_paid')) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => BillPaidScreen(env: widget.env, tableId: widget.tableId, result: r, bill: _api)));
      } else {
        Navigator.of(context).pop(r);
      }
      return;
    } on TablesApiException catch (e) {
      _payKey = null; // the server answered: nothing was taken, a new tap is a new intent
      if (mounted) setState(() => _payError = e.message);
      await _load();
    } catch (_) {
      if (mounted) setState(() => _payError = 'No answer from the server. Tap Complete Payment again: the same payment is retried, never taken twice.');
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Asks the customer's mobile number (filled in when the bill has one), then opens WhatsApp or the SMS app with the bill text.
  Future<void> _sendBill(String channel) async {
    final o = _order;
    if (o == null) return;
    final c = TextEditingController(text: localMobile(o.so('customer_phone')));
    final to = await showOlDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(channel == 'whatsapp' ? 'Send bill on WhatsApp' : 'Send bill on SMS', style: inter(18, 700)),
        content: TextField(key: const ValueKey('send-to'), controller: c, keyboardType: TextInputType.phone, inputFormatters: mobileFormatters, autofocus: true, decoration: const InputDecoration(hintText: 'Mobile number', prefixText: kMobilePrefix)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          TextButton(key: const ValueKey('send-go'), onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Send')),
        ],
      ),
    );
    if (to == null || !mounted) return;
    var digits = to.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) digits = '91$digits';
    if (digits.length < 11) return showToast(context, 'Enter a 10-digit mobile number.');
    final text = billText(o, table: _v!.m('table').s('label'));
    final uri = channel == 'whatsapp' ? Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(text)}') : Uri(scheme: 'sms', path: '+$digits', query: 'body=${Uri.encodeComponent(text)}'); // %20, not +, for spaces
    if (!await _open(uri) && mounted) showToast(context, channel == 'whatsapp' ? 'WhatsApp could not be opened.' : 'The SMS app could not be opened.');
  }

  /// Sends the bill to the printer as the 80 mm slip.
  Future<void> _printBill() async {
    final o = _order;
    if (o == null) return;
    if (!await printBillSlip(view: _v!, order: o) && mounted) showToast(context, 'Could not open the printer. Try again.');
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    final o = _order;
    final t = v?.m('table');
    final orders = v?.l('orders') ?? const <Facts>[];
    final part = widget.part;
    final idx = o == null ? 0 : orders.indexWhere((x) => x.s('id') == o.s('id')) + 1;
    final change = _method == 'cash' ? (typedAmount(_received.text) ?? 0) - _due : 0;
    return TablesPage(
      env: widget.env,
      title: 'Checkout',
      subtitle: t == null
          ? ' '
          : [
              'Table ${t.s('label')}',
              if (part != null) part.s('label'),
              if (part == null && orders.length > 1) 'Bill $idx of ${orders.length}',
            ].join(' · '),
      back: true,
      onRefresh: _load,
      children: [
        if (v == null && _error == null) tablesLoading(),
        if (_error != null) TablesError(_error!, onRetry: _load),
        if (v != null && o == null) Padding(padding: const EdgeInsets.all(24), child: Center(child: Text('No open bill on this table.', style: inter(15, 400, color: kMuted)))),
        if (v != null && o != null) ...[
          BillCard(title: 'CURRENT ITEMS (TABLE ${t!.s('label').toUpperCase()})', children: [
            // eaten here first, then the dishes packed to take away on the same bill (0606)
            for (final i in billItems(o).where((i) => !i.b('takeaway'))) ...[
              BillLine('${qty(i.n('qty'))} × ${i.s('name')}${(i.so('variant') ?? '').isEmpty ? '' : ' (${i.s('variant')})'}', money(i.n('line_total'))),
              // add-ons and combos chosen with the dish (0625), each for one dish
              for (final (what, price) in billAddOns(i)) BillLine('    $what', '${money(price)} each', muted: true),
            ],
            if (billItems(o).any((i) => i.b('takeaway'))) ...[
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 2),
                child: Text('TAKEAWAY', key: const ValueKey('bill-takeaway-head'), style: inter(13, 800, color: const Color(0xFFC2410C))),
              ),
              for (final i in billItems(o).where((i) => i.b('takeaway'))) ...[
                BillLine('${qty(i.n('qty'))} × ${i.s('name')}${(i.so('variant') ?? '').isEmpty ? '' : ' (${i.s('variant')})'} (Takeaway)', money(i.n('line_total'))),
                for (final (what, price) in billAddOns(i)) BillLine('    $what', '${money(price)} each', muted: true),
              ],
            ],
          ]),
          BillCard(title: 'BILL SUMMARY', children: [
            BillLine('Subtotal', money(o.n('subtotal')), muted: true),
            if (o.n('discount') != 0) BillLine('Discount${o.so('coupon_code') == null ? '' : ' (${o.s('coupon_code')})'}', '-${money(o.n('discount'))}', muted: true),
            if (o.n('gst_amount') != 0) BillLine('GST (${_pct(o.n('gst_pct'))}%)', money(o.n('gst_amount')), muted: true),
            if (o.n('service_charge') != 0) BillLine('Service charge', money(o.n('service_charge')), muted: true),
            if (o.n('round_off') != 0) BillLine('Round off', money(o.n('round_off')), muted: true),
            if (o.n('paid') != 0) BillLine('Paid so far', '-${money(o.n('paid'))}', muted: true),
            const Divider(height: 18, color: kLine),
            BillLine(part == null ? 'Total Due' : '${part.s('label')} pays', money(_due), bold: true, valueColor: kLink, valueKey: const ValueKey('total-due')),
          ]),
          if (part == null && _activeSplit != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: kAvailBg, borderRadius: BorderRadius.circular(14), border: Border.all(color: kAvailBorder)),
              child: Text('This bill is split between ${_activeSplit!.l('parts').length} guests. '
                  '${_activeSplit!.n('paid_parts')} paid. Take each guest\'s part from the split.', key: const ValueKey('split-banner'), style: inter(14.5, 500)),
            ),
          if (part == null)
            BillCard(title: 'DISCOUNT CODE', children: [
              Row(children: [
                Expanded(
                  child: BillField(
                    fieldKey: const ValueKey('bill-code'),
                    controller: _code,
                    hint: 'Enter code',
                    enabled: v.m('can').b('coupon'),
                  ),
                ),
                if (v.m('can').b('coupon')) TextButton(key: const ValueKey('apply-code'), onPressed: _busy ? null : _applyCode, child: Text('Apply', style: inter(15, 700, color: kInk))),
              ]),
              if (!v.m('can').b('coupon') && v.m('unavailable').so('coupon') != null)
                Padding(padding: const EdgeInsets.only(top: 6), child: Text(v.m('unavailable').s('coupon'), style: inter(13, 400, color: kMuted))),
            ]),
          BillCard(title: 'PAYMENT METHOD', children: [
            Row(children: [
              Expanded(child: MethodTile(label: 'Cash', icon: methodIcons['cash']!, selected: _method == 'cash', onTap: () => setState(() => _method = 'cash'))),
              const SizedBox(width: 10),
              Expanded(child: MethodTile(label: 'Card', icon: methodIcons['card']!, selected: _method == 'card', onTap: () => setState(() => _method = 'card'))),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: MethodTile(label: 'UPI / QR', icon: methodIcons['upi']!, selected: _method == 'upi', onTap: () => setState(() => _method = 'upi'))),
              const SizedBox(width: 10),
              Expanded(
                child: MethodTile(
                  label: 'Split Pay',
                  icon: methodIcons['split']!,
                  selected: false,
                  enabled: part == null && v.m('can').b('pay'),
                  onTap: _openSplit,
                ),
              ),
            ]),
            if (_method == 'cash') ...[
              const SizedBox(height: 14),
              Text('Amount Received', style: inter(15, 500, color: kMuted)),
              const SizedBox(height: 8),
              BillField(fieldKey: const ValueKey('bill-received'), controller: _received, hint: money(_due), keyboard: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() => _payError = null)),
              if (change > 0) Padding(padding: const EdgeInsets.only(top: 8), child: BillLine('Change to return', money(change), valueKey: const ValueKey('bill-change'))),
            ],
            // UPI (founder, 29 Oct 2026): the store's own QR for the guest to scan
            if (_method == 'upi') ...[
              const SizedBox(height: 14),
              const StoreQrCard(key: ValueKey('bill-store-qr'), big: true),
            ],
          ]),
          if (_payError != null)
            Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_payError!, key: const ValueKey('pay-error'), style: inter(14.5, 500, color: kError))),
          if (!v.m('can').b('pay') && v.m('unavailable').so('pay') != null)
            Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(v.m('unavailable').s('pay'), key: const ValueKey('pay-unavailable'), style: inter(14.5, 500, color: kMuted))),
          LimeButton(part == null ? 'Complete Payment' : 'Complete Payment · ${part.s('label')}', height: 60, busy: _busy, onPressed: v.m('can').b('pay') ? _complete : null),
          const SizedBox(height: 10),
          // send the bill: WhatsApp, SMS, or the printer
          Row(children: [
            Expanded(child: _SendButton(key: const ValueKey('bill-whatsapp'), tip: 'Send bill on WhatsApp', bg: kWhatsAppGreen, onTap: () => _sendBill('whatsapp'), child: const WhatsAppIcon())),
            const SizedBox(width: 10),
            Expanded(child: _SendButton(key: const ValueKey('bill-sms'), tip: 'Send bill on SMS', onTap: () => _sendBill('sms'), child: const Icon(LucideIcons.messageSquareText, size: 26, color: Color(0xFF2563EB)))),
            const SizedBox(width: 10),
            Expanded(child: _SendButton(key: const ValueKey('bill-print'), tip: 'Print bill', onTap: _printBill, child: const Icon(LucideIcons.printer, size: 26, color: kInk))),
          ]),
        ],
      ],
    );
  }
}

/// One of the three send buttons under Complete Payment: an icon only, named by its tooltip.
class _SendButton extends StatelessWidget {
  const _SendButton({super.key, required this.tip, required this.onTap, required this.child, this.bg = Colors.white});
  final String tip;
  final VoidCallback onTap;
  final Widget child;
  final Color bg;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tip,
        child: Semantics(
          button: true,
          label: tip,
          child: Material(
            color: bg,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: bg == Colors.white ? const BorderSide(color: kLine) : BorderSide.none),
            clipBehavior: Clip.antiAlias,
            child: InkWell(onTap: onTap, child: SizedBox(height: 56, child: Center(child: child))),
          ),
        ),
      );
}

String _pct(num v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';
