import 'package:audioplayers/audioplayers.dart';

/// The Orders screen's sounds (founder, 28 Oct 2026): a two-note chime when a delivery order arrives, and a sharper triple beep when an
/// order has 10 seconds left to be accepted (assets/sounds/order_arrive.wav, order_warning.wav). Never throws: a missed sound must not
/// stop the screen (a browser may refuse to play before the first tap).
class OrderAlertSounds {
  const OrderAlertSounds();

  Future<void> arrive() => _play('sounds/order_arrive.wav');
  Future<void> warning() => _play('sounds/order_warning.wav');

  /// A short beep: a kitchen ticket is ready to hand over (the KDS board).
  Future<void> ready() => _play('sounds/beep.wav');

  /// An alarm, the warning twice: an order the kitchen had was cancelled (the KDS board).
  Future<void> cancelled() async {
    await _play('sounds/order_warning.wav');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await _play('sounds/order_warning.wav');
  }

  static Future<void> _play(String asset) async {
    try {
      final p = AudioPlayer();
      p.onPlayerComplete.listen((_) => p.dispose());
      await p.play(AssetSource(asset), volume: 1);
    } catch (_) {/* no sound is better than a stuck screen */}
  }
}
