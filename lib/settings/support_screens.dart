import 'dart:math';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../orders/order_widgets.dart' show OrdersTopBar, DarkCta, OrderCardBox;
import '../states/state_kit.dart';
import '../ui/theme.dart';
import 'settings_api.dart';
import 'settings_sheets.dart';
import 'settings_widgets.dart';
import '../ui/i18n.dart';

String _newKey() => 'sup-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}';

/// Support & Help (Figma section P): search, frequently asked questions, help categories, support hours, Contact Support and the
/// business's own requests. The FAQ is static server content; the requests come from the database.
class SupportScreen extends StatefulWidget {
  SupportScreen({super.key, SettingsEnv? env}) : env = env ?? SettingsEnv();
  final SettingsEnv env;
  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen> {
  Map<String, dynamic>? _help;
  List<Map<String, dynamic>> _requests = const [];
  String? _error;
  bool _offline = false;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final help = await widget.env.api.help();
      final list = await widget.env.api.supportList();
      if (!mounted) return;
      setState(() {
        _help = {...help, 'hours': list['hours'] ?? help['hours']};
        _requests = ((list['requests'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is PartnerApiException ? e.message : 'Could not reach the server. Check your connection and try again.';
        _offline = e is! PartnerApiException;
      });
    }
  }

  List<Map<String, dynamic>> _list(String k) => ((_help?[k] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();

  Future<void> _contact([String? topic]) async {
    final ref = await openContactSheet(context, widget.env, topic: topic);
    if (ref != null && mounted) {
      showToast(context, 'Request $ref sent.');
      _load();
    }
  }

  void _faq(Map<String, dynamic> f) => showSettingsSheet<void>(context, title: '${f['question']}', body: (_) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('${f['answer']}', style: inter(14, 400, color: kMuted, height: 1.5))));

  @override
  Widget build(BuildContext context) {
    final help = _help;
    final q = _q.trim().toLowerCase();
    final faq = _list('faq').where((f) => q.isEmpty || '${f['question']} ${f['answer']}'.toLowerCase().contains(q)).toList();
    final cats = _list('categories').where((c) => q.isEmpty || '${c['title']} ${c['hint']}'.toLowerCase().contains(q)).toList();
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        OrdersTopBar(title: tr('Support & Help'), onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: help == null
              ? (_error == null
                  ? const Center(child: CircularProgressIndicator(color: kInk))
                  : Padding(
                      padding: const EdgeInsets.all(20),
                      child: Center(child: StatusCard(icon: _offline ? LucideIcons.wifiOff : LucideIcons.circleAlert, tone: StateTone.warn, title: _offline ? 'You’re offline' : 'Could not open Support', body: _error!, primaryLabel: tr('Try again'), onPrimary: _load)),
                    ))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 32), children: [
                    Text(tr('We’re here to help you run your store.'), style: inter(13.5, 400, color: kMuted)),
                    const SizedBox(height: 12),
                    Container(
                      height: 46,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(23), border: Border.all(color: kLine)),
                      child: Row(children: [
                        const Icon(LucideIcons.search, size: 18, color: kMuted),
                        const SizedBox(width: 10),
                        Expanded(child: TextField(onChanged: (v) => setState(() => _q = v), style: inter(14, 400), decoration: InputDecoration(border: InputBorder.none, isCollapsed: true, hintText: tr('Search help articles…'), hintStyle: inter(14, 400, color: kMuted)))),
                      ]),
                    ),
                    if (faq.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      Text(tr('Frequently asked questions'), style: inter(15, 700)),
                      const SizedBox(height: 8),
                      GroupCard(children: [for (final f in faq) _Row(icon: LucideIcons.circleQuestionMark, title: '${f['question']}', onTap: () => _faq(f))]),
                    ],
                    if (cats.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      Text(tr('Help categories'), style: inter(15, 700)),
                      const SizedBox(height: 8),
                      GroupCard(children: [for (final c in cats) _Row(icon: _catIcon('${c['id']}'), title: '${c['title']}', hint: '${c['hint']}', onTap: () => _contact('${c['topic']}'))]),
                    ],
                    if (faq.isEmpty && cats.isEmpty) Padding(padding: const EdgeInsets.only(top: 24), child: Text('No help articles match “$_q”. Contact support below.', style: inter(13.5, 400, color: kMuted))),
                    const SizedBox(height: 14),
                    Text('Need a hand? Our team is here, ${help['hours']}.', style: inter(13, 400, color: kMuted)),
                    const SizedBox(height: 8),
                    DarkCta(label: tr('Contact Support'), onPressed: () => _contact()),
                    const SizedBox(height: 22),
                    Row(children: [
                      Expanded(child: Text(tr('My Support Requests'), style: inter(15, 700))),
                      Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)), child: Text('${_requests.length} ${_requests.length == 1 ? 'request' : 'requests'}', style: inter(12, 500, color: kMuted))),
                    ]),
                    const SizedBox(height: 10),
                    if (_requests.isEmpty) OrderCardBox(child: Text(tr('No requests yet.'), style: inter(13.5, 400, color: kMuted))),
                    for (final r in _requests) _RequestCard(r),
                  ]),
                ),
        ),
      ]),
    );
  }

  IconData _catIcon(String id) => switch (id) { 'orders' => LucideIcons.shoppingBag, 'payments' => LucideIcons.indianRupee, 'inventory' => LucideIcons.box, _ => LucideIcons.user };
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, this.hint, required this.onTap});
  final IconData icon;
  final String title;
  final String? hint;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(children: [
            Icon(icon, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: inter(14, 600)), if (hint != null) Text(hint!, style: inter(12, 400, color: kMuted))])),
            const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
          ]),
        ),
      );
}

class _RequestCard extends StatelessWidget {
  const _RequestCard(this.r);
  final Map<String, dynamic> r;
  @override
  Widget build(BuildContext context) {
    final status = '${r['status']}';
    final d = DateTime.tryParse('${r['created_at']}')?.toLocal();
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: OrderCardBox(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('#${r['reference']}${d == null ? '' : ' · ${d.day} ${months[d.month - 1]}'}', style: inter(12, 400, color: kMuted))),
            StatusPill(switch (status) { 'resolved' => 'Resolved', 'in_progress' => 'In progress', _ => 'Open' }, good: status == 'resolved'),
          ]),
          const SizedBox(height: 8),
          Text('${r['title']}', style: inter(14.5, 700)),
        ]),
      ),
    );
  }
}

/// Contact Support: a topic and a message. Answers with the new request's reference. One key per opening of the sheet, so a retry
/// after a bad connection never files a second request.
Future<String?> openContactSheet(BuildContext context, SettingsEnv env, {String? topic}) {
  final key = (env.newKey ?? _newKey)();
  const topics = {'orders': 'Orders', 'payments': 'Payments', 'inventory': 'Inventory', 'account': 'Account', 'other': 'Something else'};
  return showSettingsSheet<String>(
    context,
    title: tr('Contact Support'),
    subtitle: tr('Tell us what is wrong and we will get back to you.'),
    body: (_) => FormSheet<String>(
      button: 'Send',
      initial: const {'msg': ''},
      values: {'topic': topic ?? 'other'},
      validate: (f) => f.text('msg').length < 5 ? 'Tell us a little more (at least 5 characters).' : null,
      submit: (f) async {
        final r = await env.api.supportCreate(message: f.text('msg'), topic: f.values['topic'] as String, idempotencyKey: key);
        return '${r['reference']}';
      },
      children: (f) => [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(tr('Topic'), style: inter(13, 700))),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in topics.entries)
                ChoiceChip(
                  label: Text(e.value, style: inter(13, 600)),
                  selected: f.values['topic'] == e.key,
                  onSelected: (_) {
                    f.values['topic'] = e.key;
                    f.refresh();
                  },
                ),
            ]),
          ]),
        ),
        SheetField(label: tr('What happened?'), controller: f.ctl('msg'), hint: tr('Describe the problem'), maxLines: 4, maxLength: 2000),
      ],
    ),
  );
}

/// Feedback: a short thought and an optional screenshot. Same table as support, kind "feedback".
Future<void> openFeedbackSheet(BuildContext context, SettingsEnv env) async {
  final key = (env.newKey ?? _newKey)();
  final ref = await showSettingsSheet<String>(
    context,
    title: tr('Feedback'),
    subtitle: tr('Tell us what you think'),
    body: (_) => FormSheet<String>(
      button: 'Submit',
      initial: const {'msg': ''},
      values: const {'path': null, 'file': null},
      validate: (f) => f.text('msg').length < 5 ? 'Tell us a little more (at least 5 characters).' : null,
      submit: (f) async {
        final r = await env.api.supportCreate(kind: 'feedback', message: f.text('msg'), attachmentPath: f.values['path'] as String?, idempotencyKey: key);
        return '${r['reference']}';
      },
      children: (f) => [
        SheetField(label: '', controller: f.ctl('msg'), hint: tr('Share your thought'), maxLines: 5, maxLength: 2000),
        InkWell(
          key: const Key('feedback-attach'),
          borderRadius: BorderRadius.circular(14),
          onTap: () async {
            final file = await env.picker.pick();
            if (file == null || !context.mounted) return;
            final res = await guarded(context, () => env.api.uploadFile(kind: 'feedback', file: file));
            if (res != null) {
              f.values['path'] = res['path'];
              f.values['file'] = file.name;
              f.refresh();
            }
          },
          child: Container(
            height: 84,
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(14), border: Border.all(color: kFieldBorder)),
            child: Center(child: f.values['file'] == null ? const Icon(LucideIcons.upload, size: 30, color: kMuted) : Text('Attached: ${f.values['file']}', style: inter(13, 600))),
          ),
        ),
      ],
    ),
  );
  if (ref != null && context.mounted) showToast(context, 'Thank you. Your feedback ($ref) was sent.');
}
