import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../auth/partner_api.dart';
import '../app_routes.dart';
import '../onboarding/checklist_screen.dart';
import '../ui/i18n.dart';
import '../ui/mask.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Figma "Login Success". Name and restaurant come from the One Local server (`GET /api/partner/me`). The language is chosen just
/// before this, on its own screen (LanguageGate).
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
                      ? 'Your application is saved. Continue it any time; OneLocal opens your store once it is approved.'
                      : offline
                          ? 'Check your internet connection and try again.'
                          : err.toString(),
                ),
              ]),
            ],
            actions: [
              if (!noStore) ...[PrimaryAction(label: 'Try again', onPressed: _retry), const SizedBox(height: 12)],
              if (noStore) ...[
                PrimaryAction(label: 'Continue your application', onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => OnboardingEntry(auth: _auth, phone: _auth.currentPhone, name: _auth.currentName)))),
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
                    Text(first.isEmpty ? '${tr('Welcome back')}.' : '${tr('Welcome back')}, $first.', textAlign: TextAlign.center, style: inter(24, 700)), // no name on record: no stand-in
                    const SizedBox(height: 12),
                    Text(
                      'You’re signed in to ${me.outlet.isEmpty ? 'OneLocal' : me.outlet}. Your ${_kindLabel(me.kind)} is ready to open.',
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
                    const SizedBox(height: 20),
                    PrimaryAction(label: '${tr('Continue to')} ${tr(_kindLabel(me.kind))}', onPressed: () => openWorkspace(context, auth: _auth)),
                    const SizedBox(height: 12),
                    SecondaryAction(label: tr('Switch account'), onPressed: () => _auth.signOut()),
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

/// The words for the business on the sign-in screens: Restaurant POS, Store POS or Service POS.
String _kindLabel(String kind) => switch (kind) { 'restaurant' => 'Restaurant POS', 'service' => 'Service POS', _ => 'Store POS' };
