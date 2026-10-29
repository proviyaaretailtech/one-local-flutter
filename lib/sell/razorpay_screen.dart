import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart';
import '../ui/theme.dart';
import 'result_screens.dart';
import 'sell_env.dart';
import 'sell_widgets.dart';
import '../ui/i18n.dart';

/// Figma "Razorpay checkout mobile": the hosted online checkout for a held bill (UPI, card, net banking, wallets).
/// The call goes to the POS server, which answers 503 `provider_not_configured` until a payment provider is set up there (test mode first);
/// this build has none, so the screen is honest about it: nothing is charged, the attempt is logged and the failure screen opens.
class RazorpayScreen extends StatefulWidget {
  const RazorpayScreen({super.key, required this.env, required this.order});
  final SellEnv env;
  final OrderView order;
  @override
  State<RazorpayScreen> createState() => _RazorpayScreenState();
}

class _RazorpayScreenState extends State<RazorpayScreen> {
  String _method = 'upi';
  final _upi = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _upi.dispose();
    super.dispose();
  }

  Future<void> _pay() async {
    if (_busy) return;
    final env = widget.env;
    if (_method == 'upi' && !RegExp(r'^[\w.\-]{2,}@[\w]{2,}$').hasMatch(_upi.text.trim())) {
      showToast(context, 'Enter a UPI ID like name@bank.');
      return;
    }
    setState(() => _busy = true);
    try {
      await env.sell.onlineCheckout(widget.order.id);
      // A configured provider would hand back a checkout session here; the app would open it and wait for the server to confirm the capture.
      if (mounted) showToast(context, 'Waiting for the payment provider.');
    } on OrdersApiException catch (e) {
      try {
        final f = await env.sell.recordAttempt(widget.order.id, method: 'online', status: 'failed', code: e.code ?? 'failed', message: e.message);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => FailedScreen(env: env, failure: f)));
      } catch (e2) {
        if (mounted) showToast(context, sellErrorText(e2));
      }
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    final total = (o.bill['total'] as num?) ?? 0;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        SellTopBar(title: 'Checkout ${o.displayNo}', onBack: () => Navigator.maybePop(context), initials: widget.env.initials),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 16), children: [
            Row(children: [
              Text('Razorpay', style: inter(34, 900, color: const Color(0xFF0B2A5B))),
              const Spacer(),
              const Icon(LucideIcons.shieldCheck, size: 18, color: Color(0xFF3DB800)),
              const SizedBox(width: 6),
              Text(tr('Secure checkout'), style: inter(13, 600, color: kMuted)),
            ]),
            const SizedBox(height: 16),
            OrderCardBox(
              radius: 24,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [Expanded(child: Text(widget.env.storeLine, style: inter(20, 800))), const TagChip('Store Checkout')]),
                Text('Order ${o.displayNo} · ${o.customer}', style: inter(14, 400, color: kMuted)),
                const Divider(height: 24, color: kLine),
                Row(children: [Text(tr('Amount to pay'), style: inter(15, 400, color: kMuted)), const Spacer(), Text('${rupees(total)}${total == total.roundToDouble() ? '.00' : ''}', style: inter(30, 800))]),
                const SizedBox(height: 6),
                Row(children: [Text('Subtotal ${rupees((o.bill['subtotal'] as num?) ?? 0)}', style: inter(13, 400, color: kMuted)), const Spacer(), Text('GST (${o.bill['gst_pct']}%) ${rupees((o.bill['gst'] as num?) ?? 0)}', style: inter(13, 400, color: kMuted))]),
              ]),
            ),
            const SizedBox(height: 18),
            Text(tr('Choose payment method'), style: inter(20, 800)),
            const SizedBox(height: 10),
            for (final (id, title, sub, icon) in const [
              ('upi', 'UPI', 'Google Pay, PhonePe, Paytm & more', LucideIcons.smartphone),
              ('card', 'Credit / Debit Card', 'Visa, Mastercard, RuPay & more', LucideIcons.creditCard),
              ('netbanking', 'Netbanking', 'Pay directly from your bank account', LucideIcons.landmark),
              ('wallet', 'Wallets', 'Amazon Pay, PhonePe & more', LucideIcons.wallet),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Semantics(
                  button: true,
                  selected: _method == id,
                  label: title,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(22),
                    onTap: () => setState(() => _method = id),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22), border: Border.all(color: _method == id ? const Color(0xFF3DB800) : const Color(0xFFECEDE8), width: _method == id ? 1.5 : 1)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Container(width: 44, height: 44, decoration: BoxDecoration(color: kChipGreen, borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: kGreenText)),
                          const SizedBox(width: 14),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [Text(title, style: inter(17, 700)), if (id == 'upi') ...[const SizedBox(width: 8), const TagChip('RECOMMENDED')]]),
                            Text(sub, style: inter(13, 400, color: kMuted)),
                          ])),
                          Icon(_method == id ? LucideIcons.circleDot : LucideIcons.chevronRight, color: _method == id ? const Color(0xFF3DB800) : kMuted),
                        ]),
                        if (_method == id && id == 'upi') ...[
                          const SizedBox(height: 12),
                          Text(tr('UPI ID'), style: inter(13, 600, color: kMuted)),
                          const SizedBox(height: 6),
                          TextField(controller: _upi, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(hintText: 'customer@okaxis')),
                          const SizedBox(height: 6),
                          Text(tr('Approve the payment request in your UPI app.'), style: inter(12.5, 400, color: kMuted)),
                        ],
                      ]),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Center(child: Text('Encrypted payments · No additional fees', style: inter(13, 400, color: kMuted))),
            const SizedBox(height: 12),
            DarkCta(label: 'Pay ${rupees(total)}${total == total.roundToDouble() ? '.00' : ''}', busy: _busy, onPressed: _pay),
            UnderLink('Cancel & return to order', onTap: () => Navigator.maybePop(context)),
          ]),
        ),
      ]),
    );
  }
}
