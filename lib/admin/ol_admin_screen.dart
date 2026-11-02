import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ads/ads_api.dart';
import '../ads/ads_screens.dart' show coinText, formatName, isBudgetModel, modelName, stageChip;
import '../auth/partner_api.dart';
import '../money/money_style.dart' show kMoneyLime;
import '../money/store_money.dart' show dayMonth;
import '../ui/app_header.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';

/// Is the person signed in a OneLocal platform admin? Asked once ([check]) when the restaurant home opens; the side bar shows
/// "OneLocal Admin" only then. The database decides every admin call again.
class OlAdmin {
  const OlAdmin._();
  static final isAdmin = ValueNotifier<bool>(false);
  static bool _asked = false;

  static Future<void> check({AdsApi? api}) async {
    if (_asked) return;
    _asked = true;
    try {
      isAdmin.value = await (api ?? AdsApi()).adminMe();
    } catch (_) {
      _asked = false; // not signed in yet, or offline: ask again next time
    }
  }
}

/// OneLocal Admin (0635, founder 30 Oct 2026): OneLocal's side of ad credits. Ads to check: approve, ask for changes or reject the ad,
/// then send its price (the restaurant accepts it and pays from its ad credits). Give credits: find a business and give it ad credits
/// in rupees. Only platform admins get answers; anyone else is refused by the database.
class OlAdminScreen extends StatefulWidget {
  const OlAdminScreen({super.key, this.api});
  final AdsApi? api;
  static Route<void> route({AdsApi? api}) => MaterialPageRoute(builder: (_) => OlAdminScreen(api: api));
  @override
  State<OlAdminScreen> createState() => _OlAdminScreenState();
}

class _OlAdminScreenState extends State<OlAdminScreen> {
  late final AdsApi _api = widget.api ?? AdsApi();
  Map<String, dynamic>? _q;
  String? _error;
  int _tab = 0;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final q = await _api.adminQueue(q: _search.text);
      if (mounted) {
        setState(() {
          _q = q;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : 'Could not load. Try again.');
    }
  }

  List<Map<String, dynamic>> _list(String k) => ((_q?[k] as List?) ?? const []).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();

  Future<void> _run(Future<Object?> Function() call, String done) async {
    try {
      await call();
      if (!mounted) return;
      showToast(context, done);
      await _load();
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : 'Could not save. Try again.');
    }
  }

  // ---------------------------------------------------------------------------------------------------------------- the check of an ad
  Future<void> _decide(Map<String, dynamic> a, String decision) async {
    var note = '';
    if (decision != 'approved') {
      final c = TextEditingController();
      final said = await showOlDialog<String>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(decision == 'rejected' ? 'Reject this ad' : 'Ask for changes', style: inter(18, 700)),
          content: TextField(
            key: const ValueKey('admin-note'),
            controller: c,
            autofocus: true,
            maxLength: 300,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'What the business should know'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
            TextButton(key: const ValueKey('admin-note-send'), onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Send')),
          ],
        ),
      );
      if (said == null) return;
      if (said.length < 3) {
        if (mounted) showToast(context, 'Say what to change or why (3 characters or more).');
        return;
      }
      note = said;
    }
    await _run(() => _api.adminReview('${a['id']}', decision, note: note), switch (decision) {
      'approved' => 'Ad approved. Send its price next.',
      'rejected' => 'Ad rejected; any held amount went back.',
      _ => 'Changes asked.',
    });
  }

  /// The price: a rate in rupees for the ad's pricing model, and for per-click / per-view / per-lead the most it may spend.
  Future<void> _price(Map<String, dynamic> a) async {
    final model = '${a['pricing_model'] ?? 'per_day'}';
    final rate = TextEditingController(text: a['rate_coins'] == null ? '' : coinText(a['rate_coins']).replaceFirst('₹', '').replaceAll(',', ''));
    final budget = TextEditingController(text: a['budget_coins'] == null ? '' : '${(a['budget_coins'] as num).round()}');
    final sent = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => Padding(
        padding: EdgeInsets.fromLTRB(18, 16, 18, 18 + MediaQuery.of(c).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Price for ${a['business'] ?? 'this business'}', style: inter(20, 800)),
          Text('${a['title'] ?? ''} · ${formatName(a['format_id'])} · ${modelName(model)} · ${a['days'] ?? '?'} days', style: inter(13, 500, color: kMuted)),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('admin-rate'),
            controller: rate,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: InputDecoration(labelText: 'Rate · ${modelName(model)}', prefixText: '₹ '),
          ),
          if (isBudgetModel(model)) ...[
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('admin-budget'),
              controller: budget,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Most it can spend', prefixText: '₹ '),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('admin-price-send'),
            style: FilledButton.styleFrom(backgroundColor: kInk, minimumSize: const Size.fromHeight(52)),
            onPressed: () {
              final r = num.tryParse(rate.text);
              if (r == null || r <= 0) return showToast(c, 'Enter the rate.');
              final b = num.tryParse(budget.text);
              if (isBudgetModel(model) && (b == null || b <= 0)) return showToast(c, 'Enter the most it can spend.');
              Navigator.pop(c, true);
            },
            child: Text('Send price', style: inter(15, 800, color: Colors.white)),
          ),
        ]),
      ),
    );
    if (sent != true) return;
    await _run(
      () => _api.adminOffer('${a['id']}', model: model, rate: num.parse(rate.text), budget: isBudgetModel(model) ? num.tryParse(budget.text) : null),
      'Price sent. The business accepts it and pays from its ad credits.',
    );
  }

  Widget _adCard(Map<String, dynamic> a) {
    final checked = a['creative_status'] == 'approved';
    final note = '${a['review_note'] ?? ''}';
    return Container(
      key: ValueKey('admin-ad-${a['id']}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('${a['business'] ?? ''}', style: inter(12.5, 700, color: kMuted))),
          stageChip(a['stage']),
        ]),
        const SizedBox(height: 4),
        Text('${a['title'] ?? 'Untitled ad'}', style: inter(16.5, 800)),
        if ('${a['message'] ?? ''}'.isNotEmpty) Text('${a['message']}', style: inter(13.5, 400, color: kMuted)),
        const SizedBox(height: 6),
        Text(
          [
            formatName(a['format_id']),
            '${dayMonth(a['starts_on'] as String?)} – ${dayMonth(a['ends_on'] as String?)}',
            modelName(a['pricing_model']),
            if (a['budget_coins'] != null) 'budget ${coinText(a['budget_coins'])}',
            if (a['media_kind'] != null) '${a['media_kind']}',
          ].join(' · '),
          style: inter(12.5, 500, color: kMuted),
        ),
        if (note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Note: $note', style: inter(12.5, 500))),
        const SizedBox(height: 10),
        if (!checked)
          Row(children: [
            Expanded(child: _button('admin-approve-${a['id']}', 'Approve', LucideIcons.check, () => _decide(a, 'approved'), primary: true)),
            const SizedBox(width: 8),
            Expanded(child: _button('admin-changes-${a['id']}', 'Changes', LucideIcons.pencil, () => _decide(a, 'changes_requested'))),
            const SizedBox(width: 8),
            Expanded(child: _button('admin-reject-${a['id']}', 'Reject', LucideIcons.x, () => _decide(a, 'rejected'))),
          ])
        else
          _button('admin-price-${a['id']}', 'Send price', LucideIcons.indianRupee, () => _price(a), primary: true),
      ]),
    );
  }

  Widget _button(String key, String label, IconData icon, VoidCallback onTap, {bool primary = false}) => FilledButton.icon(
        key: ValueKey(key),
        onPressed: onTap,
        icon: Icon(icon, size: 16, color: primary ? kMoneyLime : kInk),
        label: Text(label, style: inter(13.5, 800, color: primary ? kMoneyLime : kInk)),
        style: FilledButton.styleFrom(
          backgroundColor: primary ? kInk : Colors.white,
          side: primary ? null : const BorderSide(color: kLine),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );

  // ---------------------------------------------------------------------------------------------------------------- giving credits
  Future<void> _give(Map<String, dynamic> b) async {
    final amount = TextEditingController(), note = TextEditingController(text: 'OneLocal ad credits');
    final ok = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => Padding(
        padding: EdgeInsets.fromLTRB(18, 16, 18, 18 + MediaQuery.of(c).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Give ad credits', style: inter(20, 800)),
          Text('${b['name']} · has ${coinText(b['credits'] ?? 0)}', style: inter(13, 500, color: kMuted)),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('admin-give-amount'),
            controller: amount,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(7)],
            decoration: const InputDecoration(labelText: 'Amount', prefixText: '₹ '),
          ),
          const SizedBox(height: 10),
          TextField(key: const ValueKey('admin-give-note'), controller: note, maxLength: 200, decoration: const InputDecoration(labelText: 'Why (the business sees this)')),
          const SizedBox(height: 10),
          FilledButton(
            key: const ValueKey('admin-give-send'),
            style: FilledButton.styleFrom(backgroundColor: kInk, minimumSize: const Size.fromHeight(52)),
            onPressed: () {
              if ((int.tryParse(amount.text) ?? 0) <= 0) return showToast(c, 'Enter the amount.');
              Navigator.pop(c, true);
            },
            child: Text('Give credits', style: inter(15, 800, color: Colors.white)),
          ),
        ]),
      ),
    );
    if (ok != true) return;
    final rupees = int.parse(amount.text);
    await _run(() => _api.grant('${b['id']}', rupees, note: note.text), 'Gave ${coinText(rupees)} of ad credits to ${b['name']}.');
  }

  List<Widget> _credits() {
    final found = _list('businesses'), grants = _list('grants');
    return [
      TextField(
        key: const ValueKey('admin-search'),
        controller: _search,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _load(),
        decoration: InputDecoration(
          hintText: 'Find a business by name',
          prefixIcon: const Icon(LucideIcons.search, size: 18),
          suffixIcon: IconButton(key: const ValueKey('admin-search-go'), icon: const Icon(LucideIcons.arrowRight, size: 18), onPressed: _load),
        ),
      ),
      const SizedBox(height: 10),
      if (_search.text.trim().isNotEmpty && found.isEmpty) Text('No business with that name.', style: inter(14, 500, color: kMuted)),
      for (final b in found)
        Card(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: kLine)),
          child: ListTile(
            key: ValueKey('admin-business-${b['id']}'),
            title: Text('${b['name']}', style: inter(15, 700)),
            subtitle: Text('Ad credits ${coinText(b['credits'] ?? 0)}', style: inter(13, 500, color: kMuted)),
            trailing: const Icon(LucideIcons.gift, size: 20),
            onTap: () => _give(b),
          ),
        ),
      const SizedBox(height: 16),
      Text('Credits given', style: inter(16, 800)),
      const SizedBox(height: 6),
      if (grants.isEmpty) Text('None yet.', style: inter(14, 500, color: kMuted)),
      for (final g in grants)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${g['business']}', style: inter(14.5, 700)),
                Text('${g['note'] ?? ''} · ${dayMonth(g['created_at'] as String?)}', style: inter(12.5, 500, color: kMuted)),
              ]),
            ),
            Text('+${coinText(g['amount'])}', style: inter(15, 800, color: const Color(0xFF15803D))),
          ]),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final review = _list('review');
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(title: 'OneLocal Admin', onBack: () => Navigator.of(context).maybePop()),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(children: [
            for (final (i, label) in [(0, 'Ads to check${review.isEmpty ? '' : ' (${review.length})'}'), (1, 'Give credits')]) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: ChoiceChip(
                  key: ValueKey('admin-tab-$i'),
                  label: SizedBox(width: double.infinity, child: Text(label, textAlign: TextAlign.center, style: inter(13.5, 800, color: _tab == i ? kMoneyLime : kInk))),
                  selected: _tab == i,
                  showCheckmark: false,
                  selectedColor: kInk,
                  backgroundColor: Colors.white,
                  onSelected: (_) => setState(() => _tab = i),
                ),
              ),
            ],
          ]),
        ),
        Expanded(
          child: _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, key: const ValueKey('admin-error'), textAlign: TextAlign.center, style: inter(15, 500, color: kMuted))))
              : _q == null
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
                        if (_tab == 0) ...[
                          if (review.isEmpty) Padding(padding: const EdgeInsets.only(top: 24), child: Text('No ads waiting for OneLocal.', textAlign: TextAlign.center, style: inter(15, 500, color: kMuted))),
                          for (final (i, a) in review.indexed) Entrance(index: i, child: _adCard(a)),
                        ] else
                          ..._credits(),
                      ]),
                    ),
        ),
      ]),
    );
  }
}
