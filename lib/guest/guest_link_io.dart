import 'guest_api.dart';

/// Puts a tracking token in the page address (`?track=`). Only the web page has an address; elsewhere there is nothing to do.
void rememberTrackLink(String token) {}

/// This browser's little memory (the device key, "Live mode"). Off the web it lives in memory only.
GuestPrefs browserPrefs() => MemoryGuestPrefs();
