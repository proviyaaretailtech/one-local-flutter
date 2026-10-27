import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthApiException;
import 'package:vinii_pos/auth/partner_api.dart';
import 'package:vinii_pos/ui/i18n.dart';
import 'package:vinii_pos/home/control_centre_screen.dart';
import 'package:vinii_pos/screens/email_login_screen.dart';
import 'package:vinii_pos/screens/email_verify_pending_screen.dart';
import 'package:vinii_pos/screens/login_success_screen.dart';
import 'package:vinii_pos/screens/mobile_login_screen.dart';
import 'package:vinii_pos/screens/otp_verify_screen.dart';
import 'package:vinii_pos/screens/password_login_screen.dart';
import 'package:vinii_pos/screens/register_account_type_screen.dart';
import 'package:vinii_pos/screens/register_personal_screen.dart';
import 'package:vinii_pos/screens/signin_chooser_screen.dart';
import 'package:vinii_pos/screens/splash_screen.dart';

import 'package:flutter_svg/flutter_svg.dart';
import 'package:vinii_pos/ui/widgets.dart' show lucideEye, lucideX;

import 'helpers.dart';

void main() {
  group('Splash', () {
    testWidgets('Sign In opens the chooser', (t) async {
      await show(t, const SplashScreen());
      await t.tap(find.text('Sign In'));
      await t.pumpAndSettle();
      expect(find.text('How would you like to sign in?'), findsOneWidget);
    });
    testWidgets('the intro: logo and taglines first, then the buttons glide in and the taglines stay under them; a tap skips ahead', (t) async {
      await show(t, const SplashScreen(intro: true, hold: Duration(seconds: 2)));
      expect(find.text('Easy Selling starts here'), findsOneWidget);
      expect(find.text('Your Business, Simplified'), findsOneWidget);
      await t.tap(find.text('Sign In'), warnIfMissed: false); // not there yet: nothing opens
      await t.pump();
      expect(find.text('Where should we send your code?'), findsNothing);
      await t.pump(const Duration(seconds: 2)); // the hold ends
      await t.pumpAndSettle(); // the move to the second frame
      expect(find.text('Easy Selling starts here'), findsOneWidget, reason: 'the taglines stay on the sign-up page');
      await t.tap(find.text('Sign In'));
      await t.pumpAndSettle();
      expect(find.text('How would you like to sign in?'), findsOneWidget);
    });

    testWidgets('a tap during the first frame moves on at once', (t) async {
      await show(t, const SplashScreen(intro: true, hold: Duration(seconds: 30)));
      await t.tapAt(const Offset(200, 300));
      await t.pumpAndSettle();
      await t.tap(find.text('Become a seller'));
      await t.pumpAndSettle();
      expect(find.text('Create your account.'), findsOneWidget);
    });

    testWidgets('Become a seller opens registration', (t) async {
      await show(t, const SplashScreen());
      // dark text on the lime button, so it is not washed out
      expect(t.widget<Text>(find.text('Become a seller')).style?.color, const Color(0xFF0C1F15));
      await t.tap(find.text('Become a seller'));
      await t.pumpAndSettle();
      expect(find.text('Create your account.'), findsOneWidget);
    });
  });

  group('Chooser', () {
    testWidgets('text message goes to mobile login', (t) async {
      await show(t, const SigninChooserScreen());
      await t.tap(find.text('Send code'));
      await t.pumpAndSettle();
      expect(find.text('Your number. Your business.'), findsOneWidget);
    });
    testWidgets('email goes to email login', (t) async {
      await show(t, const SigninChooserScreen());
      await t.tap(find.text('Email'));
      await t.pump();
      await t.tap(find.text('Send code'));
      await t.pumpAndSettle();
      expect(find.text('Back to business.'), findsOneWidget);
    });
    testWidgets('password goes to password login, and back to the chooser', (t) async {
      await show(t, const SigninChooserScreen());
      await t.tap(find.text('Use password'));
      await t.pumpAndSettle();
      expect(find.text('Good to see you again.'), findsOneWidget);
      await t.tap(find.text('Use a sign-in code instead'));
      await t.pumpAndSettle();
      expect(find.text('How would you like to sign in?'), findsOneWidget);
      expect(find.text('Good to see you again.'), findsNothing);
    });
  });

  group('Mobile login', () {
    testWidgets('9 digits asks for 10', (t) async {
      final a = FakeAuth();
      await show(t, MobileLoginScreen(auth: a));
      await t.enterText(find.byType(TextField), '987654321');
      await t.tap(find.text('Send sign-in code'));
      await t.pump();
      expect(toast('Please enter a 10-digit mobile number.'), findsOneWidget);
      expect(a.calls, isEmpty);
    });
    testWidgets('empty asks for 10 digits too', (t) async {
      await show(t, MobileLoginScreen(auth: FakeAuth()));
      await t.tap(find.text('Send sign-in code'));
      await t.pump();
      expect(toast('Please enter a 10-digit mobile number.'), findsOneWidget);
    });
    testWidgets('letters and spaces are dropped, 10 digits max', (t) async {
      await show(t, MobileLoginScreen(auth: FakeAuth()));
      await t.enterText(find.byType(TextField), 'ab98 7654-3210999');
      expect(t.widget<TextField>(find.byType(TextField)).controller!.text, '9876543210');
    });
    testWidgets('valid number sends the code and opens verify', (t) async {
      final a = FakeAuth();
      await show(t, MobileLoginScreen(auth: a));
      await t.enterText(find.byType(TextField), '9876543210');
      await t.tap(find.text('Send sign-in code'));
      await t.pumpAndSettle();
      expect(a.calls, ['sendPhoneCode +919876543210']);
      expect(find.text('Check your messages.'), findsOneWidget);
    });
    testWidgets('keyboard Done sends the code', (t) async {
      final a = FakeAuth();
      await show(t, MobileLoginScreen(auth: a));
      await t.enterText(find.byType(TextField), '9876543210');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(a.calls, ['sendPhoneCode +919876543210']);
    });
    testWidgets('button shows Sending… and ignores a second tap', (t) async {
      final a = FakeAuth()..hold = Completer<void>();
      await show(t, MobileLoginScreen(auth: a));
      await t.enterText(find.byType(TextField), '9876543210');
      await t.tap(find.text('Send sign-in code'));
      await t.pump();
      expect(find.text('Sending…'), findsOneWidget);
      await t.tap(find.text('Sending…'), warnIfMissed: false);
      await t.pump();
      expect(a.calls.length, 1);
      a.hold!.complete();
      await t.pumpAndSettle();
    });
    testWidgets('server failure shows a plain message and stays put', (t) async {
      final a = FakeAuth()..failWith = const SocketException('x');
      await show(t, MobileLoginScreen(auth: a));
      await t.enterText(find.byType(TextField), '9876543210');
      await t.tap(find.text('Send sign-in code'));
      await t.pump();
      expect(toast('No internet connection. Check your network and try again.'), findsOneWidget);
      expect(find.text('Your number. Your business.'), findsOneWidget);
    });
    testWidgets('rate limit gets its own message', (t) async {
      final a = FakeAuth()..failWith = AuthApiException('rate limit', statusCode: '429', code: 'over_sms_send_rate_limit');
      await show(t, MobileLoginScreen(auth: a));
      await t.enterText(find.byType(TextField), '9876543210');
      await t.tap(find.text('Send sign-in code'));
      await t.pump();
      expect(toast('Too many attempts. Please wait a minute and try again.'), findsOneWidget);
    });
    testWidgets('Change country code lets you pick +971', (t) async {
      final a = FakeAuth();
      await show(t, MobileLoginScreen(auth: a));
      await t.tap(find.text('Change country code'));
      await t.pumpAndSettle();
      await t.tap(find.text('United Arab Emirates'));
      await t.pumpAndSettle();
      expect(find.text('+971'), findsOneWidget);
      await t.enterText(find.byType(TextField), '501234567');
      await t.tap(find.text('Send sign-in code'));
      await t.pumpAndSettle();
      expect(a.calls, ['sendPhoneCode +971501234567']);
    });
    testWidgets('Use email instead swaps to email login', (t) async {
      await show(t, MobileLoginScreen(auth: FakeAuth()));
      await t.tap(find.text('Use email instead'));
      await t.pumpAndSettle();
      expect(find.text('Back to business.'), findsOneWidget);
    });
  });

  group('Email login', () {
    testWidgets('bad email is refused', (t) async {
      final a = FakeAuth();
      await show(t, EmailLoginScreen(auth: a));
      await t.enterText(find.byType(TextField), 'nope');
      await t.tap(find.text('Continue with email'));
      await t.pump();
      expect(toast('Please enter a valid email address.'), findsOneWidget);
      expect(a.calls, isEmpty);
    });
    testWidgets('email is trimmed and lower-cased, then verify opens', (t) async {
      final a = FakeAuth();
      await show(t, EmailLoginScreen(auth: a));
      await t.enterText(find.byType(TextField), '  Ravi@SharmaStore.in ');
      await t.tap(find.text('Continue with email'));
      await t.pumpAndSettle();
      expect(a.calls, ['sendEmailCode ravi@sharmastore.in']);
      expect(find.text('Check your inbox.'), findsOneWidget);
    });
    testWidgets('unknown account gets a clear message', (t) async {
      final a = FakeAuth()..failWith = AuthApiException('Signups not allowed for otp', statusCode: '422', code: 'otp_disabled');
      await show(t, EmailLoginScreen(auth: a));
      await t.enterText(find.byType(TextField), 'a@b.co');
      await t.tap(find.text('Continue with email'));
      await t.pump();
      expect(toast('We could not find an account with that contact. Check it or create an account.'), findsOneWidget);
    });
    testWidgets('password and mobile links work', (t) async {
      await show(t, EmailLoginScreen(auth: FakeAuth()));
      await t.tap(find.text('Sign in with password instead'));
      await t.pumpAndSettle();
      expect(find.text('Good to see you again.'), findsOneWidget);
    });
    testWidgets('Use mobile instead swaps to mobile login', (t) async {
      await show(t, EmailLoginScreen(auth: FakeAuth()));
      await t.tap(find.text('Use mobile instead'));
      await t.pumpAndSettle();
      expect(find.text('Your number. Your business.'), findsOneWidget);
    });
  });

  group('Password login', () {
    testWidgets('empty email, then empty password', (t) async {
      final a = FakeAuth();
      await show(t, PasswordLoginScreen(auth: a));
      await t.tap(find.text('Sign in'));
      await t.pump();
      expect(toast('Please enter your account email or mobile number.'), findsOneWidget);
      await t.enterText(find.byType(TextField).at(0), 'a@b.co');
      await t.tap(find.text('Sign in'));
      await t.pump();
      expect(toast('Please enter your password.'), findsOneWidget);
      expect(a.calls, isEmpty);
    });
    testWidgets('right details sign in', (t) async {
      final a = FakeAuth();
      await show(t, PasswordLoginScreen(auth: a));
      await t.enterText(find.byType(TextField).at(0), 'A@B.co');
      await t.enterText(find.byType(TextField).at(1), 'secret123');
      await t.tap(find.text('Sign in'));
      await t.pumpAndSettle();
      expect(a.calls, ['signInWithPassword a@b.co']);
    });
    testWidgets('a mobile number works too: +91 added, spaces and a leading 0 or 91 are fine', (t) async {
      final a = FakeAuth();
      await show(t, PasswordLoginScreen(auth: a));
      expect(find.text('Email or mobile number'), findsOneWidget);
      await t.enterText(find.byType(TextField).at(0), '098765 43210');
      await t.enterText(find.byType(TextField).at(1), 'secret123');
      await t.tap(find.text('Sign in'));
      await t.pumpAndSettle();
      expect(a.calls, ['signInWithPhonePassword +919876543210']);
    });
    testWidgets('neither an email nor a mobile number: said so, nothing sent', (t) async {
      final a = FakeAuth();
      await show(t, PasswordLoginScreen(auth: a));
      await t.enterText(find.byType(TextField).at(0), '12345');
      await t.enterText(find.byType(TextField).at(1), 'secret123');
      await t.tap(find.text('Sign in'));
      await t.pump();
      expect(toast('Enter your account email, or a 10-digit mobile number.'), findsOneWidget);
      expect(a.calls, isEmpty);
    });
    testWidgets('wrong password says so', (t) async {
      final a = FakeAuth()..failWith = AuthApiException('Invalid login credentials', statusCode: '400', code: 'invalid_credentials');
      await show(t, PasswordLoginScreen(auth: a));
      await t.enterText(find.byType(TextField).at(0), 'a@b.co');
      await t.enterText(find.byType(TextField).at(1), 'bad');
      await t.tap(find.text('Sign in'));
      await t.pump();
      expect(toast('Email or password is not right.'), findsOneWidget);
    });
    testWidgets('eye icon shows and hides the password', (t) async {
      await show(t, PasswordLoginScreen(auth: FakeAuth()));
      expect(t.widget<TextField>(find.byType(TextField).at(1)).obscureText, isTrue);
      await t.tap(find.byWidgetPredicate((w) => w is SvgPicture && w.bytesLoader is SvgAssetLoader && (w.bytesLoader as SvgAssetLoader).assetName.endsWith('eye_off.svg')));
      await t.pump();
      expect(t.widget<TextField>(find.byType(TextField).at(1)).obscureText, isFalse);
      await t.tap(find.byIcon(lucideEye));
      await t.pump();
      expect(t.widget<TextField>(find.byType(TextField).at(1)).obscureText, isTrue);
    });
    testWidgets('Forgot password: bad email, then sends reset link', (t) async {
      final a = FakeAuth();
      await show(t, PasswordLoginScreen(auth: a));
      await t.tap(find.text('Forgot password?'));
      await t.pumpAndSettle();
      expect(find.text('Reset your password'), findsOneWidget);
      await t.tap(find.text('Send reset link'));
      await t.pump();
      expect(toast('Please enter a valid email address.'), findsOneWidget);
      await t.enterText(find.byType(TextField).last, 'Ravi@x.in');
      await t.tap(find.text('Send reset link'));
      await t.pumpAndSettle();
      expect(a.calls, ['sendPasswordReset ravi@x.in']);
      expect(find.text('Reset your password'), findsNothing);
      expect(toast('If that email has an account, a reset link is on its way.'), findsOneWidget);
    });
    testWidgets('sign-in code and create-account links work', (t) async {
      await show(t, PasswordLoginScreen(auth: FakeAuth()));
      await t.tap(find.text('New to OneLocal? Create an account'));
      await t.pumpAndSettle();
      expect(find.text('Create your account.'), findsOneWidget);
    });
    testWidgets('Use a sign-in code instead opens the chooser', (t) async {
      await show(t, PasswordLoginScreen(auth: FakeAuth()));
      await t.tap(find.text('Use a sign-in code instead'));
      await t.pumpAndSettle();
      expect(find.text('How would you like to sign in?'), findsOneWidget);
    });
  });

  group('OTP verify', () {
    testWidgets('Verify with fewer than 6 digits asks for all 6', (t) async {
      final a = FakeAuth();
      await show(t, OtpVerifyScreen(phone: '+919876543210', auth: a));
      await t.enterText(find.byType(TextField), '123');
      await t.tap(find.text('Verify code'));
      await t.pump();
      expect(toast('Please enter all 6 digits of the code.'), findsOneWidget);
      expect(a.calls, isEmpty);
    });
    testWidgets('typing the 6th digit verifies on its own', (t) async {
      final a = FakeAuth();
      await show(t, OtpVerifyScreen(phone: '+919876543210', auth: a));
      await t.enterText(find.byType(TextField), '246801');
      await t.pumpAndSettle();
      expect(a.calls, ['verifyPhoneCode +919876543210 246801']);
    });
    testWidgets('only digits are accepted', (t) async {
      await show(t, OtpVerifyScreen(phone: '+919876543210', auth: FakeAuth()));
      await t.enterText(find.byType(TextField), '12ab34');
      expect(t.widget<TextField>(find.byType(TextField)).controller!.text, '1234');
    });
    testWidgets('wrong code shows a message and clears the boxes', (t) async {
      final a = FakeAuth()..failWith = AuthApiException('Token has expired or is invalid', statusCode: '403', code: 'otp_expired');
      await show(t, OtpVerifyScreen(phone: '+919876543210', auth: a));
      await t.enterText(find.byType(TextField), '000000');
      await t.pumpAndSettle();
      expect(toast('That code has expired. Request a new one.'), findsOneWidget);
      expect(t.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    });
    testWidgets('email variant verifies by email', (t) async {
      final a = FakeAuth();
      await show(t, OtpVerifyScreen(email: 'ravi@x.in', auth: a));
      expect(find.text('Check your inbox.'), findsOneWidget);
      await t.enterText(find.byType(TextField), '111111');
      await t.pumpAndSettle();
      expect(a.calls, ['verifyEmailCode ravi@x.in 111111']);
    });
    testWidgets('countdown runs, then Resend sends a new code', (t) async {
      final a = FakeAuth();
      await show(t, OtpVerifyScreen(phone: '+919876543210', auth: a, resendSeconds: 3));
      expect(find.text('Resend code in 00:03'), findsOneWidget);
      await t.pump(const Duration(seconds: 1));
      expect(find.text('Resend code in 00:02'), findsOneWidget);
      await t.pump(const Duration(seconds: 3));
      expect(find.text('Resend code'), findsOneWidget);
      await t.tap(find.text('Resend code'));
      await t.pump();
      expect(a.calls, ['sendPhoneCode +919876543210']);
      expect(find.text('Resend code in 00:03'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    });
    testWidgets('registering goes on to choose an account type', (t) async {
      final a = FakeAuth();
      await show(t, OtpVerifyScreen(phone: '+919876543210', registering: true, auth: a));
      await t.enterText(find.byType(TextField), '246801');
      await t.pumpAndSettle();
      expect(find.text('Welcome to OneLocal.'), findsOneWidget);
    });
    testWidgets('Edit mobile number goes back', (t) async {
      await show(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => OtpVerifyScreen(phone: '+919876543210', auth: FakeAuth()))), child: const Text('go')))));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.tap(find.text('Edit mobile number'));
      await t.pumpAndSettle();
      expect(find.text('go'), findsOneWidget);
    });
  });

  group('Pending verification', () {
    testWidgets('resend sends and confirms', (t) async {
      final a = FakeAuth();
      await show(t, EmailVerifyPendingScreen(email: 'ravi@x.in', auth: a));
      await t.tap(find.text('Resend verification code'));
      await t.pump();
      expect(a.calls, ['sendEmailCode ravi@x.in']);
      expect(toast('New code sent to r•••@x.in'), findsOneWidget);
    });
    testWidgets('the blue notice can be dismissed', (t) async {
      await show(t, EmailVerifyPendingScreen(email: 'ravi@x.in', auth: FakeAuth()));
      expect(find.text('Contact verification pending'), findsOneWidget);
      await t.tap(find.byIcon(lucideX));
      await t.pump();
      expect(find.text('Contact verification pending'), findsNothing);
    });
    testWidgets('Verify contact opens the code screen', (t) async {
      await show(t, EmailVerifyPendingScreen(email: 'ravi@x.in', auth: FakeAuth()));
      await t.tap(find.text('Verify contact'));
      await t.pumpAndSettle();
      expect(find.text('Check your inbox.'), findsOneWidget);
    });
  });

  group('Registration', () {
    Future<void> fill(WidgetTester t, {String name = 'Riya Sharma', String phone = '9876543210', String email = 'Riya@Example.com'}) async {
      await t.enterText(find.byType(TextField).at(0), name);
      await t.enterText(find.byType(TextField).at(1), phone);
      await t.enterText(find.byType(TextField).at(2), email);
    }

    testWidgets('empty form asks for the name first', (t) async {
      await show(t, RegisterPersonalScreen(auth: FakeAuth()));
      await t.tap(find.text('Create account'));
      await t.pump();
      expect(toast('Please enter your full name.'), findsOneWidget);
    });
    testWidgets('9 digits asks for 10', (t) async {
      await show(t, RegisterPersonalScreen(auth: FakeAuth()));
      await fill(t, phone: '987654321');
      await t.tap(find.text('Create account'));
      await t.pump();
      expect(toast('Please enter a 10-digit mobile number.'), findsOneWidget);
    });
    testWidgets('bad email is refused', (t) async {
      await show(t, RegisterPersonalScreen(auth: FakeAuth()));
      await fill(t, email: 'riya@');
      await t.tap(find.text('Create account'));
      await t.pump();
      expect(toast('Please enter a valid email address.'), findsOneWidget);
    });
    testWidgets('both consents are required, in order', (t) async {
      await show(t, RegisterPersonalScreen(auth: FakeAuth()));
      await fill(t);
      await t.tap(find.text('Create account'));
      await t.pump();
      expect(toast('Please confirm the age eligibility to continue.'), findsOneWidget);
      await t.tap(find.textContaining('I confirm that I meet the age'));
      await t.pump();
      await t.tap(find.text('Create account'));
      await t.pump();
      expect(toast('Please agree to the service terms to continue.'), findsOneWidget);
    });
    testWidgets('phone keeps digits only', (t) async {
      await show(t, RegisterPersonalScreen(auth: FakeAuth()));
      await t.enterText(find.byType(TextField).at(1), '98-76 54abc3210999');
      expect(t.widget<TextField>(find.byType(TextField).at(1)).controller!.text, '9876543210');
    });
    testWidgets('valid form registers and opens the code screen', (t) async {
      final a = FakeAuth();
      await show(t, RegisterPersonalScreen(auth: a));
      await fill(t);
      await t.tap(find.textContaining('I confirm that I meet the age'));
      await t.tap(find.textContaining('I agree to the service terms'));
      await t.pump();
      await t.tap(find.text('Create account'));
      await t.pumpAndSettle();
      expect(a.calls, ['registerWithPhone +919876543210 Riya Sharma riya@example.com']);
      expect(find.text('Check your messages.'), findsOneWidget);
    });
    testWidgets('server refusal is shown, form stays', (t) async {
      final a = FakeAuth()..failWith = const SocketException('x');
      await show(t, RegisterPersonalScreen(auth: a));
      await fill(t);
      await t.tap(find.textContaining('I confirm that I meet the age'));
      await t.tap(find.textContaining('I agree to the service terms'));
      await t.pump();
      await t.tap(find.text('Create account'));
      await t.pump();
      expect(toast('No internet connection. Check your network and try again.'), findsOneWidget);
      expect(find.text('Create your account.'), findsOneWidget);
    });
    testWidgets('Service terms and Privacy notice both open', (t) async {
      await show(t, RegisterPersonalScreen(auth: FakeAuth()));
      await t.tap(find.text('Service terms'));
      await t.pumpAndSettle();
      expect(find.textContaining('Service terms is being finalised'), findsOneWidget);
      await t.tap(find.text('Close'));
      await t.pumpAndSettle();
      await t.tap(find.text('Privacy notice'));
      await t.pumpAndSettle();
      expect(find.textContaining('Privacy notice is being finalised'), findsOneWidget);
    });
    testWidgets('back arrow returns', (t) async {
      await show(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => RegisterPersonalScreen(auth: FakeAuth()))), child: const Text('go')))));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.tap(find.byType(InkWell).first);
      await t.pumpAndSettle();
      expect(find.text('go'), findsOneWidget);
    });
  });

  group('Account type', () {
    testWidgets('Continue with nothing chosen asks for a choice', (t) async {
      await show(t, const RegisterAccountTypeScreen());
      await t.tap(find.text('Continue as merchant'));
      await t.pump();
      expect(toast('Please choose one account type to continue.'), findsOneWidget);
    });
    testWidgets('choosing a type then Continue leaves the screen', (t) async {
      await show(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const RegisterAccountTypeScreen())), child: const Text('go')))));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.tap(find.text('Store'));
      await t.pump();
      await t.tap(find.text('Continue as merchant'));
      await t.pumpAndSettle();
      expect(find.text('go'), findsOneWidget);
    });
    testWidgets('Already registered? Sign in opens the chooser', (t) async {
      await show(t, const RegisterAccountTypeScreen());
      await t.tap(find.text('Already registered? Sign in'));
      await t.pumpAndSettle();
      expect(find.text('How would you like to sign in?'), findsOneWidget);
    });
  });

  group('Login success', () {
    testWidgets('shows the name and restaurant from the server', (t) async {
      final api = FakeApi(() async => PartnerMe(name: 'Riya Sharma', email: 'riya@sharmastore.in', outlet: 'Sharma Store'));
      await show(t, LoginSuccessScreen(api: api, auth: FakeAuth()));
      await t.pumpAndSettle();
      expect(find.text('Welcome back, Riya.'), findsOneWidget);
      expect(find.textContaining('Sharma Store'), findsOneWidget);
      expect(find.text('r•••@sharmastore.in'), findsOneWidget);
    });
    testWidgets('the language comes first after signing in: English, Hindi, Hinglish; the screen switches and the store keeps it', (t) async {
      addTearDown(() => setAppLanguage('en'));
      final saved = <String>[];
      final api = FakeApi(() async => PartnerMe(name: 'Riya', email: 'r@x.in', outlet: 'S'));
      await show(t, LoginSuccessScreen(api: api, auth: FakeAuth(), saveLanguage: (c) async => saved.add(c)));
      await t.pumpAndSettle();
      expect(find.text('Choose your language'), findsOneWidget);
      for (final c in ['en', 'hi', 'hi-en']) {
        expect(find.byKey(ValueKey('login-language-$c')), findsOneWidget);
      }
      // above Continue: the choice comes before going in
      expect(t.getTopLeft(find.byKey(const ValueKey('login-language-hi'))).dy, lessThan(t.getTopLeft(find.text('Continue to Store POS')).dy));
      await t.ensureVisible(find.byKey(const ValueKey('login-language-hi')));
      await t.tap(find.byKey(const ValueKey('login-language-hi')));
      await t.pumpAndSettle();
      expect(saved, ['hi']);
      expect(find.text('अपनी भाषा चुनें'), findsOneWidget);
    });
    testWidgets('Continue to store opens the control centre', (t) async {
      final api = FakeApi(() async => PartnerMe(name: 'Riya', email: 'r@x.in', outlet: ''));
      await show(t, LoginSuccessScreen(api: api, auth: FakeAuth()));
      await t.pumpAndSettle();
      await t.tap(find.text('Continue to Store POS'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(ControlCentreScreen), findsOneWidget);
    });
    testWidgets('Switch account signs out', (t) async {
      final a = FakeAuth();
      final api = FakeApi(() async => PartnerMe(name: 'Riya', email: 'r@x.in', outlet: ''));
      await show(t, LoginSuccessScreen(api: api, auth: a));
      await t.pumpAndSettle();
      await t.tap(find.text('Switch account'));
      await t.pump();
      expect(a.calls, ['signOut']);
    });
    testWidgets('no store yet: friendly state, no retry button', (t) async {
      final api = FakeApi(() async => throw const PartnerApiException(403, 'You are not a staff member of any restaurant on One Local.'));
      await show(t, LoginSuccessScreen(api: api, auth: FakeAuth()));
      await t.pumpAndSettle();
      expect(find.text('Your account is ready.'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
      expect(find.text('Switch account'), findsOneWidget);
    });
    testWidgets('offline: Try again asks the server again', (t) async {
      var fail = true;
      final api = FakeApi(() async {
        if (fail) throw const SocketException('x');
        return PartnerMe(name: 'Riya', email: 'r@x.in', outlet: 'S');
      });
      await show(t, LoginSuccessScreen(api: api, auth: FakeAuth()));
      await t.pumpAndSettle();
      expect(find.text('We could not reach OneLocal.'), findsOneWidget);
      fail = false;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(api.calls, 2);
      expect(find.text('Welcome back, Riya.'), findsOneWidget);
    });
  });
}
