import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Android has the key in its manifest already. iOS takes it here, before the first map (ios/Runner/AppDelegate.swift).
Future<bool> prepare(String key, void Function() onRefused) async {
  if (!Platform.isIOS) return true;
  try {
    await const MethodChannel('onelocal/maps').invokeMethod<void>('provideKey', key);
    return true;
  } catch (_) {
    return false;
  }
}
