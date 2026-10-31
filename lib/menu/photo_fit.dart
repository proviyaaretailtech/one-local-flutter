import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// The two standard dish photo sizes (founder, 31 Oct 2026): 4:5 portrait, 1080 × 1350, or square, 1080 × 1080.
enum PhotoSize {
  portrait(1080, 1350, '4:5'),
  square(1080, 1080, 'Square');

  const PhotoSize(this.width, this.height, this.label);
  final int width, height;
  final String label;
}

/// What sits behind the dish: its own background (cropped to fill the frame), a cream studio backdrop, or nothing (transparent PNG).
enum Backdrop { keep, studio, none }

/// The studio backdrop: a warm cream that sits well with food and the app's own cards.
const studioCream = 0xF6EFE2;

/// A finished photo: the bytes and their type (JPG, or PNG when it is transparent).
class FittedPhoto {
  const FittedPhoto(this.bytes, this.contentType);
  final Uint8List bytes;
  final String contentType;
}

/// Makes a dish photo the standard size: [source] is the original (keep) or the dish cut out on transparency (studio / none).
/// [enhance] first gives it an automatic fix: levels stretched to a full range, a little more contrast and colour, a light sharpen.
/// A kept background is cropped from the middle to fill the frame; a cut-out dish is centred with a margin, never cut off.
/// Pure Dart (package:image), so it runs on the phone and in tests; run it in a background isolate for big photos.
FittedPhoto fitPhoto(Uint8List source, {required PhotoSize size, required Backdrop backdrop, bool enhance = true}) {
  final decoded = img.decodeImage(source);
  if (decoded == null) throw const FormatException('This photo could not be read.');
  var photo = decoded.convert(numChannels: 4);
  if (enhance) photo = enhancePhoto(photo);

  final w = size.width, h = size.height;
  final img.Image out;
  if (backdrop == Backdrop.keep) {
    // fill the frame: scale so the shorter side fits, then crop the middle
    final scale = (w / photo.width) > (h / photo.height) ? w / photo.width : h / photo.height;
    final sw = (photo.width * scale).round(), sh = (photo.height * scale).round();
    final scaled = img.copyResize(photo, width: sw, height: sh, interpolation: img.Interpolation.cubic);
    out = img.copyCrop(scaled, x: ((sw - w) / 2).round(), y: ((sh - h) / 2).round(), width: w, height: h);
  } else {
    // the cut-out dish, trimmed to its own edges, centred inside 88 % of the frame
    final dish = img.trim(photo, mode: img.TrimMode.transparent);
    final box = 0.88;
    final scale = ((w * box) / dish.width) < ((h * box) / dish.height) ? (w * box) / dish.width : (h * box) / dish.height;
    final dw = (dish.width * scale).round().clamp(1, w), dh = (dish.height * scale).round().clamp(1, h);
    final scaled = img.copyResize(dish, width: dw, height: dh, interpolation: img.Interpolation.cubic);
    out = img.Image(width: w, height: h, numChannels: 4);
    if (backdrop == Backdrop.studio) {
      img.fill(out, color: img.ColorRgba8((studioCream >> 16) & 0xFF, (studioCream >> 8) & 0xFF, studioCream & 0xFF, 255));
    }
    img.compositeImage(out, scaled, dstX: ((w - dw) / 2).round(), dstY: ((h - dh) / 2).round());
  }
  if (backdrop == Backdrop.none) return FittedPhoto(Uint8List.fromList(img.encodePng(out)), 'image/png');
  return FittedPhoto(Uint8List.fromList(img.encodeJpg(out.convert(numChannels: 3), quality: 90)), 'image/jpeg');
}

/// The automatic fix: the photo's brightness levels opened up (its darkest and brightest 0.5 % moved towards black and white, by at most
/// ×1.5, the same for red, green and blue so the colours stay true), then contrast ×1.05, colour ×1.10 and a light sharpen.
/// Transparent pixels are left alone.
img.Image enhancePhoto(img.Image photo) {
  final hist = List<int>.filled(256, 0);
  var counted = 0;
  for (final p in photo) {
    if (p.a < 16) continue;
    hist[(0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255)]++;
    counted++;
  }
  if (counted == 0) return photo;
  final cut = (counted * 0.005).floor();
  var lo = 0, hi = 255, seen = 0;
  for (var i = 0; i < 256; i++) {
    seen += hist[i];
    if (seen > cut) {
      lo = i;
      break;
    }
  }
  seen = 0;
  for (var i = 255; i >= 0; i--) {
    seen += hist[i];
    if (seen > cut) {
      hi = i;
      break;
    }
  }
  // one gain for all three colours, never more than ×1.5, centred on the photo's own middle
  if (hi - lo >= 20) {
    final gain = (255 / (hi - lo)).clamp(1.0, 1.5);
    final mid = (lo + hi) / 2;
    int level(num v) => (127.5 + (v - mid) * gain).round().clamp(0, 255);
    for (final p in photo) {
      if (p.a < 16) continue;
      p
        ..r = level(p.r)
        ..g = level(p.g)
        ..b = level(p.b);
    }
  }
  img.adjustColor(photo, contrast: 1.05, saturation: 1.10);
  return img.convolution(photo, filter: const [0, -1, 0, -1, 5, -1, 0, -1, 0], amount: 0.3);
}
