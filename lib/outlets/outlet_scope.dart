import 'package:flutter/foundation.dart';

/// The outlet the whole app is showing (founder, 20 Oct 2026): `null` = "All outlets" (screens that can sum do; screens that work on one
/// outlet use the default one), otherwise one verified outlet's id. Chosen in [OutletHeader]'s switcher; screens that read data by outlet
/// listen to it. Lives for the app session (spec C5).
class OutletScope {
  OutletScope._();
  static final ValueNotifier<String?> selected = ValueNotifier<String?>(null);

  /// The outlet to send to a call that takes one outlet: the explicit [own] choice, else the app's selection, else null (server default).
  static String? pick(String? own) => (own != null && own.isNotEmpty) ? own : selected.value;

  /// Tests and sign-out.
  static void reset() => selected.value = null;
}
