import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../catalogue/item_photo.dart';
import '../ui/theme.dart';
import 'menu_api.dart';
import 'menu_build_widgets.dart' show kMbLime;
import 'photo_fit.dart';

/// "AI enhancer" on a dish (founder, 27 and 31 Oct 2026): the dish's photo made ready for the menu.
///   * Enhance: an automatic fix on the phone (levels, contrast, colour, a light sharpen).
///   * Background: keep the photo's own, put the dish on a cream studio backdrop, or remove it (a transparent PNG for listings that
///     draw their own). Cutting the dish out goes through the server to remove.bg (`cat_image_remove_bg`; the key stays on the server).
///   * Size: the standard 4:5 (1080 × 1350) or square (1080 × 1080). A kept background is cropped to fill; a cut-out dish is centred.
/// Nothing changes until "Use this picture", which saves it as the dish's photo the same way as uploading one. Answers true when saved.
Future<bool> showAiPictureSheet(BuildContext context, MenuDish dish, ItemPhotoService photos) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _AiPictureSheet(dish: dish, photos: photos),
    ) ??
    false;

/// Where the photo is worked: a background isolate in the app (a big photo takes a moment); tests run it in place.
Future<FittedPhoto> Function(Uint8List bytes, PhotoSize size, Backdrop backdrop, bool enhance) fitPhotoAsync =
    (bytes, size, backdrop, enhance) => compute(_fit, (bytes, size, backdrop, enhance));

FittedPhoto _fit((Uint8List, PhotoSize, Backdrop, bool) a) => fitPhoto(a.$1, size: a.$2, backdrop: a.$3, enhance: a.$4);

class _AiPictureSheet extends StatefulWidget {
  const _AiPictureSheet({required this.dish, required this.photos});
  final MenuDish dish;
  final ItemPhotoService photos;
  @override
  State<_AiPictureSheet> createState() => _AiPictureSheetState();
}

class _AiPictureSheetState extends State<_AiPictureSheet> {
  ItemPhoto? _source; // the photo to work on: the dish's own, or one chosen here
  ItemPhoto? _cutOut; // the dish cut out of [_source], kept so switching Studio / Remove does not ask the server again
  ItemPhoto? _result;
  Backdrop _backdrop = Backdrop.studio;
  PhotoSize _size = PhotoSize.portrait;
  bool _enhance = true;
  String? _busy; // 'make' | 'save' | 'pick'
  String? _error;

  Future<ItemPhoto?> _sourcePhoto() async {
    if (_source != null) return _source;
    final url = widget.dish.imageUrl;
    if (url == null) return null;
    return _source = await widget.photos.load(url);
  }

  Future<void> _make() async {
    setState(() {
      _busy = 'make';
      _error = null;
    });
    try {
      final src = await _sourcePhoto();
      if (src == null) {
        setState(() => _error = 'This dish has no photo yet. Choose one first.');
      } else {
        var work = src;
        if (_backdrop != Backdrop.keep) work = _cutOut ??= await widget.photos.removeBackground(src);
        final out = await fitPhotoAsync(work.bytes, _size, _backdrop, _enhance);
        if (mounted) setState(() => _result = ItemPhoto(bytes: out.bytes, contentType: out.contentType, backgroundRemoved: _backdrop != Backdrop.keep));
      }
    } on ItemPhotoUnavailable catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'The picture could not be made. Try again.');
    }
    if (mounted) setState(() => _busy = null);
  }

  Future<void> _pick() async {
    setState(() {
      _busy = 'pick';
      _error = null;
    });
    try {
      final p = await widget.photos.pick();
      if (p != null && mounted) {
        setState(() {
          _source = p;
          _cutOut = null;
          _result = null;
        });
      }
    } on ItemPhotoUnavailable catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    if (mounted) setState(() => _busy = null);
  }

  Future<void> _use() async {
    final r = _result;
    if (r == null) return;
    setState(() {
      _busy = 'save';
      _error = null;
    });
    try {
      await widget.photos.attach(widget.dish.id, r);
      if (mounted) Navigator.of(context).pop(true);
      return;
    } on ItemPhotoUnavailable catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'The picture could not be saved. Try again.');
    }
    if (mounted) setState(() => _busy = null);
  }

  /// A new choice makes the shown result out of date: it goes, and Make picture makes it again.
  void _choose(VoidCallback change) => setState(() {
        change();
        _result = null;
      });

  Widget _pills<T>(String label, List<(T, String, String, IconData)> options, T value, ValueChanged<T> onPick) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: inter(12.5, 700, color: kMuted)),
          const SizedBox(height: 6),
          Row(children: [
            for (final (i, (v, key, text, icon)) in options.indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  key: ValueKey(key),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    backgroundColor: v == value ? kNote : Colors.white,
                    side: BorderSide(color: v == value ? kMbLime : kLine, width: v == value ? 2 : 1),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _busy != null ? null : () => onPick(v),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, size: 16, color: kInk),
                    const SizedBox(width: 6),
                    Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13, 700))),
                  ]),
                ),
              ),
            ],
          ]),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final d = widget.dish;
    final r = _result;
    final hasPhoto = _source != null || d.imageUrl != null;
    Widget preview() {
      const radius = BorderRadius.all(Radius.circular(18));
      final src = _source;
      return Center(
        child: SizedBox(
          height: 260,
          child: AspectRatio(
            aspectRatio: _size.width / _size.height,
            child: Container(
              key: ValueKey(r != null ? 'ai-result' : 'ai-source'),
              decoration: BoxDecoration(
                // transparency shows on a light grey, so the cut-out's edges can be judged
                color: r != null && _backdrop == Backdrop.none ? const Color(0xFFEDEEEA) : const Color(0xFFF1F1EC),
                borderRadius: radius,
                border: Border.all(color: kLine),
              ),
              clipBehavior: Clip.antiAlias,
              child: r != null
                  ? Image.memory(r.bytes, fit: BoxFit.contain)
                  : src != null
                      ? Image.memory(src.bytes, fit: BoxFit.cover)
                      : d.imageUrl != null
                          ? Image.network(d.imageUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.utensils, color: kMuted, size: 40))
                          : const Icon(LucideIcons.utensils, color: kMuted, size: 40),
            ),
          ),
        ),
      );
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(4)))),
            const SizedBox(height: 12),
            Row(children: [
              const Icon(LucideIcons.sparkles, size: 20, color: kInk),
              const SizedBox(width: 8),
              Expanded(child: Text('AI enhancer · ${d.name}', style: inter(19, 700))),
            ]),
            const SizedBox(height: 4),
            Text(
              r == null
                  ? 'Enhance the photo, choose its background and fit it to the standard size.'
                  : '${_size.label} · ${_size.width} × ${_size.height}${_enhance ? ' · enhanced' : ''}. Use it, or change a choice and make it again.',
              key: const ValueKey('ai-note'),
              style: inter(13.5, 400, color: kMuted),
            ),
            const SizedBox(height: 12),
            preview(),
            const SizedBox(height: 14),
            _pills<Backdrop>('BACKGROUND', const [
              (Backdrop.keep, 'ai-bg-keep', 'Keep', LucideIcons.image),
              (Backdrop.studio, 'ai-bg-studio', 'Studio', LucideIcons.sparkles),
              (Backdrop.none, 'ai-bg-none', 'Remove', LucideIcons.scissors),
            ], _backdrop, (v) => _choose(() => _backdrop = v)),
            const SizedBox(height: 12),
            _pills<PhotoSize>('SIZE', const [
              (PhotoSize.portrait, 'ai-size-portrait', '4:5 · 1080×1350', LucideIcons.rectangleVertical),
              (PhotoSize.square, 'ai-size-square', 'Square · 1080×1080', LucideIcons.square),
            ], _size, (v) => _choose(() => _size = v)),
            const SizedBox(height: 4),
            SwitchListTile(
              key: const ValueKey('ai-enhance'),
              contentPadding: EdgeInsets.zero,
              activeThumbColor: kInk,
              activeTrackColor: kMbLime,
              title: Text('Enhance', style: inter(15, 700)),
              subtitle: Text('Brighter, clearer colours and a little sharper', style: inter(12.5, 400, color: kMuted)),
              value: _enhance,
              onChanged: _busy != null ? null : (v) => _choose(() => _enhance = v),
            ),
            if (!hasPhoto || r == null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('ai-pick'),
                  onPressed: _busy != null ? null : _pick,
                  icon: const Icon(LucideIcons.upload, size: 16),
                  label: Text(hasPhoto ? 'Use a different photo' : 'Choose a photo', style: inter(14, 600)),
                ),
              ),
            if (_error != null)
              Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, key: const ValueKey('ai-error'), style: inter(14, 500, color: kError))),
            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: r == null
                  ? FilledButton.icon(
                      key: const ValueKey('ai-make'),
                      style: FilledButton.styleFrom(backgroundColor: kInk, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                      onPressed: _busy != null || !hasPhoto ? null : _make,
                      icon: _busy == 'make'
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(LucideIcons.wandSparkles, size: 18, color: kMbLime),
                      label: Text('Make picture', style: inter(15.5, 700, color: kMbLime)),
                    )
                  : FilledButton(
                      key: const ValueKey('ai-use'),
                      style: FilledButton.styleFrom(backgroundColor: kInk, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                      onPressed: _busy != null ? null : _use,
                      child: _busy == 'save'
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Text('Use this picture', style: inter(15.5, 700, color: kMbLime)),
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}
