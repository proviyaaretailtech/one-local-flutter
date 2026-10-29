import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../api/maps_api.dart';
import '../../auth/partner_api.dart';
import '../theme.dart';
import 'maps_setup.dart';

/// Where the pin went, and the address Google found there (null when it found none). [searched] is true for a chosen search
/// result (the whole address is the person's pick), false for a dragged or tapped pin (only the area around it is sure).
typedef MapsPick = ({double lat, double lng, MapsPlace? place, bool searched});

const _india = LatLng(20.5937, 78.9629);
const _mapBg = Color(0xFFE8ECDA);

/// The map pin with address search (founder, 29 Oct 2026: a real Google map instead of the illustrative one). Search for the shop
/// or street, or drag or tap the pin; every pick reports the position and the address there. Without a map key ([mapsEnabled]
/// false) it shows [fallback], so the screen works as it did.
class LocationPicker extends StatefulWidget {
  const LocationPicker({super.key, required this.lat, required this.lng, required this.onPicked, required this.fallback, this.api, this.height = 220});

  /// The pin the screen has (from the saved address, "use my location" or an earlier pick); null for none yet.
  final double? lat, lng;
  final ValueChanged<MapsPick> onPicked;
  final Widget fallback;
  final MapsApi? api;
  final double height;

  @override
  State<LocationPicker> createState() => _LocationPickerState();
}

class _LocationPickerState extends State<LocationPicker> {
  late final MapsApi _api = widget.api ?? MapsApi();
  late final Future<bool> _ready = prepareMaps();
  final _q = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  String _session = MapsApi.newSession();
  List<MapsSuggestion> _results = const [];
  String? _searchNote;
  bool _searching = false, _finding = false;
  int _searchSeq = 0, _pickSeq = 0;
  GoogleMapController? _map;
  late LatLng? _pin = _given;

  LatLng? get _given => widget.lat != null && widget.lng != null ? LatLng(widget.lat!, widget.lng!) : null;

  @override
  void didUpdateWidget(LocationPicker old) {
    super.didUpdateWidget(old);
    final given = _given;
    // the screen moved the pin itself ("use my current location", typed numbers): follow it
    if (given != null && (_pin == null || (given.latitude - _pin!.latitude).abs() > 1e-6 || (given.longitude - _pin!.longitude).abs() > 1e-6)) {
      _pin = given;
      _map?.animateCamera(CameraUpdate.newLatLngZoom(given, 17));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    _focus.dispose();
    _map?.dispose();
    super.dispose();
  }

  void _typed(String text) {
    _debounce?.cancel();
    if (text.trim().length < 3) {
      setState(() {
        _results = const [];
        _searchNote = null;
        _searching = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(text.trim()));
  }

  Future<void> _search(String q) async {
    final seq = ++_searchSeq;
    setState(() => _searching = true);
    final near = _pin;
    try {
      final r = await _api.search(q, lat: near?.latitude, lng: near?.longitude, session: _session);
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _results = r;
        _searchNote = r.isEmpty ? 'No match. Try the street or area name.' : null;
      });
    } on PartnerApiException catch (e) {
      if (mounted && seq == _searchSeq) {
        setState(() {
          _results = const [];
          // 404: a server from before the map pin (no maps_search yet)
          _searchNote = e.status == 404 ? 'Address search is not available yet. Drag the pin or type the address.' : e.message;
        });
      }
    } catch (_) {
      if (mounted && seq == _searchSeq) {
        setState(() {
          _results = const [];
          _searchNote = 'Search is unavailable right now. Drag the pin or type the address.';
        });
      }
    } finally {
      if (mounted && seq == _searchSeq) setState(() => _searching = false);
    }
  }

  Future<void> _choose(MapsSuggestion s) async {
    _focus.unfocus();
    final seq = ++_pickSeq;
    setState(() {
      _q.text = s.title;
      _results = const [];
      _searchNote = null;
      _finding = true;
    });
    try {
      final place = await _api.place(s.placeId, session: _session);
      if (!mounted || seq != _pickSeq) return;
      final at = LatLng(place.lat, place.lng);
      setState(() => _pin = at);
      _map?.animateCamera(CameraUpdate.newLatLngZoom(at, 17));
      widget.onPicked((lat: place.lat, lng: place.lng, place: place, searched: true));
    } on PartnerApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not open that place. Try another result.');
    } finally {
      _session = MapsApi.newSession(); // a chosen result ends the search session
      if (mounted && seq == _pickSeq) setState(() => _finding = false);
    }
  }

  Future<void> _moveTo(LatLng at) async {
    final seq = ++_pickSeq;
    setState(() {
      _pin = at;
      _finding = true;
    });
    MapsPlace? place;
    try {
      place = await _api.reverse(at.latitude, at.longitude);
    } catch (_) {
      // the pin still counts; the person types the address
    }
    if (!mounted || seq != _pickSeq) return;
    setState(() => _finding = false);
    widget.onPicked((lat: at.latitude, lng: at.longitude, place: place, searched: false));
  }

  Widget _searchField() => Container(
        height: kFieldH,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: kField, border: Border.all(color: kFieldBorder, width: kBorderW), borderRadius: BorderRadius.circular(kRadius)),
        child: Row(children: [
          const Icon(Icons.search, size: 20, color: kMuted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              key: const ValueKey('maps-search'),
              controller: _q,
              focusNode: _focus,
              onChanged: _typed,
              textInputAction: TextInputAction.search,
              onSubmitted: (v) => v.trim().length >= 2 ? _search(v.trim()) : null,
              autocorrect: false,
              style: inter(15, 400),
              decoration: plainInput.copyWith(hintText: 'Search your shop, street or area', hintStyle: inter(15, 400, color: kMuted)),
            ),
          ),
          if (_searching)
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: kMuted))
          else if (_q.text.isNotEmpty)
            InkWell(
              onTap: () => setState(() {
                _q.clear();
                _results = const [];
                _searchNote = null;
              }),
              child: const Icon(Icons.close, size: 18, color: kMuted),
            ),
        ]),
      );

  Widget _suggestions() => Container(
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: kLine), borderRadius: BorderRadius.circular(12)),
        child: _searchNote != null
            ? Padding(padding: const EdgeInsets.all(12), child: Text(_searchNote!, style: inter(13, 500, color: kMuted)))
            : Column(children: [
                for (final (i, s) in _results.indexed)
                  InkWell(
                    key: ValueKey('maps-result-$i'),
                    onTap: () => _choose(s),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(children: [
                        const Icon(Icons.place_outlined, size: 20, color: kMuted),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 600)),
                            if (s.subtitle.isNotEmpty) Text(s.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 400, color: kMuted)),
                          ]),
                        ),
                      ]),
                    ),
                  ),
              ]),
      );

  Widget _chip(String text, {bool busy = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.94), borderRadius: BorderRadius.circular(20), boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 6)]),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (busy) ...[const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: kPrimary)), const SizedBox(width: 6)],
          Text(text, style: inter(12, 600)),
        ]),
      );

  Widget _note(String text) => Container(
        color: _mapBg,
        padding: const EdgeInsets.all(16),
        alignment: Alignment.center,
        child: Text(text, textAlign: TextAlign.center, style: inter(13, 500, color: kMuted)),
      );

  Widget _mapArea() => FutureBuilder<bool>(
        future: _ready,
        builder: (_, ready) {
          if (ready.connectionState != ConnectionState.done) {
            return Container(color: _mapBg, alignment: Alignment.center, child: const CircularProgressIndicator(strokeWidth: 2, color: kPrimary));
          }
          return ValueListenableBuilder<bool>(
            valueListenable: mapsKeyRefused,
            builder: (_, refused, _) {
              if (ready.data != true || refused) return _note('The map could not load. Search above, or type the address below.');
              return Stack(children: [
                GoogleMap(
                  key: const ValueKey('maps-map'),
                  initialCameraPosition: CameraPosition(target: _pin ?? _india, zoom: _pin == null ? 4.5 : 17),
                  onMapCreated: (c) => _map = c,
                  markers: {if (_pin != null) Marker(markerId: const MarkerId('pin'), position: _pin!, draggable: true, onDragEnd: _moveTo)},
                  onTap: _moveTo,
                  myLocationButtonEnabled: false,
                  mapToolbarEnabled: false,
                  // the page scrolls; inside the map a drag moves the map
                  gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer())},
                ),
                Positioned(
                  left: 10,
                  top: 10,
                  child: _finding ? _chip('Finding the address…', busy: true) : _chip(_pin == null ? 'Tap the map at your shop' : 'Drag the pin to your shop\'s door'),
                ),
              ]);
            },
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    if (!mapsEnabled) return widget.fallback;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _searchField(),
        if (_results.isNotEmpty || _searchNote != null) _suggestions(),
        const SizedBox(height: 10),
        ClipRRect(borderRadius: BorderRadius.circular(16), child: SizedBox(height: widget.height, child: _mapArea())),
      ],
    );
  }
}
