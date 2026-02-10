/// Counts for driver booking tabs
class DriverBookingCounts {
  final int all;
  final int live;
  final int assigned;
  final int past;

  DriverBookingCounts({
    required this.all,
    required this.live,
    required this.assigned,
    required this.past,
  });

  factory DriverBookingCounts.fromJson(Map<String, dynamic> json) {
    return DriverBookingCounts(
      all: json['all'] ?? 0,
      live: json['live'] ?? 0,
      assigned: json['assigned'] ?? 0,
      past: json['past'] ?? 0,
    );
  }
}

/// Response model for driver bookings API
class DriverBookingResponse {
  final bool status;
  final List<DriverRoute> routes;
  final DriverBookingCounts counts;

  DriverBookingResponse({
    required this.status,
    required this.routes,
    required this.counts,
  });

  factory DriverBookingResponse.fromJson(Map<String, dynamic> json) {
    return DriverBookingResponse(
      status: json['status'] ?? false,
      routes: (json['routes'] as List<dynamic>?)
              ?.map((e) => DriverRoute.fromJson(e))
              .toList() ??
          [],
      counts: DriverBookingCounts.fromJson(json['counts'] ?? {}),
    );
  }
}

/// Represents a route with multiple drop locations (bookings)
class DriverRoute {
  final DateTime? packingDate;
  final StartLocation? startLocation;
  final int? hatcheryId;
  final RouteHatchery? hatchery;
  final int? categoryId;
  final RouteCategory? category;
  final int totalDrops;
  final int totalPieces;
  final List<DropBooking> bookings;

  DriverRoute({
    this.packingDate,
    this.startLocation,
    this.hatcheryId,
    this.hatchery,
    this.categoryId,
    this.category,
    required this.totalDrops,
    required this.totalPieces,
    required this.bookings,
  });

  factory DriverRoute.fromJson(Map<String, dynamic> json) {
    return DriverRoute(
      packingDate: json['vehicle_started_date'] != null
          ? DateTime.tryParse(json['vehicle_started_date'])
          : null,
      startLocation: json['start_location'] != null
          ? StartLocation.fromJson(json['start_location'])
          : null,
      hatcheryId: json['hatchery_id'],
      hatchery: json['hatchery'] != null
          ? RouteHatchery.fromJson(json['hatchery'])
          : null,
      categoryId: json['category_id'],
      category: json['category'] != null
          ? RouteCategory.fromJson(json['category'])
          : null,
      totalDrops: json['total_drops'] ?? 0,
      totalPieces: json['total_pieces'] ?? 0,
      bookings: (json['bookings'] as List<dynamic>?)
              ?.map((e) => DropBooking.fromJson(e))
              .toList() ??
          [],
    );
  }

  String get startLocationName =>
      startLocation?.locationName ?? 'Unknown Start Location';

  /// Start latitude
  double? get startLat => startLocation?.lat;

  /// Start longitude
  double? get startLng => startLocation?.lng;

  /// Check if start location is valid for map
  bool get hasValidStartLocation => startLat != null && startLng != null;

  /// Get hatchery name or fallback
  String get hatcheryName => hatchery?.categoryName ?? 'Unknown Hatchery';

  /// Get category name or fallback
  String get categoryName => category?.categoryName ?? '';

  /// Get first drop location for route visualization
  String? get firstDropLocation =>
      bookings.isNotEmpty ? bookings.first.droppingLocation : null;

  /// Get last drop location for route visualization
  String? get lastDropLocation =>
      bookings.isNotEmpty ? bookings.last.droppingLocation : null;

  /// Get all drop location names for route visualization
  List<String> get dropLocationNames =>
      bookings.map((b) => b.droppingLocation ?? 'Unknown').toList();

  /// Check if route has any booking in progress (status 3 or 4)
  bool get hasActiveBooking =>
      bookings.any((b) => b.status == 3 || b.status == 4);

  /// Check if all bookings are completed (status 5)
  bool get isCompleted => bookings.every((b) => b.status == 5);

  bool get isFailed => bookings.every((b) => b.status == 6);

  /// Get the overall status of the route based on bookings
  int get routeStatus {
    if (bookings.isEmpty) return 0;

    // If any booking is in transit (4), route is in transit
    if (bookings.any((b) => b.status == 4)) return 4;

    // If any booking is confirmed (3), route is confirmed
    if (bookings.any((b) => b.status == 3)) return 3;

    // If all bookings are completed (5), route is completed
    if (bookings.every((b) => b.status == 5)) return 5;

    // Default to the first booking's status
    return bookings.first.status;
  }

  /// Get comma-separated booking IDs (e.g., "217, 218")
  String get bookingIdsString {
    if (bookings.isEmpty) return 'N/A';
    return bookings.map((b) => b.id.toString()).join(', ');
  }

  /// Get the first available delivery datetime from bookings
  DateTime? get firstDeliveryDatetime {
    for (final booking in bookings) {
      if (booking.deliveryDatetime != null) {
        return booking.deliveryDatetime;
      }
    }
    return null;
  }
}

/// Hatchery info within a route
class RouteHatchery {
  final int? id;
  final String? categoryName;

  RouteHatchery({
    this.id,
    this.categoryName,
  });

  factory RouteHatchery.fromJson(Map<String, dynamic> json) {
    return RouteHatchery(
      id: json['id'],
      categoryName: json['category_name'],
    );
  }
}

/// Category info within a route
class RouteCategory {
  final int? id;
  final String? categoryName;

  RouteCategory({
    this.id,
    this.categoryName,
  });

  factory RouteCategory.fromJson(Map<String, dynamic> json) {
    return RouteCategory(
      id: json['id'],
      categoryName: json['category_name'],
    );
  }
}

/// Individual booking/drop within a route
class DropBooking {
  final int id;
  final String? bookingUid;
  final String customerName;
  final String? customerMobile;
  final String? droppingLocation;
  final int noOfPieces;
  final int status;
  final double? dropLat;
  final double? dropLng;
  final String? deliveryNote;
  final DateTime? deliveryDatetime;
  final int? priority;

  DropBooking({
    required this.id,
    this.bookingUid,
    required this.customerName,
    this.customerMobile,
    this.droppingLocation,
    required this.noOfPieces,
    required this.status,
    this.dropLat,
    this.dropLng,
    this.deliveryNote,
    this.deliveryDatetime,
    this.priority,
  });

  factory DropBooking.fromJson(Map<String, dynamic> json) {
    return DropBooking(
      id: json['id'] ?? 0,
      bookingUid: json['booking_uid'],
      customerName: json['customer_name'] ?? '',
      customerMobile: json['customer_mobile'],
      droppingLocation: json['dropping_location'],
      noOfPieces: _parseInt(json['no_of_pieces']),
      status: json['status'] ?? 0,
      dropLat: _parseDouble(json['drop_lat']),
      dropLng: _parseDouble(json['drop_lng']),
      deliveryNote: json['delivery_note'],
      deliveryDatetime: json['delivery_datetime'] != null
          ? DateTime.tryParse(json['delivery_datetime'])
          : null,
      priority: json['priority'],
    );
  }

  static int _parseInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  /// Get status string
  String get statusString {
    switch (status) {
      case 0:
        return 'Pending';
      case 1:
        return 'Accepted';
      case 2:
        return 'Rejected';
      case 3:
        return 'Confirmed';
      case 4:
        return 'In Transit';
      case 5:
        return 'Delivered';
      case 6:
        return 'Cancelled';
      default:
        return 'Pending';
    }
  }

  /// Check if drop is pending
  bool get isPending => status == 0 || status == 1;

  /// Check if drop is confirmed
  bool get isConfirmed => status == 3;

  /// Check if drop is in transit
  bool get isInTransit => status == 4;

  /// Check if drop is delivered
  bool get isDelivered => status == 5;

  /// Check if drop is cancelled
  bool get isCancelled => status == 6;
}

class StartLocation {
  final int? locationId;
  final String? locationName;
  final double? lat;
  final double? lng;

  StartLocation({
    this.locationId,
    this.locationName,
    this.lat,
    this.lng,
  });

  factory StartLocation.fromJson(Map<String, dynamic> json) {
    return StartLocation(
      locationId: json['location_id'],
      locationName: json['location_name'],
      lat: _parseDouble(json['lat']),
      lng: _parseDouble(json['lng']),
    );
  }

  static double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
