import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

import '../outlets/outlets_api.dart' show outletIsRestaurant;

// USB printers for the restaurant POS (founder, 4 Nov 2026: "whenever i try to print the test print it is not connecting to any printer").
// Android's print screen cannot reach a USB thermal printer, so the router sends its ESC/POS down the cable (MainActivity:
// onelocal/usb_printer). Tested on the founder's USB printer, 5 Nov 2026. The store and service POS keep "not supported".

/// Why a USB print failed, said to the person.
class UsbPrintException implements Exception {
  UsbPrintException(this.message);
  final String message;
  @override
  String toString() => message;
}

const _usb = MethodChannel('onelocal/usb_printer');

/// Whether this device prints to a USB printer: the restaurant's Android app (tests replace it).
bool Function() usbPrintingOn = () => !kIsWeb && defaultTargetPlatform == TargetPlatform.android && outletIsRestaurant();

/// Sends bytes to the USB printer plugged into this phone or tablet (tests replace it).
Future<void> Function(List<int> bytes) sendUsbPrinter = (bytes) async {
  try {
    await _usb.invokeMethod<bool>('print', {'bytes': Uint8List.fromList(bytes)});
  } on PlatformException catch (e) {
    throw UsbPrintException(switch (e.code) {
      'USB_NONE' => 'no USB printer found. Check the cable (an OTG adapter on a phone) and that the printer is on',
      'USB_DENIED' => 'USB access was not allowed. Try again and choose OK when Android asks',
      _ => 'the USB printer did not take it: ${e.message ?? e.code}',
    });
  } on MissingPluginException {
    throw UsbPrintException('USB printers print from the Android app');
  }
};
