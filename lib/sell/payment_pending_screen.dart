import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart';
import '../shift/shift_api.dart';
import '../ui/theme.dart';
import 'result_screens.dart';
import 'sell_api.dart';
import 'sell_env.dart';
import 'sell_widgets.dart';

/// Founder Correct Flow S5.14 "Payment pending": a UPI or card payment for a held bill that is waiting for confirmation. The bill is
/// never shown as paid here: the database keeps it unpaid until the person at the counter confirms with the UPI reference or the card
/// approval code. It then pays the bill once (a retry or a double tap replays), or the payment is marked failed / cancelled and logged,
/// and the bill can be tried again. No payment provider is connected in this build.
class PaymentPendingScreen extends StatefulWidget {
  const PaymentPendingScreen({super.key, required this.env, required this.order, required this.method, this.poll = const Duration(seconds: 15)});
  final SellEnv env;
  final OrderView order;
  final String method;
  final Duration poll;
  @override
  State<PaymentPendingScreen> createState() => _PaymentPendingScreenState();
}

class _PaymentPendingScreenState extends State<PaymentPendingScreen> {
  SellEnv get env => widget.env;
  PaymentIntent? _intent;
  String? _error;
  final _ref = TextEditingController();
  final _key = OrdersApi.newKey(); // one waiting payment per screen: starting again replays it
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _start();
    _timer = Timer.periodic(widget.poll, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ref.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      final i = await env.shift.startPayment(widget.order.id, method: widget.method, key: _key);
      if (mounted) setState(() => _intent = i);
    } on OrdersApiException catch (e) {
      if (e.code == 'payment_pending') {
        // a payment on this bill is already waiting (another tap, another phone): pick it up instead of starting a second one
        try {
          final i = await env.shift.paymentStatus(orderId: widget.order.id);
          if (mounted) setState(() => _intent = i);
          return;
        } catch (_) {}
      }
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = sellErrorText(e));
    }
  }

  Future<void> _refresh() async {
    final i = _intent;
    if (i == null || !i.pending || _busy) return;
    try {
      final n = await env.shift.paymentStatus(intentId: i.id);
      if (mounted) setState(() => _intent = n);
    } catch (_) {/* the next tick tries again */}
  }

  Future<void> _guard(Future<void> Function() job) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() => _guard(() async {
        final i = _intent!;
        final ref = _ref.text.trim();
        if (ref.length < 4) {
          showToast(context, i.method == 'upi' ? 'Enter the UPI reference from the customer\'s app.' : 'Enter the approval code from the card slip.');
          return;
        }
        final done = await env.shift.confirmPayment(i.id, reference: ref);
        if (!mounted) return;
        setState(() => _intent = done);
        final view = await env.orders.get(done.orderId);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => SuccessScreen(env: env, view: view)));
      });

  Future<void> _fail(String status) => _guard(() async {
        final done = await env.shift.failPayment(_intent!.id, status: status, message: status == 'cancelled' ? 'Cancelled at the counter' : 'Not received');
        if (!mounted) return;
        setState(() => _intent = done);
        if (status == 'cancelled') {
          showToast(context, '${done.displayNo} is still unpaid. Choose another way to pay.');
          Navigator.of(context).maybePop();
          return;
        }
        final a = done.attempt ?? const {};
        Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (_) => FailedScreen(env: env, failure: PaymentFailure({
                  'order_id': done.orderId, 'display_no': done.displayNo, 'method': done.method, 'status': a['status'] ?? 'failed',
                  'code': a['code'] ?? '', 'message': a['message'] ?? '', 'amount_due': done.due, 'charged': false,
                }))));
      });

  @override
  Widget build(BuildContext context) {
    final i = _intent;
    final label = widget.method == 'upi' ? 'UPI' : 'Card';
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        SellTopBar(onBack: () => Navigator.maybePop(context), initials: env.initials),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(24, 24, 24, 16), children: [
            if (_error != null)
              StateCard(icon: LucideIcons.circleAlert, title: 'Could not start the payment', body: _error!, primary: 'Try again', onPrimary: _start, danger: true)
            else if (i == null)
              const SkeletonRows(count: 2)
            else
              OrderCardBox(
                radius: 30,
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
                child: Column(children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: const BoxDecoration(color: kWarnBg, shape: BoxShape.circle),
                    child: Icon(widget.method == 'upi' ? LucideIcons.qrCode : LucideIcons.creditCard, size: 30, color: kWarnText),
                  ),
                  const SizedBox(height: 16),
                  Text('Payment pending', textAlign: TextAlign.center, style: inter(24, 800, color: kWarnText)),
                  const SizedBox(height: 4),
                  Text('Waiting for the $label payment · ${i.age}', textAlign: TextAlign.center, style: inter(13.5, 400, color: kMuted)),
                  const SizedBox(height: 14),
                  Text(rupees(i.amount), style: inter(34, 800)),
                  const SizedBox(height: 4),
                  DotChip('Not paid yet · ${i.displayNo}', bg: kWarnBg, fg: kWarnText),
                  const Divider(height: 28, color: kLine),
                  if (i.stale) ...[
                    const StateNote(tone: 'warn', title: 'Still waiting after 15 minutes', body: 'Check the customer\'s UPI app or the card machine before you confirm or mark it failed.'),
                    const SizedBox(height: 14),
                  ],
                  Align(alignment: Alignment.centerLeft, child: Text(widget.method == 'upi' ? 'UPI reference (from the customer\'s app)' : 'Approval code (from the card slip)', style: inter(13, 600, color: kMuted))),
                  const SizedBox(height: 6),
                  TextField(
                    key: const ValueKey('payment-ref'),
                    controller: _ref,
                    maxLength: 40,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(hintText: widget.method == 'upi' ? 'e.g. 4291 3378 1102' : 'e.g. 812345'),
                  ),
                  const SizedBox(height: 8),
                  DarkCta(label: 'Payment received', busy: _busy, onPressed: i.pending ? _confirm : null),
                  const SizedBox(height: 10),
                  LightCta(label: 'Payment failed', onPressed: _busy || !i.pending ? null : () => _fail(widget.method == 'card' ? 'declined' : 'failed')),
                  const SizedBox(height: 4),
                  UnderLink('Cancel and choose another way to pay', onTap: _busy || !i.pending ? null : () => _fail('cancelled')),
                  const SizedBox(height: 8),
                  Text('Hand over the goods only after you confirm. A second tap never charges twice.', textAlign: TextAlign.center, style: inter(12.5, 400, color: kKicker)),
                ]),
              ),
          ]),
        ),
      ]),
    );
  }
}
