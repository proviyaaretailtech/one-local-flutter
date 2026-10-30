import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/rpc_client.dart';
import '../auth/auth_repository.dart';
import '../auth/partner_api.dart';
import '../inventory/inventory_widgets.dart' show kCardLine;
import '../onboarding/onboarding_widgets.dart';
import '../ui/i18n.dart';
import '../ui/name_input.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'ads_api.dart';
import 'ads_screens.dart';

// Advertising-only partners (the "Advertising & Partner Growth System" spec §1, 29 Oct 2026): a brand joins OneLocal only to advertise.
// It signs up with its brand, category, the authorised representative, the areas and goals and the ad types it wants, accepts the
// advertising terms, and OneLocal verifies it. Once approved it opens straight into Ads: no products, checkout, orders, stock or sales
// payouts. A store, restaurant or service business is a commerce partner; filling in a brand profile in Ads makes it hybrid.

/// The advertiser sign-up and the brand profile, through the one `/rpc/<name>` door.
class AdvertiserApi {
  AdvertiserApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;

  Future<Map<String, dynamic>> _call(String fn, [Map<String, Object?> args = const {}]) async {
    try {
      return await _rpc.callMap(fn, {...args}..removeWhere((_, v) => v == null));
    } on RpcException catch (e) {
      throw PartnerApiException(e.status, e.message);
    }
  }

  /// {exists, application, terms, terms_version, categories, objectives, formats}
  Future<Map<String, dynamic>> get() => _call('adv_app_get');
  Future<Map<String, dynamic>> save(Map<String, Object?> body) => _call('adv_app_save', body);
  Future<Map<String, dynamic>> submit() => _call('adv_app_submit', {'agree': true});

  /// {partner_kind: commerce | advertising | hybrid, can_edit, categories, profile}
  Future<Map<String, dynamic>> profile() => _call('ads_profile');
  Future<Map<String, dynamic>> saveProfile(Map<String, Object?> body) => _call('ads_profile_save', body);
}

String _objectiveName(String id) => tr(objectives.firstWhere((o) => o.$1 == id, orElse: () => (id, id, LucideIcons.sparkles)).$2);
String _objectiveId(String name) => objectives.firstWhere((o) => tr(o.$2) == name, orElse: () => (name, name, LucideIcons.sparkles)).$1;
List<String> _strings(Object? v) => ((v as List?) ?? const []).map((e) => '$e').toList();

/// The areas a brand advertises in: type one, Add, and it shows as a chip with an ×.
class _AreasField extends StatefulWidget {
  const _AreasField({required this.areas, required this.onChanged});
  final List<String> areas;
  final ValueChanged<List<String>> onChanged;
  @override
  State<_AreasField> createState() => _AreasFieldState();
}

class _AreasFieldState extends State<_AreasField> {
  final _c = TextEditingController();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _add() {
    final t = _c.text.trim();
    if (t.isEmpty || widget.areas.contains(t)) return;
    if (widget.areas.length >= 20) return showToast(context, tr('Up to 20 areas.'));
    widget.onChanged([...widget.areas, t]);
    _c.clear();
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Where to advertise'), style: inter(14, 500)),
        const SizedBox(height: 4),
        Text(tr('A city, an area or a PIN code. Add as many as you like.'), style: inter(12.5, 400, color: kMuted)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              key: const ValueKey('adv-area'),
              controller: _c,
              inputFormatters: [LengthLimitingTextInputFormatter(60)],
              onSubmitted: (_) => _add(),
              decoration: InputDecoration(
                hintText: tr('Kothrud, Pune'),
                filled: true,
                fillColor: kField,
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kFieldBorder)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: const ValueKey('adv-area-add'),
            onPressed: _add,
            style: FilledButton.styleFrom(backgroundColor: kInk, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: Text(tr('Add'), style: inter(14, 700, color: Colors.white)),
          ),
        ]),
        if (widget.areas.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final a in widget.areas)
              InputChip(
                key: ValueKey('adv-area-$a'),
                label: Text(a, style: inter(13, 600)),
                onDeleted: () => widget.onChanged(List.of(widget.areas)..remove(a)),
              ),
          ]),
        ],
      ]);
}

// ============================================================================ sign-up
class AdvertiserSignupScreen extends StatefulWidget {
  const AdvertiserSignupScreen({super.key, this.api, this.auth, this.phone, this.name});
  final AdvertiserApi? api;
  final AuthRepository? auth;

  /// The mobile and name from sign-up, so they are not typed twice.
  final String? phone, name;
  @override
  State<AdvertiserSignupScreen> createState() => _AdvertiserSignupScreenState();
}

class _AdvertiserSignupScreenState extends State<AdvertiserSignupScreen> {
  late final AdvertiserApi _api = widget.api ?? AdvertiserApi();
  Map<String, dynamic>? _g;
  String? _error;
  final _brand = TextEditingController(), _website = TextEditingController(), _gstin = TextEditingController();
  final _rep = TextEditingController(), _role = TextEditingController(), _phone = TextEditingController(), _email = TextEditingController();
  String? _category;
  List<String> _areas = [], _objectives = [], _formats = [];
  bool _agree = false, _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_brand, _website, _gstin, _rep, _role, _phone, _email]) {
      c.dispose();
    }
    super.dispose();
  }

  static String _ten(String s) {
    final d = s.replaceAll(RegExp(r'\D'), '');
    return d.length > 10 ? d.substring(d.length - 10) : d;
  }

  Future<void> _load() async {
    try {
      final g = await _api.get();
      if (!mounted) return;
      final a = ((g['application'] as Map?) ?? const {}).cast<String, dynamic>();
      setState(() {
        _g = g;
        _brand.text = '${a['brand_name'] ?? ''}';
        _category = a['business_category'] as String?;
        _website.text = '${a['website'] ?? ''}';
        _gstin.text = '${a['gstin'] ?? ''}';
        _rep.text = '${a['representative_name'] ?? widget.name ?? ''}';
        _role.text = '${a['representative_role'] ?? ''}';
        _phone.text = _ten('${a['phone'] ?? widget.phone ?? ''}');
        _email.text = '${a['email'] ?? ''}';
        _areas = _strings(a['target_locations']);
        _objectives = _strings(a['objectives']);
        _formats = _strings(a['formats']);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : tr('Could not reach OneLocal. Check your connection and try again.'));
    }
  }

  List<Map<String, dynamic>> get _formatList => ((_g?['formats'] as List?) ?? const []).cast<Map>().map((f) => f.cast<String, dynamic>()).toList();

  Map<String, Object?> get _body => {
        'brand_name': _brand.text.trim(),
        'business_category': _category,
        'website': _website.text.trim(),
        'gstin': _gstin.text.trim(),
        'representative_name': _rep.text.trim(),
        'representative_role': _role.text.trim(),
        'phone': _phone.text.trim(),
        'email': _email.text.trim(),
        'target_locations': _areas,
        'objectives': _objectives,
        'formats': _formats,
      };

  Future<bool> _save() async => await guarded(context, () => _api.save(_body)) != null;

  Future<void> _saveAndExit() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await _save();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      showToast(context, tr('Saved. Continue any time.'));
      exitOnboarding(context);
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (_brand.text.trim().length < 2) return showToast(context, tr('Enter your brand name.'));
    if (_category == null) return showToast(context, tr('Choose your business category.'));
    final repProblem = nameProblem(_rep.text, empty: tr('Enter the name of the person authorised for the brand.'));
    if (repProblem != null) return showToast(context, repProblem);
    if (!RegExp(r'^[6-9]\d{9}$').hasMatch(_phone.text.trim())) return showToast(context, tr('Enter a 10-digit mobile number.'));
    if (_areas.isEmpty) return showToast(context, tr('Add at least one area to advertise in.'));
    if (_objectives.isEmpty) return showToast(context, tr('Choose at least one goal.'));
    if (!_agree) return showToast(context, tr('Read the advertising terms and tick “I agree”.'));
    setState(() => _busy = true);
    try {
      if (!await _save()) return;
      final g = await guarded(context, _api.submit);
      if (g == null || !mounted) return;
      final a = ((g['application'] as Map?) ?? const {}).cast<String, dynamic>();
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => AdvertiserStatusScreen(api: _api, auth: widget.auth, application: a)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = _g;
    if (g == null) {
      return OnbPage(
        kicker: 'Advertise on OneLocal',
        title: _error == null ? 'One moment…' : 'We could not reach OneLocal.',
        subtitle: _error,
        children: [if (_error == null) const Center(child: CircularProgressIndicator(color: kLink))],
        actions: [if (_error != null) PrimaryAction(label: tr('Try again'), onPressed: () => setState(() {
              _error = null;
              _load();
            }))],
      );
    }
    final a = ((g['application'] as Map?) ?? const {}).cast<String, dynamic>();
    final rejected = a['status'] == 'rejected';
    return OnbPage(
      kicker: 'Advertise on OneLocal',
      caption: 'Advertiser sign-up',
      title: 'Tell us about your brand.',
      subtitle: 'Advertise your brand, products, services or outlet to people nearby. You do not need to sell on OneLocal.',
      children: [
        if (rejected) NoteCard(title: tr('OneLocal could not approve it yet'), body: '${a['review_note'] ?? ''}'),
        WhiteCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('1 · Your brand'), style: inter(16, 700)),
            const SizedBox(height: 14),
            LabeledField(key: const ValueKey('adv-brand'), label: tr('Brand or business name'), controller: _brand, hint: tr('Sunrise Tea'), maxLength: 80),
            const SizedBox(height: 14),
            KeyedSubtree(
              key: const ValueKey('adv-category'),
              child: SelectField(label: tr('Business category'), value: _category, options: _strings(g['categories']), onChanged: (v) => setState(() => _category = v)),
            ),
            const SizedBox(height: 14),
            LabeledField(key: const ValueKey('adv-website'), label: tr('Website (optional)'), controller: _website, hint: 'https://', keyboardType: TextInputType.url),
            const SizedBox(height: 14),
            LabeledField(
              key: const ValueKey('adv-gstin'),
              label: tr('GSTIN (optional)'),
              controller: _gstin,
              maxLength: 15,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z]')), TextInputFormatter.withFunction((o, n) => n.copyWith(text: n.text.toUpperCase()))],
            ),
          ]),
        ),
        WhiteCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('2 · The person authorised for the brand'), style: inter(16, 700)),
            const SizedBox(height: 4),
            Text(tr('OneLocal checks that this person may act for the brand before ads run.'), style: inter(12.5, 400, color: kMuted)),
            const SizedBox(height: 14),
            LabeledField(key: const ValueKey('adv-rep-name'), label: tr('Full name'), controller: _rep, inputFormatters: nameFormatters),
            const SizedBox(height: 14),
            LabeledField(key: const ValueKey('adv-rep-role'), label: tr('Role (optional)'), controller: _role, hint: tr('Owner, marketing head…'), maxLength: 60),
            const SizedBox(height: 14),
            LabeledField(
              key: const ValueKey('adv-phone'),
              label: tr('Mobile number'),
              controller: _phone,
              keyboardType: TextInputType.phone,
              prefix: Text('+91 ', style: inter(15, 600)),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
            ),
            const SizedBox(height: 14),
            LabeledField(key: const ValueKey('adv-email'), label: tr('Email (optional)'), controller: _email, keyboardType: TextInputType.emailAddress),
          ]),
        ),
        WhiteCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('3 · Where and why'), style: inter(16, 700)),
            const SizedBox(height: 14),
            _AreasField(areas: _areas, onChanged: (v) => setState(() => _areas = v)),
            const SizedBox(height: 18),
            MultiChipField(
              label: tr('Your goals'),
              hint: tr('Pick all that fit. Sales on OneLocal is only for brands that also sell here.'),
              options: [for (final id in _strings(g['objectives'])) _objectiveName(id)],
              selected: [for (final id in _objectives) _objectiveName(id)],
              onChanged: (v) => setState(() => _objectives = [for (final n in v) _objectiveId(n)]),
            ),
            const SizedBox(height: 18),
            MultiChipField(
              label: tr('Ad types you are interested in (optional)'),
              options: [for (final f in _formatList) '${f['name']}'],
              selected: [for (final f in _formatList) if (_formats.contains(f['id'])) '${f['name']}'],
              onChanged: (v) => setState(() => _formats = [for (final f in _formatList) if (v.contains('${f['name']}')) '${f['id']}']),
            ),
          ]),
        ),
        WhiteCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('4 · Advertising terms'), style: inter(16, 700)),
            const SizedBox(height: 10),
            Container(
              key: const ValueKey('adv-terms'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final line in '${g['terms'] ?? ''}'.split('\n'))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('•  ', style: inter(13, 700)),
                      Expanded(child: Text(line, style: inter(13, 400, height: 1.4))),
                    ]),
                  ),
              ]),
            ),
            const SizedBox(height: 10),
            KeyedSubtree(
              key: const ValueKey('adv-agree'),
              child: CheckRow(value: _agree, onChanged: (v) => setState(() => _agree = v), text: tr('I agree to the advertising terms and I am authorised to act for this brand.')),
            ),
          ]),
        ),
      ],
      actions: [
        PrimaryAction(key: const ValueKey('adv-submit'), label: tr(_busy ? 'Sending…' : 'Send to OneLocal for review'), onPressed: _busy ? null : _submit),
        const SizedBox(height: 12),
        SecondaryAction(key: const ValueKey('adv-save'), label: tr('Save & exit'), onPressed: _busy ? null : _saveAndExit),
      ],
    );
  }
}

// ============================================================================ where the application is
class AdvertiserStatusScreen extends StatelessWidget {
  const AdvertiserStatusScreen({super.key, this.api, this.auth, required this.application});
  final AdvertiserApi? api;
  final AuthRepository? auth;
  final Map<String, dynamic> application;

  @override
  Widget build(BuildContext context) {
    final a = application;
    final status = '${a['status']}';
    final approved = status == 'approved', rejected = status == 'rejected';
    return OnbPage(
      kicker: 'Advertise on OneLocal',
      title: approved ? 'You are ready to advertise.' : rejected ? 'Not approved yet.' : 'OneLocal is checking your brand.',
      subtitle: approved
          ? 'Your advertiser account is open. Create your first campaign; OneLocal checks every ad before it runs.'
          : rejected
              ? '${a['review_note'] ?? ''}'
              : 'We verify the brand and the person authorised for it, usually within a day. We will let you know.',
      children: [
        OutcomeCard(
          key: const ValueKey('adv-status'),
          icon: approved ? lucideCircleCheck : LucideIcons.clock,
          title: '${a['brand_name'] ?? ''}',
          lines: [
            '${tr('Reference')}: ${a['reference'] ?? ''}',
            '${tr('Category')}: ${a['business_category'] ?? ''}',
            '${tr('Areas')}: ${_strings(a['target_locations']).join(', ')}',
            '${tr('Status')}: ${tr(approved ? 'Approved' : rejected ? 'Not approved' : 'In review')}',
          ],
          noteTitle: tr('No selling needed'),
          noteBody: tr('As an advertiser you do not list products, take orders or get sales payouts. You pay for ads with ad credits (₹).'),
        ),
      ],
      actions: [
        if (approved)
          PrimaryAction(
            key: const ValueKey('adv-open-ads'),
            label: tr('Open Ads'),
            onPressed: () => Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => AdvertiserHomeScreen(auth: auth)), (r) => r.isFirst),
          ),
        if (rejected)
          PrimaryAction(
            key: const ValueKey('adv-edit'),
            label: tr('Change and send again'),
            onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => AdvertiserSignupScreen(api: api, auth: auth))),
          ),
        const SizedBox(height: 12),
        SecondaryAction(label: tr('Switch account'), onPressed: () => leaveOnboarding(context, auth)),
      ],
    );
  }
}

// ============================================================================ the advertiser's app: Ads only
/// What an advertising-only partner sees after sign-in: the Ads dashboard as the whole app, with a menu for the brand profile and
/// signing out. No store tabs.
class AdvertiserHomeScreen extends StatelessWidget {
  const AdvertiserHomeScreen({super.key, this.auth, this.adsApi, this.api});
  final AuthRepository? auth;
  final AdsApi? adsApi;
  final AdvertiserApi? api;

  Future<void> _menu(BuildContext context) async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: kCardLine, borderRadius: BorderRadius.circular(99))),
            const SizedBox(height: 8),
            for (final (key, icon, label) in const [
              ('profile', LucideIcons.badgeCheck, 'Brand profile'),
              ('signout', LucideIcons.logOut, 'Sign out'),
            ])
              ListTile(
                key: ValueKey('adv-menu-$key'),
                leading: Icon(icon, color: kInk),
                title: Text(tr(label), style: inter(15, 700)),
                onTap: () => Navigator.pop(c, key),
              ),
          ]),
        ),
      ),
    );
    if (!context.mounted || pick == null) return;
    if (pick == 'profile') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => BrandProfileScreen(api: api)));
    } else {
      final nav = Navigator.of(context);
      await (auth ?? AuthRepository()).signOut();
      nav.popUntil((r) => r.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) => AdsHomeScreen(api: adsApi, root: true, onMenu: () => _menu(context), advertiserApi: api);
}

// ============================================================================ brand profile (any business)
/// The brand behind the ads. For a store, restaurant or service business, saving it makes the business hybrid: it sells and
/// advertises, and its ad coins stay apart from its sales.
class BrandProfileScreen extends StatefulWidget {
  const BrandProfileScreen({super.key, this.api});
  final AdvertiserApi? api;
  @override
  State<BrandProfileScreen> createState() => _BrandProfileScreenState();
}

class _BrandProfileScreenState extends State<BrandProfileScreen> {
  late final AdvertiserApi _api = widget.api ?? AdvertiserApi();
  Map<String, dynamic>? _p;
  String? _error;
  final _brand = TextEditingController(), _website = TextEditingController(), _rep = TextEditingController(), _role = TextEditingController();
  String? _category;
  List<String> _areas = [], _objectives = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_brand, _website, _rep, _role]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final p = await _api.profile();
      if (!mounted) return;
      final b = ((p['profile'] as Map?) ?? const {}).cast<String, dynamic>();
      setState(() {
        _p = p;
        _brand.text = '${b['brand_name'] ?? ''}';
        final c = '${b['business_category'] ?? ''}';
        _category = c.isEmpty ? null : c;
        _website.text = '${b['website'] ?? ''}';
        _rep.text = '${b['representative_name'] ?? ''}';
        _role.text = '${b['representative_role'] ?? ''}';
        _areas = _strings(b['target_locations']);
        _objectives = _strings(b['objectives']);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : tr('Could not load the brand profile.'));
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    if (_brand.text.trim().length < 2) return showToast(context, tr('Enter your brand name.'));
    setState(() => _busy = true);
    final r = await guarded(context, () => _api.saveProfile({
          'brand_name': _brand.text.trim(),
          'business_category': _category,
          'website': _website.text.trim(),
          'representative_name': _rep.text.trim(),
          'representative_role': _role.text.trim(),
          'target_locations': _areas,
          'objectives': _objectives,
        }));
    if (!mounted) return;
    setState(() => _busy = false);
    if (r != null) {
      showToast(context, tr('Brand profile saved.'));
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final kind = '${p?['partner_kind'] ?? 'commerce'}';
    return Scaffold(
      backgroundColor: kBg,
      body: p == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!, style: inter(14, 500, color: kMuted)))
          : OnbPage(
              kicker: 'Ads',
              caption: 'Brand profile',
              title: 'Your brand',
              subtitle: switch (kind) {
                'advertising' => 'You advertise on OneLocal without selling here.',
                'hybrid' => 'You sell and advertise on OneLocal. Ad credits are kept apart from your sales and payouts.',
                _ => 'Add your brand to advertise it. Your business then sells and advertises; ad credits stay apart from your sales and payouts.',
              },
              children: [
                Container(
                  key: ValueKey('brand-kind-$kind'),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(color: kNote, borderRadius: BorderRadius.circular(99)),
                  child: Text(tr(switch (kind) { 'advertising' => 'Advertising-only partner', 'hybrid' => 'Sells and advertises', _ => 'Sells on OneLocal' }), style: inter(13, 700, color: kLink)),
                ),
                LabeledField(key: const ValueKey('brand-name'), label: tr('Brand name'), controller: _brand, maxLength: 80),
                SelectField(label: tr('Business category'), value: _category, options: _strings(p['categories']), onChanged: (v) => setState(() => _category = v)),
                LabeledField(key: const ValueKey('brand-website'), label: tr('Website (optional)'), controller: _website, keyboardType: TextInputType.url),
                LabeledField(key: const ValueKey('brand-rep'), label: tr('Authorised person'), controller: _rep, inputFormatters: nameFormatters),
                LabeledField(key: const ValueKey('brand-role'), label: tr('Their role (optional)'), controller: _role, maxLength: 60),
                _AreasField(areas: _areas, onChanged: (v) => setState(() => _areas = v)),
                MultiChipField(
                  label: tr('Your goals'),
                  options: [for (final o in objectives) tr(o.$2)],
                  selected: [for (final id in _objectives) _objectiveName(id)],
                  onChanged: (v) => setState(() => _objectives = [for (final n in v) _objectiveId(n)]),
                ),
              ],
              actions: [
                if (p['can_edit'] != false) PrimaryAction(key: const ValueKey('brand-save'), label: tr(_busy ? 'Saving…' : 'Save'), onPressed: _busy ? null : _save),
              ],
            ),
    );
  }
}
