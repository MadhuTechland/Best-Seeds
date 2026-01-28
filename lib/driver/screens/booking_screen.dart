import 'package:flutter/material.dart';
import 'edit_hatchery_details_screen.dart';

class BookingScreen extends StatefulWidget {
  const BookingScreen({super.key});

  @override
  State<BookingScreen> createState() => _BookingScreenState();
}

class _BookingScreenState extends State<BookingScreen> {
  int selectedTabIndex = 1; // New Bookings is highlighted

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

            /// ================= Tab Bar =================
            _buildTabBar(width, height),

            /// ================= Bookings List =================
            Expanded(
              child: _buildBookingsList(width, height),
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
            'Booking',
            style: TextStyle(
              fontSize: width * 0.06,
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

  Widget _buildTabBar(double width, double height) {
    final tabs = [
      {'label': 'All', 'count': null},
      {'label': 'New Bookings', 'count': 1},
      {'label': 'Current Bookings', 'count': null},
      {'label': 'Past', 'count': null},
    ];

    return Container(
      height: height * 0.06,
      color: Colors.white,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: width * 0.03),
        itemCount: tabs.length,
        itemBuilder: (context, index) {
          final isSelected = selectedTabIndex == index;
          final tab = tabs[index];

          return GestureDetector(
            onTap: () {
              setState(() {
                selectedTabIndex = index;
              });
            },
            child: Container(
              margin: EdgeInsets.symmetric(
                horizontal: width * 0.02,
                vertical: height * 0.01,
              ),
              padding: EdgeInsets.symmetric(
                horizontal: width * 0.04,
              ),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF0077C8) : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  Text(
                    tab['label'] as String,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.black,
                      fontSize: width * 0.038,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  if (tab['count'] != null) ...[
                    SizedBox(width: width * 0.015),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.white : Colors.grey.shade200,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${tab['count']}',
                        style: TextStyle(
                          color: isSelected ? const Color(0xFF0077C8) : Colors.black,
                          fontSize: width * 0.03,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBookingsList(double width, double height) {
    return ListView(
      padding: EdgeInsets.all(width * 0.04),
      children: [
        _buildBookingCard(
          width,
          height,
          id: 'ID:324646',
          time: '12:30PM, 25/11/2025',
          type: 'Spot Hatchery',
          title: 'Seven Star Hatchery',
          location: 'Syaqua',
          pieces: '1400 Pieces',
          date: '22/06/2025',
          address: '9-186, Prakash Nagar, Hyderabad, Telang...',
          contactName: 'Sanjay Kumar',
          contactPhone: '+9176765858',
          status: 'pending',
        ),
        SizedBox(height: height * 0.02),
        _buildBookingCard(
          width,
          height,
          id: 'ID:324646',
          time: '12:30PM, 25/11/2025',
          type: 'Vehicle Availability',
          title: 'Seven Star Hatchery',
          location: 'Syaqua',
          pieces: '5 Lakhs seeds',
          date: null,
          address: null,
          contactName: null,
          contactPhone: null,
          status: 'availability',
          pickupLocation: 'Seven Star Hatchery',
          dropLocation: 'Kakinada, Andhra Pradesh',
          additionalInfo: 'No of space available',
        ),
      ],
    );
  }

  Widget _buildBookingCard(
    double width,
    double height, {
    required String id,
    required String time,
    required String type,
    required String title,
    required String location,
    required String pieces,
    String? date,
    String? address,
    String? contactName,
    String? contactPhone,
    required String status,
    String? pickupLocation,
    String? dropLocation,
    String? additionalInfo,
  }) {
    return Container(
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

          /// Type badge
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: width * 0.03,
              vertical: height * 0.005,
            ),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              type,
              style: TextStyle(
                fontSize: width * 0.035,
                fontWeight: FontWeight.w500,
              ),
            ),
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

          /// Availability specific section
          if (status == 'availability') ...[
            _buildLocationRow(
              width,
              height,
              Icons.circle,
              Colors.green,
              'Pickup location',
              pickupLocation!,
            ),
            SizedBox(height: height * 0.01),
            _buildLocationRow(
              width,
              height,
              Icons.circle,
              Colors.red,
              'Drop location',
              dropLocation!,
            ),
            SizedBox(height: height * 0.015),
            Text(
              pieces,
              style: TextStyle(
                fontSize: width * 0.04,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              additionalInfo!,
              style: TextStyle(
                fontSize: width * 0.032,
                color: Colors.grey,
              ),
            ),
          ] else ...[
            /// Default info section
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
                if (date != null) ...[
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
              ],
            ),
            if (address != null) ...[
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
            ],
            if (contactName != null && contactPhone != null) ...[
              SizedBox(height: height * 0.015),
              Row(
                children: [
                  Icon(Icons.person_outline, size: width * 0.045, color: Colors.grey.shade700),
                  SizedBox(width: width * 0.02),
                  Text(
                    contactName,
                    style: TextStyle(
                      fontSize: width * 0.038,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.phone_outlined, size: width * 0.045, color: Colors.grey.shade700),
                  SizedBox(width: width * 0.02),
                  Text(
                    contactPhone,
                    style: TextStyle(
                      fontSize: width * 0.038,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ],
              ),
            ],
          ],

          SizedBox(height: height * 0.02),

          /// Action buttons
          if (status == 'pending') ...[
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {},
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      padding: EdgeInsets.symmetric(vertical: height * 0.015),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      'Accept',
                      style: TextStyle(
                        fontSize: width * 0.04,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: width * 0.03),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {},
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      padding: EdgeInsets.symmetric(vertical: height * 0.015),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      'Reject',
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
                        builder: (context) => EditHatcheryDetailsScreen(
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
          ] else if (status == 'availability') ...[
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {},
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      padding: EdgeInsets.symmetric(vertical: height * 0.015),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      'Accept',
                      style: TextStyle(
                        fontSize: width * 0.04,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: width * 0.03),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {},
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      padding: EdgeInsets.symmetric(vertical: height * 0.015),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      'Reject',
                      style: TextStyle(
                        fontSize: width * 0.04,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: width * 0.03),
                Container(
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
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLocationRow(
    double width,
    double height,
    IconData icon,
    Color iconColor,
    String label,
    String value,
  ) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(2),
          child: Icon(
            icon,
            size: width * 0.03,
            color: iconColor,
          ),
        ),
        SizedBox(width: width * 0.02),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: width * 0.028,
                color: Colors.grey,
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: width * 0.038,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
