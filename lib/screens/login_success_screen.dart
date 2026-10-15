import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../auth/partner_api.dart';
import '../app_routes.dart';
import '../onboarding/checklist_screen.dart';
import '../ui/mask.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Figma "Login Success". Name and restaurant come from the One Local server (`GET /api/partner/me`).
class LoginSuccessScreen extends StatefulWidget {
  const LoginSuccessScreen({super.key, this.api, this.auth});
  final PartnerApi? api;
  final AuthRepository? auth;
  @override
  State<LoginSuccessScreen> createState() => _LoginSuccessScreenState();
}

class _LoginSuccessScreenState extends State<LoginSuccessScreen> {
  late final _auth = widget.auth ?? AuthRepository();
  late Future<PartnerMe> _me = (widget.api ?? PartnerApi()).me();

  void _retry() {
    final next = (widget.api ?? PartnerApi()).me();
    setState(() {
      _me = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PartnerMe>(
      future: _me,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator(color: kLink)));
        }
        if (snap.hasError) {
          final err = snap.error;
          final noStore = err is PartnerApiException && err.status == 403;
          final offline = err is! PartnerApiException;
          return ScreenShell(
            gradient: kRegistrationGradient,
            children: [
              const BrandNav(),
              FormContent(children: [
                const Kicker('Sign in · Complete'),
                PageIntro(
                  title: noStore ? 'Your account is ready.' : offline ? 'We could not reach OneLocal.' : 'Something went wrong.',
                  subtitle: noStore
                      ? 'You are signed in, but no store is set up on this account yet. OneLocal will open your store once onboarding is complete.'
                      : offline
                          ? 'Check your internet connection and try again.'
                          : err.toString(),
                ),
              ]),
            ],
            actions: [
              if (!noStore) ...[PrimaryAction(label: 'Try again', onPressed: _retry), const SizedBox(height: 12)],
              if (noStore) ...[
                PrimaryAction(label: 'Set up your business', onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => OnboardingEntry(auth: _auth)))),
                const SizedBox(height: 12),
              ],
              SecondaryAction(label: 'Switch account', onPressed: () => _auth.signOut()),
            ],
          );
        }
        final me = snap.data!;
        final first = me.name.split(' ').first;
        return ScreenShell(
          gradient: kRegistrationGradient,
          children: [
            const BrandNav(),
            FormContent(children: [
              const Kicker('Sign in · Complete'),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: kLine),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const [BoxShadow(color: Color(0x0F000000), offset: Offset(0, 4), blurRadius: 16)],
                ),
                child: Column(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: const BoxDecoration(color: kNote, shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: const Ico(lucideCircleCheck, size: 32),
                    ),
                    const SizedBox(height: 24),
                    Text('Welcome back, ${first.isEmpty ? 'there' : first}.', textAlign: TextAlign.center, style: inter(24, 700)),
                    const SizedBox(height: 12),
                    Text(
                      'You’re signed in to ${me.outlet.isEmpty ? 'OneLocal' : me.outlet}. Your store is ready to open.',
                      textAlign: TextAlign.center,
                      style: inter(14, 400, color: kMuted, height: 1.5),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(16)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Signed in securely', style: inter(13, 600)),
                          const SizedBox(height: 8),
                          Text(me.email.isEmpty ? '' : maskEmail(me.email), style: inter(15, 400, color: kMuted)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    PrimaryAction(label: 'Continue to store', onPressed: () => openWorkspace(context, auth: _auth)),
                    const SizedBox(height: 12),
                    SecondaryAction(label: 'Switch account', onPressed: () => _auth.signOut()),
                  ],
                ),
              ),
              Text('On a shared device, log out when you’re finished.', textAlign: TextAlign.center, style: inter(13, 400, color: kMuted)),
            ]),
          ],
          actions: const [],
        );
      },
    );
  }
}
