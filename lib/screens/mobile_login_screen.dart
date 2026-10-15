import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/auth_repository.dart';
import '../ui/mask.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'email_login_screen.dart';
import 'otp_verify_screen.dart';

/// Figma "Mobile Login".
class MobileLoginScreen extends StatefulWidget {
  const MobileLoginScreen({super.key, this.auth});
  final AuthRepository? auth;
  @override
  State<MobileLoginScreen> createState() => _MobileLoginScreenState();
}

class _MobileLoginScreenState extends State<MobileLoginScreen> {
  final _phone = TextEditingController();
  late final _auth = widget.auth ?? AuthRepository();
  String _cc = '+91';
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  String get _digits => _phone.text.replaceAll(RegExp(r'\D'), '');

  /// India numbers are exactly 10 digits; other countries 6 to 14.
  String? get _problem {
    if (_cc == '+91') return _digits.length == 10 ? null : 'Please enter a 10-digit mobile number.';
    return (_digits.length >= 6 && _digits.length <= 14) ? null : 'Please enter a valid mobile number.';
  }

  Future<void> _send() async {
    if (_busy) return;
    final problem = _problem;
    if (problem != null) {
      showToast(context, problem);
      return;
    }
    final e164 = '$_cc$_digits';
    setState(() => _busy = true);
    try {
      await _auth.sendPhoneCode(e164);
      if (!mounted) return;
      showToast(context, 'Code sent to ${maskPhone(e164)}');
      Navigator.push(context, MaterialPageRoute(builder: (_) => OtpVerifyScreen(phone: e164, auth: _auth)));
    } catch (e) {
      if (mounted) showToast(context, friendlyAuthError(e, fallback: 'Could not send the code. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeCode() async {
    final picked = await pickCountryCode(context, _cc);
    if (picked != null && mounted) setState(() => _cc = picked);
  }

  @override
  Widget build(BuildContext context) {
    return ScreenShell(
      gradient: kRegistrationGradient,
      children: [
        const BrandNav(),
        FormContent(children: [
          const Kicker('Sign in · Mobile'),
          const PageIntro(title: 'Your number. Your store.', subtitle: 'Use the mobile number registered with your OneLocal account.'),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LabeledField(
                label: 'Mobile number',
                controller: _phone,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _send(),
                maxLength: 14,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(_cc == '+91' ? 10 : 14)],
                autofillHints: const [AutofillHints.telephoneNumberNational],
                hint: _cc == '+91' ? '10-digit number' : 'Mobile number',
                prefix: Row(children: [
                  Text(_cc, style: inter(15, 500)),
                  const SizedBox(width: 10),
                  Container(width: 1, height: 20, color: kLine),
                ]),
              ),
              const SizedBox(height: 8),
              Text('We’ll send a 6-digit sign-in code to this number.', style: inter(13, 400, color: kMuted)),
              const SizedBox(height: 20),
              LinkText('Change country code', align: TextAlign.left, onTap: _changeCode),
              const SizedBox(height: 20),
              const HelpfulNote(
                iconAsset: 'assets/figma/message_circle.svg',
                title: 'No password needed',
                body: 'Only enter a code you requested. Never share your sign-in code.',
              ),
            ],
          ),
        ]),
      ],
      actions: [
        PrimaryAction(label: _busy ? 'Sending…' : 'Send sign-in code', onPressed: _busy ? null : _send),
        const SizedBox(height: 16),
        LinkText('Use email instead', onTap: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => EmailLoginScreen(auth: widget.auth)))),
      ],
    );
  }
}
