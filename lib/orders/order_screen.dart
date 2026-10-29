import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/net_guard.dart';
import '../home/home_nav.dart';
import '../ui/mobile_input.dart';
import '../ui/theme.dart';
import 'cart_screen.dart';
import 'order_widgets.dart';
import 'orders_api.dart';
import 'orders_board_screen.dart' show OrdersBoardScreen;

/// Every placed order state from Figma section E: Checkout (held bill), Order Confirmation, Preparing, Picked, Ready, In Transit,
/// Exception, Cancelled, and Completed. What the screen says and which buttons it shows come from the server's view of the order.
class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key, this.api, required this.orderId, this.initial, this.onNavigate, this.onDeliveryStatus});
  final OrdersApi? api;
  final String orderId;
  final OrderView? initial;
  final ValueChanged<String>? onNavigate;

  /// Delivery status opens the delivery update list (founder, 29 Oct 2026) instead of the store's courier sheet. The Orders board passes
  /// its own (back to it, on this order); elsewhere a restaurant goes to Orders with the order asked for.
  final void Function(BuildContext context)? onDeliveryStatus;
  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  late final OrdersApi _api = widget.api ?? OrdersApi();
  late OrderView? _v = widget.initial;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (_v == null) _load();
  }

  Future<void> _load() async {
    try {
      final v = await _api.get(widget.orderId);
      if (mounted) {
        setState(() {
          _v = v;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorSentence(e));
    }
  }

  /// Runs one server call; on a version conflict the order is reloaded and the person is told why.
  Future<bool> _run(Future<OrderView> Function() call) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      final v = await call();
      if (mounted) setState(() => _v = v);
      return true;
    } on OrdersApiException catch (e) {
      if (mounted) showToast(context, e.message);
      if (e.stale || e.status == 409) await _load();
      return false;
    } catch (e) {
      if (mounted) showToast(context, errorSentence(e));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _act(String action, {List<Map<String, dynamic>>? lines, Map<String, String>? delivery, String? note, String? reason}) =>
      _run(() => _api.act(_v!.id, action, version: _v!.version, lines: lines, delivery: delivery, note: note, reason: reason));

  Future<void> _onAction(String id) async {
    final v = _v!;
    switch (id) {
      case 'pack' || 'handover' || 'dispatch' || 'choose_collection' || 'return_to_store' || 'online_accept' || 'online_ready':
        await _act(id);
      case 'refresh':
        await _load();
      case 'pay':
        await _paySheet();
      case 'cancel':
        final reason = await _textSheet('Cancel bill', 'Why is this bill cancelled?', 'Cancel bill');
        if (reason != null) await _run(() => _api.cancel(v.id, reason: reason, version: v.version));
      case 'online_reject':
        final reason = await _textSheet('Reject order', 'Why can this order not be made?', 'Reject order');
        if (reason != null) await _act('online_reject', reason: reason);
      case 'print':
        showToast(context, 'No receipt printer is connected to this device yet.');
      case 'whatsapp':
        final uri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(v.receiptText)}');
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) showToast(context, 'WhatsApp could not be opened.');
      case 'acceptance':
        await _acceptanceSheet();
      case 'picking':
        await _pickingSheet();
      case 'report_missing':
        await _missingSheet();
      case 'delivery_status' || 'online_delivery':
        if (widget.onDeliveryStatus != null) {
          widget.onDeliveryStatus!(context);
        } else if (HomeNav.shell?.kind == 'restaurant') {
          // a restaurant's delivery orders are moved on in Orders → the source's delivery list
          OrdersBoardScreen.requestedDelivery.value = (source: null, orderId: v.id);
          Navigator.of(context).maybePop();
          if (mounted) HomeNav.go(context, HomeNav.orders, 'Orders');
        } else if (id == 'online_delivery') {
          await _load(); // a store's online order: the latest from the platform
        } else {
          await _deliverySheet(); // a store's courier fulfilment
        }
      case 'report_delivery_issue':
        final note = await _textSheet('Report delivery issue', 'What went wrong?', 'Report issue');
        if (note != null) await _act('report_delivery_issue', note: note);
      case 'set_delivery_info':
        await _deliveryInfoSheet();
      case 'new_cart':
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => CartScreen(
            api: _api,
            onNavigate: widget.onNavigate,
            initialLines: [for (final i in v.items) if (i['menu_item_id'] != null) CartLine(menuItemId: i['menu_item_id'] as String, name: i['name'] as String, qty: i['qty'] as int)],
          ),
        ));
      case 'receipt':
        await _infoSheet('Receipt', v.receiptText);
      case 'review_cancellation' || 'exception_details':
        await _infoSheet(id == 'review_cancellation' ? 'Cancellation' : 'Exception details', [
          if (id == 'review_cancellation') 'Reason: ${v.cancelReason ?? 'not recorded'}',
          if (v.exception != null) '${v.exception!['note'] ?? ''}',
          '',
          for (final e in v.events) '${e['at']}  ${e['message']}',
        ].join('\n'));
      default:
        showToast(context, 'That action is not available here.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        OrdersTopBar(title: v == null ? 'Order' : '${v.stage == 'checkout' ? 'Checkout' : 'Order'} ${v.displayNo}', onBack: () => Navigator.maybePop(context)),
        Expanded(
          child: v == null
              ? Center(
                  child: _error == null
                      ? const CircularProgressIndicator(color: kGreenText)
                      : Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Text(_error!, textAlign: TextAlign.center, style: inter(14, 400, color: kMuted)),
                            const SizedBox(height: 12),
                            OutlinedButton(onPressed: _load, child: Text('Try again', style: inter(14, 600))),
                          ]),
                        ),
                )
              : RefreshIndicator(onRefresh: _load, child: _body(v)),
        ),
        PosBottomNav(active: 'online', onTap: (id) {
          if (id == 'bill') {
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => CartScreen(api: _api, onNavigate: widget.onNavigate)));
          } else if (widget.onNavigate != null) {
            widget.onNavigate!(id);
          } else {
            showToast(context, 'That part of the app is not built yet.');
          }
        }),
      ]),
    );
  }

  Widget _body(OrderView v) {
    final bill = v.bill, pay = v.payment, record = v.paymentRecord;
    num n(Object? x) => num.tryParse('${x ?? 0}') ?? 0;
    final primary = v.action('primary'), secondary = v.action('secondary'), links = v.actionsOf('link');
    final checkout = v.stage == 'checkout';
    final cancelled = v.stage == 'cancelled';
    return ListView(padding: const EdgeInsets.fromLTRB(12, 14, 12, 16), children: [
      OrderHeaderCard(
        number: 'Order #${v.displayNo}${v.placeLabel != null ? ' - ${v.placeLabel}' : ''}',
        channel: v.channelLabel,
        subtitle: 'Customer: ${v.customer} · ${v.placedAt}',
      ),
      const SizedBox(height: 14),
      StateHeader(title: v.title, chip: v.paymentChip, orderStatus: v.orderStatus, fulfilment: v.fulfilment, danger: v.danger),
      const SizedBox(height: 10),
      StateNote(tone: '${v.note['tone'] ?? 'info'}', title: '${v.note['title'] ?? ''}', body: '${v.note['body'] ?? ''}'),
      const SizedBox(height: 12),
      OrderCardBox(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [const Expanded(child: Kick('Order items')), Text(v.summary, style: inter(11.5, 400, color: kMuted))]),
          const SizedBox(height: 8),
          for (final i in v.items) ItemLine(name: '${i['name'] ?? ''}', sub: '${i['sub'] ?? ''}', amount: n(i['amount']), qtyBadge: '${i['qty']}×'),
          const Divider(height: 18, color: kLine),
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: kChipGreen, borderRadius: BorderRadius.circular(999)),
              child: Text(checkout ? 'Locked for payment' : 'Locked', style: inter(12.5, 700, color: kGreenText)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(v.adjustments, style: inter(12, 400, color: kMuted))),
          ]),
        ]),
      ),
      if (record != null) ...[
        const SizedBox(height: 12),
        OrderCardBox(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Kick('Payment record'),
            const SizedBox(height: 8),
            KeyValue('${record['title'] ?? ''}', '${record['value'] ?? ''}', size: 13.5),
            KeyValue('${record['second'] ?? ''}', '${record['second_value'] ?? ''}', size: 13.5),
            const SizedBox(height: 6),
            Text('${record['footer'] ?? ''}', style: inter(12.5, 400, color: kMuted)),
          ]),
        ),
      ],
      const SizedBox(height: 12),
      BillSummary(
        subtotal: n(bill['subtotal']),
        gstPct: n(bill['gst_pct']),
        gst: n(bill['gst']),
        serviceCharge: n(bill['service_charge']),
        discount: n(bill['discount']),
        roundOff: n(bill['round_off']),
        total: n(bill['total']),
        footer: TenderBlock(
          label: '${pay['label'] ?? ''}',
          amountText: rupees(checkout ? 0 : n(pay['tendered'])),
          chips: checkout
              ? ['${rupees(n(pay['due']))} due', 'Held']
              : ['${rupees(n(pay['settled']))} ${cancelled && n(pay['settled']) == 0 ? 'captured' : 'settled'}', if (pay['method'] != null) '${pay['method']}', 'Read-only'],
          selectedChip: checkout ? 'Held' : 'Read-only',
          changeLabel: n(pay['change']) > 0 ? 'Change returned' : 'Change Due · none',
          changeChip: n(pay['change']) > 0 ? 'Returned' : (n(pay['settled']) > 0 ? 'Settled' : 'Unpaid'),
          changeValue: rupees(n(pay['change'])),
        ),
      ),
      const SizedBox(height: 16),
      if (primary != null) _button(primary, dark: true),
      if (secondary != null) ...[const SizedBox(height: 10), _button(secondary, dark: false)],
      for (final l in links) ...[const SizedBox(height: 8), UnderLink('${l['label'] ?? ''}', onTap: _busy ? null : () => _onAction('${l['id'] ?? ''}'))],
    ]);
  }

  Widget _button(Map<String, dynamic> a, {required bool dark}) {
    final id = '${a['id'] ?? ''}', label = '${a['label'] ?? ''}';
    if (dark) return DarkCta(label: label, busy: _busy, onPressed: () => _onAction(id));
    if (id == 'whatsapp') return LightCta(label: label, bg: kWhatsApp, fg: Colors.white, icon: LucideIcons.messageCircle, onPressed: _busy ? null : () => _onAction(id));
    return LightCta(label: label, onPressed: _busy ? null : () => _onAction(id));
  }

  // ---------------------------------------------------------------- sheets

  Future<String?> _textSheet(String title, String hint, String confirm) async {
    final c = TextEditingController();
    final r = await showOrderSheet<String>(
      context,
      title: title,
      body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: c, maxLength: 200, minLines: 1, maxLines: 3, decoration: InputDecoration(hintText: hint)),
        const SizedBox(height: 12),
        DarkCta(label: confirm, onPressed: () => Navigator.pop(ctx, c.text.trim())),
      ]),
    );
    return r == null || r.isEmpty ? null : r;
  }

  Future<void> _infoSheet(String title, String body) => showOrderSheet<void>(
        context,
        title: title,
        body: (ctx) => SingleChildScrollView(child: SelectableText(body, style: inter(13.5, 400, height: 1.5))),
      );

  Future<void> _paySheet() async {
    final v = _v!;
    final due = num.tryParse('${v.payment['due']}') ?? 0;
    var method = 'cash';
    final tender = TextEditingController(text: due == due.roundToDouble() ? due.toInt().toString() : due.toString());
    final key = OrdersApi.newKey();
    final go = await showOrderSheet<bool>(
      context,
      title: 'Complete payment · ${rupees(due)}',
      body: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 8, children: [
            for (final (id, label) in const [('cash', 'Cash'), ('card', 'Card'), ('upi', 'UPI / QR')])
              ChoiceChip(label: Text(label), selected: method == id, selectedColor: kLime, onSelected: (_) => set(() => method = id)),
          ]),
          if (method == 'cash') ...[
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('pay-tender'),
              controller: tender,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              decoration: const InputDecoration(labelText: 'Cash received (₹)'),
            ),
          ],
          const SizedBox(height: 16),
          DarkCta(label: 'Complete Payment ${rupees(due)}', onPressed: () => Navigator.pop(ctx, true)),
        ]),
      ),
    );
    if (go != true) return;
    await _run(() => _api.pay(v.id, method: method, tendered: method == 'cash' ? num.tryParse(tender.text) : null, version: v.version, key: key));
  }

  Future<void> _acceptanceSheet() async {
    final v = _v!;
    final accept = await showOrderSheet<bool>(
      context,
      title: 'Acceptance status',
      body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        KeyValue('Order status', v.orderStatus, size: 14),
        KeyValue('Fulfillment', v.fulfilment, size: 14),
        const SizedBox(height: 16),
        DarkCta(label: 'Accept order', onPressed: () => Navigator.pop(ctx, true)),
      ]),
    );
    if (accept == true) await _act('accept');
  }

  Future<void> _pickingSheet() async {
    final v = _v!;
    final counts = {for (final i in v.items) '${i['order_item_id'] ?? ''}': (i['picked_qty'] ?? 0) as int};
    final save = await showOrderSheet<bool>(
      context,
      title: 'Picking checklist',
      body: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final i in v.items)
                Builder(builder: (_) {
                  final id = '${i['order_item_id'] ?? ''}', qty = i['qty'] as int, missing = (i['missing_qty'] ?? 0) as int;
                  final max = qty - missing;
                  return CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: counts[id] == max,
                    activeColor: kGreenText,
                    title: Text('${i['name'] ?? ''}', style: inter(14, 500)),
                    subtitle: Text('${counts[id]} of $qty picked${missing > 0 ? ' · $missing missing' : ''}', style: inter(12, 400, color: kMuted)),
                    secondary: QtyStepper(
                      qty: counts[id]!,
                      name: '${i['name'] ?? ''}',
                      onMinus: () => set(() => counts[id] = (counts[id]! - 1).clamp(0, max)),
                      onPlus: () => set(() => counts[id] = (counts[id]! + 1).clamp(0, max)),
                    ),
                    onChanged: (on) => set(() => counts[id] = on == true ? max : 0),
                  );
                }),
            ]),
          ),
          const SizedBox(height: 12),
          DarkCta(label: 'Save picked quantities', onPressed: () => Navigator.pop(ctx, true)),
        ]),
      ),
    );
    if (save == true) await _act('pick', lines: [for (final e in counts.entries) {'order_item_id': e.key, 'qty': e.value}]);
  }

  Future<void> _missingSheet() async {
    final v = _v!;
    String? line;
    var qty = 1;
    final save = await showOrderSheet<bool>(
      context,
      title: 'Report missing item',
      body: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final i in v.items)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(line == '${i['order_item_id'] ?? ''}' ? LucideIcons.circleCheck : LucideIcons.circle, color: kGreenText, size: 20),
              title: Text('${i['name'] ?? ''}', style: inter(14, 500)),
              subtitle: Text('${i['qty']} ordered · ${i['picked_qty'] ?? 0} picked', style: inter(12, 400, color: kMuted)),
              onTap: () => set(() {
                line = '${i['order_item_id'] ?? ''}';
                qty = 1;
              }),
            ),
          if (line != null)
            Row(children: [
              Text('Units missing', style: inter(14, 500)),
              const Spacer(),
              QtyStepper(qty: qty, name: 'missing', onMinus: () => set(() => qty = qty > 1 ? qty - 1 : 1), onPlus: () => set(() => qty = qty < 99 ? qty + 1 : 99)),
            ]),
          const SizedBox(height: 12),
          DarkCta(label: 'Report missing', onPressed: line == null ? null : () => Navigator.pop(ctx, true)),
        ]),
      ),
    );
    if (save == true && line != null) await _act('report_missing', lines: [{'order_item_id': line, 'qty': qty}]);
  }

  Future<void> _deliverySheet() async {
    final v = _v!;
    final d = v.delivery;
    final choice = await showOrderSheet<String>(
      context,
      title: 'Delivery status',
      body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        KeyValue('Status', v.fulfilment, size: 14),
        if (d?['address'] != null) KeyValue('Address', '${d!['address']}', size: 14),
        if (d?['phone'] != null) KeyValue('Phone', '${d!['phone']}', size: 14),
        const SizedBox(height: 8),
        Text('No courier tracking is connected. Confirm with the customer before closing the order.', style: inter(12.5, 400, color: kMuted)),
        const SizedBox(height: 16),
        DarkCta(label: 'Confirm delivered', onPressed: () => Navigator.pop(ctx, 'confirm_delivery')),
        const SizedBox(height: 10),
        LightCta(label: 'Return to store', onPressed: () => Navigator.pop(ctx, 'return_to_store')),
      ]),
    );
    if (choice != null) await _act(choice);
  }

  Future<void> _deliveryInfoSheet() async {
    final d = _v!.delivery ?? const {};
    final name = TextEditingController(text: '${d['name'] ?? ''}'), phone = TextEditingController(text: localMobile('${d['phone'] ?? ''}')), address = TextEditingController(text: '${d['address'] ?? ''}');
    final save = await showOrderSheet<bool>(
      context,
      title: 'Delivery information',
      body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Name (optional)')),
        TextField(key: const ValueKey('delivery-phone'), controller: phone, keyboardType: TextInputType.phone, inputFormatters: mobileFormatters, decoration: const InputDecoration(labelText: 'Mobile number', prefixText: kMobilePrefix)),
        TextField(key: const ValueKey('delivery-address'), controller: address, minLines: 1, maxLines: 3, decoration: const InputDecoration(labelText: 'Delivery address')),
        const SizedBox(height: 16),
        DarkCta(label: 'Save', onPressed: () => Navigator.pop(ctx, true)),
      ]),
    );
    if (save == true) await _act('set_delivery_info', delivery: {'name': name.text.trim(), 'phone': phone.text.trim(), 'address': address.text.trim()});
  }
}
