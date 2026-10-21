import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../ui/theme.dart';
import 'email_login_screen.dart';
import 'mobile_login_screen.dart';
import 'password_login_screen.dart';

/// Figma "OTP Request": where should we send your code. A password sign-in sits underneath as the quieter second way in.
class SigninChooserScreen extends StatefulWidget {
  const SigninChooserScreen({super.key});
  @override
  State<SigninChooserScreen> createState() => _SigninChooserScreenState();
}

class _SigninChooserScreenState extends State<SigninChooserScreen> {
  bool _sms = true;

  void _open(Widget screen) => Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    return ScreenShell(
      children: [
        const BrandNav(back: true),
        FormContent(children: [
          const Kicker('Sign in · Delivery'),
          const PageIntro(
            title: 'How would you like to sign in?',
            subtitle: 'We’ll send a 6-digit code to a registered contact.',
          ),
          Column(
            children: [
              OptionCard(
                iconAsset: 'assets/figma/smartphone.svg',
                title: 'Text message',
                subtitle: 'Your registered mobile number',
                selected: _sms,
                onTap: () => setState(() => _sms = true),
              ),
              const SizedBox(height: 16),
              OptionCard(
                iconAsset: 'assets/figma/mail_green.svg',
                title: 'Email',
                subtitle: 'Your registered email address',
                selected: !_sms,
                onTap: () => setState(() => _sms = false),
              ),
              const SizedBox(height: 16),
              const HelpfulNote(
                iconAsset: 'assets/figma/message_circle.svg',
                title: 'Choose a contact you can access',
                body: 'You’ll need the code from your messages or inbox to continue.',
              ),
            ],
          ),
        ]),
      ],
      actions: [
        PrimaryAction(label: 'Send code', onPressed: () => _open(_sms ? const MobileLoginScreen() : const EmailLoginScreen())),
        const SizedBox(height: 12),
        // Both secondary ways out share one line, so the screen stays as short as the code-only design.
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _SmallLink(icon: 'assets/figma/lock_green.svg', label: 'Use password', onTap: () => _open(const PasswordLoginScreen())),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('·', style: inter(14, 600, color: kMuted))),
          _SmallLink(label: 'Change account', onTap: () => Navigator.pop(context)),
        ]),
        const SizedBox(height: 12),
        const FooterNote('Never share your verification code with anyone.'),
      ],
    );
  }
}

/// A green text link, optionally with a small icon, sized for the action area.
class _SmallLink extends StatelessWidget {
  const _SmallLink({required this.label, required this.onTap, this.icon});
  final String label;
  final String? icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[SvgPicture.asset(icon!, width: 14, height: 14), const SizedBox(width: 6)],
            Text(label, style: inter(14, 600, color: kLink, height: 1.5)),
          ]),
        ),
      );
}
