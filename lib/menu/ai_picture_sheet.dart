import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../catalogue/item_photo.dart';
import '../ui/theme.dart';
import 'menu_api.dart';
import 'menu_build_widgets.dart' show kMbLime;

/// "AI picture" on a dish (founder, 27 Oct 2026): the dish's photo made clean by AI, two ways.
///   * With background: the dish cut out and set on a soft cream studio backdrop (a JPG; looks the same in every app).
///   * Without background: the dish cut out on transparency (a PNG; for listings that draw their own background).
/// The photo goes through the server to remove.bg (`cat_image_remove_bg`; the key stays on the server). Nothing changes until
/// "Use this picture", which saves it as the dish's photo the same way as uploading one. Answers true when the photo was replaced.
Future<bool> showAiPictureSheet(BuildContext context, MenuDish dish, ItemPhotoService photos) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _AiPictureSheet(dish: dish, photos: photos),
    ) ??
    false;

/// The studio backdrop for "With background": a warm cream that sits well with food and with the app's own cards.
const aiBackdropHex = 'f6efe2';

class _AiPictureSheet extends StatefulWidget {
  const _AiPictureSheet({required this.dish, required this.photos});
  final MenuDish dish;
  final ItemPhotoService photos;
  @override
  State<_AiPictureSheet> createState() => _AiPictureSheetState();
}

class _AiPictureSheetState extends State<_AiPictureSheet> {
  ItemPhoto? _source; // the photo the AI works on: the dish's own, or one chosen here
  ItemPhoto? _result;
  bool? _withBackground; // which version [_result] is
  String? _busy; // 'with' | 'without' | 'save' | 'pick'
  String? _error;

  Future<ItemPhoto?> _sourcePhoto() async {
    if (_source != null) return _source;
    final url = widget.dish.imageUrl;
    if (url == null) return null;
    return _source = await widget.photos.load(url);
  }

  Future<void> _make(bool withBackground) async {
    setState(() {
      _busy = withBackground ? 'with' : 'without';
      _error = null;
    });
    try {
      final src = await _sourcePhoto();
      if (src == null) {
        setState(() => _error = 'This dish has no photo yet. Choose one first.');
      } else {
        final out = await widget.photos.removeBackground(src, bgColor: withBackground ? aiBackdropHex : null);
        if (mounted) {
          setState(() {
            _result = out;
            _withBackground = withBackground;
          });
        }
      }
    } on ItemPhotoUnavailable catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'The AI picture could not be made. Try again.');
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

  @override
  Widget build(BuildContext context) {
    final d = widget.dish;
    final r = _result;
    final hasPhoto = _source != null || d.imageUrl != null;
    Widget preview() {
      const radius = BorderRadius.all(Radius.circular(18));
      if (r != null) {
        return Container(
          key: const ValueKey('ai-result'),
          height: 240,
          decoration: BoxDecoration(
            // transparency shows on a light grey, so the cut-out's edges can be judged
            color: _withBackground == true ? null : const Color(0xFFEDEEEA),
            borderRadius: radius,
            border: Border.all(color: kLine),
          ),
          clipBehavior: Clip.antiAlias,
          child: Image.memory(r.bytes, fit: BoxFit.contain),
        );
      }
      final src = _source;
      return Container(
        height: 200,
        decoration: BoxDecoration(color: const Color(0xFFF1F1EC), borderRadius: radius, border: Border.all(color: kLine)),
        clipBehavior: Clip.antiAlias,
        child: src != null
            ? Image.memory(src.bytes, fit: BoxFit.cover)
            : d.imageUrl != null
                ? Image.network(d.imageUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.utensils, color: kMuted, size: 40))
                : const Icon(LucideIcons.utensils, color: kMuted, size: 40),
      );
    }

    Widget choice(bool withBg) {
      final busy = _busy == (withBg ? 'with' : 'without');
      final chosen = r != null && _withBackground == withBg;
      return Expanded(
        child: OutlinedButton(
          key: ValueKey(withBg ? 'ai-with-bg' : 'ai-without-bg'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(64),
            backgroundColor: chosen ? kNote : Colors.white,
            side: BorderSide(color: chosen ? kMbLime : kLine, width: chosen ? 2 : 1),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          onPressed: _busy != null || !hasPhoto ? null : () => _make(withBg),
          child: busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kInk))
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(withBg ? LucideIcons.image : LucideIcons.scissors, size: 20, color: kInk),
                  const SizedBox(height: 4),
                  Text(withBg ? 'With background' : 'Without background', textAlign: TextAlign.center, style: inter(13.5, 700)),
                ]),
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
              Expanded(child: Text('AI picture · ${d.name}', style: inter(19, 700))),
            ]),
            const SizedBox(height: 4),
            Text(
              r == null
                  ? 'AI cuts the dish out of its photo. Keep a clean studio background, or none for listings that add their own.'
                  : _withBackground == true
                      ? 'On a clean studio background. Use it, or try without a background.'
                      : 'Background removed (shown on grey). Use it, or try with a background.',
              style: inter(13.5, 400, color: kMuted),
            ),
            const SizedBox(height: 12),
            preview(),
            const SizedBox(height: 12),
            Row(children: [choice(true), const SizedBox(width: 10), choice(false)]),
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
            if (r != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 52,
                child: FilledButton(
                  key: const ValueKey('ai-use'),
                  style: FilledButton.styleFrom(backgroundColor: kInk, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  onPressed: _busy != null ? null : _use,
                  child: _busy == 'save'
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text('Use this picture', style: inter(15.5, 700, color: kMbLime)),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
