import 'dart:async';

import 'package:http/http.dart' as http;

/// Which backend the app talks to, chosen once at start-up.
///
/// Two environments can be given with --dart-define (names only in code, values in the git-ignored
/// `.env.local` file; see `.env.example`):
///   local:  SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, PARTNER_API_BASE_URL
///   hosted: HOSTED_SUPABASE_URL, HOSTED_SUPABASE_PUBLISHABLE_KEY, HOSTED_PARTNER_API_BASE_URL
/// The local one wins when its POS server answers `/health`; otherwise the hosted one is used.
/// A server and its Supabase always go together: a sign-in token from one database is not valid on the other.
/// APP_ENV=local or APP_ENV=hosted forces a choice and skips the check.
class AppEnv {
  AppEnv._(this.name, this.supabaseUrl, this.supabaseKey, this.apiBase);

  final String name;
  final String supabaseUrl;
  final String supabaseKey;
  final String apiBase;

  static AppEnv? _current;

  /// The chosen environment. Before [resolve] runs (tests, tools) it is the local one as defined.
  static AppEnv get current => _current ?? _local;

  /// Base URL of the POS server without a trailing slash.
  static String get apiBaseUrl => current.apiBase;

  static final AppEnv _local = AppEnv._(
    'local',
    const String.fromEnvironment('SUPABASE_URL'),
    const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
    _trim(const String.fromEnvironment('PARTNER_API_BASE_URL')),
  );

  static final AppEnv _hosted = AppEnv._(
    'hosted',
    const String.fromEnvironment('HOSTED_SUPABASE_URL'),
    const String.fromEnvironment('HOSTED_SUPABASE_PUBLISHABLE_KEY'),
    _trim(const String.fromEnvironment('HOSTED_PARTNER_API_BASE_URL')),
  );

  static String _trim(String u) => u.replaceAll(RegExp(r'/+$'), '');

  static bool _complete(AppEnv e) => e.supabaseUrl.isNotEmpty && e.supabaseKey.isNotEmpty && e.apiBase.isNotEmpty;

  /// Picks the environment. [probe] is replaceable for tests.
  static Future<AppEnv> resolve({Future<bool> Function(String base)? probe, String? forced}) async {
    final force = forced ?? const String.fromEnvironment('APP_ENV');
    final check = probe ?? _healthy;
    AppEnv pick;
    if (force == 'hosted' && _complete(_hosted)) {
      pick = _hosted;
    } else if (force == 'local' || !_complete(_hosted)) {
      pick = _local;
    } else if (_complete(_local) && await check(_local.apiBase)) {
      pick = _local;
    } else {
      pick = _hosted;
    }
    _current = pick;
    return pick;
  }

  static Future<bool> _healthy(String base) async {
    try {
      final r = await http.get(Uri.parse('$base/health')).timeout(const Duration(seconds: 2));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
