import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/partner_api.dart';

/// KOT, KDS, orders, stock and purchases kept in step on every screen (founder, 30 Oct 2026; migration 0631).
///
/// The database broadcasts on three private channels of the business: `org:<id>:kitchen` (a KOT made or moved), `org:<id>:orders`
/// (an order placed or changed) and `org:<id>:stock` (stock in or out: a sale, a receipt, a count, a purchase). Only the business's
/// members may hear them. A screen says which it cares about with [LiveSync.watch]; on a message it re-reads at once (a burst of
/// messages is one re-read). The screens keep their slow re-read as a fallback, so nothing depends on the connection.
class LiveSync {
  LiveSync._();
  static final LiveSync instance = LiveSync._();

  /// Off in tests and wherever Supabase is not set up; a screen's [watch] then does nothing.
  static bool enabled = true;

  final _listeners = <String, Set<VoidCallback>>{'kitchen': {}, 'orders': {}, 'stock': {}};
  final _channels = <RealtimeChannel>[];
  String? _org;
  Future<void>? _starting;
  StreamSubscription<AuthState>? _auth;

  /// Calls [onChange] (debounced) whenever one of [kinds] changes; returns the function that stops it (call it in dispose).
  static VoidCallback watch(Set<String> kinds, VoidCallback onChange, {Duration debounce = const Duration(milliseconds: 400)}) {
    if (!enabled) return () {};
    Timer? t;
    void fire() {
      t?.cancel();
      t = Timer(debounce, onChange);
    }

    final self = instance;
    for (final k in kinds) {
      self._listeners[k]?.add(fire);
    }
    unawaited(self._start());
    return () {
      t?.cancel();
      for (final k in kinds) {
        self._listeners[k]?.remove(fire);
      }
    };
  }

  /// Joins the business's channels once per signed-in session; signing out leaves them.
  Future<void> _start() => _starting ??= () async {
        try {
          final client = Supabase.instance.client;
          _auth ??= client.auth.onAuthStateChange.listen((s) {
            if (s.event == AuthChangeEvent.signedOut) unawaited(_stop());
          });
          if (client.auth.currentSession == null) {
            _starting = null;
            return;
          }
          final org = (await PartnerApi().me()).organizationId;
          if (org == null || org.isEmpty) {
            _starting = null;
            return;
          }
          _org = org;
          await client.realtime.setAuth(client.auth.currentSession?.accessToken);
          for (final kind in _listeners.keys) {
            final ch = client.channel('org:$org:$kind', opts: const RealtimeChannelConfig(private: true));
            ch.onBroadcast(event: '*', callback: (_) {
              for (final l in List.of(_listeners[kind]!)) {
                l();
              }
            });
            ch.subscribe();
            _channels.add(ch);
          }
        } catch (_) {
          // no live channel (offline, not set up): the screens still re-read on their own timer
          _starting = null;
        }
      }();

  Future<void> _stop() async {
    final client = Supabase.instance.client;
    for (final ch in _channels) {
      await client.removeChannel(ch);
    }
    _channels.clear();
    _org = null;
    _starting = null;
  }

  /// The business the channels are for (null until joined).
  String? get organizationId => _org;
}
