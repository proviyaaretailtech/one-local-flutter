import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../ui/forgot_password_sheet.dart' show isEmail;
import '../ui/mask.dart';
import '../ui/theme.dart';
import 'mobile_login_screen.dart';
import 'otp_verify_screen.dart';
import 'password_login_screen.dart';

/// Figma "Email Login".
class EmailLoginScreen extends StatefulWidget {
  const EmailLoginScreen({super.key, this.auth});
  final AuthRepository? auth;
  @override
  State<EmailLoginScreen> createState() => _EmailLoginScreenState();
}

class _EmailLoginScreenState extends State<EmailLoginScreen> {
  final _email = TextEditingController();
  late final _auth = widget.auth ?? AuthRepository();
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy) return;
    final email = _email.text.trim().toLowerCase();
    if (!isEmail(email)) {
      showToast(context, 'Please enter a valid email address.');
      return;
    }
    setState(() => _busy = true);
    try {
      await _auth.sendEmailCode(email);
      if (!mounted) return;
      showToast(context, 'Code sent to ${maskEmail(email)}');
      Navigator.push(context, MaterialPageRoute(builder: (_) => OtpVerifyScreen(email: email, auth: _auth)));
    } catch (e) {
      if (mounted) showToast(context, friendlyAuthError(e, fallback: 'Could not send the code. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScreenShell(
      children: [
        const BrandNav(back: true),
        FormContent(children: [
          const Kicker('Sign in · Email'),
          const PageIntro(title: 'Back to business.', subtitle: 'Enter the email address you use for OneLocal. We’ll send you a sign-in code.'),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LabeledField(
                label: 'Email address',
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _send(),
                autofillHints: const [AutofillHints.email],
                trailingSvg: 'assets/figma/mail_gray.svg',
              ),
              const SizedBox(height: 8),
              Text('Your code will arrive by email. Check your spam folder too.', style: inter(13, 400, color: kMuted)),
              const SizedBox(height: 20),
              LinkText('Sign in with password instead', align: TextAlign.left, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PasswordLoginScreen(auth: widget.auth)))),
              const SizedBox(height: 20),
              const HelpfulNote(
                iconAsset: 'assets/figma/mail_green.svg',
                title: 'Use your registered email',
                body: 'This is a sign-in route for an existing account, not a new registration.',
              ),
            ],
          ),
        ]),
      ],
      actions: [
        PrimaryAction(label: _busy ? 'Sending…' : 'Continue with email', onPressed: _busy ? null : _send),
        const SizedBox(height: 16),
        LinkText('Use mobile instead', onTap: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => MobileLoginScreen(auth: widget.auth)))),
      ],
    );
  }
}
