import 'package:flutter/material.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'agreement_screens.dart';
import 'onboarding_api.dart';
import 'onboarding_widgets.dart';

void _help(BuildContext context, Application app) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Need help?', style: inter(20, 600)),
        const SizedBox(height: 12),
        Text('Keep your reference handy when you contact OneLocal support: ${app.reference}. A support contact is not set up in this build yet.', style: inter(14, 400, color: kMuted, height: 1.5)),
      ]),
    ),
  );
}

/// Figma "Onboarding Submitted": the receipt straight after submit.
class SubmittedScreen extends StatelessWidget {
  const SubmittedScreen({super.key, required this.api, required this.app});
  final OnboardingApi api;
  final Application app;
  @override
  Widget build(BuildContext context) {
    final first = app.ownerName.split(' ').first;
    return OnbPage(
      kicker: 'Application · Submitted',
      title: 'Application received.',
      caption: 'Submission receipt',
      onBack: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => StatusScreen(api: api, app: app))),
      subtitle: 'Thanks, $first. Your merchant application has been submitted successfully.',
      children: [
        OutcomeCard(
          title: 'Submitted, not yet approved',
          lines: [app.businessName, 'Your application is safely recorded.'],
          noteTitle: 'What happens next',
          noteBody: 'We’ll review the information and documents you provided. Check your application status for a decision or any requested corrections.',
        ),
        SectionCard(title: 'Submission receipt', lines: ['Reference: ${app.reference}', 'Submitted: ${niceDate(app.submittedAt)}'], chip: const StatusChip('Submitted', Tone.neutral)),
      ],
      actions: [
        PrimaryAction(label: 'View application status', onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => StatusScreen(api: api, app: app)))),
        const SizedBox(height: 12),
        SecondaryAction(label: 'View submitted application', onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => VerificationScreen(api: api, app: app)))),
      ],
    );
  }
}

/// Figma "Onboarding Pending": review timeline. Also shows a rejected application with the reviewer's note.
class StatusScreen extends StatefulWidget {
  const StatusScreen({super.key, required this.api, required this.app});
  final OnboardingApi api;
  final Application app;
  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  late Application _app = widget.app;
  bool _busy = false;

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    final next = await guarded(context, widget.api.get);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (next != null) _app = next;
    });
    if (next?.status == 'approved') {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ApprovedScreen(api: widget.api, app: next!)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rejected = _app.status == 'rejected';
    final steps = {for (final t in _app.timeline) t['key']: t['state']};
    Widget row(String label, String key) {
      final st = steps[key] as String? ?? 'pending';
      final (dot, text, word) = switch (st) {
        'complete' => (const Color(0xFF3DB800), const Color(0xFF1E8A00), 'Complete'),
        'in_progress' => (const Color(0xFF92400E), const Color(0xFF92400E), 'In progress'),
        _ => (kLine, kMuted, 'Pending'),
      };
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 14),
          Expanded(child: Text(label, style: inter(15, 400, color: st == 'pending' ? kMuted : kInk))),
          Text(word, style: inter(14, 400, color: text)),
        ]),
      );
    }

    return OnbPage(
      kicker: rejected ? 'Application · Needs attention' : 'Application · Pending',
      title: rejected ? 'Your application was not approved.' : 'Your review is in progress.',
      caption: 'Application status',
      onBack: () => Navigator.of(context).maybePop(),
      subtitle: rejected ? (_app.reviewNote ?? 'Contact OneLocal support with your reference to find out more.') : 'Your application is waiting for a review decision. There’s nothing else to submit right now.',
      children: [
        SectionCard(title: _app.businessName, lines: ['Reference: ${_app.reference}', 'Submitted: ${niceDate(_app.submittedAt)}'], chip: StatusChip(rejected ? 'Not approved' : 'Pending review', rejected ? Tone.bad : Tone.warn)),
        Text('Review timeline', style: inter(24, 700)),
        WhiteCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Application checkpoints', style: inter(15, 600)),
          const SizedBox(height: 8),
          row('Application received', 'received'),
          row('Details & document review', 'review'),
          row('Review decision', 'decision'),
        ])),
        const NoteCard(title: 'No duplicate submission needed', body: 'Keep your reference handy when contacting support. If anything needs correcting, it will appear in your status.'),
      ],
      actions: [
        PrimaryAction(label: _busy ? 'Checking…' : 'Refresh status', onPressed: _busy ? null : _refresh),
        const SizedBox(height: 12),
        SecondaryAction(label: 'Get help', onPressed: () => _help(context, _app)),
        const SizedBox(height: 12),
        const FooterNote('We’ll share updates through your verified contact details.'),
      ],
    );
  }
}

/// Figma "Onboarding Approved". Workspace setup (Figma section C) is a later phase, so its button says so.
class ApprovedScreen extends StatelessWidget {
  const ApprovedScreen({super.key, required this.api, required this.app});
  final OnboardingApi api;
  final Application app;
  @override
  Widget build(BuildContext context) {
    return OnbPage(
      kicker: 'Application · Approved',
      title: 'Your application is approved.',
      caption: 'Review decision',
      onBack: () => Navigator.of(context).maybePop(),
      subtitle: 'Your business review is complete. Finish workspace setup before you start using your merchant tools.',
      children: [
        OutcomeCard(
          title: 'Business review approved',
          lines: [app.businessName, 'Reference: ${app.reference}'],
          noteTitle: 'Next: workspace readiness',
          noteBody: 'Approval confirms the review decision. Your workspace preferences and first catalogue setup are still outstanding.',
        ),
        const SectionCard(title: 'Remaining setup', action: 'Set up', lines: ['Confirm workspace preferences', 'Set up your first catalogue'], chip: StatusChip('Setup pending', Tone.warn)),
      ],
      actions: [
        PrimaryAction(label: 'Finish workspace setup', onPressed: () => showToast(context, 'Workspace setup opens in the next release.')),
        const SizedBox(height: 12),
        SecondaryAction(label: 'View approved application', onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => VerificationScreen(api: api, app: app)))),
      ],
    );
  }
}

/// Figma "Onboarding Complete". Shown once workspace setup (a later phase) is done; [onGo] opens the workspace.
class CompleteScreen extends StatelessWidget {
  const CompleteScreen({super.key, required this.app, this.onGo, this.city = ''});
  final Application app;
  final VoidCallback? onGo;
  final String city;
  @override
  Widget build(BuildContext context) {
    final first = app.ownerName.split(' ').first;
    return OnbPage(
      kicker: 'Application · Complete',
      title: 'You’re all set, $first.',
      caption: 'Setup complete',
      onBack: () => Navigator.of(context).maybePop(),
      subtitle: 'Your business is approved and workspace setup is complete. Welcome to OneLocal.',
      children: [
        OutcomeCard(
          title: 'Onboarding complete',
          lines: [app.businessName, 'Business approved · Workspace ready'],
          noteTitle: 'Ready for your next step',
          noteBody: 'Your application sections, workspace preferences and first catalogue setup are complete. Open your workspace to get started.',
        ),
        ProgressLine(done: app.total, total: app.total, percent: 100),
        SectionCard(title: 'Workspace readiness', lines: ['Workspace preferences · Complete', 'First catalogue setup · Complete', 'Reference: ${app.reference}'], chip: const StatusChip('Ready', Tone.done)),
      ],
      actions: [
        PrimaryAction(label: 'Go to workspace', onPressed: onGo ?? () => showToast(context, 'Your workspace opens in the next release.')),
        const SizedBox(height: 12),
        FooterNote([app.businessName, city].where((s) => s.isNotEmpty).join(' · ')),
      ],
    );
  }
}
