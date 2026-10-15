import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'app_routes.dart';

/// Config comes from --dart-define, names only. No values in code.
///   SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: const String.fromEnvironment('SUPABASE_URL'),
    publishableKey: const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
  );
  installRoutes();
  runApp(const PosApp());
}
