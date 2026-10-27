import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/register_account_type_screen.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'checklist_screen.dart';
import 'onboarding_draft.dart';
import 'onboarding_api.dart';
import 'onboarding_widgets.dart';

/// Figma "Merchant Registration" (three frames: store, restaurant, service). Sections 1 and 2: shop profile and owner contact, and
/// (founder, 27 Oct 2026) the plan right here, instead of two screens after it. The owner's name and mobile come from sign-up.
/// First time through it goes on to the next section; opened from the checklist it returns the saved application.
class MerchantProfileScreen extends StatefulWidget {
  const MerchantProfileScreen({super.key, required this.api, required this.type, this.app, this.phone, this.name});
  final OnboardingApi api;
  final String type; // store | restaurant | service
  final Application? app;
  final String? phone;

  /// The owner's name from sign-up (not typed twice).
  final String? name;
  @override
  State<MerchantProfileScreen> createState() => _MerchantProfileScreenState();
}

class _MerchantProfileScreenState extends State<MerchantProfileScreen> {
  late final Future<Taxonomy> _tax = widget.api.taxonomy();
  late final _name = TextEditingController(text: widget.app?.businessName ?? '');
  late final _owner = TextEditingController(text: (widget.app?.ownerName ?? '').isNotEmpty ? widget.app!.ownerName : (widget.name ?? ''));
  late final _phone = TextEditingController(text: _tenDigits(widget.app?.phone ?? widget.phone ?? ''));
  String? _category, _sub, _mode;
  late String? _plan = widget.app?.sellPlan; // pos_and_onelocal | pos_only (onelocal_app: older applications)
  final _draft = OnbDraft('profile');
  List<String> _cuisines = []; // restaurant: every cuisine it serves, first = main
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final a = widget.app?.app;
    if (a != null) {
      _category = a['category'] as String?;
      final subs = (a['subcategories'] as List?)?.cast<String>() ?? const [];
      _sub = widget.type == 'store' && subs.isNotEmpty ? subs.first : null;
      if (widget.type == 'restaurant') _cuisines = subs.isNotEmpty ? List.of(subs) : [?_category];
      _mode = a['selling_mode'] as String?;
    }
    // what was typed before the app closed, where the server has nothing yet
    _draft.load().then((d) {
      if (!mounted || d.isEmpty) return;
      setState(() {
        if (_name.text.isEmpty) _name.text = d['name'] ?? '';
        if (_owner.text.isEmpty) _owner.text = d['owner'] ?? '';
        if (_phone.text.isEmpty) _phone.text = d['phone'] ?? '';
        _category ??= d['category'];
        _sub ??= d['sub'];
        _mode ??= d['mode'];
        _plan ??= d['plan'];
        if (_cuisines.isEmpty && (d['cuisines'] ?? '').isNotEmpty) _cuisines = d['cuisines']!.split('|');
      });
    });
    for (final c in [_name, _owner, _phone]) {
      c.addListener(_keep);
    }
  }

  void _keep() => _draft.keep({
        'name': _name.text, 'owner': _owner.text, 'phone': _phone.text, 'category': _category, 'sub': _sub, 'mode': _mode, 'plan': _plan,
        'cuisines': _cuisines.join('|'),
      });

  void _set(VoidCallback change) {
    setState(change);
    _keep();
  }

  @override
  void dispose() {
    _draft.dispose();
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
  bool get _rst => widget.type == 'restaurant';
  /// What the business is called on this form: a restaurant registers a "Restaurant", everyone else a "Shop".
  String get _noun => _rst ? 'Restaurant' : 'Shop';

  Future<void> _save() async {
    if (_saving) return;
    if (_name.text.trim().length < 2) return showToast(context, 'Enter your ${_noun.toLowerCase()} name.');
    if (_rst && _cuisines.isEmpty) return showToast(context, 'Choose the cuisines you serve.');
    if (!_rst && _category == null) return showToast(context, widget.type == 'service' ? 'Choose your service.' : 'Choose your category.');
    if (widget.type == 'store' && _sub == null) return showToast(context, 'Choose your subcategory.');
    if (_owner.text.trim().length < 2) return showToast(context, "Enter the owner's full name.");
    if (!RegExp(r'^[6-9]\d{9}$').hasMatch(_phone.text)) return showToast(context, 'Enter a 10-digit mobile number.');
    if (_mode == null) return showToast(context, 'Choose how you sell.');
    if (_plan == null) return showToast(context, 'Choose your OneLocal plan.');
    setState(() => _saving = true);
    final saved = await guarded(
      context,
      () => widget.api.saveProfile({
        'partner_type': widget.type,
        'business_name': _name.text.trim(),
        'owner_name': _owner.text.trim(),
        'phone': _phone.text,
        'selling_mode': _mode,
        if (_rst) 'categories': _cuisines else 'category': _category,
        if (widget.type == 'store') 'subcategory': _sub,
      }),
    );
    if (saved == null || !mounted) {
      if (mounted) setState(() => _saving = false);
      return;
    }
    // the plan, in the same tap
    final planned = saved.sellPlan == _plan ? saved : await guarded(context, () => widget.api.choosePlan(_plan!));
    if (!mounted) return;
    setState(() => _saving = false);
    if (planned == null) return;
    await _draft.clear();
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (widget.app?.exists == true && widget.app?.sellPlan != null) {
      nav.pop(planned); // from the checklist: back to it, which opens the next section
    } else {
      // first time through: the checklist, which opens the next section straight away
      nav.pushReplacement(MaterialPageRoute(builder: (_) => ChecklistScreen(api: widget.api, app: planned, autoNext: true)));
    }
  }

  Widget _planCard(String id, String title, String body, IconData icon) => ChoiceCard(icon: icon, title: title, body: body, selected: _plan == id, onTap: () => _set(() => _plan = id));

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Taxonomy>(
      future: _tax,
      builder: (context, snap) {
        if (snap.hasError) {
          return OnbPage(
            kicker: _kicker, title: _title, caption: '$_noun profile',
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
          caption: '$_noun profile',
          subtitle: 'Start with your ${_rst ? 'restaurant' : 'shop'} profile. You can review every detail before submitting.',
          children: [
            LabeledField(label: '$_noun name', controller: _name, labelSize: 14, labelWeight: 500, textInputAction: TextInputAction.next),
            if (_rst)
              MultiChipField(
                label: 'Cuisines you serve',
                hint: 'Pick all that apply. The first one you pick is shown as your main cuisine.',
                options: cats,
                selected: _cuisines,
                onChanged: (v) => _set(() => _cuisines = v),
              )
            else
              SelectField(
                label: widget.type == 'service' ? 'Services' : 'Category',
                value: _category,
                options: cats,
                onChanged: (v) => _set(() {
                  if (v != _category) _sub = null;
                  _category = v;
                }),
              ),
            if (widget.type == 'store')
              SelectField(label: 'Subcategory', value: _sub, options: subs, hint: _category == null ? 'Choose a category first' : 'Choose', onChanged: (v) => _set(() => _sub = v)),
            LabeledField(label: '$_noun owner', controller: _owner, labelSize: 14, labelWeight: 500, textInputAction: TextInputAction.next),
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
              ChoiceCard(icon: _rst ? Icons.restaurant_outlined : lucideStore, title: _rst ? 'Dine-in & takeaway' : 'Physical store', body: _rst ? 'Customers eat in or pick up at my restaurant.' : 'Customers visit my shop.', selected: _mode == 'physical', onTap: () => _set(() => _mode = 'physical')),
              const SizedBox(height: 12),
              ChoiceCard(icon: Icons.shopping_bag_outlined, title: 'Online or both', body: 'I also take orders online.', selected: _mode == 'online_or_both', onTap: () => _set(() => _mode = 'online_or_both')),
            ]),
            // the plan, here instead of two screens after this one
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Your OneLocal plan', style: inter(17, 600)),
              const SizedBox(height: 14),
              // the two plans (founder, 27 Oct 2026)
              _planCard('pos_and_onelocal', 'Sell on OneLocal and Purchase POS', 'Customers order from you on OneLocal, and the POS runs your counter: billing, stock and reports, in sync.', Icons.storefront_outlined),
              const SizedBox(height: 12),
              _planCard('pos_only', 'Purchase POS', 'The POS for your counter only: billing, stock, prices and reports. Not listed on the OneLocal app.', Icons.point_of_sale_outlined),
            ]),
          ],
          actions: [
            PrimaryAction(label: _saving ? 'Saving…' : 'Save & continue', onPressed: _saving ? null : _save),
            const SizedBox(height: 12),
            const FooterNote('Next: your address. What you type is kept if you stop halfway.'),
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
  const StartScreen({super.key, required this.api, this.phone, this.name});
  final OnboardingApi api;
  final String? phone, name;
  @override
  Widget build(BuildContext context) => RegisterAccountTypeScreen(
        onChosen: (t) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => MerchantProfileScreen(api: api, type: t.name, phone: phone, name: name))),
      );
}
