import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../orders/order_widgets.dart' show OrdersTopBar, kChipGreen, kGreenText, kLimeSoft, kWarnBg, kWarnText;
import '../states/state_kit.dart' show StateTone, StatusCard;
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'returns_api.dart';
import 'settings_widgets.dart';

/// A category the store sets a policy for; [id] null is "All other items".
typedef RrTarget = ({String? id, String name});

/// Settings → Returns & refunds (founder's spec, 29 Oct 2026, Phase 1): what customers can always claim, each category's policy
/// (or OneLocal's suggestion when none is set), "All other items", and the handover rules (a photo before the rider takes the order,
/// the bulk-order checklist). What may be saved is the database's decision (`can_edit`).
class ReturnsHomeScreen extends StatefulWidget {
  const ReturnsHomeScreen({super.key, this.api});
  final ReturnsApi? api;

  @override
  State<ReturnsHomeScreen> createState() => _ReturnsHomeScreenState();
}

class _ReturnsHomeScreenState extends State<ReturnsHomeScreen> {
  late final ReturnsApi _api = widget.api ?? ReturnsApi();
  Map<String, dynamic>? _h;
  String? _error;
  bool _busy = false;

  /// Picking several categories to set at once; null when not picking.
  Set<String?>? _pick;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final h = await _api.home();
      if (mounted) setState(() => _h = h);
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : 'Could not reach the server. Check your connection and try again.');
    }
  }

  List<RrTemplate> get _templates => [for (final t in _h?['templates'] as List? ?? const []) RrTemplate((t as Map).cast<String, dynamic>())];
  List<Map<String, dynamic>> get _cats => [for (final c in _h?['categories'] as List? ?? const []) (c as Map).cast<String, dynamic>()];
  bool get _canEdit => _h?['can_edit'] == true;

  RrTemplate? _template(String? id) => _templates.where((t) => t.id == id).firstOrNull;

  Future<void> _edit(List<RrTarget> targets, {Map<String, dynamic>? policy, String? suggested, int versions = 0}) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => PolicyEditScreen(
        api: _api,
        templates: _templates,
        targets: targets,
        policy: policy,
        suggested: suggested,
        versions: versions,
        canEdit: _canEdit,
      ),
    ));
    if (!mounted) return;
    if (saved == true) {
      setState(() => _pick = null);
      showToast(context, targets.length == 1 ? 'Policy turned on for ${targets.first.name}.' : 'Policy turned on for ${targets.length} categories.');
    }
    _load();
  }

  Future<void> _saveSettings({bool? photo, int? bulk}) async {
    setState(() => _busy = true);
    final h = await guarded(context, () => _api.saveSettings(dispatchPhoto: photo, bulkItems: bulk));
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (h != null) _h = h;
    });
  }

  Future<void> _bulkSheet() async {
    var n = (_h?['bulk_items'] as num?)?.toInt() ?? 10;
    final picked = await showSettingsSheet<int>(
      context,
      title: 'Bulk order checklist',
      subtitle: 'When an order has this many items or more, customers tick off each item on delivery.',
      body: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _Stepper(
            keyPrefix: 'rr-bulk',
            value: '$n items',
            onMinus: n > 2 ? () => set(() => n = n > 6 ? n - 5 : n - 1) : null,
            onPlus: n < 200 ? () => set(() => n = n >= 5 ? (n + 5).clamp(2, 200) : n + 1) : null,
          ),
          const SizedBox(height: 18),
          SaveButton(key: const ValueKey('rr-bulk-save'), label: tr('Save'), onPressed: () => Navigator.of(ctx).pop(n)),
        ]),
      ),
    );
    if (picked != null && picked != (_h?['bulk_items'] as num?)?.toInt()) await _saveSettings(bulk: picked);
  }

  @override
  Widget build(BuildContext context) {
    final h = _h;
    return PopScope(
      canPop: _pick == null,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) setState(() => _pick = null);
      },
      child: Scaffold(
        backgroundColor: kBg,
        body: Column(children: [
          OrdersTopBar(title: tr('Returns & refunds'), onBack: () => _pick != null ? setState(() => _pick = null) : Navigator.of(context).maybePop()),
          Expanded(
            child: h == null
                ? (_error == null
                    ? const Center(child: CircularProgressIndicator(color: kInk))
                    : Padding(
                        padding: const EdgeInsets.all(20),
                        child: Center(
                          child: StatusCard(icon: LucideIcons.circleAlert, tone: StateTone.warn, title: 'Could not open Returns & refunds', body: _error!, primaryLabel: tr('Try again'), onPrimary: _load),
                        ),
                      ))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: _body(h)),
                  ),
          ),
          if (_pick != null) _pickBar(),
        ]),
      ),
    );
  }

  List<Widget> _body(Map<String, dynamic> h) {
    final def = (h['default'] as Map?)?.cast<String, dynamic>();
    final others = (h['uncategorised_items'] as num?)?.toInt() ?? 0;
    return [
      Text(
        tr('Pick a policy once for each category. Every item in it follows that policy, including new ones, and customers see it before they pay.'),
        style: inter(13, 400, color: kMuted, height: 1.4),
      ),
      const SizedBox(height: 12),
      const _AlwaysCovered(),
      if (!_canEdit) ...[const SizedBox(height: 12), const _ReadOnly()],
      Row(children: [
        Expanded(child: GroupTitle(tr('Your categories'))),
        if (_canEdit && _pick == null && _cats.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: RowAction(tr('Set several at once'), key: const ValueKey('rr-multi'), onTap: () => setState(() => _pick = {})),
          ),
      ]),
      if (_cats.isEmpty)
        EmptyPanel(title: tr('No categories yet'), body: tr('Add categories to your items, or set one policy for all items below.'))
      else
        GroupCard(children: [for (final c in _cats) _catRow(c)]),
      const SizedBox(height: 10),
      GroupCard(children: [
        _row(
          key: 'default',
          target: (id: null, name: 'All other items'),
          subtitleTop: others > 0 ? '$others ${others == 1 ? 'item' : 'items'} without a category, and categories with no policy' : 'Categories with no policy of their own',
          policy: def,
          suggested: 'packaged',
          versions: def == null ? 0 : (def['version'] as num).toInt(),
        ),
      ]),
      GroupTitle(tr('Handover & delivery')),
      GroupCard(children: [
        SettingRow(
          key: const ValueKey('rr-dispatch-row'),
          icon: LucideIcons.camera,
          title: tr('Photo before handover'),
          subtitle: tr('Take a photo of the packed order before the rider takes it. It protects you if a customer says something was missing.'),
          actions: [
            LimeSwitch(
              key: const ValueKey('rr-dispatch-photo'),
              label: tr('Photo before handover'),
              value: h['dispatch_photo'] != false,
              onChanged: _canEdit && !_busy ? (v) => _saveSettings(photo: v) : null,
            ),
          ],
        ),
        SettingRow(
          key: const ValueKey('rr-bulk-row'),
          icon: LucideIcons.listChecks,
          title: tr('Bulk order checklist'),
          subtitle: 'Customers tick off each item when an order has ${(h['bulk_items'] as num?)?.toInt() ?? 10} or more items',
          actions: [if (_canEdit) RowAction(tr('Edit'), key: const ValueKey('rr-bulk-edit'), onTap: _busy ? null : _bulkSheet)],
        ),
      ]),
      const SizedBox(height: 14),
      Text(
        tr('Refunds go back to the way the customer paid. Claims, refunds and payout adjustments will show here once customers can raise them in the OneLocal app.'),
        style: inter(12, 400, color: kMuted, height: 1.4),
      ),
    ];
  }

  Widget _catRow(Map<String, dynamic> c) {
    final items = (c['items'] as num?)?.toInt() ?? 0;
    return _row(
      key: c['id'] as String,
      target: (id: c['id'] as String, name: c['name'] as String),
      subtitleTop: '$items ${items == 1 ? 'item' : 'items'}',
      policy: (c['policy'] as Map?)?.cast<String, dynamic>(),
      suggested: c['suggested'] as String?,
      versions: (c['versions'] as num?)?.toInt() ?? 0,
    );
  }

  Widget _row({required String key, required RrTarget target, required String subtitleTop, Map<String, dynamic>? policy, String? suggested, int versions = 0}) {
    final pick = _pick;
    final picked = pick?.contains(target.id) ?? false;
    final tpl = _template(policy?['template_id'] as String? ?? suggested);
    final set = policy != null;
    return InkWell(
      key: ValueKey('rr-cat-$key'),
      onTap: pick != null
          ? () => setState(() => picked ? pick.remove(target.id) : pick.add(target.id))
          : () => _edit([target], policy: policy, suggested: suggested, versions: versions),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
        child: Row(children: [
          if (pick != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(picked ? LucideIcons.squareCheck : LucideIcons.square, key: ValueKey('rr-pick-$key'), size: 22, color: picked ? kGreenText : kMuted),
            ),
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: set ? kChipGreen : kWarnBg, borderRadius: BorderRadius.circular(12)),
            child: Icon(set ? LucideIcons.shieldCheck : LucideIcons.shield, size: 18, color: set ? kGreenText : kWarnText),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(tr(target.name), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14.5, 600))),
                const SizedBox(width: 6),
                if (set)
                  _Tag('v${policy['version']}', key: ValueKey('rr-version-$key'))
                else
                  _Tag(tr('Not set'), warn: true, key: ValueKey('rr-unset-$key')),
              ]),
              const SizedBox(height: 2),
              Text(
                set ? '${tr(subtitleTop)} · ${tpl?.name ?? ''}' : '${tr(subtitleTop)} · ${tr('Suggested')}: ${tpl?.name ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: inter(12, 400, color: kMuted),
              ),
              if (set) ...[
                const SizedBox(height: 3),
                Text(policy['label'] as String? ?? '', key: ValueKey('rr-label-$key'), style: inter(12.5, 600, color: kGreenText, height: 1.3)),
              ],
            ]),
          ),
          if (pick == null) const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
        ]),
      ),
    );
  }

  Widget _pickBar() {
    final pick = _pick!;
    final targets = <RrTarget>[
      for (final c in _cats)
        if (pick.contains(c['id'])) (id: c['id'] as String, name: c['name'] as String),
      if (pick.contains(null)) (id: null, name: 'All other items'),
    ];
    // the suggestion of the first picked category, so the editor opens on something sensible
    final first = _cats.where((c) => pick.contains(c['id'])).firstOrNull;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: kLine))),
      child: SafeArea(
        top: false,
        child: SaveButton(
          key: const ValueKey('rr-pick-go'),
          label: targets.isEmpty ? tr('Pick categories') : (targets.length == 1 ? 'Set policy for 1 category' : 'Set policy for ${targets.length} categories'),
          onPressed: targets.isEmpty ? null : () => _edit(targets, suggested: first?['suggested'] as String?),
        ),
      ),
    );
  }
}

/// Choose OneLocal's policy and its options for one or more categories, then read the terms and agree.
class PolicyEditScreen extends StatefulWidget {
  const PolicyEditScreen({
    super.key,
    required this.api,
    required this.templates,
    required this.targets,
    this.policy,
    this.suggested,
    this.versions = 0,
    this.canEdit = true,
  });
  final ReturnsApi api;
  final List<RrTemplate> templates;
  final List<RrTarget> targets;

  /// The category's active policy (one target only), or null.
  final Map<String, dynamic>? policy;
  final String? suggested;
  final int versions;
  final bool canEdit;

  @override
  State<PolicyEditScreen> createState() => _PolicyEditScreenState();
}

class _PolicyEditScreenState extends State<PolicyEditScreen> {
  late PolicyChoice _c;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final p = widget.policy;
    _c = p != null ? PolicyChoice.fromPolicy(p) : (_byId(widget.suggested) ?? widget.templates.first).defaults();
  }

  RrTemplate? _byId(String? id) => widget.templates.where((t) => t.id == id).firstOrNull;
  RrTemplate get _t => _byId(_c.templateId) ?? widget.templates.first;
  List<String?> get _ids => [for (final t in widget.targets) t.id];

  String get _title => widget.targets.length == 1 ? widget.targets.first.name : '${widget.targets.length} categories';

  void _pickTemplate(RrTemplate t) {
    if (t.id == _c.templateId) return;
    setState(() => _c = t.defaults());
  }

  Future<void> _review() async {
    setState(() => _busy = true);
    final pre = await guarded(context, () => widget.api.savePolicy(_c, categoryIds: _ids, preview: true));
    if (!mounted) return;
    setState(() => _busy = false);
    if (pre == null) return;
    final ok = await showSettingsSheet<bool>(
      context,
      title: 'Read and agree',
      subtitle: widget.targets.length == 1 ? 'This turns on the policy for ${widget.targets.first.name}.' : 'This turns on the same policy for ${widget.targets.length} categories.',
      body: (ctx) => _AgreeBody(terms: pre['terms'] as String? ?? '', label: pre['label'] as String? ?? _c.label, onAgree: () => widget.api.savePolicy(_c, categoryIds: _ids, agree: true)),
    );
    if (ok == true && mounted) Navigator.of(context).pop(true);
  }

  Future<void> _history() async {
    final id = widget.targets.first.id;
    await showSettingsSheet<void>(
      context,
      title: 'Past versions',
      subtitle: 'Orders keep the version they were sold under.',
      body: (ctx) => FutureBuilder<Map<String, dynamic>>(
        future: widget.api.history(id),
        builder: (ctx, snap) {
          if (snap.hasError) return Text(snap.error is PartnerApiException ? (snap.error as PartnerApiException).message : tr('Could not load. Try again.'), style: inter(13, 500, color: kMuted));
          if (!snap.hasData) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(color: kInk)));
          final vs = [for (final v in snap.data!['versions'] as List? ?? const []) (v as Map).cast<String, dynamic>()];
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final v in vs) _VersionCard(v, name: _byId(v['template_id'] as String?)?.name),
          ]);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final windows = t.windows;
    final wi = windows.indexOf(_c.windowHours);
    final edit = widget.canEdit;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        OrdersTopBar(title: _title, onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
            if (widget.targets.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(widget.targets.map((e) => e.name).join(', '), style: inter(12.5, 500, color: kMuted)),
              ),
            GroupTitle(tr('OneLocal policy')),
            for (final x in widget.templates) _TemplateTile(x, selected: x.id == t.id, suggested: x.id == widget.suggested, onTap: edit ? () => _pickTemplate(x) : null),
            GroupTitle(tr('Your choices')),
            GroupCard(children: [
              if (t.changeAllowed)
                SettingRow(
                  icon: LucideIcons.undo2,
                  title: tr('Change-of-mind returns'),
                  subtitle: tr('Customers may return an item they no longer want'),
                  actions: [LimeSwitch(key: const ValueKey('rr-change'), label: tr('Change-of-mind returns'), value: _c.changeOfMind, onChanged: edit ? (v) => setState(() => _c.changeOfMind = v) : null)],
                )
              else
                SettingRow(icon: LucideIcons.ban, title: tr('No change-of-mind returns'), subtitle: tr('OneLocal does not allow them for ${t.name.toLowerCase()}')),
              if (t.changeAllowed && _c.changeOfMind)
                SettingRow(
                  icon: LucideIcons.packageCheck,
                  title: tr('Sealed items only'),
                  subtitle: tr('Only unopened items with the seal intact'),
                  actions: [LimeSwitch(key: const ValueKey('rr-sealed'), label: tr('Sealed items only'), value: _c.sealedOnly, onChanged: edit ? (v) => setState(() => _c.sealedOnly = v) : null)],
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr(_c.changeOfMind ? 'Time to return or report a problem' : 'Time to report a problem'), style: inter(14.5, 600)),
                  const SizedBox(height: 2),
                  Text('From delivery. OneLocal allows ${windowWords(t.minHours)} to ${windowWords(t.maxHours)}.', style: inter(12, 400, color: kMuted)),
                  const SizedBox(height: 10),
                  _Stepper(
                    keyPrefix: 'rr-window',
                    value: windowWords(_c.windowHours),
                    onMinus: edit && wi > 0 ? () => setState(() => _c.windowHours = windows[wi - 1]) : null,
                    onPlus: edit && wi >= 0 && wi < windows.length - 1 ? () => setState(() => _c.windowHours = windows[wi + 1]) : null,
                  ),
                ]),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('How you make it right'), style: inter(14.5, 600)),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final r in kRemedies.keys)
                      if (t.remedies.contains(r))
                        _Chip(
                          tr(kRemedies[r]!),
                          key: ValueKey('rr-remedy-$r'),
                          on: _c.remedies.contains(r),
                          // at least one stays on
                          onTap: !edit || (_c.remedies.length == 1 && _c.remedies.contains(r))
                              ? null
                              : () => setState(() => _c.remedies.contains(r) ? _c.remedies.remove(r) : _c.remedies.add(r)),
                        ),
                  ]),
                ]),
              ),
              SettingRow(
                icon: LucideIcons.scanSearch,
                title: tr('Check returns before refund'),
                subtitle: tr('You check the returned item before the refund goes out'),
                actions: [LimeSwitch(key: const ValueKey('rr-inspect'), label: tr('Check returns before refund'), value: _c.inspection, onChanged: edit ? (v) => setState(() => _c.inspection = v) : null)],
              ),
            ]),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: kLimeSoft, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFD6F5B0))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Customers see before paying'), style: inter(11.5, 700, color: kGreenText).copyWith(letterSpacing: 0.3)),
                const SizedBox(height: 6),
                Text(_c.label, key: const ValueKey('rr-label'), style: inter(15, 700, height: 1.3)),
                const SizedBox(height: 4),
                Text(tr('Wrong, missing, damaged, expired or defective items are always covered.'), style: inter(12, 400, color: kMuted)),
              ]),
            ),
            if (widget.targets.length == 1 && widget.versions > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Center(
                  child: TextButton.icon(
                    key: const ValueKey('rr-history'),
                    onPressed: _history,
                    icon: const Icon(LucideIcons.history, size: 16, color: kInk),
                    label: Text(widget.versions == 1 ? tr('See who agreed and when') : 'See all ${widget.versions} versions', style: inter(13, 600)),
                  ),
                ),
              ),
          ]),
        ),
        if (edit)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: kLine))),
            child: SafeArea(top: false, child: SaveButton(key: const ValueKey('rr-review'), label: tr('Review and turn on'), busy: _busy, onPressed: _review)),
          ),
      ]),
    );
  }
}

/// The terms the database will save, the "I agree" tick and the button that turns the policy on.
class _AgreeBody extends StatefulWidget {
  const _AgreeBody({required this.terms, required this.label, required this.onAgree});
  final String terms, label;
  final Future<Map<String, dynamic>> Function() onAgree;
  @override
  State<_AgreeBody> createState() => _AgreeBodyState();
}

class _AgreeBodyState extends State<_AgreeBody> {
  bool _agreed = false, _busy = false;
  String? _error;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onAgree();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is PartnerApiException ? e.message : tr('Could not save. Try again.');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: kSoftBg, borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final line in widget.terms.split('\n'))
              if (line.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Padding(padding: EdgeInsets.only(top: 6), child: Icon(Icons.circle, size: 5, color: kMuted)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(line, style: inter(13, 400, height: 1.4))),
                  ]),
                ),
          ]),
        ),
        const SizedBox(height: 12),
        FormError(_error),
        InkWell(
          key: const ValueKey('rr-agree'),
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _agreed = !_agreed),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Icon(_agreed ? LucideIcons.squareCheck : LucideIcons.square, size: 22, color: _agreed ? kGreenText : kMuted),
              const SizedBox(width: 10),
              Expanded(child: Text(tr('I have read this policy and agree to it for my store.'), style: inter(13.5, 600))),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        SaveButton(key: const ValueKey('rr-confirm'), label: tr('Turn on policy'), busy: _busy, onPressed: _agreed ? _go : null),
      ]);
}

const kSoftBg = Color(0xFFF5F5F0);

class _TemplateTile extends StatelessWidget {
  const _TemplateTile(this.t, {required this.selected, required this.suggested, required this.onTap});
  final RrTemplate t;
  final bool selected, suggested;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: selected ? kLimeSoft : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: selected ? kGreenText : kLine, width: selected ? 1.5 : 1)),
          child: InkWell(
            key: ValueKey('rr-tpl-${t.id}'),
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(selected ? LucideIcons.circleCheck : LucideIcons.circle, size: 20, color: selected ? kGreenText : kMuted),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(child: Text(tr(t.name), style: inter(14, 700))),
                      if (suggested) ...[const SizedBox(width: 6), _Tag(tr('Suggested'))],
                    ]),
                    const SizedBox(height: 2),
                    Text(tr(t.blurb), style: inter(12, 400, color: kMuted, height: 1.35)),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      );
}

class _VersionCard extends StatelessWidget {
  const _VersionCard(this.v, {this.name});
  final Map<String, dynamic> v;
  final String? name;
  @override
  Widget build(BuildContext context) {
    final consent = (v['consent'] as Map?)?.cast<String, dynamic>();
    final at = DateTime.tryParse(consent?['at'] as String? ?? v['effective_from'] as String? ?? '')?.toLocal();
    final active = v['status'] == 'active';
    return Container(
      key: ValueKey('rr-v-${v['version']}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: active ? kLimeSoft : kSoftBg, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Version ${v['version']}', style: inter(13.5, 700)),
          const SizedBox(width: 6),
          _Tag(active ? tr('In use') : tr('Replaced'), warn: !active),
        ]),
        const SizedBox(height: 4),
        Text('${name ?? ''} · ${v['label'] ?? ''}', style: inter(12.5, 500, height: 1.3)),
        const SizedBox(height: 3),
        Text(
          'Agreed by ${consent?['name'] ?? 'someone at your store'}${at == null ? '' : ' on ${at.day}/${at.month}/${at.year}'}',
          style: inter(12, 400, color: kMuted),
        ),
      ]),
    );
  }
}

/// Green-tick card of the claims customers always have.
class _AlwaysCovered extends StatelessWidget {
  const _AlwaysCovered();
  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('rr-always'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(color: kChipGreen, borderRadius: BorderRadius.circular(10)),
              child: const Icon(LucideIcons.shieldCheck, size: 17, color: kGreenText),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(tr('Always covered'), style: inter(15, 700))),
          ]),
          const SizedBox(height: 6),
          Text(tr('Whatever policy you pick, customers can always claim for these.'), style: inter(12.5, 400, color: kMuted)),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [for (final x in kAlwaysCovered) _Tag(tr(x), big: true)]),
        ]),
      );
}

class _ReadOnly extends StatelessWidget {
  const _ReadOnly();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
        child: Row(children: [
          const Icon(LucideIcons.lock, size: 16, color: kMuted),
          const SizedBox(width: 8),
          Expanded(child: Text(tr('Only the owner or a manager can change return policies.'), key: const ValueKey('rr-readonly'), style: inter(12.5, 400, color: kMuted))),
        ]),
      );
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {super.key, this.warn = false, this.big = false});
  final String text;
  final bool warn, big;
  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: big ? 10 : 7, vertical: big ? 5 : 2),
        decoration: BoxDecoration(color: warn ? kWarnBg : kChipGreen, borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: inter(big ? 12 : 11, 700, color: warn ? kWarnText : kGreenText)),
      );
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, {super.key, required this.on, required this.onTap});
  final String text;
  final bool on;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: on,
        child: Material(
          color: on ? kCheck : kSoftBg,
          shape: StadiumBorder(side: BorderSide(color: on ? kCheck : kLine)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (on) ...[const Icon(LucideIcons.check, size: 15, color: kInk), const SizedBox(width: 5)],
                Text(text, style: inter(13, on ? 700 : 500, color: on ? kInk : kMuted)),
              ]),
            ),
          ),
        ),
      );
}

/// − value + in one pill.
class _Stepper extends StatelessWidget {
  const _Stepper({required this.keyPrefix, required this.value, required this.onMinus, required this.onPlus});
  final String keyPrefix, value;
  final VoidCallback? onMinus, onPlus;
  @override
  Widget build(BuildContext context) {
    Widget btn(String k, IconData i, VoidCallback? f) => Material(
          color: f == null ? const Color(0xFFF1F2EE) : Colors.white,
          shape: const CircleBorder(side: BorderSide(color: kLine)),
          child: InkWell(
            key: ValueKey('$keyPrefix-$k'),
            customBorder: const CircleBorder(),
            onTap: f,
            child: Padding(padding: const EdgeInsets.all(9), child: Icon(i, size: 18, color: f == null ? kMuted : kInk)),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(color: kSoftBg, borderRadius: BorderRadius.circular(30)),
      child: Row(children: [
        btn('minus', LucideIcons.minus, onMinus),
        Expanded(child: Text(value, key: ValueKey('$keyPrefix-value'), textAlign: TextAlign.center, style: inter(16, 800))),
        btn('plus', LucideIcons.plus, onPlus),
      ]),
    );
  }
}
