import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/api/live_sync.dart';
import 'package:vinii_pos/assistant/ol_bot.dart';
import 'package:vinii_pos/orders/channel_orders.dart';

/// Runs before every test file: Ol (the helper on the restaurant bar) holds still in tests, with no blinking or timed tips
/// to keep the test clock busy, and starts each test with its tips unsaid.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  OlBot.animate = false;
  LiveSync.enabled = false; // no live channel in tests: the screens re-read on their own
  ChannelStack.animate = false; // the delivery cards do not pulse in tests
  setUp(OlBot.reset);
  await testMain();
}
