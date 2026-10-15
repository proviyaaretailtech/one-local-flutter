import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../auth/auth_repository.dart';
import '../ui/forgot_password_sheet.dart' show isEmail;
import '../ui/mask.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'otp_verify_screen.dart';

/// Figma "Personal Registration". Verification is by code (phone), so no password is asked.
class RegisterPersonalScreen extends StatefulWidget {
  const RegisterPersonalScreen({super.key, this.auth});
  final AuthRepository? auth;
  @override
  State<RegisterPersonalScreen> createState() => _RegisterPersonalScreenState();
}

class _RegisterPersonalScreenState extends State<RegisterPersonalScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _phoneFocus = FocusNode();
  final _emailFocus = FocusNode();
  late final _auth = widget.auth ?? AuthRepository();
  bool _ageOk = false;
  bool _termsOk = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _phone, _email]) {
      c.dispose();
    }
    _phoneFocus.dispose();
    _emailFocus.dispose();
    super.dispose();
  }

  String get _digits => _phone.text.replaceAll(RegExp(r'\D'), '');

  Future<void> _create() async {
    final problem = !_name.text.trim().isNotEmpty
        ? 'Please enter your full name.'
        : _digits.length != 10
            ? 'Please enter a 10-digit mobile number.'
            : !isEmail(_email.text)
                ? 'Please enter a valid email address.'
                : !_ageOk
                    ? 'Please confirm the age eligibility to continue.'
                    : !_termsOk
                        ? 'Please agree to the service terms to continue.'
                        : null;
    if (problem != null) {
      if (mounted) showToast(context, problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final e164 = '+91$_digits';
    try {
      await _auth.registerWithPhone(e164: e164, fullName: _name.text.trim(), email: _email.text.trim().toLowerCase());
      if (!mounted) return;
      showToast(context, 'Code sent to ${maskPhone(e164)}');
      Navigator.push(context, MaterialPageRoute(builder: (_) => OtpVerifyScreen(phone: e164, registering: true, auth: _auth)));
    } catch (e) {
      if (mounted) showToast(context, friendlyAuthError(e, fallback: 'Could not create the account. Check the details and try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _checkbox(bool on) {
    return Container(
      width: 18,
      height: 18,
      margin: const EdgeInsets.only(top: 1),
      decoration: BoxDecoration(
        color: on ? kCheck : Colors.white,
        borderRadius: BorderRadius.circular(5),
        border: on ? null : Border.all(color: kFieldBorder, width: 1.5),
      ),
      alignment: Alignment.center,
      child: on ? SvgPicture.asset('assets/figma/check.svg', width: 13, height: 13) : null,
    );
  }

  Widget _consent({required bool value, required VoidCallback onTap, required String title, String? note}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _checkbox(value),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: inter(13, 400, height: 1.5)),
                  if (note != null) ...[const SizedBox(height: 4), Text(note, style: inter(12, 400, color: kMuted, height: 1.5))],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScreenShell(
      gradient: kRegistrationGradient,
      children: [
        const BrandNav(),
        StepNav(caption: 'Account details', onBack: () => Navigator.pop(context)),
        Padding(
          padding: const EdgeInsets.fromLTRB(kPadX, 12, kPadX, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Kicker('Registration · Personal', size: 11),
              const SizedBox(height: 12),
              const PageIntro(
                title: 'Create your account.',
                subtitle: 'A few details to get started. We’ll help you verify your contact information next.',
                titleSize: 30,
                subtitleSize: 14,
              ),
              const SizedBox(height: 24),
              LabeledField(
                label: 'Full name',
                labelSize: 13,
                labelWeight: 500,
                controller: _name,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _phoneFocus.requestFocus(),
                autofillHints: const [AutofillHints.name],
              ),
              const SizedBox(height: 16),
              LabeledField(
                label: 'Mobile number',
                labelSize: 13,
                labelWeight: 500,
                controller: _phone,
                focusNode: _phoneFocus,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _emailFocus.requestFocus(),
                maxLength: 10,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
                autofillHints: const [AutofillHints.telephoneNumberNational],
                prefix: Row(children: [
                  Text('+91', style: inter(15, 500)),
                  const SizedBox(width: 10),
                  Container(width: 1, height: 20, color: kLine),
                ]),
              ),
              const SizedBox(height: 16),
              LabeledField(
                label: 'Email address',
                labelSize: 14,
                labelWeight: 600,
                labelGap: 7,
                controller: _email,
                focusNode: _emailFocus,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _create(),
                autofillHints: const [AutofillHints.email],
                trailingSvg: 'assets/figma/mail_reg.svg',
              ),
              const SizedBox(height: 20),
              _consent(
                value: _ageOk,
                onTap: () => setState(() => _ageOk = !_ageOk),
                title: 'I confirm that I meet the age eligibility described in the service terms.',
                note: 'Review the eligibility information before continuing.',
              ),
              const SizedBox(height: 20),
              _consent(
                value: _termsOk,
                onTap: () => setState(() => _termsOk = !_termsOk),
                title: 'I agree to the service terms and acknowledge the privacy notice.',
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  InkWell(onTap: () => showLegalSheet(context, 'Service terms'), child: Text('Service terms', style: inter(14, 600, color: kLink, height: 1.5))),
                  Text(' · ', style: inter(14, 600, color: kLink, height: 1.5)),
                  InkWell(onTap: () => showLegalSheet(context, 'Privacy notice'), child: Text('Privacy notice', style: inter(14, 600, color: kLink, height: 1.5))),
                ],
              ),
              if (_error != null) ...[const SizedBox(height: 12), Text(_error!, style: inter(13, 500, color: kError))],
            ],
          ),
        ),
      ],
      actions: [
        PrimaryAction(label: _busy ? 'Creating…' : 'Create account', onPressed: _busy ? null : _create),
        const SizedBox(height: 12),
        const FooterNote('Your contact details are used to secure your account.'),
      ],
    );
  }
}
