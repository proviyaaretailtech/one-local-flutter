import 'package:flutter/material.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'onboarding_api.dart';
import 'onboarding_widgets.dart';

/// The agreement version the server records when the person acknowledges the overview.
const kAgreementVersion = 'partner-agreement-2026-10';

StatusChip _checkChip(Map<String, dynamic>? c) {
  return switch (c?['status']) {
    'verified' => const StatusChip('Verified', Tone.done),
    'under_review' => const StatusChip('Under review', Tone.warn),
    'failed' => const StatusChip('Needs correction', Tone.bad),
    'pending' => const StatusChip('Check pending', Tone.neutral),
    _ => const StatusChip('Not checked yet', Tone.neutral),
  };
}

/// Figma "Business Verification": the four checks behind the application. Saved details are never shown as verified; only the
/// status operations records is.
class VerificationScreen extends StatelessWidget {
  const VerificationScreen({super.key, required this.api, required this.app});
  final OnboardingApi api;
  final Application app;

  @override
  Widget build(BuildContext context) {
    final bank = app.bank;
    final addr = app.address;
    final pan = app.identity['pan_masked'] as String?;
    return OnbPage(
      kicker: 'Business setup',
      title: 'Business verification.',
      caption: 'Verification overview',
      onBack: () => Navigator.of(context).pop(app),
      subtitle: 'Track the checks behind your merchant application. These are separate from phone and email verification.',
      children: [
        SectionCard(title: 'Individual identity', lines: [app.ownerName, pan == null ? 'PAN not added yet' : 'PAN saved: $pan'], chip: _checkChip(app.check('individual_identity'))),
        SectionCard(
          title: 'Business identity',
          lines: [app.businessName, app.document('business_proof') == null ? 'Business proof not added' : 'Business proof added, awaiting review'],
          chip: _checkChip(app.check('business_identity')),
        ),
        SectionCard(
          title: 'Business address',
          lines: [addr['address_line'] as String? ?? '', '${addr['city'] ?? ''} · ${addr['pin_code'] ?? ''} · Address saved'],
          chip: _checkChip(app.check('business_address')),
        ),
        SectionCard(
          title: 'Bank ownership',
          lines: ['${bank?['bank_name'] ?? 'No bank added'} · ${bank?['account_masked'] ?? ''}', 'Ownership check has not started'],
          chip: _checkChip(app.check('bank_ownership')),
        ),
        const NoteCard(green: true, title: 'Verification in progress', body: 'Continue reviewing your application while the outstanding checks are completed.'),
      ],
      actions: [
        PrimaryAction(label: 'Continue to agreement', onPressed: () => Navigator.of(context).pop(app)),
        const SizedBox(height: 12),
        const FooterNote('Saved details are not the same as verified details.'),
      ],
    );
  }
}

/// Figma "Agreement" and "Terms & Consent" on one screen (founder, 27 Oct 2026). The service terms and privacy notice were accepted
/// on Create account, so they are recorded with this step rather than ticked again; marketing updates stay optional. When this is
/// the last section ([last]) the button submits the application too.
class AgreementScreen extends StatefulWidget {
  const AgreementScreen({super.key, required this.api, required this.app, this.last = false});
  final OnboardingApi api;
  final Application app;
  final bool last;
  @override
  State<AgreementScreen> createState() => _AgreementScreenState();
}

class _AgreementScreenState extends State<AgreementScreen> {
  late bool _ack = widget.app.consents['merchant_agreement'] == true;
  late bool _marketing = widget.app.consents['marketing_updates'] == true;
  bool _saving = false;

  Future<void> _accept() async {
    if (_saving) return;
    if (!_ack) return showToast(context, 'Please acknowledge that you have reviewed the agreement.');
    setState(() => _saving = true);
    // the terms and privacy notice accepted on Create account, and the marketing choice made here
    final consents = await guarded(context, () => widget.api.saveConsents({'service_terms': true, 'privacy_notice': true, 'marketing_updates': _marketing}));
    final saved = consents == null || !mounted ? null : await guarded(context, () => widget.api.acceptAgreement(kAgreementVersion));
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved != null) Navigator.of(context).pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    return OnbPage(
      kicker: 'Business setup',
      title: 'Review your agreement.',
      caption: 'Section 6 of 6 · Agreement',
      subtitle: 'Read the agreement overview and open the full document before acknowledging it.',
      children: [
        SectionCard(title: 'Merchant agreement', lines: ['Preview · Version ${kAgreementVersion.replaceFirst('partner-agreement-', '')}', '${widget.app.businessName} · ${widget.app.ownerName}'], chip: const StatusChip('Ready to review', Tone.neutral)),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('What this overview covers', style: inter(19, 600)),
          const SizedBox(height: 14),
          for (final l in const ['Your business profile and the account owner’s role.', 'How to access service information and manage your workspace.', 'Where to find privacy information and support.']) ...[
            Text(l, style: inter(16, 400, height: 1.5)),
            const SizedBox(height: 12),
          ],
          LinkText('View full agreement ↗', align: TextAlign.left, onTap: () => showLegalSheet(context, 'Merchant agreement')),
        ]),
        const NoteCard(title: 'Preview, not legal terms', body: 'This overview does not set fees or binding clauses. Review the actual agreement presented to you before accepting.'),
        CheckRow(value: _ack, onChanged: (v) => setState(() => _ack = v), text: 'I have reviewed this agreement preview and acknowledge the acceptance step.'),
        Text('You accepted the OneLocal service terms and privacy notice when you created your account.', style: inter(14, 400, color: kMuted, height: 1.4)),
        LinkText('Review service terms ↗', align: TextAlign.left, onTap: () => showLegalSheet(context, 'Service terms')),
        LinkText('Review privacy notice ↗', align: TextAlign.left, onTap: () => showLegalSheet(context, 'Privacy notice')),
        CheckRow(value: _marketing, onChanged: (v) => setState(() => _marketing = v), text: 'Send me OneLocal news and marketing updates.', sub: 'Optional.'),
      ],
      actions: [
        PrimaryAction(label: _saving ? 'Saving…' : widget.last ? 'Accept & submit application' : 'Accept & continue', onPressed: _saving ? null : _accept),
        const SizedBox(height: 12),
        const FooterNote('Your acknowledgement is recorded with the date and version.'),
      ],
    );
  }
}

/// Figma "Terms & Consent". Section 7, second half. Terms and privacy are required; marketing is optional.
class ConsentScreen extends StatefulWidget {
  const ConsentScreen({super.key, required this.api, required this.app});
  final OnboardingApi api;
  final Application app;
  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  late bool _terms = widget.app.consents['service_terms'] == true;
  late bool _privacy = widget.app.consents['privacy_notice'] == true;
  late bool _marketing = widget.app.consents['marketing_updates'] == true;
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    if (!_terms) return showToast(context, 'Please agree to the OneLocal service terms to continue.');
    if (!_privacy) return showToast(context, 'Please acknowledge the privacy notice to continue.');
    setState(() => _saving = true);
    final saved = await guarded(context, () => widget.api.saveConsents({'service_terms': true, 'privacy_notice': true, 'marketing_updates': _marketing}));
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved != null) Navigator.of(context).pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    return OnbPage(
      kicker: 'Business setup',
      title: 'Your terms. Your choices.',
      caption: 'Section 6 of 6 · Consent',
      subtitle: 'Review the service and privacy information. Marketing updates are optional and do not affect registration.',
      children: [
        Text('Required acknowledgements', style: inter(19, 600)),
        CheckRow(value: _terms, onChanged: (v) => setState(() => _terms = v), text: 'I agree to the OneLocal service terms.', sub: 'Required to continue.'),
        LinkText('Review service terms ↗', align: TextAlign.left, onTap: () => showLegalSheet(context, 'Service terms')),
        CheckRow(value: _privacy, onChanged: (v) => setState(() => _privacy = v), text: 'I acknowledge the privacy notice and how my information is handled.', sub: 'Required to continue.'),
        LinkText('Review privacy notice ↗', align: TextAlign.left, onTap: () => showLegalSheet(context, 'Privacy notice')),
        Text('Optional communications', style: inter(19, 600)),
        CheckRow(value: _marketing, onChanged: (v) => setState(() => _marketing = v), text: 'Send me OneLocal news and marketing updates.', sub: _marketing ? 'Optional · Selected.' : 'Optional · Not selected.'),
        const NoteCard(green: true, title: 'Review before you submit', body: 'Your acknowledgements are saved with the application. You’ll see a final summary next.'),
      ],
      actions: [
        PrimaryAction(label: _saving ? 'Saving…' : 'Save & continue to review', onPressed: _saving ? null : _save),
        const SizedBox(height: 12),
        const FooterNote('You can change optional communication preferences later.'),
      ],
    );
  }
}
