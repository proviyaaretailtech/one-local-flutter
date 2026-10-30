import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'motion.dart';
import 'theme.dart';

const _lime = Color(0xFFA1FE2F);

/// Opens the camera full screen and answers the first barcode it reads (with a beep and a buzz), or null when the person closes it.
/// Works on phones (Android camera permission) and in the browser (needs camera permission; localhost or https).
Future<String?> scanBarcode(BuildContext context, {bool allowTyping = false}) =>
    Navigator.of(context).push<String>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => BarcodeScannerScreen(allowTyping: allowTyping)));

/// Like [scanBarcode], with a "Type the code instead" button: an empty answer ('') means the person chose to type it.
Future<String?> scanBarcodeOrType(BuildContext context) => scanBarcode(context, allowTyping: true);

/// The shop-scanner beep (assets/sounds/beep.wav). Never throws: no sound is better than a lost scan.
Future<void> playScanBeep() async {
  try {
    final p = AudioPlayer();
    await p.play(AssetSource('sounds/beep.wav'), volume: 1);
    p.onPlayerComplete.first.then((_) => p.dispose());
  } catch (_) {}
}

class BarcodeScannerScreen extends StatefulWidget {
  const BarcodeScannerScreen({super.key, this.allowTyping = false});

  /// Shows "Type the code instead", which closes the camera answering '' (see [scanBarcodeOrType]).
  final bool allowTyping;
  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> {
  final _camera = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _done = false;

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  void _found(BarcodeCapture capture) {
    if (_done) return;
    final code = capture.barcodes.map((b) => b.rawValue?.trim() ?? '').firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (code.isEmpty) return;
    _done = true;
    playScanBeep();
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(code);
  }

  Widget _error(BuildContext context, MobileScannerException e) {
    final denied = e.errorCode == MobileScannerErrorCode.permissionDenied;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(LucideIcons.cameraOff, size: 40, color: Colors.white70),
            const SizedBox(height: 14),
            Text(denied ? 'Camera permission is off' : 'The camera could not start', style: inter(18, 700, color: Colors.white), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(denied ? 'Allow the camera for this app in your settings, or type the barcode instead.' : 'Close this and type the barcode instead.',
                style: inter(14, 400, color: Colors.white70, height: 1.4), textAlign: TextAlign.center),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(widget.allowTyping ? '' : null),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white54), shape: const StadiumBorder()),
              child: const Text('Type it instead'),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        // SizedBox.expand: the stack takes the whole screen (on its own it shrinks to the top button row and squeezes the camera).
        body: SizedBox.expand(
          child: Stack(children: [
            Positioned.fill(child: MobileScanner(controller: _camera, fit: BoxFit.cover, onDetect: _found, errorBuilder: _error)),
            // A clear window over the camera with darkened edges, so it is obvious where to hold the barcode.
            Positioned.fill(
              child: IgnorePointer(
                child: LayoutBuilder(builder: (_, c) {
                  final w = (c.maxWidth * 0.8).clamp(220.0, 420.0);
                  return Center(
                    child: Container(
                      key: const ValueKey('scan-window'),
                      width: w,
                      height: w * 0.6,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: _lime, width: 3),
                        boxShadow: const [BoxShadow(color: Color(0x88000000), spreadRadius: 2000)],
                      ),
                    ),
                  );
                }),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(children: [
                    _round(LucideIcons.x, 'Close', () => Navigator.of(context).pop()),
                    const Spacer(),
                    _round(LucideIcons.flashlight, 'Torch', () => _camera.toggleTorch()),
                  ]),
                ),
              ),
            ),
            Positioned(
              left: 24,
              right: 24,
              bottom: 48,
              child: SafeArea(
                top: false,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('Point the camera at the barcode', textAlign: TextAlign.center, style: inter(15, 600, color: Colors.white)),
                  if (widget.allowTyping) ...[
                    const SizedBox(height: 14),
                    TextButton.icon(
                      key: const ValueKey('scan-type-instead'),
                      onPressed: () => Navigator.of(context).pop(''),
                      style: TextButton.styleFrom(backgroundColor: const Color(0x33FFFFFF), foregroundColor: Colors.white, shape: const StadiumBorder(), padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12)),
                      icon: const Icon(LucideIcons.keyboard, size: 18),
                      label: Text('Type the code instead', style: inter(14, 600, color: Colors.white)),
                    ),
                  ],
                ]),
              ),
            ),
          ]),
        ),
      );

  Widget _round(IconData icon, String label, VoidCallback onTap) => Material(
        color: const Color(0x66000000),
        shape: const CircleBorder(),
        child: IconButton(tooltip: label, onPressed: onTap, icon: Icon(icon, color: Colors.white, size: 22)),
      );
}

/// The code typed in by hand ("Type the code instead" on the scanner); null when cancelled.
Future<String?> askBarcode(BuildContext context) {
  final c = TextEditingController();
  return showOlDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Type the barcode', style: inter(17, 700)),
      content: TextField(
        key: const ValueKey('barcode-typed'),
        controller: c,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'e.g. 8901234567890'),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(key: const ValueKey('barcode-typed-ok'), onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Use this code')),
      ],
    ),
  );
}
