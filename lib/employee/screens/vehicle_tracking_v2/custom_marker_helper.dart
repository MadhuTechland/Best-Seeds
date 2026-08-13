import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// 1:1 copy of the user app's `custom_marker_helper.dart` so the vendor
/// tracking screen's vehicle/pickup/drop icons are identical to the user app
/// (delivery-truck image rotated to face north, with Google Maps marker
/// rotation handling the real heading). Named `…V2` to avoid colliding with the
/// vendor's existing shared `CustomMarkerHelper`.
class CustomMarkerHelperV2 {
  /// Create a clean navigation arrow marker (Uber / Google Maps style).
  /// Dark circle with a white directional arrow inside.
  /// Arrow points UP — Google Maps marker rotation handles direction.
  static Future<BitmapDescriptor> getVehicleArrowMarker({int size = 60}) async {
    final double s = size.toDouble();
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);

    final double cx = s / 2;
    final double cy = s / 2;
    final double radius = s * 0.40;

    // ── Outer glow / shadow ring ──
    final Paint glowPaint = Paint()
      ..color = const Color(0x30000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawCircle(Offset(cx, cy + 1), radius + 2, glowPaint);

    // ── White border ring ──
    final Paint borderPaint = Paint()..color = const Color(0xFFFFFFFF);
    canvas.drawCircle(Offset(cx, cy), radius + 2, borderPaint);

    // ── Dark circle background ──
    final Paint bgPaint = Paint()..color = const Color(0xFF1A1A2E);
    canvas.drawCircle(Offset(cx, cy), radius, bgPaint);

    // ── Navigation arrow (pointing UP) ──
    final double arrowH = radius * 1.1;
    final double arrowW = radius * 0.8;
    final double arrowTop = cy - arrowH * 0.5;

    final Path arrowPath = Path();
    // Tip (top center)
    arrowPath.moveTo(cx, arrowTop);
    // Right wing
    arrowPath.lineTo(cx + arrowW / 2, arrowTop + arrowH * 0.75);
    // Right notch
    arrowPath.lineTo(cx, arrowTop + arrowH * 0.55);
    // Left notch
    arrowPath.lineTo(cx - arrowW / 2, arrowTop + arrowH * 0.75);
    arrowPath.close();

    final Paint arrowPaint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.fill;
    canvas.drawPath(arrowPath, arrowPaint);

    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(size, size);
    final ByteData? byteData =
        await image.toByteData(format: ui.ImageByteFormat.png);

    if (byteData != null) {
      return BitmapDescriptor.bytes(byteData.buffer.asUint8List());
    }

    return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet);
  }

  /// Load delivery truck marker from asset image.
  /// Asset is rotated 180° at load time so it faces UP (north).
  /// Google Maps marker rotation then handles direction automatically.
  /// This is done here (not in _buildMarkers) so any future icon change
  /// only needs the asset to face any direction — this method normalizes it.
  static Future<BitmapDescriptor> getTruckMarker({int size = 60}) async {
    try {
      final ByteData data =
          await rootBundle.load('assets/images/delivery_truck.png');
      // delivery_truck.png is a top-down/rear truck already facing north (up)
      // at 0°, so NO baked-in rotation is applied — the Marker's [rotation]
      // handles heading. Scale by width only so the truck keeps its aspect
      // ratio (forcing targetHeight too would squish the tall image).
      final ui.Codec codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(),
        targetWidth: size,
      );
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      final ByteData? byteData =
          await frameInfo.image.toByteData(format: ui.ImageByteFormat.png);
      // The PNG bytes are a copy, so the decoded image and the codec
      // can go now. ui.Image holds NATIVE memory that Dart's GC only
      // reclaims via a finalizer — on iOS that lag lets marker images
      // accumulate across screen opens. Explicit disposal is required.
      frameInfo.image.dispose();
      codec.dispose();

      if (byteData != null) {
        return BitmapDescriptor.bytes(byteData.buffer.asUint8List());
      }
    } catch (e) {
      debugPrint('Error loading delivery truck marker: $e');
    }

    // Fallback to arrow marker if asset fails
    return getVehicleArrowMarker(size: size);
  }

  /// Load start/pickup location marker from asset with fallback
  static Future<BitmapDescriptor> getStartLocationMarkerFromAsset(
      {int size = 30}) async {
    try {
      final ByteData data =
          await rootBundle.load('assets/images/pickup_vehicle_icon.png');
      final ui.Codec codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(),
        targetWidth: size,
      );
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      final ByteData? byteData =
          await frameInfo.image.toByteData(format: ui.ImageByteFormat.png);
      // The PNG bytes are a copy, so the decoded image and the codec
      // can go now. ui.Image holds NATIVE memory that Dart's GC only
      // reclaims via a finalizer — on iOS that lag lets marker images
      // accumulate across screen opens. Explicit disposal is required.
      frameInfo.image.dispose();
      codec.dispose();

      if (byteData != null) {
        return BitmapDescriptor.bytes(byteData.buffer.asUint8List());
      }
    } catch (e) {
      debugPrint('Error loading start location marker from asset: $e');
    }

    // Fallback: Green pin marker
    return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);
  }

  /// Load drop/destination location marker from asset with fallback
  static Future<BitmapDescriptor> getDropLocationMarkerFromAsset(
      {int size = 30}) async {
    try {
      final ByteData data =
          await rootBundle.load('assets/images/drop_vehicle_icon.png');
      final ui.Codec codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(),
        targetWidth: size,
      );
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      final ByteData? byteData =
          await frameInfo.image.toByteData(format: ui.ImageByteFormat.png);
      // The PNG bytes are a copy, so the decoded image and the codec
      // can go now. ui.Image holds NATIVE memory that Dart's GC only
      // reclaims via a finalizer — on iOS that lag lets marker images
      // accumulate across screen opens. Explicit disposal is required.
      frameInfo.image.dispose();
      codec.dispose();

      if (byteData != null) {
        return BitmapDescriptor.bytes(byteData.buffer.asUint8List());
      }
    } catch (e) {
      debugPrint('Error loading drop location marker from asset: $e');
    }

    // Fallback: Red pin marker
    return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);
  }
}
