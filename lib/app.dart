import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/email_verify_pending_screen.dart';
import 'screens/login_success_screen.dart';
import 'screens/splash_screen.dart';
import 'ui/theme.dart';

class PosApp extends StatelessWidget {
  const PosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'One Local POS',
      debugShowCheckedModeBanner: false,
      theme: posTheme(),
      // On a wide desktop browser the app sits in a phone-width column, as it would on a phone.
      builder: (context, child) {
        if (!kIsWeb || MediaQuery.sizeOf(context).width <= 600) return child!;
        return ColoredBox(
          color: const Color(0xFF1B1F1C),
          child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 430), child: child)),
        );
      },
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

  @override
  Widget build(BuildContext context) {
    final auth = Supabase.instance.client.auth;
    return StreamBuilder<AuthState>(
      stream: auth.onAuthStateChange,
      builder: (context, _) {
        final user = auth.currentSession?.user;
        final Widget page;
        if (user == null) {
          // One screen for both splash frames: the first build plays the intro (logo, then the buttons glide in); coming back to it
          // later (after signing out) opens straight on the buttons.
          page = SplashScreen(key: const ValueKey('splash'), intro: !_introDone);
          _introDone = true;
        } else if (user.email != null && user.email!.isNotEmpty && user.emailConfirmedAt == null && (user.phone ?? '').isEmpty) {
          page = EmailVerifyPendingScreen(key: const ValueKey('pending'), email: user.email!);
        } else {
          page = const LoginSuccessScreen(key: ValueKey('success'));
        }
        return AnimatedSwitcher(duration: const Duration(milliseconds: 350), child: page);
      },
    );
  }
}
