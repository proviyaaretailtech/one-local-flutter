import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../auth/partner_api.dart';
import '../app_routes.dart';
import '../onboarding/checklist_screen.dart';
import '../settings/settings_api.dart';
import '../ui/i18n.dart';
import '../ui/mask.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Figma "Login Success". Name and restaurant come from the One Local server (`GET /api/partner/me`). The first thing after signing in is
/// the language (founder, 27 Oct 2026): English, हिन्दी or Hinglish, right above Continue; the app switches at once and the store keeps it.
class LoginSuccessScreen extends StatefulWidget {
  const LoginSuccessScreen({super.key, this.api, this.auth, this.saveLanguage});
  final PartnerApi? api;
  final AuthRepository? auth;

  /// Keeps the chosen language for the store (tests pass their own).
  final Future<void> Function(String code)? saveLanguage;
  @override
  State<LoginSuccessScreen> createState() => _LoginSuccessScreenState();
}

class _LoginSuccessScreenState extends State<LoginSuccessScreen> {
  late final _auth = widget.auth ?? AuthRepository();
  late Future<PartnerMe> _me = (widget.api ?? PartnerApi()).me();

  Future<void> _pick(String code) async {
    setAppLanguage(code); // every screen switches at once
    setState(() {});
    try {
      await (widget.saveLanguage ?? (c) => SettingsApi().saveLanguage(c))(code);
    } catch (_) {} // a role that may not change store settings still gets the language on this phone for now
  }

  Widget _languages() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('Choose your language'), key: const ValueKey('login-language-title'), style: inter(15, 700)),
        const SizedBox(height: 10),
        Row(children: [
          for (final (i, (code, label, sample)) in const [('en', 'English', 'Hello'), ('hi', 'हिन्दी', 'नमस्ते'), ('hi-en', 'Hinglish', 'Namaste')].indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: Material(
                color: appLang.value == code ? const Color(0xFFA1FE2F) : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: appLang.value == code ? const Color(0xFF8BE800) : kLine, width: 1.5),
                ),
                child: InkWell(
                  key: ValueKey('login-language-$code'),
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => _pick(code),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(children: [
                      Text(label, style: inter(15, 700)),
                      const SizedBox(height: 2),
                      Text(sample, style: inter(12, 400, color: kMuted)),
                    ]),
                  ),
                ),
              ),
            ),
          ],
        ]),
      ]);

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
                    Text('${tr('Welcome back')}, ${first.isEmpty ? tr('there') : first}.', textAlign: TextAlign.center, style: inter(24, 700)),
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
                    _languages(),
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
