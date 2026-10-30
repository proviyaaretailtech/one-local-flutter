import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/partner_api.dart';

/// What a screen says about [e]: the server's own sentence, or a plain one (never "TypeError …" or "Instance of …").
String errorSentence(Object e) => e is PartnerApiException ? e.message : 'Something went wrong. Please try again.';

/// The sentence a person reads when the server could not be reached at all.
const kOfflineSentence = 'No internet, or the server did not answer. Check the internet and try again.';

/// The sentence for an answer this app cannot read (a proxy's error page, a half-sent reply).
const kUnreadableSentence = 'The server sent an answer this app could not read. Try again in a moment.';

/// Waits for [request]; a dropped connection or a timeout becomes [onFail] with [kOfflineSentence], so no screen ever shows
/// "ClientException: Failed host lookup".
Future<http.Response> guardNet(Future<http.Response> request, Never Function(String sentence) onFail, {Duration timeout = const Duration(seconds: 30)}) async {
  try {
    return await request.timeout(timeout);
  } on TimeoutException {
    onFail(kOfflineSentence);
  } on http.ClientException {
    onFail(kOfflineSentence);
  }
}

/// The JSON in [res] (an empty body is null); a body that is not JSON (a proxy's HTML error page) becomes [onFail] with
/// [kUnreadableSentence].
Object? readJson(http.Response res, Never Function(String sentence) onFail) {
  if (res.body.isEmpty) return null;
  try {
    return jsonDecode(res.body);
  } on FormatException {
    onFail(kUnreadableSentence);
  }
}
