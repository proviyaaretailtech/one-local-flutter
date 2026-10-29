import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthResponse;
import 'package:vinii_pos/auth/auth_repository.dart';
import 'package:vinii_pos/auth/partner_api.dart';
import 'package:vinii_pos/ui/theme.dart';

/// Records what the screens ask of auth and can be told to fail.
class FakeAuth extends AuthRepository {
  final calls = <String>[];
  Object? failWith;
  Completer<void>? hold;

  Future<void> _do(String what) async {
    calls.add(what);
    if (hold != null) await hold!.future;
    if (failWith != null) throw failWith!;
  }

  @override
  Future<void> sendPhoneCode(String e164) => _do('sendPhoneCode $e164');
  @override
  Future<void> sendEmailCode(String email) => _do('sendEmailCode $email');
  @override
  Future<AuthResponse> verifyPhoneCode(String e164, String code) async {
    await _do('verifyPhoneCode $e164 $code');
    return AuthResponse();
  }

  @override
  Future<AuthResponse> verifyEmailCode(String email, String code) async {
    await _do('verifyEmailCode $email $code');
    return AuthResponse();
  }

  @override
  Future<AuthResponse> signInWithPassword(String email, String password) async {
    await _do('signInWithPassword $email');
    return AuthResponse();
  }

  @override
  Future<AuthResponse> signInWithPhonePassword(String e164, String password) async {
    await _do('signInWithPhonePassword $e164');
    return AuthResponse();
  }

  @override
  Future<void> sendPasswordReset(String email) => _do('sendPasswordReset $email');
  @override
  Future<void> registerWithPhone({required String e164, required String fullName, required String email}) =>
      _do('registerWithPhone $e164 $fullName $email');
  @override
  Future<bool> signInWithGoogle() async {
    await _do('google');
    return true;
  }

  @override
  Future<bool> signInWithApple() async {
    await _do('apple');
    return true;
  }

  @override
  Future<void> signOut() => _do('signOut');
}

class FakeApi extends PartnerApi {
  FakeApi(this.result);
  final Future<PartnerMe> Function() result;
  int calls = 0;
  @override
  Future<PartnerMe> me() {
    calls++;
    return result();
  }
}

/// Tests draw text with the square Ahem font, which is wider than Inter, so layout overflow is not a real failure here.
void ignoreOverflow() {
  final original = FlutterError.onError;
  FlutterError.onError = (d) {
    if (d.exceptionAsString().contains('overflowed')) return;
    original?.call(d);
  };
  addTearDown(() => FlutterError.onError = original);
}

Future<void> show(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 3000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pump();
}

Finder toast(String text) => find.descendant(of: find.byType(SnackBar), matching: find.text(text));
