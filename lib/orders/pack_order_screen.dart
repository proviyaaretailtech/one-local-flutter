import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../catalogue/photo_capture_screen.dart' show findCameras;
import '../onboarding/document_picker.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'order_widgets.dart';
import 'orders_api.dart';
import '../ui/motion.dart';

/// Packing an order in one place (founder, 29 Oct 2026: "the current way is a bit confusing"; returns spec §6): tick each item as it goes
/// in the bag, take a photo of the packed bag (or say why there is none), then "Mark packed". Answers the updated order, or null.
class PackOrderScreen extends StatefulWidget {
  const PackOrderScreen({super.key, required this.api, required this.order});
  final OrdersApi api;
  final OrderView order;
  @override
  State<PackOrderScreen> createState() => _PackOrderScreenState();
}

class _PackOrderScreenState extends State<PackOrderScreen> {
  late OrderView _v = widget.order;
  late final Set<String> _ticked = {
    for (final i in widget.order.items)
      if (_max(i) > 0 && (i['picked_qty'] ?? 0) == _max(i)) '${i['order_item_id']}',
  };
  PickedDocument? _photo;
  String? _skip;
  bool _busy = false;
  String? _error;

  static int _max(Map<String, dynamic> i) => (i['qty'] as int) - ((i['missing_qty'] ?? 0) as int);

  /// Lines with something to pack (a line reported fully missing has nothing).
  List<Map<String, dynamic>> get _lines => [for (final i in _v.items) if (_max(i) > 0) i];
  bool get _allTicked => _lines.every((i) => _ticked.contains('${i['order_item_id']}'));
  bool get _hadPhoto => _v.packedPhoto != null;
  bool get _photoDone => !_v.photoRequired || _photo != null || _skip != null || _hadPhoto;

  Future<void> _takePhoto() async {
    final p = await takePackedPhoto(context);
    if (p == null || !mounted) return;
    if (p.bytes.length > 5 * 1024 * 1024) {
      showToast(context, 'That photo is over 5 MB. Take it again.');
      return;
    }
    setState(() {
      _photo = p;
      _skip = null;
    });
  }

  Future<void> _noPhoto() async {
    final c = TextEditingController();
    String? pick;
    final reason = await showOrderSheet<String>(
      context,
      title: tr('No photo?'),
      body: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('The photo protects you if a customer says something was missing. Say why there is none.'), style: inter(13, 400, color: kMuted, height: 1.4)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final r in const ['Camera not working', 'No camera on this device', 'Customer is waiting'])
              ChoiceChip(
                key: ValueKey('pack-skip-$r'),
                label: Text(tr(r)),
                selected: pick == r,
                selectedColor: kLime,
                onSelected: (_) => set(() {
                  pick = r;
                  c.text = r;
                }),
              ),
          ]),
          const SizedBox(height: 10),
          TextField(key: const ValueKey('pack-skip-text'), controller: c, maxLength: 200, decoration: InputDecoration(hintText: tr('Or write the reason'))),
          const SizedBox(height: 8),
          DarkCta(key: const ValueKey('pack-skip-save'), label: tr('Continue without photo'), onPressed: () => Navigator.pop(ctx, c.text.trim())),
        ]),
      ),
    );
    if (reason == null || !mounted) return;
    if (reason.length < 3) {
      showToast(context, 'Say why there is no photo.');
      return;
    }
    setState(() {
      _skip = reason;
      _photo = null;
    });
  }

  Future<void> _packed() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = widget.api;
    try {
      // 1. the photo (or why there is none) goes first: the server will not mark it packed without it
      if (_photo != null) {
        await api.savePackedPhoto(_v.id, _photo!);
        _photo = null; // saved; a retry does not upload it again
      } else if (_skip != null) {
        await api.skipPackedPhoto(_v.id, _skip!);
        _skip = null;
      }
      // 2. the items: a store order records what was packed; a OneLocal order just moves on
      if (_v.online) {
        _v = await api.act(_v.id, 'online_ready', version: _v.version);
      } else {
        if (_v.stage == 'preparing') {
          _v = await api.act(_v.id, 'pick', version: _v.version, lines: [for (final i in _v.items) {'order_item_id': i['order_item_id'], 'qty': _max(i)}]);
        }
        _v = await api.act(_v.id, 'pack', version: _v.version);
      }
      if (mounted) Navigator.of(context).pop(_v);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is OrdersApiException ? e.message : 'Could not save. Check your connection and try again.';
      });
      // a version clash: reload the order and let them tap again
      try {
        final fresh = await api.get(_v.id);
        if (mounted) setState(() => _v = fresh);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    final ready = _allTicked && _photoDone && lines.isNotEmpty;
    final left = lines.length - lines.where((i) => _ticked.contains('${i['order_item_id']}')).length;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        OrdersTopBar(title: 'Pack ${_v.displayNo}', onBack: () {
          if (!_busy) Navigator.maybePop(context);
        }),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(12, 14, 12, 20), children: [
            _StepTitle(n: 1, title: tr('Put each item in the bag'), done: _allTicked, trailing: '${lines.length - left} of ${lines.length}'),
            const SizedBox(height: 8),
            OrderCardBox(
              child: Column(children: [
                for (final i in lines) _itemRow(i),
                if (lines.length > 1)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      key: const ValueKey('pack-tick-all'),
                      onPressed: () => setState(() => _allTicked ? _ticked.clear() : _ticked.addAll([for (final i in lines) '${i['order_item_id']}'])),
                      child: Text(_allTicked ? tr('Untick all') : tr('Tick all'), style: inter(13, 700, color: kGreenText)),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 18),
            _StepTitle(n: 2, title: tr('Photo of the packed bag'), done: _photoDone && (_photo != null || _skip != null || _hadPhoto), optional: !_v.photoRequired),
            const SizedBox(height: 8),
            _photoBox(),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: kBadBg, borderRadius: BorderRadius.circular(12)),
                child: Text(_error!, key: const ValueKey('pack-error'), style: inter(13, 500, color: kBadText)),
              ),
            ],
          ]),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: kLine))),
          child: SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (!ready)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    !_allTicked ? (left == 1 ? tr('1 item still to tick') : '$left items still to tick') : tr('Take a photo of the packed bag'),
                    key: const ValueKey('pack-hint'),
                    textAlign: TextAlign.center,
                    style: inter(12.5, 500, color: kMuted),
                  ),
                ),
              DarkCta(key: const ValueKey('pack-done'), label: tr('Mark packed'), busy: _busy, onPressed: ready && !_busy ? _packed : null),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _itemRow(Map<String, dynamic> i) {
    final id = '${i['order_item_id']}';
    final on = _ticked.contains(id);
    final missing = (i['missing_qty'] ?? 0) as int;
    return InkWell(
      key: ValueKey('pack-item-$id'),
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => on ? _ticked.remove(id) : _ticked.add(id)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
        child: Row(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: on ? kLime : Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: on ? kGreenText : kLine, width: 1.5),
            ),
            child: on ? const Icon(LucideIcons.check, size: 17, color: kInk) : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${i['name']}', style: inter(14.5, 600, color: on ? kMuted : kInk).copyWith(decoration: on ? TextDecoration.lineThrough : null)),
              if (missing > 0) Text('$missing missing', style: inter(12, 500, color: kWarnText)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: kChipGreen, borderRadius: BorderRadius.circular(999)),
            child: Text('${_max(i)}×', style: inter(13, 800, color: kGreenText)),
          ),
        ]),
      ),
    );
  }

  Widget _photoBox() {
    final photo = _photo;
    if (photo != null) {
      return OrderCardBox(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(aspectRatio: 4 / 3, child: Image.memory(photo.bytes, key: const ValueKey('pack-photo-preview'), fit: BoxFit.cover)),
          ),
          const SizedBox(height: 8),
          Row(children: [
            const Icon(LucideIcons.circleCheck, size: 18, color: kGreenText),
            const SizedBox(width: 6),
            Expanded(child: Text(tr('Photo ready. It is saved with the order.'), style: inter(13, 600, color: kGreenText))),
            TextButton.icon(
              key: const ValueKey('pack-retake'),
              onPressed: _busy ? null : _takePhoto,
              icon: const Icon(LucideIcons.refreshCw, size: 15, color: kInk),
              label: Text(tr('Retake'), style: inter(13, 700)),
            ),
          ]),
        ]),
      );
    }
    final skip = _skip ?? (_v.packedPhoto?['skip_reason'] as String?);
    final had = _hadPhoto && _v.packedPhoto?['has_photo'] == true && _skip == null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: const ValueKey('pack-photo'),
          borderRadius: BorderRadius.circular(16),
          onTap: _busy ? null : _takePhoto,
          child: Container(
            height: 150,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: had ? kGreenText : const Color(0xFFCBD5C0), width: 1.5),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(color: kLime, shape: BoxShape.circle),
                child: Icon(had ? LucideIcons.circleCheck : LucideIcons.camera, size: 24, color: kInk),
              ),
              const SizedBox(height: 10),
              Text(had ? tr('Photo already taken · tap to retake') : tr('Take photo of the packed bag'), style: inter(14.5, 700)),
              const SizedBox(height: 2),
              Text(tr('Show the bag and what is inside'), style: inter(12, 400, color: kMuted)),
            ]),
          ),
        ),
      ),
      if (skip != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            const Icon(LucideIcons.info, size: 16, color: kWarnText),
            const SizedBox(width: 6),
            Expanded(child: Text('No photo: $skip', key: const ValueKey('pack-skip-note'), style: inter(12.5, 600, color: kWarnText))),
          ]),
        )
      else if (_v.photoRequired && !had)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('pack-no-photo'),
            onPressed: _busy ? null : _noPhoto,
            child: Text(tr('Can’t take a photo?'), style: inter(13, 600, color: kMuted).copyWith(decoration: TextDecoration.underline)),
          ),
        ),
    ]);
  }
}

class _StepTitle extends StatelessWidget {
  const _StepTitle({required this.n, required this.title, required this.done, this.trailing, this.optional = false});
  final int n;
  final String title;
  final bool done, optional;
  final String? trailing;
  @override
  Widget build(BuildContext context) => Row(children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: done ? kGreenText : kDark, shape: BoxShape.circle),
          child: done ? const Icon(LucideIcons.check, size: 14, color: Colors.white) : Text('$n', style: inter(12, 800, color: Colors.white)),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(title, style: inter(15.5, 700))),
        if (optional) Text(tr('optional'), style: inter(12, 500, color: kMuted)),
        if (trailing != null) Text(trailing!, style: inter(12.5, 600, color: kMuted)),
      ]);
}

/// Where the order is: Accept · Pack · Hand over · Done, the current step highlighted.
class OrderSteps extends StatelessWidget {
  const OrderSteps({super.key, required this.labels, required this.current});
  final List<String> labels;
  final int current;
  @override
  Widget build(BuildContext context) => OrderCardBox(
        child: Row(children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0) Expanded(child: Container(height: 2, margin: const EdgeInsets.only(bottom: 18), color: i <= current ? kGreenText : kLine)),
            Column(key: ValueKey('order-step-$i'), mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: i < current ? kGreenText : (i == current ? kLime : Colors.white),
                  shape: BoxShape.circle,
                  border: Border.all(color: i < current ? kGreenText : (i == current ? kInk : kLine), width: i == current ? 2 : 1.5),
                ),
                child: i < current ? const Icon(LucideIcons.check, size: 15, color: Colors.white) : Text('${i + 1}', style: inter(12, 800, color: i == current ? kInk : kMuted)),
              ),
              const SizedBox(height: 4),
              Text(tr(labels[i]), style: inter(11.5, i == current ? 800 : 500, color: i <= current ? kInk : kMuted)),
            ]),
          ],
        ]),
      );
}

/// The photo of the packed bag on the order: a thumbnail that opens full size, or why there is none.
class PackedPhotoCard extends StatefulWidget {
  const PackedPhotoCard({super.key, required this.api, required this.order});
  final OrdersApi api;
  final OrderView order;
  @override
  State<PackedPhotoCard> createState() => _PackedPhotoCardState();
}

class _PackedPhotoCardState extends State<PackedPhotoCard> {
  Future<String>? _url;

  @override
  void initState() {
    super.initState();
    if (widget.order.packedPhoto?['has_photo'] == true) _url = widget.api.packedPhotoLink(widget.order.id);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.order.packedPhoto;
    if (p == null) return const SizedBox.shrink();
    final at = DateTime.tryParse('${p['at']}')?.toLocal();
    final when = at == null ? '' : ' · ${at.hour % 12 == 0 ? 12 : at.hour % 12}:${at.minute.toString().padLeft(2, '0')} ${at.hour < 12 ? 'AM' : 'PM'}';
    return OrderCardBox(
      child: Row(children: [
        if (_url != null)
          FutureBuilder<String>(
            future: _url,
            builder: (ctx, s) => InkWell(
              key: const ValueKey('packed-photo-open'),
              onTap: s.hasData ? () => _open(s.data!) : null,
              borderRadius: BorderRadius.circular(10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 64,
                  height: 64,
                  color: kChipGreen,
                  child: s.hasData
                      ? Image.network(s.data!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.image, color: kGreenText))
                      : const Icon(LucideIcons.image, color: kGreenText),
                ),
              ),
            ),
          )
        else
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: kWarnBg, borderRadius: BorderRadius.circular(10)),
            child: const Icon(LucideIcons.cameraOff, size: 20, color: kWarnText),
          ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Kick('Packed bag'),
            const SizedBox(height: 3),
            Text(
              _url != null ? '${tr('Photo taken')}$when' : 'No photo: ${p['skip_reason'] ?? ''}',
              key: const ValueKey('packed-photo-line'),
              style: inter(13.5, 600, color: _url != null ? kInk : kWarnText),
            ),
            if (_url != null) Text(tr('Tap to see it full size'), style: inter(12, 400, color: kMuted)),
          ]),
        ),
      ]),
    );
  }

  void _open(String url) => showOlDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          insetPadding: const EdgeInsets.all(16),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Stack(children: [
            InteractiveViewer(child: Image.network(url, fit: BoxFit.contain)),
            Positioned(
              right: 8,
              top: 8,
              child: IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: Colors.white),
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(LucideIcons.x, color: kInk),
              ),
            ),
          ]),
        ),
      );
}

/// Takes the photo of the packed bag: the in-app camera (so it is a fresh photo, not an old one from the gallery); where there is no
/// camera (a desktop browser) a photo file. Null when closed. Tests replace it.
Future<PickedDocument?> Function(BuildContext context) takePackedPhoto = (context) async {
  List<CameraDescription> cams = const [];
  try {
    cams = await findCameras();
  } catch (_) {}
  if (cams.isNotEmpty && context.mounted) {
    return Navigator.of(context).push<PickedDocument>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _PackedCamera(cameras: cams)));
  }
  final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp']);
  if (f == null) return null;
  final ext = f.name.split('.').last.toLowerCase();
  return PickedDocument(name: f.name, bytes: await f.readAsBytes(), contentType: ext == 'png' ? 'image/png' : ext == 'webp' ? 'image/webp' : 'image/jpeg');
};

/// A plain camera: the preview and one shutter button.
class _PackedCamera extends StatefulWidget {
  const _PackedCamera({required this.cameras});
  final List<CameraDescription> cameras;
  @override
  State<_PackedCamera> createState() => _PackedCameraState();
}

class _PackedCameraState extends State<_PackedCamera> {
  CameraController? _c;
  String? _problem;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final back = widget.cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => widget.cameras.first);
    // medium keeps the photo well under the 5 MB limit
    final c = CameraController(back, ResolutionPreset.medium, enableAudio: false);
    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _c = c);
    } catch (_) {
      await c.dispose();
      if (mounted) setState(() => _problem = 'The camera could not start. Allow camera access, or go back and choose “Can’t take a photo?”.');
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  Future<void> _shoot() async {
    final c = _c;
    if (c == null || _busy) return;
    setState(() => _busy = true);
    try {
      final shot = await c.takePicture();
      final bytes = await shot.readAsBytes();
      if (mounted) Navigator.of(context).pop(PickedDocument(name: 'packed.jpg', bytes: bytes, contentType: 'image/jpeg'));
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(children: [
          Positioned.fill(
            child: c != null
                ? Center(child: CameraPreview(c))
                : Center(
                    child: _problem == null
                        ? const CircularProgressIndicator(color: kLime)
                        : Padding(padding: const EdgeInsets.all(24), child: Text(tr(_problem!), textAlign: TextAlign.center, style: inter(14, 500, color: Colors.white))),
                  ),
          ),
          Positioned(
            left: 8,
            top: 8,
            child: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(LucideIcons.x, color: Colors.white, size: 26)),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 16,
            child: Text(tr('Photo of the packed bag'), textAlign: TextAlign.center, style: inter(15, 700, color: Colors.white)),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 28,
            child: Center(
              child: GestureDetector(
                onTap: _shoot,
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
                  padding: const EdgeInsets.all(5),
                  child: Container(decoration: BoxDecoration(color: _busy ? Colors.white54 : kLime, shape: BoxShape.circle)),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
