import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../core/api_client.dart';
import '../core/models.dart';
import 'theme.dart';

/// Renders the reference design's map pins: the employee's photo in a circle,
/// ringed in the status colour, with a pointed tail.
class MarkerFactory {
  MarkerFactory(this.api);

  final ApiClient api;
  final Map<String, BitmapDescriptor> _cache = {};
  final Map<String, ui.Image?> _photos = {};

  static const _logicalSize = 56.0;

  Future<BitmapDescriptor> forEmployee(Employee e, double devicePixelRatio) async {
    final key = '${e.id}:${e.photoVersion}:${e.status.wire}:${e.hasPhoto}';
    final cached = _cache[key];
    if (cached != null) return cached;
    final photo = e.hasPhoto ? await _photo(e) : null;
    final bitmap = await _draw(e, photo, devicePixelRatio);
    _cache[key] = bitmap;
    return bitmap;
  }

  Future<ui.Image?> _photo(Employee e) async {
    final key = '${e.id}:${e.photoVersion}';
    if (_photos.containsKey(key)) return _photos[key];
    try {
      final res = await http
          .get(Uri.parse(api.photoUrl(e.id, e.photoVersion)), headers: api.imageHeaders)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return _photos[key] = null;
      final codec = await ui.instantiateImageCodec(res.bodyBytes, targetWidth: 160);
      return _photos[key] = (await codec.getNextFrame()).image;
    } catch (_) {
      return null; // retried next time the marker is built
    }
  }

  Future<BitmapDescriptor> _draw(Employee e, ui.Image? photo, double dpr) async {
    final scale = dpr.clamp(1.0, 4.0);
    final w = _logicalSize * scale;
    final h = w * 1.25;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final ring = AppColors.status(e.status);
    final c = Offset(w / 2, w / 2);
    final r = w / 2 - 2 * scale;

    // Shadow + tail.
    final tail = Path()
      ..moveTo(w / 2 - r * 0.45, w / 2 + r * 0.75)
      ..lineTo(w / 2, h - 2 * scale)
      ..lineTo(w / 2 + r * 0.45, w / 2 + r * 0.75)
      ..close();
    canvas.drawShadow(tail.shift(Offset.zero), Colors.black, 3 * scale, false);
    canvas.drawCircle(c.translate(0, 1.5 * scale), r, Paint()..color = Colors.black.withValues(alpha: 0.18)..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 * scale));
    canvas.drawPath(tail, Paint()..color = ring);
    canvas.drawCircle(c, r, Paint()..color = ring);
    canvas.drawCircle(c, r - 3.5 * scale, Paint()..color = Colors.white);

    final inner = r - 5.5 * scale;
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: inner)));
    if (photo != null) {
      final src = Rect.fromLTWH(0, 0, photo.width.toDouble(), photo.height.toDouble());
      final side = src.shortestSide;
      final crop = Rect.fromCenter(center: src.center, width: side, height: side);
      canvas.drawImageRect(photo, crop, Rect.fromCircle(center: c, radius: inner), Paint()..filterQuality = FilterQuality.medium);
    } else {
      canvas.drawCircle(c, inner, Paint()..color = AppColors.orangeSoft);
      final tp = TextPainter(
        text: TextSpan(
          text: e.initials,
          style: TextStyle(color: AppColors.orangeDeep, fontSize: inner * 0.8, fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
    }
    canvas.restore();

    final image = await recorder.endRecording().toImage(w.ceil(), h.ceil());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(bytes!.buffer.asUint8List(), imagePixelRatio: scale);
  }
}
