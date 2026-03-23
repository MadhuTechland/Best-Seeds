class Booking {
  final String bookingUid;
  final int bookingId;
  final String bookingType;
  final int hatcheryId;
  final String hatcheryName;
  final int categoryId;
  final String categoryName;
  final int noOfPieces;
  final int? salinity;
  final String? preferredDate;
  final String? deliveryDatetime;
  final String droppingLocation;
  final double travelCost;
  final String? bookingDescription;
  final String? vehicleDescription;
  final double? latitude;
  final double? longitude;
  final BookingFarmer farmer;
  final BookingStatus status;
  final BookingDriverDetails driverDetails;
  final BookingPickup? pickup;
  final BookingCurrentLocation? currentLocation;
  final BookingDestination? destination;
  final List<BookingRouteWaypoint> routeWaypoints;

  Booking({
    required this.bookingUid,
    required this.bookingId,
    required this.bookingType,
    required this.hatcheryId,
    required this.hatcheryName,
    required this.categoryId,
    required this.categoryName,
    required this.noOfPieces,
    this.salinity,
    this.preferredDate,
    this.deliveryDatetime,
    required this.droppingLocation,
    required this.travelCost,
    this.bookingDescription,
    this.vehicleDescription,
    this.latitude,
    this.longitude,
    required this.farmer,
    required this.status,
    required this.driverDetails,
    this.pickup,
    this.currentLocation,
    this.destination,
    this.routeWaypoints = const [],
  });

  factory Booking.fromJson(Map<String, dynamic> json) {
    return Booking(
      bookingUid: json['booking_uid'] ?? '',
      bookingId: json['booking_id'] ?? 0,
      bookingType: json['booking_type'] ?? '',
      hatcheryId: json['hatchery_id'] ?? 0,
      hatcheryName: json['hatchery_name'] ?? '',
      categoryId: json['category_id'] ?? 0,
      categoryName: json['category_name'] ?? '',
      noOfPieces: json['no_of_pieces'] ?? 0,
      salinity: json['salinity'],
      preferredDate: json['packing_date'],
      deliveryDatetime: json['delivery_datetime'],
      droppingLocation: json['drop_location'] ?? '',
      travelCost: (json['price'] != null) ? double.tryParse(json['price'].toString()) ?? 0.0 : 0.0,
      bookingDescription: json['vendor_booking_description'] ?? '',
      vehicleDescription: json['vendor_vehicle_description'] ?? '',
      latitude: json['latitude'] != null
          ? double.tryParse(json['latitude'].toString())
          : null,
      longitude: json['longitude'] != null
          ? double.tryParse(json['longitude'].toString())
          : null,
      farmer: BookingFarmer.fromJson(json['farmer'] ?? {}),
      status: BookingStatus.fromJson(json['status'] ?? {}),
      driverDetails: BookingDriverDetails.fromJson(json['driver'] ?? {}),
      pickup: json['pickup'] != null
          ? BookingPickup.fromJson(json['pickup'])
          : null,
      currentLocation: json['current_location'] != null
          ? BookingCurrentLocation.fromJson(json['current_location'])
          : null,
      destination: json['destination'] != null
          ? BookingDestination.fromJson(json['destination'])
          : null,
      routeWaypoints: (json['route_waypoints'] as List<dynamic>?)
              ?.map((e) => BookingRouteWaypoint.fromJson(e))
              .toList() ??
          [],
    );
  }

  bool get isEditable =>
      status.value == 1 || status.value == 2 || status.value == 3 || status.value == 4;

  bool get isVehicleAvailability => bookingType == 'vehicle_availability';

  String get displayBookingType {
    switch (bookingType) {
      case 'spot_hatchery':
        return 'Spot Hatchery';
      case 'hatchery':
        return 'Hatchery';
      case 'vehicle_availability':
        return 'Vehicle Availability';
      default:
        return bookingType;
    }
  }
}

class BookingFarmer {
  final String name;

  BookingFarmer({required this.name});

  factory BookingFarmer.fromJson(Map<String, dynamic> json) {
    return BookingFarmer(
      name: json['name'] ?? '',
    );
  }
}

class BookingDriverDetails {
  final int? driverId;
  final String name;
  final String mobile;
  final String vehicleNumber;
  final String? vehicleStartDate;
  final String? vehicleEndDate;
  final double? vehicleStartLat;
  final double? vehicleStartLng;
  final String? vehicleStartAddress;
  final int? priority;

  BookingDriverDetails({
    this.driverId,
    required this.name,
    required this.mobile,
    required this.vehicleNumber,
    this.vehicleStartDate,
    this.vehicleEndDate,
    this.vehicleStartLat,
    this.vehicleStartLng,
    this.vehicleStartAddress,
    this.priority,
  });

  factory BookingDriverDetails.fromJson(Map<String, dynamic> json) {
    return BookingDriverDetails(
      driverId: json['driver_id'],
      name: json['driver_name'] ?? '',
      mobile: json['driver_mobile'] ?? '',
      vehicleNumber: json['vehicle_number'] ?? '',
      vehicleStartDate: json['vehicle_start_date'],
      vehicleEndDate: json['vehicle_end_date'],
      vehicleStartLat: json['vehicle_start_lat'] != null
          ? double.tryParse(json['vehicle_start_lat'].toString())
          : null,
      vehicleStartLng: json['vehicle_start_lng'] != null
          ? double.tryParse(json['vehicle_start_lng'].toString())
          : null,
      vehicleStartAddress: json['vehicle_start_address'],
      priority: json['priority'],
    );
  }

  bool get isAssigned => mobile.isNotEmpty;
}

class BookingStatus {
  final int value;
  final String label;

  BookingStatus({
    required this.value,
    required this.label,
  });

  factory BookingStatus.fromJson(Map<String, dynamic> json) {
    return BookingStatus(
      value: json['value'] ?? 0,
      label: json['label'] ?? '',
    );
  }

  bool get isPending => value == 1;
  bool get isConfirmed => value == 2;
  bool get isAccepted => value == 2;
  bool get isDriverAssigned => value == 3;
  bool get isInProgress => value == 4;
  bool get isDelivered => value == 4;
  bool get isCompleted => value == 5;
  bool get isFailed => value == 6;
  bool get isRejected => value == 6;

  String get displayLabel {
    switch (value) {
      case 1:
        return 'Pending';
      case 2:
        return 'Confirmed';
      case 3:
        return 'Driver Assigned';
      case 4:
        return 'In Transit';
      case 5:
        return 'Completed';
      case 6:
        return 'Failed';
      default:
        return label;
    }
  }
}

class BookingPickup {
  final String? locationName;
  final double? lat;
  final double? lng;
  final String? vehicleStartedDate;
  final String? inProgressAt;

  BookingPickup({
    this.locationName,
    this.lat,
    this.lng,
    this.vehicleStartedDate,
    this.inProgressAt,
  });

  factory BookingPickup.fromJson(Map<String, dynamic> json) {
    return BookingPickup(
      locationName: json['location_name'],
      lat: json['lat'] != null ? double.tryParse(json['lat'].toString()) : null,
      lng: json['lng'] != null ? double.tryParse(json['lng'].toString()) : null,
      vehicleStartedDate: json['vehicle_started_date'],
      inProgressAt: json['in_progress_at'],
    );
  }
}

class BookingCurrentLocation {
  final double? lat;
  final double? lng;
  final String? locationName;
  final String? updatedAt;

  BookingCurrentLocation({
    this.lat,
    this.lng,
    this.locationName,
    this.updatedAt,
  });

  factory BookingCurrentLocation.fromJson(Map<String, dynamic> json) {
    return BookingCurrentLocation(
      lat: json['lat'] != null ? double.tryParse(json['lat'].toString()) : null,
      lng: json['lng'] != null ? double.tryParse(json['lng'].toString()) : null,
      locationName: json['location_name'],
      updatedAt: json['updated_at'],
    );
  }
}

class BookingDestination {
  final String? locationName;
  final double? lat;
  final double? lng;

  BookingDestination({
    this.locationName,
    this.lat,
    this.lng,
  });

  factory BookingDestination.fromJson(Map<String, dynamic> json) {
    return BookingDestination(
      locationName: json['location_name'],
      lat: json['lat'] != null ? double.tryParse(json['lat'].toString()) : null,
      lng: json['lng'] != null ? double.tryParse(json['lng'].toString()) : null,
    );
  }
}

class BookingPagination {
  final int currentPage;
  final int lastPage;
  final int perPage;
  final int total;
  final String? nextPageUrl;
  final String? prevPageUrl;

  BookingPagination({
    required this.currentPage,
    required this.lastPage,
    required this.perPage,
    required this.total,
    this.nextPageUrl,
    this.prevPageUrl,
  });

  factory BookingPagination.fromJson(Map<String, dynamic> json) {
    return BookingPagination(
      currentPage: json['current_page'] ?? 1,
      lastPage: json['last_page'] ?? 1,
      perPage: json['per_page'] ?? 10,
      total: json['total'] ?? 0,
      nextPageUrl: json['next_page_url'],
      prevPageUrl: json['prev_page_url'],
    );
  }
}

class BookingCounts {
  final int all;
  final int newBookings;
  final int current;
  final int past;

  BookingCounts({
    required this.all,
    required this.newBookings,
    required this.current,
    required this.past,
  });

  factory BookingCounts.fromJson(Map<String, dynamic> json) {
    return BookingCounts(
      all: json['all'] ?? 0,
      newBookings: json['new'] ?? 0,
      current: json['current'] ?? 0,
      past: json['past'] ?? 0,
    );
  }
}

class BookingsResponse {
  final bool status;
  final String message;
  final BookingPagination pagination;
  final List<Booking> bookings;
  final BookingCounts counts;

  BookingsResponse({
    required this.status,
    required this.message,
    required this.pagination,
    required this.bookings,
    required this.counts,
  });

  factory BookingsResponse.fromJson(Map<String, dynamic> json) {
    return BookingsResponse(
      status: json['status'] ?? false,
      message: json['message'] ?? '',
      pagination: BookingPagination.fromJson(json['pagination'] ?? {}),
      bookings: (json['bookings'] as List<dynamic>?)
              ?.map((e) => Booking.fromJson(e))
              .toList() ??
          [],
      counts: BookingCounts.fromJson(json['counts'] ?? {}),
    );
  }
}

class BookingRouteWaypoint {
  final double lat;
  final double lng;

  BookingRouteWaypoint({required this.lat, required this.lng});

  factory BookingRouteWaypoint.fromJson(Map<String, dynamic> json) {
    return BookingRouteWaypoint(
      lat: (json['lat'] ?? 0).toDouble(),
      lng: (json['lng'] ?? 0).toDouble(),
    );
  }
}
