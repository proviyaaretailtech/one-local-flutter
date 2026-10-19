import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/api/app_env.dart';

void main() {
  // Tests run without --dart-define, so the hosted environment is incomplete and the local one is chosen
  // without asking the network; a forced "hosted" with no hosted values also stays local.
  test('no hosted values: local is chosen without a health check', () async {
    var asked = 0;
    final e = await AppEnv.resolve(probe: (_) async { asked++; return false; });
    expect(e.name, 'local');
    expect(asked, 0);
    expect(AppEnv.current.name, 'local');
  });

  test('forced hosted without hosted values falls back to local', () async {
    final e = await AppEnv.resolve(forced: 'hosted', probe: (_) async => false);
    expect(e.name, 'local');
  });
}
