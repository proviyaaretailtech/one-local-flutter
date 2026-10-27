import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'onboarding_api.dart';
import 'onboarding_widgets.dart';
import 'profile_screens.dart';
import 'section_screens.dart';
import 'status_screens.dart';
import 'agreement_screens.dart';

/// Figma "Onboarding Checklist": seven sections, progress, and the next one to do. When all seven are done the same
/// screen offers "Submit application"; the server refuses a submit that is not complete.
/// One section after another (founder, 27 Oct 2026): saving a section opens the next one straight away, and accepting the agreement
/// when it is the last step submits the application. The checklist is where a person lands to continue later.
class ChecklistScreen extends StatefulWidget {
  const ChecklistScreen({super.key, required this.api, required this.app, this.auth, this.autoNext = false});
  final OnboardingApi api;
  final Application app;
  final AuthRepository? auth;

  /// Open the next section at once (right after the business details).
  final bool autoNext;
  @override
  State<ChecklistScreen> createState() => _ChecklistScreenState();
}

class _ChecklistScreenState extends State<ChecklistScreen> {
  late Application _app = widget.app;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoNext) WidgetsBinding.instance.addPostFrameCallback((_) => _advance());
  }

  Map<String, dynamic>? get _next => _app.sections.where((s) => s['done'] != true).firstOrNull;

  /// On to the next section that is not done.
  void _advance() {
    if (!mounted) return;
    final next = _next;
    if (next != null) _open(next['key'] as String);
  }

  Future<void> _refresh() async {
    final next = await guarded(context, widget.api.get);
    if (next != null && mounted) setState(() => _app = next);
  }

  Future<void> _open(String key) async {
    final api = widget.api;
    final before = _app.done;
    final last = _app.total - _app.done == 1 && _next?['key'] == key; // this section is all that is left
    final Widget screen = switch (key) {
      'business' || 'contact' => MerchantProfileScreen(api: api, type: _app.partnerType ?? 'store', app: _app),
      'address' => AddressScreen(api: api, app: _app),
      'tax' => TaxScreen(api: api, app: _app),
      'documents' => IdentityScreen(api: api, app: _app),
      'bank' => BankScreen(api: api, app: _app),
      _ => AgreementScreen(api: api, app: _app, last: last),
    };
    final result = await Navigator.of(context).push<Application>(MaterialPageRoute(builder: (_) => screen));
    if (!mounted) return;
    if (result != null) setState(() => _app = result);
    await _refresh();
    if (!mounted || _app.done <= before) return; // "save for later", or nothing new: stay here
    if (_app.canSubmit) {
      if (last) await _submit(); // the agreement said "Accept & submit"
      return;
    }
    _advance();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    final saved = await guarded(context, widget.api.submit);
    if (!mounted) return;
    setState(() => _busy = false);
    if (saved != null) Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => SubmittedScreen(api: widget.api, app: saved)));
  }

  @override
  Widget build(BuildContext context) {
    final sections = _app.sections;
    final left = _app.total - _app.done;
    final next = sections.where((s) => s['done'] != true).firstOrNull;
    final ready = _app.canSubmit;
    return OnbPage(
      kicker: 'Application · Draft',
      title: 'Let’s finish your setup.',
      subtitle: '${_app.businessName} · Your application is saved. Complete the remaining sections when you’re ready.',
      caption: 'Onboarding checklist',
      children: [
        ProgressLine(done: _app.done, total: _app.total, percent: _app.percent),
        Column(children: [
          for (final s in sections)
            InkWell(
              onTap: () => _open(s['key'] as String),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: kLine))),
                child: Row(children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(color: s['done'] == true ? kNote : const Color(0xFFE9EAEE), borderRadius: BorderRadius.circular(14)),
                    child: s['done'] == true ? const Icon(Icons.check, color: kLink, size: 22) : null,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s['title'] as String, style: inter(17, 600)),
                      const SizedBox(height: 4),
                      Text('${s['done'] == true ? 'Saved' : 'To do'} · ${s['summary']}', style: inter(14, 400, color: kMuted)),
                    ]),
                  ),
                ]),
              ),
            ),
        ]),
        if (ready)
          const NoteCard(green: true, title: 'Everything is filled in', body: 'Review your answers, then submit. We review the application and tell you the decision here.')
        else if (left > 0)
          NoteCard(
            green: true,
            title: '${const ['Zero', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven'][left.clamp(0, 7)]} section${left == 1 ? '' : 's'} to go',
            body: next == null ? '' : 'Next: ${next['title']} · ${next['summary']}.',
          ),
      ],
      actions: [
        if (ready)
          PrimaryAction(label: _busy ? 'Submitting…' : 'Submit application', onPressed: _busy ? null : _submit)
        else if (next != null)
          PrimaryAction(label: 'Resume ${(next['title'] as String).toLowerCase()}', onPressed: () => _open(next['key'] as String)),
        const SizedBox(height: 12),
        SecondaryAction(label: 'Save & exit', onPressed: () => exitOnboarding(context)),
      ],
    );
  }
}

/// Decides which onboarding screen a person lands on, from the application the server holds.
/// Signed in, no store yet, comes here. Nothing is stored on the phone; the server is the record.
class OnboardingEntry extends StatefulWidget {
  const OnboardingEntry({super.key, this.api, this.auth, this.phone, this.name});
  final OnboardingApi? api;
  final AuthRepository? auth;
  final String? phone;

  /// The owner's name and mobile from sign-up (else the login's), so they are not typed twice.
  final String? name;
  @override
  State<OnboardingEntry> createState() => _OnboardingEntryState();
}

class _OnboardingEntryState extends State<OnboardingEntry> {
  late final _api = widget.api ?? OnboardingApi();
  late Future<Application> _app = _api.get();

  void _retry() {
    final next = _api.get();
    setState(() {
      _app = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Application>(
      future: _app,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Scaffold(body: Center(child: CircularProgressIndicator(color: kLink)));
        if (snap.hasError) {
          return OnbPage(
            kicker: 'Set up',
            title: 'We could not reach OneLocal.',
            subtitle: 'Check your internet connection and try again.',
            children: const [],
            actions: [
              PrimaryAction(label: 'Try again', onPressed: _retry),
              const SizedBox(height: 12),
              SecondaryAction(label: 'Switch account', onPressed: () => leaveOnboarding(context, widget.auth)),
            ],
          );
        }
        final app = snap.data!;
        if (!app.exists) return StartScreen(api: _api, phone: widget.phone ?? widget.auth?.currentPhone, name: widget.name ?? widget.auth?.currentName);
        return switch (app.status) {
          'draft' => app.sellPlan == null
              ? MerchantProfileScreen(api: _api, type: app.partnerType ?? 'store', app: app, phone: widget.phone, name: widget.name)
              : ChecklistScreen(api: _api, app: app, auth: widget.auth),
          'approved' => ApprovedScreen(api: _api, app: app),
          _ => StatusScreen(api: _api, app: app),
        };
      },
    );
  }
}
