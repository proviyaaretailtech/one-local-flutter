import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/email_verify_pending_screen.dart';
import 'screens/login_success_screen.dart';
import 'screens/splash_screen.dart';
import 'orders/online_locked.dart';
import 'settings/settings_api.dart';
import 'ui/language_step.dart';
import 'ui/theme.dart';

class PosApp extends StatelessWidget {
  const PosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'One Local POS',
      debugShowCheckedModeBanner: false,
      theme: posTheme(),
      // No fixed column: every screen fills the device's own width and height (phone, tablet or browser) and follows rotation.
      home: const AuthGate(),
    );
  }
}

/// Decides what the person sees from the session alone:
/// signed out → intro splash (once) then the sign-in splash;
/// signed in with an unconfirmed email → "almost verified"; otherwise → welcome.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _introDone = false;

  /// The login that signed in while the app was open (not one kept from last time): only then is the language asked.
  String? _signedInNow;

  /// Whose plan is known: a different login (or none) reads it again.
  String? _planFor;

  @override
  Widget build(BuildContext context) {
    final auth = Supabase.instance.client.auth;
    return StreamBuilder<AuthState>(
      stream: auth.onAuthStateChange,
      builder: (context, snap) {
        final user = auth.currentSession?.user;
        if (user?.id != _planFor) {
          _planFor = user?.id;
          StorePlan.reset();
        }
        if (snap.data?.event == AuthChangeEvent.signedIn && user != null) _signedInNow = user.id;
        final Widget page;
        if (user == null) {
          // One screen for both splash frames: the first build plays the intro (logo, then the buttons glide in); coming back to it
          // later (after signing out) opens straight on the buttons.
          page = SplashScreen(key: const ValueKey('splash'), intro: !_introDone);
          _introDone = true;
        } else if (user.email != null && user.email!.isNotEmpty && user.emailConfirmedAt == null && (user.phone ?? '').isEmpty) {
          page = EmailVerifyPendingScreen(key: const ValueKey('pending'), email: user.email!);
        } else {
          // right after signing in: the language, then the welcome (founder, 27 Oct 2026). Opening the app already signed in goes
          // straight on, in the language kept on this phone.
          page = _signedInNow == user.id
              ? LanguageGate(key: ValueKey('success-${user.id}'), userId: user.id, saveToStore: (c) => SettingsApi().saveLanguage(c), child: const LoginSuccessScreen())
              : const LoginSuccessScreen(key: ValueKey('success'));
        }
        return AnimatedSwitcher(duration: const Duration(milliseconds: 350), child: page);
      },
    );
  }
}
