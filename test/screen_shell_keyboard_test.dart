import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/screens/create_password_screen.dart';
import 'package:vinii_pos/screens/email_login_screen.dart';
import 'package:vinii_pos/screens/mobile_login_screen.dart';
import 'package:vinii_pos/screens/otp_verify_screen.dart';
import 'package:vinii_pos/screens/password_login_screen.dart';
import 'package:vinii_pos/screens/register_personal_screen.dart';
import 'package:vinii_pos/ui/theme.dart';
import 'package:vinii_pos/ui/widgets.dart' show OtpBoxes;

import 'helpers.dart';

// Sign-in and sign-up pages (founder, 1 Nov 2026): with the phone's keyboard open, the email and password fields must stay in view; the
// buttons pinned at the bottom move into the scrolling page while the keyboard is up. A small phone: 360 × 640, a 24 px status bar, a 340 px keyboard (with its suggestion strip).

const _phone = Size(360, 640), _keyboard = 340.0;

Future<void> show(WidgetTester t, Widget page) async {
  ignoreOverflow();
  t.view.physicalSize = _phone;
  t.view.devicePixelRatio = 1;
  t.view.padding = const FakeViewPadding(top: 24);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: page));
  await t.pumpAndSettle();
}

/// Tap a field, then the keyboard slides up (as on a phone: the page shrinks and the field is scrolled into view).
Future<void> typeIn(WidgetTester t, Finder f) async {
  t.view.viewInsets = FakeViewPadding.zero;
  await t.pumpAndSettle();
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pump();
  t.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
  await t.pumpAndSettle();
}

/// As a phone browser does it: tap the field, then the page itself gets shorter by the keyboard's height and no keyboard is reported.
Future<void> shrinkFor(WidgetTester t, Finder f) async {
  t.view.viewInsets = FakeViewPadding.zero;
  t.view.physicalSize = _phone;
  await t.pumpAndSettle();
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pump();
  t.view.physicalSize = Size(_phone.width, _phone.height - _keyboard);
  await t.pumpAndSettle();
  await t.pump(const Duration(milliseconds: 500));
  await t.pumpAndSettle();
}

/// The field (its whole box, label included) is between the top of the screen and the top of the keyboard.
void expectInView(WidgetTester t, Finder f) {
  final r = t.getRect(f);
  expect(r.top, greaterThanOrEqualTo(0));
  expect(r.bottom, lessThanOrEqualTo(_phone.height - _keyboard));
  // and not under the buttons pinned below the page: inside the part of the page that scrolls
  final page = t.getRect(find.byType(Scrollable).first);
  expect(r.top, greaterThanOrEqualTo(page.top - 0.5), reason: 'not scrolled up out of the page');
  expect(r.bottom, lessThanOrEqualTo(page.bottom + 0.5), reason: 'not hidden under the buttons');
}

void main() {
  testWidgets('keyboard closed: Sign in is pinned at the bottom', (t) async {
    await show(t, PasswordLoginScreen(auth: FakeAuth()));
    expect(t.getRect(find.text('Sign in')).bottom, greaterThan(_phone.height - 160));
  });

  testWidgets('password sign-in, keyboard open: the email and password fields stay above the keyboard', (t) async {
    await show(t, PasswordLoginScreen(auth: FakeAuth()));
    final fields = find.byType(TextField), boxes = find.byType(LabeledField);
    await typeIn(t, fields.at(0));
    expectInView(t, boxes.at(0));
    await typeIn(t, fields.at(1));
    expectInView(t, boxes.at(1));
    // Sign in scrolls with the page
    await t.scrollUntilVisible(find.text('Sign in'), 100, scrollable: find.byType(Scrollable).first);
    expectInView(t, find.text('Sign in'));
  });

  // The rest of the sign-in pages, and the phone-browser case (founder, 2 Nov 2026: the fields still hid behind the keyboard on the
  // phone): a browser often shrinks the page for its keyboard and reports none, so each field is checked both ways.
  final pages = <String, Widget Function()>{
    'password sign-in': () => PasswordLoginScreen(auth: FakeAuth()),
    'sign-up': () => const RegisterPersonalScreen(),
    'email code sign-in': () => EmailLoginScreen(auth: FakeAuth()),
    'mobile code sign-in': () => MobileLoginScreen(auth: FakeAuth()),
    'create password': () => const CreatePasswordScreen(next: SizedBox()),
  };
  for (final MapEntry(key: name, value: page) in pages.entries) {
    testWidgets('$name, keyboard open: each field in view', (t) async {
      await show(t, page());
      final fields = find.byType(TextField), boxes = find.byType(LabeledField);
      for (var i = 0; i < t.widgetList(fields).length; i++) {
        await typeIn(t, fields.at(i));
        expectInView(t, boxes.at(i));
      }
    });

    testWidgets('$name, a phone browser shrinks the page for its keyboard: each field in view, buttons out of its way', (t) async {
      await show(t, page());
      final fields = find.byType(TextField), boxes = find.byType(LabeledField);
      for (var i = 0; i < t.widgetList(fields).length; i++) {
        await shrinkFor(t, fields.at(i));
        expectInView(t, boxes.at(i));
      }
    });
  }

  testWidgets('verify code: the six boxes stay in view, keyboard reported or page shrunk', (t) async {
    await show(t, OtpVerifyScreen(email: 'niks@example.com', auth: FakeAuth()));
    final code = find.byType(TextField).first;
    await typeIn(t, code);
    expectInView(t, find.byType(OtpBoxes));
    await shrinkFor(t, code);
    expectInView(t, find.byType(OtpBoxes));
  });

  testWidgets('sign-up, keyboard open: every field can be typed in, in view', (t) async {
    await show(t, const RegisterPersonalScreen());
    final fields = find.byType(TextField), boxes = find.byType(LabeledField);
    for (var i = 0; i < t.widgetList(fields).length; i++) {
      await typeIn(t, fields.at(i));
      expectInView(t, boxes.at(i));
    }
  });
}
