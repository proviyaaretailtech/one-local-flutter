import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/register_account_type_screen.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'checklist_screen.dart';
import 'onboarding_api.dart';
import 'onboarding_widgets.dart';

/// Figma "Merchant Registration" (three frames: store, restaurant, service). Sections 1 and 2: shop profile and owner contact.
/// First time through it continues to "How do you want to sell?"; opened from the checklist it returns the saved application.
class MerchantProfileScreen extends StatefulWidget {
  const MerchantProfileScreen({super.key, required this.api, required this.type, this.app, this.phone});
  final OnboardingApi api;
  final String type; // store | restaurant | service
  final Application? app;
  final String? phone;
  @override
  State<MerchantProfileScreen> createState() => _MerchantProfileScreenState();
}

class _MerchantProfileScreenState extends State<MerchantProfileScreen> {
  late final Future<Taxonomy> _tax = widget.api.taxonomy();
  late final _name = TextEditingController(text: widget.app?.businessName ?? '');
  late final _owner = TextEditingController(text: widget.app?.ownerName ?? '');
  late final _phone = TextEditingController(text: _tenDigits(widget.app?.phone ?? widget.phone ?? ''));
  String? _category, _sub, _mode;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final a = widget.app?.app;
    if (a != null) {
      _category = a['category'] as String?;
      final subs = (a['subcategories'] as List?)?.cast<String>() ?? const [];
      _sub = widget.type == 'store' && subs.isNotEmpty ? subs.first : null;
      _mode = a['selling_mode'] as String?;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _owner.dispose();
    _phone.dispose();
    super.dispose();
  }

  static String _tenDigits(String s) {
    final d = s.replaceAll(RegExp(r'\D'), '');
    return d.length > 10 ? d.substring(d.length - 10) : d;
  }

  String get _title => switch (widget.type) { 'restaurant' => 'Register as a Restaurant', 'service' => 'Register as service', _ => 'Register as a Store' };
  String get _kicker => widget.type == 'restaurant' ? 'Registration · Merchant' : 'Registration · Partner';

  Future<void> _save() async {
    if (_saving) return;
    if (_name.text.trim().length < 2) return showToast(context, 'Enter your shop name.');
    if (_category == null) return showToast(context, widget.type == 'service' ? 'Choose your service.' : 'Choose your category.');
    if (widget.type == 'store' && _sub == null) return showToast(context, 'Choose your subcategory.');
    if (_owner.text.trim().length < 2) return showToast(context, "Enter the owner's full name.");
    if (!RegExp(r'^[6-9]\d{9}$').hasMatch(_phone.text)) return showToast(context, 'Enter a 10-digit mobile number.');
    if (_mode == null) return showToast(context, 'Choose how you sell.');
    setState(() => _saving = true);
    final saved = await guarded(
      context,
      () => widget.api.saveProfile({
        'partner_type': widget.type,
        'business_name': _name.text.trim(),
        'owner_name': _owner.text.trim(),
        'phone': _phone.text,
        'selling_mode': _mode,
        'category': _category,
        if (widget.type == 'store') 'subcategory': _sub,
      }),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved == null) return;
    final nav = Navigator.of(context);
    if (saved.sellPlan == null) {
      nav.pushReplacement(MaterialPageRoute(builder: (_) => ChooseSellScreen(api: widget.api, app: saved)));
    } else {
      nav.pop(saved);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Taxonomy>(
      future: _tax,
      builder: (context, snap) {
        if (snap.hasError) {
          return OnbPage(
            kicker: _kicker, title: _title, caption: 'Shop profile',
            subtitle: 'We could not load the lists. Check your connection and try again.',
            children: const [],
            actions: [PrimaryAction(label: 'Go back', onPressed: () => Navigator.maybePop(context))],
          );
        }
        if (!snap.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator(color: kLink)));
        final t = snap.data!;
        final cats = switch (widget.type) {
          'restaurant' => t.restaurantCategories,
          'service' => t.serviceCategories.map((c) => c.name).toList(),
          _ => t.storeCategories.map((c) => c.name).toSet().toList(),
        };
        final subs = widget.type == 'store' ? t.storeCategories.where((c) => c.name == _category).expand((c) => c.subs).toList() : <String>[];
        return OnbPage(
          kicker: _kicker,
          title: _title,
          titleSize: 30,
          caption: 'Shop profile',
          subtitle: 'Start with your ${widget.type == 'restaurant' ? 'Restaurant' : 'shop'} profile. You can review every detail before submitting.',
          children: [
            LabeledField(label: 'Shop name', controller: _name, labelSize: 14, labelWeight: 500, textInputAction: TextInputAction.next),
            SelectField(
              label: widget.type == 'service' ? 'Services' : 'Category',
              value: _category,
              options: cats,
              onChanged: (v) => setState(() {
                if (v != _category) _sub = null;
                _category = v;
              }),
            ),
            if (widget.type == 'store')
              SelectField(label: 'Subcategory', value: _sub, options: subs, hint: _category == null ? 'Choose a category first' : 'Choose', onChanged: (v) => setState(() => _sub = v)),
            LabeledField(label: "Shop owner", controller: _owner, labelSize: 14, labelWeight: 500, textInputAction: TextInputAction.next),
            LabeledField(
              label: 'Owner mobile',
              controller: _phone,
              keyboardType: TextInputType.phone,
              labelWeight: 500,
              maxLength: 10,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              prefix: Text('+91', style: inter(15, 400)),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('How do you sell?', style: inter(17, 600)),
              const SizedBox(height: 14),
              ChoiceCard(icon: lucideStore, title: 'Physical store', body: 'Customers visit my shop.', selected: _mode == 'physical', onTap: () => setState(() => _mode = 'physical')),
              const SizedBox(height: 12),
              ChoiceCard(icon: Icons.shopping_bag_outlined, title: 'Online or both', body: 'I also take orders online.', selected: _mode == 'online_or_both', onTap: () => setState(() => _mode = 'online_or_both')),
            ]),
          ],
          actions: [
            PrimaryAction(label: _saving ? 'Saving…' : 'Continue to business details', onPressed: _saving ? null : _save),
            const SizedBox(height: 12),
            const FooterNote('Next: business, contact and verification details.'),
          ],
        );
      },
    );
  }
}

/// Figma "Choose how to sell": two cards. The POS card leads to the plan; the app card records the choice.
class ChooseSellScreen extends StatefulWidget {
  const ChooseSellScreen({super.key, required this.api, required this.app});
  final OnboardingApi api;
  final Application app;
  @override
  State<ChooseSellScreen> createState() => _ChooseSellScreenState();
}

class _ChooseSellScreenState extends State<ChooseSellScreen> {
  bool _saving = false;

  Future<void> _app() async {
    if (_saving) return;
    setState(() => _saving = true);
    final saved = await guarded(context, () => widget.api.choosePlan('onelocal_app'));
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved != null) Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ChecklistScreen(api: widget.api, app: saved)));
  }

  Widget _card(String title, String body, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(32),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(color: Colors.white, border: Border.all(color: kLine), borderRadius: BorderRadius.circular(32)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: inter(22, 600, height: 1.2)),
            const SizedBox(height: 16),
            Text(body, style: inter(16, 400, color: kMuted, height: 1.5)),
            const SizedBox(height: 28),
            const Align(alignment: Alignment.centerRight, child: Icon(Icons.arrow_forward, color: kLink, size: 22)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return OnbPage(
      kicker: 'Set up · Selling',
      title: 'How do you want to sell?',
      titleSize: 30,
      children: [
        _card('Purchase POS & sell on OneLocal', 'Get the POS system and manage your business while selling on OneLocal.', () {
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => BasicPosPlanScreen(api: widget.api, app: widget.app)));
        }),
        _card('Sell on OneLocal App', 'Sell through the OneLocal app without purchasing the POS.', _app),
      ],
      actions: [if (_saving) const Center(child: CircularProgressIndicator(color: kLink))],
    );
  }
}

/// Figma "Basic POS Plan". Choosing it records the plan; no payment is taken here (no price or checkout exists yet).
class BasicPosPlanScreen extends StatefulWidget {
  const BasicPosPlanScreen({super.key, required this.api, required this.app});
  final OnboardingApi api;
  final Application app;
  @override
  State<BasicPosPlanScreen> createState() => _BasicPosPlanScreenState();
}

class _BasicPosPlanScreenState extends State<BasicPosPlanScreen> {
  bool _saving = false;

  Future<void> _choose() async {
    if (_saving) return;
    setState(() => _saving = true);
    final saved = await guarded(context, () => widget.api.choosePlan('pos_and_onelocal'));
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved != null) Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => ChecklistScreen(api: widget.api, app: saved)), (r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return OnbPage(
      kicker: 'Set up · POS',
      title: 'Basic POS Plan',
      titleSize: 30,
      caption: 'Plan',
      children: [
        WhiteCard(
          padding: 28,
          radius: 32,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Basic Pack', style: inter(26, 600)),
            const SizedBox(height: 24),
            for (final f in const ['Customer reports', 'Inventory management', 'Price management', 'Auto inventory sync']) ...[
              Row(children: [
                Container(width: 40, height: 40, decoration: BoxDecoration(color: kNote, borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.check, color: kLink, size: 20)),
                const SizedBox(width: 16),
                Text(f, style: inter(17, 400)),
              ]),
              const SizedBox(height: 16),
            ],
            const SizedBox(height: 8),
            PrimaryAction(label: _saving ? 'Saving…' : 'Purchase POS', onPressed: _saving ? null : _choose),
          ]),
        ),
      ],
      actions: const [],
    );
  }
}

/// Signed in with no application yet: choose Restaurant, Store or Service, then fill the shop profile.
class StartScreen extends StatelessWidget {
  const StartScreen({super.key, required this.api, this.phone});
  final OnboardingApi api;
  final String? phone;
  @override
  Widget build(BuildContext context) => RegisterAccountTypeScreen(
        onChosen: (t) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => MerchantProfileScreen(api: api, type: t.name, phone: phone))),
      );
}
