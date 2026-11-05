import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../catalogue/item_photo.dart';
import '../onboarding/document_picker.dart' show PickedDocument;
import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'service_api.dart';
import 'catalogue_screen.dart' show serviceFields;
import 'service_parts.dart';
import 'service_widgets.dart';
import 'step_form.dart';

// The one Add service form (founder, 3 Nov 2026: "simplify the screen into just one form, one common form"): start from a saved template
// (it fills what the service needs, its rules and its length), then the basics, booking, price, what it needs, rules and notes. Anything
// can be changed; the publisher is not tied to a category's fields. It can also be saved as a new template.
//
// In steps (founder, 4 Nov 2026): a small Back at the top, the step's name with a step bar under it ("Step 3 of 6", the next one), Next
// at the bottom, and Save as a template, Save draft and Publish on the last step. Basics takes banner photos and videos too.

/// The six steps: name, icon, and the line under the step's card.
/// The steps follow the design's sections (Basics, How it is booked, Where, Who is coming, Price, What it uses, Confirmation). The booking
/// and price rules are part of Price (founder, 4 Nov 2026): the base price, then the exceptions for some people.
const kServiceSteps = [
  ('Basics', LucideIcons.fileText, 'Name it, pick its category, add photos and videos.'),
  ('How it is booked', LucideIcons.calendarClock, 'What customers book, for how long, and when.'),
  ('Where and who', LucideIcons.mapPin, 'Where it happens, and who can come.'),
  ('Price', LucideIcons.indianRupee, 'What customers pay, any different prices or limits for some people, and what they pay first.'),
  ('What it uses', LucideIcons.boxes, 'Who does it, the place, tools and materials, per booking.'),
  ('Notes and confirm', LucideIcons.notebookPen, 'Anything the team should know, and how bookings are confirmed.'),
];

const _mediaExt = {'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'webp': 'image/webp', 'mp4': 'video/mp4', 'mov': 'video/quicktime', 'webm': 'video/webm'};

/// Picks a banner photo ([video] false) or video from the device: photos up to 5 MB, videos up to 50 MB (the server checks again).
Future<PickedDocument?> pickServiceMedia({required bool video}) async {
  final exts = [for (final e in _mediaExt.entries) if (e.value.startsWith(video ? 'video/' : 'image/')) e.key];
  final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: exts);
  if (f == null) return null;
  final type = _mediaExt[f.name.split('.').last.toLowerCase()];
  if (type == null) return null;
  final bytes = await f.readAsBytes();
  if (bytes.length > (video ? 50 : 5) * 1024 * 1024) throw ItemPhotoUnavailable(video ? 'A video can be up to 50 MB.' : 'A photo can be up to 5 MB.');
  return PickedDocument(name: f.name, bytes: bytes, contentType: type);
}

// the design's dropdown options (Fields board, 3 Nov 2026); per subcategory ones (booking types, units, surfaces, amenities, where,
// pricing) come from listingProfile
const _advance = ['None', 'Fixed amount', '% of price'];
const _bookedFor = ['Any', 'Single', 'Couple', 'Family', 'Group'];
const _grades = ['Standard', 'Practice', 'Tournament'];
const _startEvery = ['Every 15 min', 'Every 30 min', 'Every 60 min'];
const _spans = ['30 min', '1 hr', '1.5 hr', '2 hr', '3 hr', '4 hr'];
const _steps = ['15 min', '30 min', '60 min'];
const _entryValid = ['This session', 'Full day', 'Multi-day'];
const _repeats = ['Once', 'Daily', 'Weekly', 'Custom'];
const _available = ['Business hours', 'Weekdays', 'Weekends', 'Custom'];
final _times = [for (var m = 0; m < 24 * 60; m += 30) '${(m ~/ 60) % 12 == 0 ? 12 : (m ~/ 60) % 12}:${(m % 60).toString().padLeft(2, '0')} ${m < 720 ? 'am' : 'pm'}'];
final _nights = [for (var i = 1; i <= 7; i++) '$i ${i == 1 ? 'night' : 'nights'}'];
const _bookAhead = ['7 days ahead', '30 days ahead', '60 days ahead', '90 days ahead'];
const _notice = ['None', '1 hr', '3 hr', '1 day'];
const _onCallArea = ['Within 3 km', 'Within 5 km', 'Within 10 km', 'Whole city'];
const _travel = ['Free', 'Fixed', 'Per km'];
const _ageRules = ['Anyone', '18+ only', '21+ only', 'Children with an adult', 'Children under 6 stay free', 'Children under 12 stay free'];
const _genderRules = ['Anyone', 'Women only', 'Men only'];
const _safety = ['None', 'Minimum height', 'Health declaration'];
const _guestId = ['Not needed', 'Required at check-in'];
const _grace = ['None', '5 min', '10 min', '15 min'];
const _noShow = ['Mark no-show', 'Free the slot', 'Keep waiting'];
const _gst = ['0%', '5%', '12%', '18%', '28%'];
const _cancel = ['Free until 1 hr before', 'Free until 2 hr before', 'Free until 24 hr before', 'Free until 48 hr before', 'No refund'];
const _buffers = ['None', '5 min', '10 min', '15 min', '30 min'];
const _confirm = ['Auto-confirm', "I'll confirm"];
final _people = [for (var i = 1; i <= 50; i++) '$i'];

class ServiceFormScreen extends StatefulWidget {
  const ServiceFormScreen(
      {super.key, required this.api, this.detail, this.listing, this.template, this.category, this.business = '', this.photos = const DeviceItemPhotos(), this.addMedia});

  /// Picks and uploads one banner photo ([video] false) or video; null when nothing was picked. Tests replace it.
  final Future<({String url, String kind})?> Function({required bool video})? addMedia;

  /// The category picked in "What are you adding?" (events, activities, play, service, stay).
  final String? category;
  final ServiceApi api;
  final ServiceDetail? detail;
  final Map<String, dynamic>? listing;

  /// A template to start from (from the Templates tab's "Use for a new service").
  final ServiceTemplate? template;
  final String business;
  final ItemPhotoService photos;
  @override
  State<ServiceFormScreen> createState() => _ServiceFormScreenState();
}

class _ServiceFormScreenState extends State<ServiceFormScreen> {
  late final Map<String, Object?> v = _start();
  int _step = 0; // the step shown
  // the category is fixed once known (founder, 4 Nov 2026: "if I selected an event form ... it should be established"); only a service saved
  // before the categories, or a template without one, picks it here, once
  late final bool _catGiven = (widget.listing?['category'] ?? widget.category ?? widget.template?.category) != null;
  bool _catPicked = false;
  bool get _catFixed => _catGiven || _catPicked;
  ListingProfile get _p => listingProfile(_cat, v['subcategory'] as String?);

  /// A new subcategory starts from its own defaults: how it is booked, what is booked, where, and how it is priced.
  void _applyProfile() {
    // its own defaults, not the last subcategory's (a museum is ticketed, plumbing is on call): found by the end-to-end test, 4 Nov 2026
    final p = _p;
    v['booking_type'] = p.bookingType;
    v['unit_kind'] = p.unitKind;
    v['where'] = p.whereDefault ?? 'At your place';
    v['pricing'] = p.pricingDefault;
    v['booked_for'] = p.bookedFor;
  }
  bool _uploading = false, _coverGone = false; // _coverGone: the saved cover photo was taken off
  final _ctl = <String, TextEditingController>{};
  NeedsOptions _options = const NeedsOptions();
  List<String> _branches = const [];
  ItemPhoto? _photo;
  bool _busy = false;
  final _key = ServiceApi.newKey(), _listingKey = ServiceApi.newKey();

  Map<String, Object?> _start() {
    final d = widget.detail;
    final l = widget.listing ?? const {};
    final sub = l['subcategory'] ?? d?.so('category');
    // a service saved before the categories (its old category, e.g. Repairs) is a Service, or Events when it is booked by entry
    final cat = (l['category'] ?? widget.category ?? categoryOfSubcategory(sub as String?) ?? (d == null ? null : d.fulfilment == 'event' ? 'events' : 'service')) as String?;
    final p = listingProfile(cat, sub);
    final s = <String, Object?>{
      'category': cat,
      'booking_type': p.bookingType,
      if (p.unitKind != null) 'unit_kind': p.unitKind,
      'booked_for': p.bookedFor,
      'book_up_to': '30 days ahead',
      'min_notice': d == null || d.i('min_notice_min') == 0 ? 'None' : lengthLabel(d.i('min_notice_min')),
      'rule_order': kRuleOrder.first,
      'amenities': <String>[],
      'duration': d == null ? '1 hr' : lengthLabel(d.i('duration_min')),
      'buffer': d == null || d.i('buffer_min') == 0 ? 'None' : '${d.i('buffer_min')} min',
      'people_min': '1',
      'people_max': d == null ? '1' : '${d.i('capacity')}',
      'where': d?.fulfilment == 'on_location' ? 'On call' : p.whereDefault ?? 'At your place',
      'confirm': 'Auto-confirm',
      'pricing': p.pricingDefault,
      'advance': 'None',
      'cancellation': 'Free until 2 hr before',
      'requirements': <Map<String, dynamic>>[],
      'rules': <Map<String, dynamic>>[],
      if (d != null) ...{'name': d.name, 'description': d.so('description') ?? '', 'price': d.price == 0 ? null : '${d.price}'},
      ...l,
      'subcategory': sub,
    };
    s['requirements'] = [for (final r in (s['requirements'] as List? ?? const [])) Map<String, dynamic>.from(r as Map)];
    s['rules'] = [for (final r in (s['rules'] as List? ?? const [])) Map<String, dynamic>.from(r as Map)];
    for (final k in ['types', 'parts', 'addons', 'units', 'bands']) {
      s[k] = [for (final r in (s[k] as List? ?? const [])) Map<String, dynamic>.from(r as Map)];
    }
    s['amenities'] = [for (final a in (s['amenities'] as List? ?? const [])) '$a'];
    s['sub_group'] ??= groupOfSubcategory(s['category'] as String?, s['subcategory'] as String?);
    if (widget.template != null) _applyTo(s, widget.template!);
    return s;
  }

  /// A template fills what the service needs, its rules, length, category and notes (the name and price stay the publisher's).
  void _applyTo(Map<String, Object?> s, ServiceTemplate t) {
    s['template_id'] = t.id;
    s['template_name'] = t.name;
    s['requirements'] = [for (final r in t.requirements) {...r}];
    s['rules'] = [for (final r in t.rules) {...r}];
    if (t.durationMin != null) s['duration'] = lengthLabel(t.durationMin!);
    if (t.category != null) s['category'] = t.category;
    if (t.subcategory != null) {
      s['subcategory'] = t.subcategory;
      s['sub_group'] = groupOfSubcategory(s['category'] as String?, t.subcategory);
    }
    if (t.notes.isNotEmpty && '${s['notes'] ?? ''}'.isEmpty) s['notes'] = t.notes;
    if ('${s['name'] ?? ''}'.isEmpty) s['name'] = t.name;
  }

  @override
  void initState() {
    super.initState();
    CustomOptions.load();
    widget.api.listingView().then((o) {
      if (mounted) {
        setState(() {
          _options = NeedsOptions.of(o);
          _branches = [for (final b in o.branches) b.s('name')].where((n) => n.isNotEmpty).toList();
        });
      }
    }).catchError((_) {});
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _text(String key) => _ctl.putIfAbsent(key, () => TextEditingController(text: v[key] == null ? '' : '${v[key]}'));
  void _set(String key, Object? value) => setState(() => v[key] = value);
  List<Map<String, dynamic>> get _needs => v['requirements'] as List<Map<String, dynamic>>;
  List<Map<String, dynamic>> get _rules => v['rules'] as List<Map<String, dynamic>>;

  // ---------------------------------------------------------------------------------------------------------------- steps
  void _go(int i) {
    if (i < 0 || i >= kServiceSteps.length || i == _step) return;
    FocusScope.of(context).unfocus();
    setState(() => _step = i);
  }

  String? get _savedCover => _coverGone ? null : widget.detail?.so('image_url');
  bool get _hasCover => _photo != null || _savedCover != null;

  /// "+ Add": a photo (the first one is the cover customers see on the list; the rest are banners), a video, or the camera.
  Future<void> _add(String what) async {
    try {
      if (what == 'video') return await _addMedia(video: true);
      if (!_hasCover) {
        final p = what == 'camera' ? await widget.photos.capture(context) : await widget.photos.pick();
        if (p != null && mounted) setState(() => _photo = p);
        return;
      }
      if (what == 'camera') {
        final p = await widget.photos.capture(context);
        if (p == null || !mounted) return;
        return await _addMedia(video: false, shot: PickedDocument(name: 'camera.${p.contentType == 'image/png' ? 'png' : 'jpg'}', bytes: p.bytes, contentType: p.contentType));
      }
      return await _addMedia(video: false);
    } on ItemPhotoUnavailable catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  /// A banner photo or video: picked (or [shot] with the camera), uploaded, then kept in the listing's media list.
  Future<void> _addMedia({required bool video, PickedDocument? shot}) async {
    setState(() => _uploading = true);
    try {
      final got = shot != null && widget.addMedia == null
          ? await widget.api.uploadMedia(shot)
          : await (widget.addMedia ??
              ({required bool video}) async {
                final d = await pickServiceMedia(video: video);
                return d == null ? null : await widget.api.uploadMedia(d);
              })(video: video);
      if (got != null && mounted) {
        setState(() => v['media'] = [..._media, {'kind': got.kind, 'url': got.url}]);
      }
    } on ItemPhotoUnavailable catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (e) {
      if (mounted) showServiceError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  List<Map<String, dynamic>> get _media => [for (final m in (v['media'] as List? ?? const [])) Map<String, dynamic>.from(m as Map)];

  // ---------------------------------------------------------------------------------------------------------------- save
  num? _price() {
    if (v['pricing'] == 'No charge to book') return 0;
    final base = num.tryParse('${v['price'] ?? ''}'.replaceAll(',', '').trim());
    if (base != null || v['pricing'] != 'By type') return base;
    return [for (final t in _rows('types')) if (t['price'] is num) t['price'] as num].firstOrNull;
  }

  List<Map<String, dynamic>> _rows(String key) => v[key] as List<Map<String, dynamic>>? ?? [];
  String get _cat => v['category'] as String? ?? '';
  bool _in(List<String> cats) => cats.contains(_cat);

  /// "Save as a template" (founder, 4 Nov 2026: at the end of the form, before publishing): what this service needs, its rules, length,
  /// category and notes, saved under a name to pick next time. The form stays open, so the service can still be published.
  Future<void> _saveAsTemplate() async {
    final name = await askText(context, 'Save as a template', initial: '${v['template_name'] ?? v['name'] ?? ''}'.trim(), hint: 'Template name, e.g. ${_eg.name}',
        action: 'Save template');
    if (name == null || !mounted) return;
    if (name.trim().length < 2) return showToast(context, 'Name the template.');
    try {
      final d = await widget.api.saveTemplate({
        'name': name.trim(),
        'category': v['category'],
        'subcategory': v['subcategory'],
        'duration_min': listingMinutes(v['duration'] as String?).clamp(5, 600),
        'requirements': _needs,
        'rules': _rules,
        'notes': '${v['notes'] ?? ''}'.trim(),
      }, key: ServiceApi.newKey());
      if (!mounted) return;
      setState(() {
        final t = d.saved;
        if (t != null) {
          v['template_id'] = t.id;
          v['template_name'] = t.name;
        }
      });
      showToast(context, 'Saved as template "${name.trim()}". Pick it next time from Add from existing templates.');
    } catch (e) {
      if (mounted) showServiceError(context, e);
    }
  }

  Future<void> _save({required bool publish}) async {
    final name = '${v['name'] ?? ''}'.trim();
    final price = _price();
    // a missing detail takes the person back to its step
    if (name.length < 2) {
      _go(0);
      return showToast(context, 'Enter the service name.');
    }
    if (v['category'] == null || v['subcategory'] == null) {
      _go(0);
      return showToast(context, 'Choose the category and subcategory.');
    }
    if (price == null || price < 0) {
      _go(3);
      return showToast(context, 'Enter the price.');
    }
    setState(() => _busy = true);
    final d = widget.detail;
    try {
      final saved = await widget.api.saveService({
        // editing keeps what this form does not show (notice, grace, code, checklist ...), then puts the form's answers over it
        if (d != null) ...serviceFields(d),
        'name': name,
        'price': price,
        'category': '${v['subcategory']}',
        'kind': 'service',
        'fulfilment': v['category'] == 'events' || v['booking_type'] == 'Entry' ? 'event' : v['where'] == 'On call' ? 'on_location' : 'appointment',
        'duration_min': listingMinutes(v['duration'] as String?).clamp(5, 600),
        'buffer_min': listingMinutes(v['buffer'] as String?).clamp(0, 120),
        'capacity': (switch (v['booking_type']) {
              'Entry' => int.tryParse('${v['capacity'] ?? ''}'),
              'Nights' => (int.tryParse('${v['adults'] ?? ''}') ?? 2) + (int.tryParse('${v['children'] ?? ''}') ?? 0),
              _ => int.tryParse('${v['people_max']}'),
            } ??
            1)
            .clamp(1, 500),
        'min_notice_min': listingMinutes(v['min_notice'] as String?).clamp(0, 10080),
        if (v['late_grace'] != null) 'grace_min': listingMinutes(v['late_grace'] as String?).clamp(0, 120),
        'staff_required': needsSummary(_needs.where((r) => r['type'] == 'person').toList()),
        'description': '${v['description'] ?? ''}'.trim(),
        'is_bookable': publish,
      }, key: _key);
      await widget.api.saveListing(saved.id, '${v['category']}', {
        for (final e in v.entries)
          e.key: e.value,
        ...usesOf(_needs),
        'status': publish ? 'live' : 'draft',
      }, key: _listingKey);
      try {
        if (_photo != null) {
          await widget.photos.attach(saved.id, _photo!);
        } else if (_coverGone) {
          await widget.photos.remove(saved.id);
        }
      } on ItemPhotoUnavailable catch (e) {
        if (mounted) showToast(context, e.message);
      }
      if (!mounted) return;
      showToast(context, publish ? '$name is live.' : '$name is saved as a draft.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showServiceError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------------------------------------------------- build
  /// A dropdown for [key]. [show] turns the kept value into its label and [keep] a picked label into the value kept (the category keeps
  /// its key, shows its name).
  Widget _pick(String key, String label, List<String> options,
          {List<(String, List<String>)>? groups,
          String hint = 'Choose',
          String? Function(String?)? show,
          String Function(String)? keep,
          bool canAdd = true,
          String? addKey,
          OwnInput input = OwnInput.text}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        fieldLabel(label),
        PickBox(
          fieldKey: ValueKey('sf-$key'),
          value: show == null ? v[key] as String? : show(v[key] as String?),
          hint: hint,
          onTap: options.isEmpty && !canAdd
              ? null
              : () async {
                  final p = await pickOne(context, label, options,
                      current: show == null ? v[key] as String? : show(v[key] as String?), groups: groups, canAdd: canAdd, addKey: addKey, input: input);
                  if (p == null) return;
                  setState(() {
                    v[key] = keep == null ? p : keep(p);
                    if (key == 'subcategory') _applyProfile();
                    if (key == 'sub_group') v['subcategory'] = null; // a new type: pick its subcategory again
                  });
                },
        ),
      ]);

  Widget _input(String key, String label, {String hint = '', bool money = false, int lines = 1}) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        fieldLabel(label),
        TextField(
          key: ValueKey('sf-$key'),
          controller: _text(key),
          minLines: lines,
          maxLines: lines,
          keyboardType: money ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
          inputFormatters: money ? numberOnly(const TextInputType.numberWithOptions(decimal: true)) : null,
          style: inter(14, 500),
          decoration: formBox(hint: hint.isEmpty ? null : hint, prefix: money ? '₹ ' : null),
          onChanged: (s) => setState(() => v[key] = s),
        ),
      ]);

  @override
  Widget build(BuildContext context) => StepFormPage(
        title: [widget.detail == null ? 'New listing' : 'Edit listing', if (listingCategory(v['category'] as String?) case final c?) c.name].join(' · '),
        steps: [for (final st in kServiceSteps) st.$1],
        step: _step,
        onStep: _go,
        lastLine: 'Last step: save or publish',
        body: _stepBody(),
        // the end of the form, with Save draft and Publish: keep this setup as a template (founder, 4 Nov 2026)
        finish: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          OutlinedButton.icon(
            key: const ValueKey('sf-save-template'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              side: const BorderSide(color: kGreenText, width: 1.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              backgroundColor: Colors.white,
            ),
            onPressed: _busy ? null : _saveAsTemplate,
            icon: const Icon(LucideIcons.bookmarkPlus, size: 18, color: kGreenText),
            label: Text('Save as a template', style: inter(15, 700, color: kGreenText)),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: LightCta(key: const ValueKey('sf-draft'), label: 'Save draft', onPressed: _busy ? null : () => _save(publish: false))),
            const SizedBox(width: 10),
            Expanded(child: DarkCta(key: const ValueKey('sf-publish'), label: 'Publish', busy: _busy, onPressed: _busy ? null : () => _save(publish: true))),
          ]),
        ]),
      );

  /// This form's examples, for its category and subcategory.
  ListingExamples get _eg => listingExamples(_cat, v['subcategory'] as String?);

  List<Widget> _stepBody() {
    final cat = listingCategory(v['category'] as String?);
    final eg = _eg;
    final (title, icon, line) = kServiceSteps[_step];
    Widget card(Widget child) => FormCard(title: title, line: line, icon: icon, child: child);
    final type = v['booking_type'] as String? ?? 'Slot';
    final units = '${v['unit_kind'] ?? 'unit'}'.toLowerCase();
    final p = _p;
    final unitsOn = p.unitKinds.isNotEmpty;
    final playLike = unitsOn;
    return switch (_step) {
      // 1 Basics
      0 => [
          _hero(),
          if (v['template_name'] != null) _fromTemplate(),
          if (!_catFixed || cat == null) _categoryFirst() else _categoryLine(cat),
          card(FieldGrid(children: [
            (false, _input('name', _cat == 'stay' ? 'Room type' : _cat == 'events' ? 'Event name' : _cat == 'activities' ? 'Activity name' : 'Service name', hint: 'e.g. ${eg.name}')),
            if (cat != null && cat.subcategories.length > 1)
              (true, _pick('sub_group', cat.key == 'service' ? 'Type of service' : 'Type', [for (final (g, _) in cat.subcategories) g], canAdd: false)),
            (true, _subcategoryPick(cat)),
            (false, _input('description', 'Description', hint: 'e.g. ${eg.description}')),
            if (_hasCover || _media.isNotEmpty || _uploading) (false, _mediaField()),
            // amenities on every category (founder, 4 Nov 2026: "add to all")
            (false, Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                fieldLabel('Amenities'),
                MultiChips(keyPrefix: 'sf-amenity', options: _p.amenities, selected: [for (final a in v['amenities'] as List) '$a'], addTitle: 'Add an amenity', onChanged: (x) => _set('amenities', x)),
              ])),
          ])),
        ],
      // 2 How it is booked
      1 => [
          card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FieldGrid(children: [
              (true, _pick('booking_type', 'Booking type', p.bookingTypes, canAdd: false)),
              if (unitsOn) ...[
                (true, _pick('unit_kind', 'What customers book', p.unitKinds)),
                (true, _pick('unit_count', 'How many ${units}s you have', _people, input: OwnInput.count)),
              ],
              if (type == 'Slot') ...[
                (true, _pick('duration', playLike ? 'Slot length' : 'Duration', kLengths, input: OwnInput.length)),
                (true, _pick('buffer', playLike ? 'Cleanup between' : 'Buffer after', _buffers, input: OwnInput.length)),
                if (playLike) ...[
                  (true, _pick('start_every', 'Start times', _startEvery, input: OwnInput.minutes)),
                  (true, _pick('shortest', 'Shortest booking', _spans, input: OwnInput.length)),
                  (true, _pick('longest', 'Longest booking', _spans, input: OwnInput.length)),
                  (true, _pick('length_step', 'Length changes in steps of', _steps, input: OwnInput.length)),
                ],
                if (_cat == 'activities') (true, _pick('available', 'Available', _available)),
              ],
              if (type == 'Entry') ...[
                (true, _pick('entry_valid', 'Entry valid for', _entryValid)),
                (true, _dateBox('event_date', 'Date')),
                (true, _pick('starts_at', 'Starts at', _times, canAdd: false)),
                (true, _pick('repeats', 'Repeats', _repeats)),
              ],
              if (type == 'Nights') ...[
                (true, _pick('check_in', 'Check-in', _times, canAdd: false)),
                (true, _pick('check_out', 'Check-out', _times, canAdd: false)),
                (true, _pick('min_stay', 'Minimum stay', _nights, input: OwnInput.nights)),
              ],
              (true, _pick('book_up_to', 'Book up to', _bookAhead, input: OwnInput.days)),
              (true, _pick('min_notice', 'Minimum notice', _notice, input: OwnInput.length)),
              if (_cat == 'play') ...[
                (true, _pick('late_grace', 'Late arrival grace', _grace, input: OwnInput.length)),
                (true, _pick('no_show', 'If no one arrives', _noShow)),
              ],
            ]),
            if (playLike) ...[
              const SizedBox(height: 4),
              fieldLabel('Your ${units}s · each shows as its own card when customers pick a time'),
              RowsEditor(
                keyPrefix: 'sf-unit',
                rows: _rows('units'),
                addLabel: 'Add $units',
                columns: [
                  // no price per court: price lives on the Price step only (founder, 4 Nov 2026)
                  RowColumn('name', 'Name', hint: 'e.g. ${'${v['unit_kind'] ?? 'Unit'}'} 1', flex: 3),
                  RowColumn('setting', 'Setting', kind: 'pick', options: p.settings),
                  if (p.surfaces.isNotEmpty) RowColumn('surface', 'Surface', kind: 'pick', options: p.surfaces),
                  if (_cat == 'play') const RowColumn('grade', 'Grade', kind: 'pick', options: _grades),
                ],
                onChanged: (r) => _set('units', r),
              ),
              fieldLabel('Time bands shown to customers (optional)'),
              RowsEditor(
                keyPrefix: 'sf-band',
                rows: _rows('bands'),
                addLabel: 'Add band',
                starter: const {'name': 'Morning', 'from': '5:00 am', 'to': '12:00 pm'},
                columns: [
                  const RowColumn('name', 'Band', flex: 3),
                  RowColumn('from', 'From', kind: 'pick', options: _times, input: null),
                  RowColumn('to', 'To', kind: 'pick', options: _times, input: null),
                ],
                onChanged: (r) => _set('bands', r),
              ),
            ],
            if (p.parts)
              switchRow(
                  key: const ValueKey('sf-part-bookings'),
                  label: 'Allow part bookings',
                  line: 'Book the full $units or a named part of it (North half, Court A).',
                  value: v['part_bookings'] == true,
                  onChanged: (x) => _set('part_bookings', x)),
            if (_cat == 'play')
              switchRow(
                  key: const ValueKey('sf-mark-arrived'),
                  label: 'Mark players as arrived',
                  line: 'A quick tap at the gate, for no-shows.',
                  value: v['mark_arrived'] == true,
                  onChanged: (x) => _set('mark_arrived', x)),
          ])),
        ],
      // 3 Where and who
      2 => [
          card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FieldGrid(children: [
              if (p.where.isNotEmpty) (true, _pick('where', 'Where', p.where)),
              if (_branches.isNotEmpty && v['where'] != 'On call') (true, _pick('branch', _cat == 'events' ? 'Venue' : 'Branch', _branches)),
              if (p.where.isNotEmpty && v['where'] != 'At your place') ...[
                (true, _pick('oncall_area', 'On-call area', _onCallArea, input: OwnInput.km)),
                (true, _pick('travel_charge', 'Travel charge', _travel)),
                if (v['travel_charge'] == 'Fixed' || v['travel_charge'] == 'Per km') (true, _input('travel_amount', v['travel_charge'] == 'Per km' ? 'Per km' : 'Travel charge', money: true)),
              ],
              (true, _pick('booked_for', 'Booked for', _bookedFor)),
              if (type == 'Nights') ...[
                (true, _pick('adults', 'Adults, up to', _people, input: OwnInput.count)),
                (true, _pick('children', 'Children, up to', ['0', ..._people], input: OwnInput.count)),
                (true, _pick('guest_id', 'Guest ID', _guestId)),
              ] else if (type == 'Entry') ...[
                (true, _pick('capacity', 'Capacity', [for (var i = 10; i <= 500; i += 10) '$i'], input: OwnInput.count)),
                (true, _pick('max_per_booking', 'Max per booking', _people, input: OwnInput.count)),
              ] else ...[
                (true, _pick('people_min', playLike ? 'Players per $units, from' : 'People, from', _people, input: OwnInput.count)),
                (true, _pick('people_max', playLike ? 'Players per $units, up to' : 'People, up to', _people, input: OwnInput.count)),
              ],
              if (p.age) (true, _pick('age_rule', 'Age rule', _ageRules)),
              if (p.gender) (true, _pick('gender_rule', 'Gender rule', _genderRules)),
              if (p.safety) (true, _pick('safety_rule', 'Height or safety rule', _safety)),
            ]),
            if (_cat == 'activities')
              switchRow(
                  key: const ValueKey('sf-safety-terms'),
                  label: 'Customer accepts safety terms',
                  line: 'Shown before payment.',
                  value: v['safety_terms'] == true,
                  onChanged: (x) => _set('safety_terms', x)),
            if (_cat == 'service')
              switchRow(
                  key: const ValueKey('sf-ask-staff'),
                  label: 'Customer can ask for a staff member',
                  line: 'By name or gender.',
                  value: v['ask_staff'] == true,
                  onChanged: (x) => _set('ask_staff', x)),
          ])),
        ],
      // 4 Price
      3 => [
          card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FieldGrid(children: [
              (true, _pick('pricing', 'Pricing basis', p.pricing)),
              if (v['pricing'] != 'No charge to book')
                // with rules on, this is still needed: whoever no rule matches pays it (founder asked, 4 Nov 2026)
                (true, _input('price', v['rules_on'] == true || _rules.isNotEmpty ? 'Price for everyone else' : switch (v['pricing']) { 'Per person' => 'Price per person', 'Per night' => _cat == 'stay' ? 'Weekday price' : 'Price per night', 'By type' => 'Base price', 'Per hour' => 'Price per hour', 'Per slot' => 'Price per slot', _ => 'Price' }, money: true)),
              if (_cat == 'stay') ...[
                (true, _input('weekend_price', 'Weekend price', money: true)),
                (true, _input('extra_guest', 'Extra guest per night', money: true)),
              ],
            ]),
            if (v['pricing'] == 'By type') ...[
              fieldLabel('Types and prices'),
              RowsEditor(
                keyPrefix: 'sf-type',
                rows: _rows('types'),
                addLabel: 'Add type',
                columns: [
                  RowColumn('name', 'Type', hint: 'e.g. ${eg.type}', flex: 4),
                  const RowColumn('price', 'Price', kind: 'money'),
                  RowColumn('length', 'Time', kind: 'pick', options: kLengths, input: OwnInput.length),
                ],
                onChanged: (r) => _set('types', r),
              ),
            ],
            if (p.parts && v['part_bookings'] == true) ...[
              fieldLabel('Parts and prices · booking the full $units blocks every part'),
              RowsEditor(
                keyPrefix: 'sf-part',
                rows: _rows('parts'),
                addLabel: 'Add part',
                columns: const [RowColumn('name', 'Part', hint: 'e.g. North half', flex: 4), RowColumn('price', 'Price', kind: 'money')],
                onChanged: (r) => _set('parts', r),
              ),
            ],
            // the exceptions to the base price, folded away until needed
            switchRow(
                key: const ValueKey('sf-rules-on'),
                label: 'Different prices or limits for some people',
                line: 'By gender, age, group, number of people, day ... Everyone else pays the base price.',
                value: v['rules_on'] == true || _rules.isNotEmpty,
                onChanged: (x) => setState(() {
                      v['rules_on'] = x;
                      if (!x) v['rules'] = <Map<String, dynamic>>[];
                    })),
            if (v['rules_on'] == true || _rules.isNotEmpty) ...[
              RulesEditor(rows: _rules, keyPrefix: 'sf-rule', onChanged: (r) => _set('rules', r)),
              if (_rules.length > 1) FieldGrid(children: [(false, _pick('rule_order', 'When more than one rule fits', kRuleOrder, canAdd: false))]),
            ],
            FieldGrid(children: [
              (true, _pick('gst', 'GST rate', _gst, input: OwnInput.percent)),
              (true, _pick('advance', 'Advance', _cat == 'stay' ? [..._advance, 'First night'] : _advance)),
              if (v['advance'] == 'Fixed amount' || v['advance'] == '% of price')
                (true, _input('advance_amount', v['advance'] == '% of price' ? 'Advance %' : 'Advance amount', money: v['advance'] != '% of price')),
              (true, _pick('cancellation', 'Cancellation', _cancel, input: OwnInput.hours)),
            ]),
            if (_cat != 'stay') ...[
              switchRow(key: const ValueKey('sf-peak'), label: 'Peak price', line: 'Evenings, weekends and holidays.', value: v['peak'] == true, onChanged: (x) => _set('peak', x)),
              if (v['peak'] == true) FieldGrid(children: [(true, _input('peak_price', 'Peak price', money: true))]),
            ],
            if (_in(['service', 'activities', 'play'])) ...[
              fieldLabel('Add-ons (optional)'),
              RowsEditor(
                keyPrefix: 'sf-addon',
                rows: _rows('addons'),
                addLabel: 'Add add-on',
                columns: [
                  RowColumn('name', 'Add-on', hint: 'e.g. ${eg.addon}', flex: 4),
                  const RowColumn('price', 'Price', kind: 'money'),
                  RowColumn('length', 'Extra time', kind: 'pick', options: ['None', ...kLengths], input: OwnInput.length),
                ],
                onChanged: (r) => _set('addons', r),
              ),
            ],
          ])),
        ],
      // 5 What it uses: the recipe of people, places, tools and materials
      4 => [
          card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            NeedsEditor(rows: _needs, options: _options, keyPrefix: 'sf-need', onChanged: (r) => _set('requirements', r)),
            needsTotal(_needs, _rules, key: const ValueKey('sf-total')),
            if (_cat == 'stay')
              FieldGrid(children: [
                (true, _pick('after_checkout', 'Staff after checkout', ['Not needed', for (final (_, n, _) in _options.itemsFor('person')) n])),
              ]),
          ])),
        ],
      // 6 Notes and confirm
      _ => [
          card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _input('notes', 'Notes', hint: 'e.g. ${eg.notes} (optional)', lines: 3),
            const SizedBox(height: 10),
            FieldGrid(children: [(true, _pick('confirm', 'Confirm bookings', _confirm))]),
          ])),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Text('"Save as a template" keeps what it needs, its rules and length under a name, to fill this form next time. It does not publish.',
                textAlign: TextAlign.center, style: inter(12, 400, color: kMuted)),
          ),
        ],
    };
  }

  /// No category yet (a template without one): the five categories first; the form's own fields follow the one picked.
  Widget _categoryFirst() => Container(
        key: const ValueKey('sf-category-first'),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: kGreenText, width: 1.5)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(v['category'] == null ? 'What are you listing?' : 'Check what this is', style: inter(15, 800)),
          Text(
              v['category'] == null
                  ? 'Each one has its own form: Stay asks for check-in, Play for courts and parts, Events for dates.'
                  : 'Saved before the categories. Tap the right one; the form is then fixed to it.',
              style: inter(12, 400, color: kMuted)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in listingCategories)
              ActionChip(
                key: ValueKey('sf-cat-${c.key}'),
                avatar: Icon(c.icon, size: 16, color: kGreenText),
                label: Text(c.name, style: inter(13, 700)),
                backgroundColor: v['category'] == c.key ? kChipGreen : Colors.white,
                side: BorderSide(color: v['category'] == c.key ? kGreenText : kLine),
                onPressed: () => setState(() {
                  if (v['category'] != c.key) {
                    v['subcategory'] = null;
                    v['sub_group'] = null;
                  }
                  v['category'] = c.key;
                  _catPicked = true;
                  _applyProfile();
                }),
              ),
          ]),
        ]),
      );

  /// What this category's form is for, under the bar ("Play · court, turf or table by the hour").
  Widget _categoryLine(ListingCategory c) => Padding(
        key: const ValueKey('sf-category-line'),
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: kChipGreen, borderRadius: BorderRadius.circular(999)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(c.icon, size: 14, color: kGreenText), const SizedBox(width: 6), Text(c.name, style: inter(12.5, 700, color: kGreenText))]),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text('Books: ${c.books[0].toLowerCase()}${c.books.substring(1)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12.5, 500, color: kMuted))),
        ]),
      );

  /// A date for an event: the calendar opens in the middle of the screen; kept as 2026-11-15, shown as "Sat, 15 Nov".
  Widget _dateBox(String key, String label) {
    final at = DateTime.tryParse('${v[key] ?? ''}');
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      fieldLabel(label),
      PickBox(
        fieldKey: ValueKey('sf-$key'),
        value: at == null ? null : '${days[at.weekday - 1]}, ${at.day} ${months[at.month - 1]}',
        hint: 'Pick a date',
        onTap: () async {
          PickBox.takeAnchor();
          final now = DateTime.now();
          final p = await showDatePicker(context: context, initialDate: at ?? now, firstDate: DateTime(now.year, now.month, now.day), lastDate: DateTime(now.year + 2));
          if (p != null) _set(key, '${p.year}-${p.month.toString().padLeft(2, '0')}-${p.day.toString().padLeft(2, '0')}');
        },
      ),
    ]);
  }

  /// Photos and videos in one compact row (founder, 4 Nov 2026): the cover first (shown on the list), then the banner photos and videos
  /// (shown at the top of the service), then a small dashed Add tile whose menu opens right on it: Photo, Video or Camera.
  Widget _mediaField() {
    final media = _media;
    const w = 92.0, h = 72.0;
    Widget remove(String key, VoidCallback onTap) => Positioned(
          right: -6,
          top: -6,
          child: InkWell(
            key: ValueKey(key),
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: kLine)),
              child: const Icon(LucideIcons.x, size: 13, color: kInk),
            ),
          ),
        );
    Widget tile(Key key, Widget child, {String? tag}) => Container(
          key: key,
          width: w,
          height: h,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(color: kInk, borderRadius: BorderRadius.circular(12), border: Border.all(color: kFieldBorder)),
          child: Stack(fit: StackFit.expand, children: [
            child,
            if (tag != null)
              Positioned(
                left: 5,
                bottom: 5,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xCC111827), borderRadius: BorderRadius.circular(6)),
                  child: Text(tag, style: inter(10, 700, color: Colors.white)),
                ),
              ),
          ]),
        );
    final cover = _photo != null
        ? Image.memory(_photo!.bytes, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.image, color: Colors.white))
        : _savedCover != null
            ? Image.network(_savedCover!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.image, color: Colors.white))
            : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      fieldLabel('Photos and videos'),
      SizedBox(
        height: h + 8,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.only(top: 6, right: 6), clipBehavior: Clip.none, children: [
          if (cover != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Stack(clipBehavior: Clip.none, children: [
                tile(const ValueKey('sf-cover'), cover, tag: 'Cover'),
                remove('sf-cover-remove', () => setState(() {
                      if (_photo != null) {
                        _photo = null;
                      } else {
                        _coverGone = true;
                      }
                    })),
              ]),
            ),
          for (final (i, m) in media.indexed)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Stack(clipBehavior: Clip.none, children: [
                tile(
                  ValueKey('sf-media-$i'),
                  m['kind'] == 'video'
                      ? const Icon(LucideIcons.circlePlay, color: Colors.white, size: 26)
                      : Image.network('${m['url']}', fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.image, color: Colors.white)),
                  tag: m['kind'] == 'video' ? 'Video' : null,
                ),
                remove('sf-media-remove-$i', () => setState(() => v['media'] = [...media]..removeAt(i))),
              ]),
            ),
          if (_uploading)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Container(
                width: w,
                height: h,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(12), border: Border.all(color: kFieldBorder)),
                child: const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kGreenText)),
              ),
            ),
          _addMenu(
            child: CustomPaint(
              painter: const _DashedBox(),
              child: SizedBox(
                width: w,
                height: h,
                child: FittedBox(fit: BoxFit.scaleDown, child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(LucideIcons.camera, size: 20, color: kInk),
                  const SizedBox(height: 3),
                  Text('Add', style: inter(12.5, 700)),
                  Text('jpg · png · mp4', style: inter(10, 400, color: kMuted)),
                ])),
              ),
            ),
          ),
        ]),
      ),
    ]);
  }

  /// "+ Add": Cover photo (the first) or Photo, Video, Camera, in a small menu on what was tapped.
  Widget _addMenu({required Widget child}) => PopupMenuButton<String>(
        key: const ValueKey('sf-media-add'),
        enabled: !_uploading,
        tooltip: 'Add a photo or video',
        position: PopupMenuPosition.under,
        color: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: kLine)),
        onSelected: _add,
        itemBuilder: (_) => [
          for (final (k, label, icon) in [
            ('photo', _hasCover ? 'Photo' : 'Cover photo', LucideIcons.image),
            ('video', 'Video', LucideIcons.video),
            ('camera', 'Camera', LucideIcons.camera),
          ])
            PopupMenuItem<String>(
              key: ValueKey('sf-media-$k'),
              value: k,
              height: 40,
              child: Row(children: [Icon(icon, size: 17, color: kInk), const SizedBox(width: 10), Text(label, style: inter(14, 500))]),
            ),
        ],
        child: child,
      );

  int _heroPage = 0;

  /// The banner on top, as customers will see the listing (founder, 4 Nov 2026: "the image displayed on the top, like the customer app"):
  /// empty, a big dashed box to add photos and videos; with some, they fill the width, swiped through with dots, the cover tagged.
  Widget _hero() {
    final pages = <Widget>[
      if (_photo != null) Image.memory(_photo!.bytes, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.image, color: Colors.white))
      else if (_savedCover != null) Image.network(_savedCover!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.image, color: Colors.white)),
      for (final m in _media)
        m['kind'] == 'video'
            ? const Center(child: Icon(LucideIcons.circlePlay, color: Colors.white, size: 44))
            : Image.network('${m['url']}', fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.image, color: Colors.white)),
    ];
    const h = 200.0;
    if (pages.isEmpty && !_uploading) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _addMenu(
          child: CustomPaint(
            key: const ValueKey('sf-hero'),
            painter: const _DashedBox(),
            child: SizedBox(
              height: h,
              width: double.infinity,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(color: Color(0xFF111827), shape: BoxShape.circle),
                  child: const Icon(LucideIcons.camera, color: kLime, size: 24),
                ),
                const SizedBox(height: 10),
                Text('Add photos and videos', style: inter(15, 700)),
                const SizedBox(height: 2),
                Text('Shown at the top of your listing, like this · jpg, png, mp4', style: inter(12, 400, color: kMuted)),
              ]),
            ),
          ),
        ),
      );
    }
    final at = _heroPage.clamp(0, pages.isEmpty ? 0 : pages.length - 1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ClipRRect(
        key: const ValueKey('sf-hero'),
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: h,
          color: kInk,
          child: Stack(fit: StackFit.expand, children: [
            if (pages.isEmpty)
              const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: kLime)))
            else
              PageView(onPageChanged: (i) => setState(() => _heroPage = i), children: pages),
            if (_hasCover && at == 0)
              Positioned(
                left: 12,
                top: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: const Color(0xCC111827), borderRadius: BorderRadius.circular(8)),
                  child: Text('Cover', style: inter(11, 700, color: Colors.white)),
                ),
              ),
            if (pages.length > 1)
              Positioned(
                left: 0,
                right: 0,
                bottom: 10,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  for (var i = 0; i < pages.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == at ? 10 : 6,
                      height: i == at ? 10 : 6,
                      decoration: BoxDecoration(color: i == at ? Colors.white : const Color(0x99FFFFFF), shape: BoxShape.circle),
                    ),
                ]),
              ),
          ]),
        ),
      ),
    );
  }

  /// Only the subcategories of the type picked (a category with one type lists them all); the type comes first.
  Widget _subcategoryPick(ListingCategory? cat) {
    final typed = cat != null && cat.subcategories.length > 1;
    final group = v['sub_group'] as String?;
    final options = cat == null ? const <String>[] : typed ? [for (final (g, n) in cat.subcategories) if (g == group) ...n] : cat.allSubcategories;
    return _pick('subcategory', 'Subcategory', options,
        hint: cat == null ? 'Pick a category first' : typed && group == null ? 'Pick the type first' : 'Choose',
        canAdd: cat != null && (!typed || group != null),
        addKey: 'Subcategory:${cat?.key}${typed ? ':$group' : ''}');
  }

  /// Where this form's details came from, when it was opened from a template (picked in Add service's list, not here).
  Widget _fromTemplate() => Padding(
        key: const ValueKey('sf-from-template'),
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
        child: Row(children: [
          const Icon(LucideIcons.clipboardList, size: 15, color: kGreenText),
          const SizedBox(width: 6),
          Expanded(child: Text('From template: ${v['template_name']}', style: inter(12.5, 600, color: kGreenText))),
        ]),
      );
}

/// The dashed outline of the Add tile.
class _DashedBox extends CustomPainter {
  const _DashedBox();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)), Paint()..color = kField);
    final path = Path()..addRRect(RRect.fromRectAndRadius((Offset.zero & size).deflate(0.75), const Radius.circular(12)));
    final dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..color = const Color(0xFF9AA3A0);
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 8) {
        canvas.drawPath(m.extractPath(d, math.min(d + 4.5, m.length)), dash);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBox old) => false;
}
