import 'package:flutter/material.dart';
import 'edit_vehicle_details_screen.dart';
import 'vehicle_tracking_map_screen.dart';

class TrackingScreen extends StatelessWidget {
  const TrackingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: SafeArea(
        child: Column(
          children: [
            /// ================= Header =================
            _buildHeader(width, height),

            /// ================= Search Bar =================
            _buildSearchBar(width, height),

            /// ================= Tracking List =================
            Expanded(
              child: _buildTrackingList(width, height),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(double width, double height) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: width * 0.05,
        vertical: height * 0.02,
      ),
      color: Colors.white,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'Vehicle Tracking',
            style: TextStyle(
              fontSize: width * 0.055,
              fontWeight: FontWeight.bold,
            ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.translate,
              size: width * 0.06,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(double width, double height) {
    return Container(
      padding: EdgeInsets.all(width * 0.05),
      color: Colors.white,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: width * 0.04,
          vertical: height * 0.015,
        ),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              Icons.search,
              color: Colors.grey,
              size: width * 0.06,
            ),
            SizedBox(width: width * 0.03),
            Text(
              'Search Bookings',
              style: TextStyle(
                color: Colors.grey,
                fontSize: width * 0.04,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrackingList(double width, double height) {
    return ListView(
      padding: EdgeInsets.all(width * 0.04),
      children: [
        _buildTrackingCard(
          width,
          height,
          id: 'ID:324646',
          time: '12:30PM, 25/11/2025',
          title: 'Seven Star Hatchery',
          location: 'Syaqua',
          pieces: '1400 Pieces',
          date: '22/06/2025',
          address: '9-186, Prakash Nagar, Hyderabad, Tel...',
        ),
        SizedBox(height: height * 0.02),
        _buildTrackingCard(
          width,
          height,
          id: 'ID:324646',
          time: '12:30PM, 25/11/2025',
          title: 'Seven Star Hatchery',
          location: 'Syaqua',
          pieces: '1400 Pieces',
          date: '22/06/2025',
          address: '9-186, Prakash Nagar, Hyderabad, Tel...',
        ),
      ],
    );
  }

  Widget _buildTrackingCard(
    double width,
    double height, {
    required String id,
    required String time,
    required String title,
    required String location,
    required String pieces,
    required String date,
    required String address,
  }) {
    return Builder(
      builder: (context) => Container(
      padding: EdgeInsets.all(width * 0.04),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          /// Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                id,
                style: TextStyle(
                  fontSize: width * 0.04,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                time,
                style: TextStyle(
                  fontSize: width * 0.032,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
          SizedBox(height: height * 0.015),

          /// Title and location
          Text(
            title,
            style: TextStyle(
              fontSize: width * 0.045,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            location,
            style: TextStyle(
              fontSize: width * 0.035,
              color: Colors.grey,
            ),
          ),
          SizedBox(height: height * 0.015),

          /// Info section
          Row(
            children: [
              Icon(Icons.inventory_2_outlined, size: width * 0.04, color: Colors.grey),
              SizedBox(width: width * 0.02),
              Text(
                pieces,
                style: TextStyle(
                  fontSize: width * 0.038,
                  color: Colors.grey.shade700,
                ),
              ),
              SizedBox(width: width * 0.06),
              Icon(Icons.calendar_today_outlined, size: width * 0.04, color: Colors.grey),
              SizedBox(width: width * 0.02),
              Text(
                date,
                style: TextStyle(
                  fontSize: width * 0.038,
                  color: Colors.grey.shade700,
                ),
              ),
            ],
          ),
          SizedBox(height: height * 0.01),
          Row(
            children: [
              Icon(Icons.location_on_outlined, size: width * 0.04, color: Colors.grey),
              SizedBox(width: width * 0.02),
              Expanded(
                child: Text(
                  address,
                  style: TextStyle(
                    fontSize: width * 0.038,
                    color: Colors.grey.shade700,
                  ),
                ),
              ),
            ],
          ),

          SizedBox(height: height * 0.02),

          /// Vehicle Tracking Button
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => VehicleTrackingMapScreen(
                          bookingId: id,
                          title: title,
                          driverName: 'Ramesh',
                          vehicleNumber: 'TSN05656',
                        ),
                      ),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0077C8),
                    padding: EdgeInsets.symmetric(vertical: height * 0.015),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                  ),
                  child: Text(
                    'Vehicle Tracking',
                    style: TextStyle(
                      fontSize: width * 0.04,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              SizedBox(width: width * 0.03),
              GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => EditVehicleDetailsScreen(
                        bookingId: id,
                        title: title,
                        time: time,
                      ),
                    ),
                  );
                },
                child: Container(
                  padding: EdgeInsets.all(width * 0.025),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.edit_outlined,
                    size: width * 0.05,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }
}
