import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'signin_chooser_screen.dart';

/// Figma "Registration res / store / service": choose Restaurant, Store or Service.
/// The choice is saved when organisation setup is built (phase B); nothing is created here.
enum AccountType { restaurant, store, service }

class RegisterAccountTypeScreen extends StatefulWidget {
  const RegisterAccountTypeScreen({super.key, this.onChosen, this.onAdvertise});

  /// Onboarding passes this to carry the choice into the shop profile. Without it the choice is only recorded (phase A).
  final void Function(AccountType type)? onChosen;

  /// Only advertising, no products or orders: opens the advertiser sign-up. The card shows only when this is given.
  final VoidCallback? onAdvertise;
  @override
  State<RegisterAccountTypeScreen> createState() => _RegisterAccountTypeScreenState();
}

class _RegisterAccountTypeScreenState extends State<RegisterAccountTypeScreen> {
  AccountType? _choice;

  static const _items = {
    AccountType.restaurant: ('Restaurant', 'Register your Restaurant and its account owner.', lucideBuilding),
    AccountType.store: ('Store', 'Register your Shop and its account owner.', lucideHandshake),
    AccountType.service: ('Service', 'Set up your shop and Start offering your services', lucideStore),
  };

  /// Only advertise (the Advertising & Partner Growth spec, 29 Oct 2026): straight to the advertiser sign-up, no store set-up.
  Widget _advertise() => InkWell(
        key: const ValueKey('account-advertise'),
        borderRadius: BorderRadius.circular(kRadius),
        onTap: widget.onAdvertise,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.white, border: Border.all(color: kLine), borderRadius: BorderRadius.circular(kRadius)),
          child: Row(children: [
            const Icon(Icons.campaign_outlined, size: 24, color: Color(0xFF4B5563)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Only advertise', style: inter(16, 600)),
                const SizedBox(height: 4),
                Text('Promote your brand, products or outlet on OneLocal without selling here.', style: inter(14, 400, color: kMuted, height: 1.4)),
              ]),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.chevron_right, color: kMuted),
          ]),
        ),
      );

  Widget _card(AccountType t) {
    final (title, body, icon) = _items[t]!;
    final on = _choice == t;
    return InkWell(
      borderRadius: BorderRadius.circular(kRadius),
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _choice = t);
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: on ? const Color(0xFFEBFAE0) : Colors.white,
          border: Border.all(color: on ? kLink : kLine, width: on ? 1.5 : 1),
          borderRadius: BorderRadius.circular(kRadius),
        ),
        child: Row(
          children: [
            Ico(icon, size: 22, color: on ? kLink : const Color(0xFF4B5563)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: inter(16, 600)),
                  const SizedBox(height: 4),
                  Text(body, style: inter(14, 400, color: kMuted, height: 1.4)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            on ? const Ico(lucideCircleCheck, size: 22) : Container(width: 20, height: 20, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kLine, width: 2))),
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
        StepNav(caption: 'Choose your account', onBack: () => Navigator.pop(context)),
        Padding(
          padding: const EdgeInsets.fromLTRB(kPadX, 12, kPadX, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Kicker('Registration'),
              const SizedBox(height: 12),
              const PageIntro(
                title: 'Welcome to OneLocal.',
                subtitle: 'Choose the account that fits you. You can set up a business workspace after registering.',
              ),
              const SizedBox(height: 24),
              for (final t in AccountType.values) ...[_card(t), const SizedBox(height: 20)],
              if (widget.onAdvertise != null) ...[_advertise(), const SizedBox(height: 20)],
              if (widget.onChosen == null) LinkText('Already registered? Sign in', align: TextAlign.left, onTap: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SigninChooserScreen()))),
            ],
          ),
        ),
      ],
      actions: [
        PrimaryAction(
          label: 'Continue as merchant',
          // Phase B turns this choice into an organisation. Phase A only records it.
          onPressed: () {
            if (_choice == null) {
              showToast(context, 'Please choose one account type to continue.');
              return;
            }
            final cb = widget.onChosen;
            if (cb != null) {
              cb(_choice!);
            } else {
              Navigator.of(context).popUntil((r) => r.isFirst);
            }
          },
        ),
        const SizedBox(height: 12),
        const FooterNote('Choose one account type to get started.'),
      ],
    );
  }
}
