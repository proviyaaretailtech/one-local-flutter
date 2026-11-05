import 'package:web/web.dart' as web;

import 'guest_api.dart';

/// Puts a tracking token (a pre-order's, or a web order's) in the page address (`?track=`), keeping the path (the store link or the table
/// code): a reload or a shared link reopens its tracking. Replaces the entry instead of adding one, so Back does not walk through it.
void rememberTrackLink(String token) {
  final at = web.window.location;
  web.window.history.replaceState(null, '', '${at.pathname}?track=${Uri.encodeQueryComponent(token)}${at.hash}');
}

/// This browser's little memory in localStorage (the device key, "Live mode"). A browser that refuses storage (private mode) keeps it for
/// this visit only.
GuestPrefs browserPrefs() => _LocalPrefs();

class _LocalPrefs implements GuestPrefs {
  final _memory = MemoryGuestPrefs();

  @override
  String? read(String key) {
    try {
      return web.window.localStorage.getItem(key) ?? _memory.read(key);
    } catch (_) {
      return _memory.read(key);
    }
  }

  @override
  void write(String key, String value) {
    _memory.write(key, value);
    try {
      web.window.localStorage.setItem(key, value);
    } catch (_) {
      // storage refused: the memory copy serves this visit
    }
  }
}
