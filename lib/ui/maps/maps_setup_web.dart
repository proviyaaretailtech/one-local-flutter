import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Adds Google's Maps JavaScript API to the page once and waits for it. google_maps_flutter_web needs `google.maps` before a map is made.
Future<bool> prepare(String key, void Function() onRefused) {
  // Google calls this global when the key is not allowed on this page
  globalContext.setProperty('gm_authFailure'.toJS, onRefused.toJS);
  final done = Completer<bool>();
  final script = web.HTMLScriptElement()
    ..src = 'https://maps.googleapis.com/maps/api/js?key=${Uri.encodeQueryComponent(key)}&v=weekly'
    ..async = true;
  script.onload = ((web.Event _) => done.complete(true)).toJS;
  script.onerror = ((web.Event _) => done.complete(false)).toJS;
  web.document.head!.append(script);
  return done.future;
}
