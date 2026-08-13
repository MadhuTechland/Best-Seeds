import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class CustomMarkerHelper {
  /// Create a truck marker icon from asset image with fallback to drawn marker
  static Future<BitmapDescriptor> getTruckMarkerFromAsset({
    double size = 80,
  }) async {
    try {
      // Load the truck icon from assets
      final ByteData data = await rootBundle.load('assets/icons/truck_icon.png');
      final ui.Codec codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(),
        targetWidth: size.toInt(),
        targetHeight: size.toInt(),
      );
      final ui.FrameInfo fi = await codec.getNextFrame();
      final ByteData? byteData = await fi.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      // The PNG bytes are a copy, so the decoded image and codec can go now.
      // ui.Image holds NATIVE memory that Dart's GC only reclaims via a
      // finalizer — on iOS that lag lets marker images accumulate.
      fi.image.dispose();
      codec.dispose();

      if (byteData != null) {
        return BitmapDescriptor.bytes(byteData.buffer.asUint8List());
      }
    } catch (e) {
      debugPrint('Error loading truck marker from asset: $e');
    }

    // Fallback to drawn marker
    return _createTruckMarkerFallback(size: size);
  }

  /// Create a start location marker from asset image with fallback
  static Future<BitmapDescriptor> getStartLocationMarkerFromAsset({
    double size = 80,
  }) async {
    try {
      // Load the start location icon from assets
      final ByteData data = await rootBundle.load('assets/icons/start_location.png');
      final ui.Codec codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(),
        targetWidth: size.toInt(),
        targetHeight: size.toInt(),
      );
      final ui.FrameInfo fi = await codec.getNextFrame();
      final ByteData? byteData = await fi.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      // The PNG bytes are a copy, so the decoded image and codec can go now.
      // ui.Image holds NATIVE memory that Dart's GC only reclaims via a
      // finalizer — on iOS that lag lets marker images accumulate.
      fi.image.dispose();
      codec.dispose();

      if (byteData != null) {
        return BitmapDescriptor.bytes(byteData.buffer.asUint8List());
      }
    } catch (e) {
      debugPrint('Error loading start location marker from asset: $e');
    }

    // Fallback to drawn marker
    return _createLocationPinMarkerFallback(size: size, color: Colors.green, isDestination: false);
  }

  /// Create a drop/destination location marker from asset image with fallback
  static Future<BitmapDescriptor> getDropLocationMarkerFromAsset({
    double size = 80,
  }) async {
    try {
      // Load the drop location icon from assets
      final ByteData data = await rootBundle.load('assets/icons/drop_location.png');
      final ui.Codec codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(),
        targetWidth: size.toInt(),
        targetHeight: size.toInt(),
      );
      final ui.FrameInfo fi = await codec.getNextFrame();
      final ByteData? byteData = await fi.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      // The PNG bytes are a copy, so the decoded image and codec can go now.
      // ui.Image holds NATIVE memory that Dart's GC only reclaims via a
      // finalizer — on iOS that lag lets marker images accumulate.
      fi.image.dispose();
      codec.dispose();

      if (byteData != null) {
        return BitmapDescriptor.bytes(byteData.buffer.asUint8List());
      }
    } catch (e) {
      debugPrint('Error loading drop location marker from asset: $e');
    }

    // Fallback to drawn marker
    return _createLocationPinMarkerFallback(size: size, color: Colors.red, isDestination: true);
  }

  /// Fallback: Create a truck marker with custom design when asset fails
  static Future<BitmapDescriptor> _createTruckMarkerFallback({
    double size = 100,
    Color backgroundColor = const Color(0xFF0077C8),
  }) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);

    // Draw outer shadow/glow
    final Paint shadowPaint = Paint()
      ..color = backgroundColor.withValues(alpha: 0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawCircle(
      Offset(size / 2, size / 2),
      size / 2 - 5,
      shadowPaint,
    );

    // Draw main circle
    final Paint circlePaint = Paint()..color = backgroundColor;
    canvas.drawCircle(
      Offset(size / 2, size / 2),
      size / 2 - 10,
      circlePaint,
    );

    // Draw white border
    final Paint borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(
      Offset(size / 2, size / 2),
      size / 2 - 10,
      borderPaint,
    );

    // Draw truck icon using Material Icons
    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );
    textPainter.text = TextSpan(
      text: String.fromCharCode(Icons.local_shipping.codePoint),
      style: TextStyle(
        fontSize: size * 0.4,
        fontFamily: Icons.local_shipping.fontFamily,
        package: Icons.local_shipping.fontPackage,
        color: Colors.white,
      ),
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(
        (size - textPainter.width) / 2,
        (size - textPainter.height) / 2,
      ),
    );

    final img = await pictureRecorder.endRecording().toImage(
      size.toInt(),
      size.toInt(),
    );
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    // The PNG bytes are a copy, so the decoded image and codec can go now.
    // ui.Image holds NATIVE memory that Dart's GC only reclaims via a
    // finalizer — on iOS that lag lets marker images accumulate.
    img.dispose();

    if (data != null) {
      return BitmapDescriptor.bytes(data.buffer.asUint8List());
    }

    return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
  }

  /// Fallback: Create a location pin marker when asset fails
  static Future<BitmapDescriptor> _createLocationPinMarkerFallback({
    double size = 100,
    Color color = Colors.green,
    bool isDestination = false,
  }) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);

    // Pin dimensions
    final double pinWidth = size * 0.6;
    final double pinHeight = size * 0.85;
    final double circleRadius = pinWidth / 2;
    final double centerX = size / 2;
    final double topY = size * 0.08;

    // Draw shadow
    final Paint shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    final Path shadowPath = Path();
    shadowPath.addOval(Rect.fromCenter(
      center: Offset(centerX + 2, topY + circleRadius + 2),
      width: circleRadius * 2,
      height: circleRadius * 2,
    ));
    canvas.drawPath(shadowPath, shadowPaint);

    // Draw pin body
    final Paint pinPaint = Paint()..color = color;

    final Path pinPath = Path();
    // Circle part
    pinPath.addOval(Rect.fromCenter(
      center: Offset(centerX, topY + circleRadius),
      width: circleRadius * 2,
      height: circleRadius * 2,
    ));
    // Triangle/pointer part
    pinPath.moveTo(centerX - circleRadius * 0.6, topY + circleRadius + circleRadius * 0.5);
    pinPath.lineTo(centerX, pinHeight);
    pinPath.lineTo(centerX + circleRadius * 0.6, topY + circleRadius + circleRadius * 0.5);
    pinPath.close();

    canvas.drawPath(pinPath, pinPaint);

    // Draw white inner circle
    final Paint innerCirclePaint = Paint()..color = Colors.white;
    canvas.drawCircle(
      Offset(centerX, topY + circleRadius),
      circleRadius * 0.5,
      innerCirclePaint,
    );

    // Draw icon inside
    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );
    final IconData icon = isDestination ? Icons.flag : Icons.circle;
    textPainter.text = TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontSize: circleRadius * 0.7,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        color: color,
      ),
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(
        centerX - textPainter.width / 2,
        topY + circleRadius - textPainter.height / 2,
      ),
    );

    final img = await pictureRecorder.endRecording().toImage(
      size.toInt(),
      size.toInt(),
    );
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    // The PNG bytes are a copy, so the decoded image and codec can go now.
    // ui.Image holds NATIVE memory that Dart's GC only reclaims via a
    // finalizer — on iOS that lag lets marker images accumulate.
    img.dispose();

    if (data != null) {
      return BitmapDescriptor.bytes(data.buffer.asUint8List());
    }

    return BitmapDescriptor.defaultMarker;
  }

  /// Navigation arrow marker (Uber / Google Maps style).
  /// Dark circle with white directional arrow inside.
  static Future<BitmapDescriptor> getVehicleArrowMarker({int size = 60}) async {
    final double s = size.toDouble();
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final double cx = s / 2;
    final double cy = s / 2;
    final double radius = s * 0.40;

    canvas.drawCircle(Offset(cx, cy + 1), radius + 2,
        Paint()..color = const Color(0x30000000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawCircle(Offset(cx, cy), radius + 2, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawCircle(Offset(cx, cy), radius, Paint()..color = const Color(0xFF1A1A2E));

    final double arrowH = radius * 1.1;
    final double arrowW = radius * 0.8;
    final double arrowTop = cy - arrowH * 0.5;
    final Path arrowPath = Path()
      ..moveTo(cx, arrowTop)
      ..lineTo(cx + arrowW / 2, arrowTop + arrowH * 0.75)
      ..lineTo(cx, arrowTop + arrowH * 0.55)
      ..lineTo(cx - arrowW / 2, arrowTop + arrowH * 0.75)
      ..close();
    canvas.drawPath(arrowPath, Paint()..color = const Color(0xFFFFFFFF)..style = PaintingStyle.fill);

    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(size, size);
    final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData != null) return BitmapDescriptor.bytes(byteData.buffer.asUint8List());
    return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet);
  }

  // ============ Legacy methods — now use navigation arrow ============

  static Future<BitmapDescriptor> getTruckMarker({double size = 80}) async {
    return getVehicleArrowMarker(size: size.toInt());
  }

  static Future<BitmapDescriptor> createTruckMarker({
    double size = 100,
    Color backgroundColor = const Color(0xFF0077C8),
  }) async {
    return getVehicleArrowMarker(size: size.toInt());
  }

  /// Create a location pin marker (legacy - now uses asset first)
  static Future<BitmapDescriptor> createLocationPinMarker({
    double size = 100,
    Color color = Colors.green,
    bool isDestination = false,
  }) async {
    if (isDestination) {
      return getDropLocationMarkerFromAsset(size: size);
    } else {
      return getStartLocationMarkerFromAsset(size: size);
    }
  }

  /// Create a custom marker with a widget (painted as image)
  static Future<BitmapDescriptor> createCustomMarkerFromWidget({
    required IconData icon,
    required Color backgroundColor,
    required Color iconColor,
    double size = 80,
  }) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    final Paint paint = Paint()..color = backgroundColor;

    // Draw circle background
    canvas.drawCircle(
      Offset(size / 2, size / 2),
      size / 2,
      paint,
    );

    // Draw border
    final Paint borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(
      Offset(size / 2, size / 2),
      size / 2 - 1.5,
      borderPaint,
    );

    // Draw icon
    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );
    textPainter.text = TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontSize: size * 0.5,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        color: iconColor,
      ),
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(
        (size - textPainter.width) / 2,
        (size - textPainter.height) / 2,
      ),
    );

    final img = await pictureRecorder.endRecording().toImage(
      size.toInt(),
      size.toInt(),
    );
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    // The PNG bytes are a copy, so the decoded image and codec can go now.
    // ui.Image holds NATIVE memory that Dart's GC only reclaims via a
    // finalizer — on iOS that lag lets marker images accumulate.
    img.dispose();

    if (data != null) {
      return BitmapDescriptor.bytes(data.buffer.asUint8List());
    }

    return BitmapDescriptor.defaultMarker;
  }
}
