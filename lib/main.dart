import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api/app_env.dart';
import 'app.dart';
import 'app_routes.dart';
import 'ui/language_step.dart';

/// Config comes from --dart-define, names only. No values in code. See `lib/api/app_env.dart`:
/// the local server is used when it answers, otherwise the hosted one, each with its own Supabase.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final env = await AppEnv.resolve();
  await Supabase.initialize(url: env.supabaseUrl, publishableKey: env.supabaseKey);
  installRoutes();
  await restoreAppLanguage(); // opens in the language this phone chose
  runApp(const PosApp());
}
