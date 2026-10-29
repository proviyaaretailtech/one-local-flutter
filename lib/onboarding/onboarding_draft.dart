import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// What a person has typed on an onboarding screen but not saved yet (founder, 27 Oct 2026: "the draft should be saved if onboarding is
/// stopped abruptly"). Kept on this phone as they type and filled back in when the screen opens again; cleared once the server has the
/// section. Never PAN, Aadhaar or bank account numbers: those are typed again.
class OnbDraft {
  OnbDraft(this.section);
  final String section;
  Timer? _wait;

  String get _key => 'onb_draft_$section';

  /// The saved answers, or an empty map (no draft, or no storage here).
  Future<Map<String, String>> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return {};
      return (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      return {};
    }
  }

  /// Keeps [values] a moment after the last change (typing does not write on every key).
  void keep(Map<String, String?> values) {
    _wait?.cancel();
    _wait = Timer(const Duration(milliseconds: 400), () async {
      try {
        final clean = {for (final e in values.entries) if (e.value != null && e.value!.isNotEmpty) e.key: e.value!};
        (await SharedPreferences.getInstance()).setString(_key, jsonEncode(clean));
      } catch (_) {}
    });
  }

  /// The server has the section: the phone's copy goes.
  Future<void> clear() async {
    _wait?.cancel();
    try {
      (await SharedPreferences.getInstance()).remove(_key);
    } catch (_) {}
  }

  void dispose() => _wait?.cancel();
}
