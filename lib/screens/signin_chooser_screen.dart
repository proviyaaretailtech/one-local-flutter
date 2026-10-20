import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'email_login_screen.dart';
import 'mobile_login_screen.dart';

/// Figma "OTP Request": where should we send your code.
class SigninChooserScreen extends StatefulWidget {
  const SigninChooserScreen({super.key});
  @override
  State<SigninChooserScreen> createState() => _SigninChooserScreenState();
}

class _SigninChooserScreenState extends State<SigninChooserScreen> {
  bool _sms = true;

  @override
  Widget build(BuildContext context) {
    return ScreenShell(
      children: [
        const BrandNav(back: true),
        FormContent(children: [
          const Kicker('Sign in · Delivery'),
          const PageIntro(
            title: 'Where should we send your code?',
            subtitle: 'Choose a registered contact to receive your 6-digit sign-in code.',
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
              const SizedBox(height: 20),
              OptionCard(
                iconAsset: 'assets/figma/mail_green.svg',
                title: 'Email',
                subtitle: 'Your registered email address',
                selected: !_sms,
                onTap: () => setState(() => _sms = false),
              ),
              const SizedBox(height: 20),
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
        PrimaryAction(
          label: 'Send code',
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _sms ? const MobileLoginScreen() : const EmailLoginScreen())),
        ),
        const SizedBox(height: 16),
        LinkText('Change account', onTap: () => Navigator.pop(context)),
        const SizedBox(height: 16),
        const FooterNote('Never share your verification code with anyone.'),
      ],
    );
  }
}
