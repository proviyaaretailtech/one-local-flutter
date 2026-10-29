import 'dart:async';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Every sign-in path in Phase A. Business rules live in the backend, not here.
/// Redirect scheme for OAuth must match Supabase → Auth → URL configuration.
const kOAuthRedirect = 'io.onelocal.pos://login-callback';

class AuthRepository {
  AuthRepository([SupabaseClient? client]) : _client = client;
  final SupabaseClient? _client;

  // Resolved on use, so screens can be built (and tested) before Supabase starts.
  GoTrueClient get _auth => (_client ?? Supabase.instance.client).auth;

  // Phone OTP (Twilio via Supabase).
  Future<void> sendPhoneCode(String e164) => _auth.signInWithOtp(phone: e164, shouldCreateUser: false);
  Future<AuthResponse> verifyPhoneCode(String e164, String code) =>
      _auth.verifyOTP(type: OtpType.sms, phone: e164, token: code);

  // Email OTP.
  Future<void> sendEmailCode(String email) => _auth.signInWithOtp(email: email, shouldCreateUser: false);
  Future<AuthResponse> verifyEmailCode(String email, String code) =>
      _auth.verifyOTP(type: OtpType.email, email: email, token: code);

  // Email + password.
  Future<AuthResponse> signInWithPassword(String email, String password) =>
      _auth.signInWithPassword(email: email, password: password);

  // Mobile number + password (27 Oct 2026): the same password, with the account's mobile number instead of its email.
  Future<AuthResponse> signInWithPhonePassword(String e164, String password) =>
      _auth.signInWithPassword(phone: e164, password: password);

  Future<void> sendPasswordReset(String email) => _auth.resetPasswordForEmail(email);

  // Registration is OTP-based (Figma "Create account" -> verify contact). No password is set here.
  /// [email] is optional (founder, 29 Oct 2026): the mobile number is enough to register.
  Future<void> registerWithPhone({required String e164, required String fullName, String? email}) =>
      _auth.signInWithOtp(phone: e164, shouldCreateUser: true, data: {'full_name': fullName, if (email != null && email.isNotEmpty) 'email': email});

  // Google and Apple (external providers configured in Supabase).
  Future<bool> signInWithGoogle() => _auth.signInWithOAuth(OAuthProvider.google, redirectTo: kOAuthRedirect);
  Future<bool> signInWithApple() => _auth.signInWithOAuth(OAuthProvider.apple, redirectTo: kOAuthRedirect);

  Future<void> signOut() => _auth.signOut();

  /// The signed-in person's email, for the side nav profile. Null when Supabase has not started (tests).
  /// The name given when the account was made (sign-up keeps it with the login), or null.
  String? get currentName {
    try {
      final n = _auth.currentUser?.userMetadata?['full_name'];
      return n is String && n.trim().isNotEmpty ? n.trim() : null;
    } catch (_) {
      return null;
    }
  }

  /// The login's mobile number (digits, with 91), or null.
  String? get currentPhone {
    try {
      final p = _auth.currentUser?.phone;
      return p == null || p.isEmpty ? null : p;
    } catch (_) {
      return null;
    }
  }

  /// The signed-in login's id, or null.
  String? get currentUserId {
    try {
      return _auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  String? get currentEmail {
    try {
      return _auth.currentUser?.email;
    } catch (_) {
      return null;
    }
  }
}

/// One plain sentence for any sign-in failure. [fallback] is used when the cause is unknown.
String friendlyAuthError(Object e, {String fallback = 'Something went wrong. Please try again.'}) {
  if (e is SocketException || e is http.ClientException || e is TimeoutException) {
    return 'No internet connection. Check your network and try again.';
  }
  if (e is AuthApiException) {
    final code = e.code ?? '';
    final msg = e.message.toLowerCase();
    if (e.statusCode == '429' || code.contains('rate_limit') || msg.contains('rate limit') || msg.contains('seconds')) {
      return 'Too many attempts. Please wait a minute and try again.';
    }
    if (code == 'otp_expired' || msg.contains('expired')) return 'That code has expired. Request a new one.';
    if (code == 'invalid_credentials' || msg.contains('invalid login')) return 'Email or password is not right.';
    if (code == 'otp_disabled' || msg.contains('signups not allowed') || msg.contains('user not found')) {
      return 'We could not find an account with that contact. Check it or create an account.';
    }
    if (msg.contains('token has expired or is invalid') || msg.contains('invalid')) {
      return 'That code is not right. Check it and try again.';
    }
    if (msg.contains('provider') && msg.contains('not enabled')) return 'This sign-in method is not available yet.';
    if (msg.contains('sms') || msg.contains('twilio') || msg.contains('phone')) {
      return 'We could not send the SMS right now. Try email instead.';
    }
  }
  return fallback;
}

/// Plain sentence for a failure that is not an auth error (network, timeout, anything else).
String friendlyError(Object e, {String fallback = 'Something went wrong. Please try again.'}) => friendlyAuthError(e, fallback: fallback);
