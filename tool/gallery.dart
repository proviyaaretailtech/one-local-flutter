// Dev only: shows one screen by name so it can be compared with the Figma export.
// flutter run -d web-server --web-port 8094 -t tool/gallery.dart
//   open http://localhost:8094/?s=splash|chooser|mobile|email|password|otp|pending|success|register|type
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vinii_pos/screens/email_login_screen.dart';
import 'package:vinii_pos/screens/intro_splash_screen.dart';
import 'package:vinii_pos/screens/email_verify_pending_screen.dart';
import 'package:vinii_pos/screens/mobile_login_screen.dart';
import 'package:vinii_pos/screens/otp_verify_screen.dart';
import 'package:vinii_pos/screens/password_login_screen.dart';
import 'package:vinii_pos/screens/register_account_type_screen.dart';
import 'package:vinii_pos/screens/register_personal_screen.dart';
import 'package:vinii_pos/screens/signin_chooser_screen.dart';
import 'package:vinii_pos/screens/splash_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: 'http://127.0.0.1:54321', publishableKey: 'gallery-not-a-key');
  final s = Uri.base.queryParameters['s'] ?? 'splash';
  final screens = <String, Widget>{
    'intro': IntroSplashScreen(onDone: () {}),
    'splash': const SplashScreen(),
    'chooser': const SigninChooserScreen(),
    'mobile': const MobileLoginScreen(),
    'email': const EmailLoginScreen(),
    'password': const PasswordLoginScreen(),
    'otp': const OtpVerifyScreen(phone: '+919876543210'),
    'pending': const EmailVerifyPendingScreen(email: 'ravi@sharmastore.in'),
    'register': const RegisterPersonalScreen(),
    'type': const RegisterAccountTypeScreen(),
  };
  runApp(MaterialApp(debugShowCheckedModeBanner: false, theme: posTheme(), home: screens[s] ?? const SplashScreen()));
}
