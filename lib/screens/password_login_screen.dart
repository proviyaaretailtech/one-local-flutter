import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../ui/forgot_password_sheet.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'register_personal_screen.dart';
import 'signin_chooser_screen.dart';

/// Figma "Password Login".
class PasswordLoginScreen extends StatefulWidget {
  const PasswordLoginScreen({super.key, this.auth});
  final AuthRepository? auth;
  @override
  State<PasswordLoginScreen> createState() => _PasswordLoginScreenState();
}

class _PasswordLoginScreenState extends State<PasswordLoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  late final _auth = widget.auth ?? AuthRepository();
  bool _hide = true;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_busy) return;
    final email = _email.text.trim().toLowerCase();
    if (!isEmail(email)) {
      showToast(context, 'Please enter your account email.');
      return;
    }
    if (_password.text.isEmpty) {
      showToast(context, 'Please enter your password.');
      return;
    }
    setState(() => _busy = true);
    try {
      await _auth.signInWithPassword(email, _password.text);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) showToast(context, friendlyAuthError(e, fallback: 'Email or password is not right.'));
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
          const Kicker('Log in · Password'),
          const PageIntro(title: 'Good to see you again.', subtitle: 'Sign in to your OneLocal account with your password.'),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LabeledField(
                label: 'Account email',
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _passwordFocus.requestFocus(),
                autofillHints: const [AutofillHints.username, AutofillHints.email],
                trailingSvg: 'assets/figma/mail_gray.svg',
              ),
              const SizedBox(height: 20),
              LabeledField(
                label: 'Password',
                controller: _password,
                focusNode: _passwordFocus,
                obscure: _hide,
                labelGap: 7,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _signIn(),
                autofillHints: const [AutofillHints.password],
                trailingSvg: _hide ? 'assets/figma/eye_off.svg' : null,
                trailingIcon: _hide ? null : lucideEye,
                onTrailingTap: () => setState(() => _hide = !_hide),
              ),
              const SizedBox(height: 20),
              LinkText('Forgot password?', align: TextAlign.left, onTap: () => showForgotPasswordSheet(context, initialEmail: _email.text, auth: _auth)),
              const SizedBox(height: 20),
              const HelpfulNote(
                iconAsset: 'assets/figma/shield_check.svg',
                title: 'Keep your account private',
                body: 'On a shared device, remember to log out when you’re finished.',
              ),
            ],
          ),
        ]),
      ],
      actions: [
        PrimaryAction(label: _busy ? 'Signing in…' : 'Sign in', onPressed: _busy ? null : _signIn),
        const SizedBox(height: 16),
        LinkText('Use a sign-in code instead', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SigninChooserScreen()))),
        const SizedBox(height: 16),
        InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterPersonalScreen())),
          child: const FooterNote('New to OneLocal? Create an account'),
        ),
      ],
    );
  }
}
