import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../plans/subscription_plans.dart';
import '../ui/theme.dart';
import 'setup_api.dart';
import 'setup_flow.dart';
import 'setup_widgets.dart';
import '../settings/store_qr.dart';
import '../ui/i18n.dart';

String _sellPlanName(String? p) => switch (p) {
      'pos_and_onelocal' => 'Sell on OneLocal and Purchase POS',
      'pos_only' => 'Purchase POS',
      'onelocal_app' => 'OneLocal app',
      _ => 'Your plan',
    };

String _cadence(String? c) => switch (c) { 'Monthly' => 'Monthly', 'Quarterly' => 'Quarterly', 'Annual' => 'Yearly', _ => 'Not set yet' };

List<String> _modules(Object? v) => ((v as List?) ?? const [])
    .map((m) => m is Map ? (m['name'] ?? m['label'] ?? m['key'] ?? '').toString() : m.toString())
    .where((s) => s.isNotEmpty)
    .toList();

/// Everything a OneLocal plan can include, and what each selling plan has (founder, 28 Oct 2026: show what is not included too).
const kAllModules = ['POS billing', 'Catalogue', 'Stock & purchase', 'OneLocal listing', 'Online orders', 'Delivery & pickup'];
List<String> modulesOf(String? sellPlan) => switch (sellPlan) {
      'pos_only' => const ['POS billing', 'Catalogue', 'Stock & purchase'],
      'onelocal_app' => const ['Catalogue', 'OneLocal listing', 'Online orders', 'Delivery & pickup'],
      _ => kAllModules,
    };

/// Figma 18 "Plan & Subscription". The choice is recorded; no subscription or charge starts here.
class PlanScreen extends StatefulWidget {
  const PlanScreen({super.key, required this.api, required this.state});
  final SetupApi api;
  final SetupState state;
  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> with TourHost {
  final _cardKey = GlobalKey();
  late final List<Map<String, dynamic>> _plans = SetupState.maps(widget.state.plan['available']);
  late String? _code = widget.state.plan['selected_code'] as String? ?? (_plans.isEmpty ? null : _plans.first['code'] as String?);
  bool _busy = false;

  @override
  SetupApi get tourApi => widget.api;
  @override
  SetupState get tourState => widget.state;

  Map<String, dynamic>? get _plan => _plans.where((p) => p['code'] == _code).firstOrNull;

  Future<void> _change() async {
    if (_plans.length < 2) {
      showToast(context, _plans.isEmpty ? 'OneLocal has not published plans yet. You can change your plan later.' : 'This is the only plan available right now.');
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.all(20), child: Text('Choose your plan', style: inter(16, 700))),
          for (final p in _plans)
            ListTile(
              title: Text(p['name'] as String, style: inter(14, p['code'] == _code ? 700 : 400)),
              subtitle: Text('${_cadence(p['cadence'] as String?)} · ₹${p['price']}', style: inter(12, 400, color: kMuted)),
              onTap: () => Navigator.pop(context, p['code'] as String),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (picked != null) setState(() => _code = picked);
  }

  Future<void> _continue() async {
    setState(() => _busy = true);
    final s = await setupGuarded(context, () => widget.api.confirmPlan(_code));
    if (!mounted) return;
    setState(() => _busy = false);
    if (s != null) popWith(context, s, advance: true);
  }

  @override
  Widget build(BuildContext context) {
    final p = _plan;
    final sell = widget.state.plan['sell_plan'] as String?;
    final modules = p != null ? _modules(p['modules']) : modulesOf(sell);
    final have = modules.map((m) => m.toLowerCase()).toSet();
    final missing = kAllModules.where((m) => !have.contains(m.toLowerCase())).toList();
    final users = p?['users_limit'];
    final locations = p?['locations_limit'];
    return SetupDialog(
      title: 'Plan & Subscription',
      subtitle: 'Review your plan before continuing.',
      tour: tourFor(2, 'Choose your plan', 'Review your plan, included features, and usage limits in one place.', _cardKey),
      children: [
        TourTarget(
          tourKey: _cardKey,
          child: SetupBox(padding: const EdgeInsets.fromLTRB(12, 12, 12, 10), children: [
            Text('Current plan · ${p?['name'] ?? _sellPlanName(sell)}', style: inter(13, 700)),
            const SizedBox(height: 6),
            Text('Your selection only. No subscription or charge starts here.', style: inter(12, 400, color: kMuted, height: 1.4)),
            const SizedBox(height: 6),
            if (p == null && planByCode(sell) != null) ...[
              SetupKeyValue('Price', '${rupees(planByCode(sell)!.perMonth)}/month'),
              SetupKeyValue('Billing', '6 months ${rupees(planByCode(sell)!.price(BillingCycle.sixMonths))} · 12 months ${rupees(planByCode(sell)!.price(BillingCycle.twelveMonths))}'),
            ] else
              SetupKeyValue('Billing cycle', _cadence(p?['cadence'] as String?)),
          ]),
        ),
        const SizedBox(height: 16),
        const SetupHeading('Included modules'),
        const SizedBox(height: 8),
        SetupBox(children: [for (final m in modules) SetupCheck(value: true, title: m)]),
        if (missing.isNotEmpty) ...[
          const SizedBox(height: 16),
          const SetupHeading('Not included'),
          const SizedBox(height: 8),
          SetupBox(key: const ValueKey('plan-not-included'), children: [
            for (final m in missing)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(color: const Color(0xFFE9EAEE), borderRadius: BorderRadius.circular(6)),
                    child: const Icon(Icons.close, size: 15, color: kMuted),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(m, style: inter(14, 500, color: kMuted))),
                ]),
              ),
          ]),
          if (sell == 'pos_only' || sell == 'onelocal_app') ...[
            const SizedBox(height: 8),
            SetupNote(sell == 'pos_only'
                ? 'Want online orders? They come with Sell on OneLocal and Purchase POS. You can upgrade any time from Online orders.'
                : 'Want billing at your counter? It comes with Sell on OneLocal and Purchase POS.'),
          ],
        ],
        const SizedBox(height: 16),
        SetupHeading(p == null ? 'Usage limits' : 'Usage limits · ${p['name']}'),
        const SizedBox(height: 8),
        SetupBox(padding: const EdgeInsets.fromLTRB(12, 8, 12, 8), children: [
          SetupKeyValue('Locations', p == null ? 'Shown with your plan' : (locations == null ? 'Unlimited' : 'Up to $locations')),
          SetupKeyValue('Staff accounts', p == null ? 'Shown with your plan' : (users == null ? 'Unlimited' : 'Up to $users staff')),
        ]),
        const SizedBox(height: 12),
        const SetupNote('Final limits and billing terms are shown when you choose a plan.'),
      ],
      actions: [
        PillSecondary(label: 'Change Plan', onPressed: _busy ? null : _change),
        const SizedBox(height: 8),
        PillPrimary(label: _busy ? 'Saving…' : 'Continue', onPressed: _busy ? null : _continue),
      ],
    );
  }
}

/// Figma 19 "Payment Setup": settlement account, payment methods, UPI ID.
class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key, required this.api, required this.state});
  final SetupApi api;
  final SetupState state;
  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> with TourHost {
  final _methodsKey = GlobalKey();
  late final Map<String, dynamic> _p = widget.state.payment;
  late final _holder = TextEditingController(text: _p['holder_name'] as String? ?? '');
  final _account = TextEditingController();
  late final _ifsc = TextEditingController(text: _p['ifsc'] as String? ?? '');
  late final _upiId = TextEditingController(text: _p['upi_id'] as String? ?? '');
  late bool _upi = _p['accept_upi'] == true;
  late bool _card = _p['accept_card'] == true;
  bool _busy = false;

  @override
  SetupApi get tourApi => widget.api;
  @override
  SetupState get tourState => widget.state;

  @override
  void dispose() {
    for (final c in [_holder, _account, _ifsc, _upiId]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final masked = _p['account_masked'] as String?;
    if (_holder.text.trim().length < 2) return showToast(context, 'Enter the name as on the bank account.');
    if (_account.text.isEmpty && masked == null) return showToast(context, 'Enter your settlement account number.');
    if (_upi && _upiId.text.trim().isEmpty) return showToast(context, 'Enter your business UPI ID, or turn UPI off.');
    setState(() => _busy = true);
    final s = await setupGuarded(context, () => widget.api.savePayment({
          'holder_name': _holder.text,
          if (_account.text.isNotEmpty) 'account_number': _account.text,
          if (_account.text.isNotEmpty) 'ifsc': _ifsc.text,
          'accept_upi': _upi,
          'accept_card': _card,
          if (_upiId.text.trim().isNotEmpty) 'upi_id': _upiId.text.trim(),
        }));
    if (!mounted) return;
    setState(() => _busy = false);
    if (s != null) popWith(context, s, advance: true);
  }

  @override
  Widget build(BuildContext context) {
    final masked = _p['account_masked'] as String?;
    final verified = _p['bank_status'] == 'verified';
    return SetupDialog(
      title: 'Payment Setup',
      subtitle: 'Choose how customers pay and where you receive settlements.',
      tour: tourFor(3, 'Set up your payments', 'Configure how your business accepts payments and receives settlements.', _methodsKey),
      children: [
        SetupStatusPill(_p['saved'] == true ? 'Setup complete' : 'Setup incomplete', done: _p['saved'] == true),
        const SizedBox(height: 14),
        // the shop's own UPI QR (founder, 29 Oct 2026): saved at once, shown on the Bill screen when a customer pays by UPI
        const SetupHeading('Payment QR'),
        const SizedBox(height: 4),
        Text(tr('A photo of your shop’s UPI QR. Customers scan it when they pay by UPI. You can change it later in Settings.'), style: inter(12.5, 400, color: kMuted, height: 1.4)),
        const SizedBox(height: 12),
        const StoreQrCard(key: ValueKey('setup-store-qr'), canEdit: true),
        const SizedBox(height: 20),
        const SetupHeading('Settlement bank account'),
        const SizedBox(height: 10),
        SetupField(label: 'Account holder name', controller: _holder, hint: 'Name as on bank account'),
        const SizedBox(height: 12),
        SetupField(
          label: 'Account number',
          controller: _account,
          hint: masked == null ? 'Enter account number' : 'Keep $masked',
          keyboardType: TextInputType.number,
          maxLength: 18,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        ),
        if (masked != null) ...[
          const SizedBox(height: 6),
          Text(verified ? 'Using $masked · verified by OneLocal' : 'Using $masked · not verified yet', style: inter(11.5, 400, color: verified ? kDone : kMuted)),
        ],
        const SizedBox(height: 12),
        SetupField(label: 'IFSC · if changing the account', controller: _ifsc, hint: 'e.g. HDFC0001234', maxLength: 11, inputFormatters: [UpperCaseFormatter()]),
        const SizedBox(height: 16),
        const SetupHeading('Payment methods'),
        const SizedBox(height: 8),
        TourTarget(
          tourKey: _methodsKey,
          child: SetupBox(children: [
            SetupCheck(value: _upi, title: 'UPI', sub: 'Add your UPI ID below', onChanged: (v) => setState(() => _upi = v)),
            SetupCheck(value: _card, title: 'Card', sub: 'Connect your card terminal in POS Setup', onChanged: (v) => setState(() => _card = v)),
          ]),
        ),
        const SizedBox(height: 14),
        SetupField(label: 'UPI ID · if enabled', controller: _upiId, hint: 'Enter your business UPI ID', keyboardType: TextInputType.emailAddress),
        const SizedBox(height: 12),
        const SetupNote('Bank verification is required for digital settlements.'),
      ],
      actions: [PillPrimary(label: _busy ? 'Saving…' : 'Save & Continue', onPressed: _busy ? null : _save)],
    );
  }
}

class UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) => newValue.copyWith(text: newValue.text.toUpperCase());
}

/// Figma 20 "Tax & Business Configuration": GST, invoice prefix, tax-inclusive prices, receipt flags.
class TaxScreen extends StatefulWidget {
  const TaxScreen({super.key, required this.api, required this.state});
  final SetupApi api;
  final SetupState state;
  @override
  State<TaxScreen> createState() => _TaxScreenState();
}

class _TaxScreenState extends State<TaxScreen> with TourHost {
  final _invoiceKey = GlobalKey();
  late final Map<String, dynamic> _t = widget.state.tax;
  late bool? _registered = _t['gst_registered'] as bool?;
  late final _gstin = TextEditingController(text: _t['gstin'] as String? ?? '');
  // Smart default: "INV" until the partner saves their own. GST status stays an explicit answer (it is a tax declaration).
  late final _prefix = TextEditingController(text: _t['saved'] == true ? (_t['invoice_prefix'] as String? ?? '') : 'INV');
  late bool _inclusive = _t['prices_include_tax'] != false;
  late bool _showAddress = _t['show_address_on_receipt'] != false;
  late bool _showGstin = _t['show_gstin_on_invoice'] != false;
  bool _busy = false;

  @override
  SetupApi get tourApi => widget.api;
  @override
  SetupState get tourState => widget.state;

  @override
  void dispose() {
    _gstin.dispose();
    _prefix.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_registered == null) return showToast(context, 'Tell us whether your business is GST-registered.');
    if (_registered! && _gstin.text.trim().length != 15) return showToast(context, 'GSTIN looks wrong. It has 15 characters, like 27ABCDE1234F1Z5.');
    setState(() => _busy = true);
    final s = await setupGuarded(context, () => widget.api.saveTax({
          'gst_registered': _registered,
          if (_registered!) 'gstin': _gstin.text.trim(),
          if (_prefix.text.trim().isNotEmpty) 'invoice_prefix': _prefix.text.trim(),
          'prices_include_tax': _inclusive,
          'show_address_on_receipt': _showAddress,
          'show_gstin_on_invoice': _showGstin,
        }));
    if (!mounted) return;
    setState(() => _busy = false);
    if (s != null) popWith(context, s, advance: true);
  }

  @override
  Widget build(BuildContext context) {
    return SetupDialog(
      title: 'Tax & Business Configuration',
      subtitle: 'Set the tax and receipt details for your shop.',
      tour: tourFor(4, 'Configure billing', 'Add the applicable tax details and customize your invoices and receipts.', _invoiceKey),
      children: [
        SetupSelect<bool>(
          label: 'GST registration',
          value: _registered,
          options: const [true, false],
          hint: 'Is your business GST-registered?',
          display: (v) => v ? 'Registered · I have a GSTIN' : 'Not registered',
          onChanged: (v) => setState(() => _registered = v),
        ),
        if (_registered == true) ...[
          const SizedBox(height: 12),
          SetupField(label: 'GSTIN', controller: _gstin, hint: '15-character GSTIN', maxLength: 15, inputFormatters: [UpperCaseFormatter()]),
        ],
        const SizedBox(height: 16),
        const SetupHeading('Invoice & receipt settings'),
        const SizedBox(height: 10),
        TourTarget(
          tourKey: _invoiceKey,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: SetupField(label: 'Invoice prefix', controller: _prefix, hint: 'INV · default', maxLength: 6, inputFormatters: [UpperCaseFormatter()])),
            const SizedBox(width: 8),
            Expanded(
              child: SetupSelect<bool>(
                label: 'Price includes tax',
                value: _inclusive,
                options: const [true, false],
                hint: 'Choose',
                multiLineValue: true,
                display: (v) => v ? 'Yes · tax-inclusive prices' : 'No · tax added at billing',
                onChanged: (v) => setState(() => _inclusive = v),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        SetupBox(children: [
          SetupCheck(value: _showAddress, title: 'Show business address on receipts', onChanged: (v) => setState(() => _showAddress = v)),
          SetupCheck(value: _showGstin && _registered != false, title: 'Show GSTIN on tax invoices', sub: 'Applies to GST-registered businesses',
              onChanged: _registered == false ? null : (v) => setState(() => _showGstin = v)),
        ]),
        const SizedBox(height: 12),
        const SetupNote('Set the correct tax rate for each item in your catalogue.'),
      ],
      actions: [PillPrimary(label: _busy ? 'Saving…' : 'Save & Continue', onPressed: _busy ? null : _save)],
    );
  }
}
