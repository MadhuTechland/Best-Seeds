import 'package:flutter/material.dart';

class EditVehicleDetailsScreen extends StatefulWidget {
  final String bookingId;
  final String title;
  final String time;

  const EditVehicleDetailsScreen({
    super.key,
    required this.bookingId,
    required this.title,
    required this.time,
  });

  @override
  State<EditVehicleDetailsScreen> createState() => _EditVehicleDetailsScreenState();
}

class _EditVehicleDetailsScreenState extends State<EditVehicleDetailsScreen> {
  int selectedStatusIndex = 0;
  String selectedDropdown1 = 'Pending';
  String selectedDropdown2 = 'Pending';
  String selectedDropdown3 = 'Pending';

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            /// ================= Header =================
            _buildHeader(context, width, height),

            /// ================= Content =================
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(width * 0.05),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    /// Title
                    Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: width * 0.048,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: height * 0.01),

                    /// Booking ID and Time
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          widget.bookingId,
                          style: TextStyle(
                            fontSize: width * 0.038,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        Text(
                          widget.time,
                          style: TextStyle(
                            fontSize: width * 0.032,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: height * 0.03),

                    /// Driver Details Section
                    _buildDriverDetails(width, height),
                    SizedBox(height: height * 0.03),

                    /// Vehicle Status Section
                    _buildVehicleStatus(width, height),
                    SizedBox(height: height * 0.03),

                    /// Expected Delivery Date
                    _buildExpectedDeliveryDate(width, height),
                    SizedBox(height: height * 0.03),

                    /// Booking Description
                    _buildTextFieldSection(
                      width,
                      height,
                      'Booking Description',
                      '9-186, Prakash Nagar, Hyderabad, Telangan...',
                    ),
                    SizedBox(height: height * 0.03),

                    /// Vehicle Description
                    _buildTextFieldSection(
                      width,
                      height,
                      'Vehicle Description',
                      '9-186, Prakash Nagar, Hyderabad, Telangan...',
                    ),
                    SizedBox(height: height * 0.03),

                    /// Drop Locations
                    _buildDropLocations(width, height),
                    SizedBox(height: height * 0.1),
                  ],
                ),
              ),
            ),

            /// ================= Save Button =================
            _buildSaveButton(width, height),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, double width, double height) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: width * 0.05,
        vertical: height * 0.02,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(
            color: Colors.grey.shade200,
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              Navigator.pop(context);
            },
            child: Icon(
              Icons.arrow_back,
              size: width * 0.06,
              color: Colors.black,
            ),
          ),
          SizedBox(width: width * 0.03),
          Text(
            'Edit Vehicle Details',
            style: TextStyle(
              fontSize: width * 0.048,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDriverDetails(double width, double height) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Driver Details',
              style: TextStyle(
                fontSize: width * 0.042,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'Change Driver',
              style: TextStyle(
                fontSize: width * 0.038,
                color: Colors.grey.shade600,
              ),
            ),
          ],
        ),
        SizedBox(height: height * 0.015),
        Container(
          padding: EdgeInsets.all(width * 0.04),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(
                    Icons.person_outline,
                    size: width * 0.05,
                    color: Colors.grey.shade700,
                  ),
                  SizedBox(width: width * 0.03),
                  Text(
                    'Ramesh',
                    style: TextStyle(
                      fontSize: width * 0.04,
                      color: Colors.grey.shade800,
                    ),
                  ),
                  SizedBox(width: width * 0.06),
                  Icon(
                    Icons.phone_outlined,
                    size: width * 0.05,
                    color: Colors.grey.shade700,
                  ),
                  SizedBox(width: width * 0.03),
                  Text(
                    '+918975745',
                    style: TextStyle(
                      fontSize: width * 0.04,
                      color: Colors.grey.shade800,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.edit_outlined,
                    size: width * 0.05,
                    color: Colors.grey.shade600,
                  ),
                ],
              ),
              SizedBox(height: height * 0.015),
              Row(
                children: [
                  Icon(
                    Icons.local_shipping_outlined,
                    size: width * 0.05,
                    color: Colors.grey.shade700,
                  ),
                  SizedBox(width: width * 0.03),
                  Text(
                    'TSN05656',
                    style: TextStyle(
                      fontSize: width * 0.04,
                      color: Colors.grey.shade800,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.delete_outline,
                    size: width * 0.05,
                    color: Colors.grey.shade600,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildVehicleStatus(double width, double height) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Vehicle Status',
          style: TextStyle(
            fontSize: width * 0.042,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: height * 0.015),
        Row(
          children: [
            _buildStatusOption(0, 'Journey Started', width),
            SizedBox(width: width * 0.03),
            _buildStatusOption(1, 'In progress', width),
            SizedBox(width: width * 0.03),
            _buildStatusOption(2, 'Delivered', width),
          ],
        ),
      ],
    );
  }

  Widget _buildStatusOption(int index, String label, double width) {
    final isSelected = selectedStatusIndex == index;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            selectedStatusIndex = index;
          });
        },
        child: Container(
          padding: EdgeInsets.symmetric(vertical: width * 0.025),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF0077C8).withValues(alpha: 0.1) : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isSelected ? const Color(0xFF0077C8) : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: width * 0.025,
                height: width * 0.025,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isSelected ? const Color(0xFF0077C8) : Colors.grey.shade400,
                ),
              ),
              SizedBox(width: width * 0.02),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: width * 0.03,
                    color: isSelected ? const Color(0xFF0077C8) : Colors.grey.shade700,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpectedDeliveryDate(double width, double height) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Expected Delivery Date',
          style: TextStyle(
            fontSize: width * 0.042,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: height * 0.015),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: width * 0.04,
            vertical: height * 0.018,
          ),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '29/12/2025',
            style: TextStyle(
              fontSize: width * 0.04,
              color: Colors.grey.shade700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTextFieldSection(double width, double height, String label, String hint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: width * 0.042,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: height * 0.015),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: width * 0.04,
            vertical: height * 0.018,
          ),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            hint,
            style: TextStyle(
              fontSize: width * 0.04,
              color: Colors.grey.shade700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDropLocations(double width, double height) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Drop locations',
          style: TextStyle(
            fontSize: width * 0.042,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: height * 0.02),
        _buildDropLocationItem(
          width,
          height,
          1,
          'Rajesh\nPuducherry',
          '9-186, Prakash Nagar,\nHyderabad, Telangana, 500032',
          selectedDropdown1,
          (value) {
            setState(() {
              selectedDropdown1 = value!;
            });
          },
        ),
        SizedBox(height: height * 0.02),
        _buildDropLocationItem(
          width,
          height,
          2,
          'Rajesh\nPuducherry',
          '9-186, Prakash Nagar, Hyderabad,\nTelangana, 500032',
          selectedDropdown2,
          (value) {
            setState(() {
              selectedDropdown2 = value!;
            });
          },
        ),
        SizedBox(height: height * 0.02),
        _buildDropLocationItem(
          width,
          height,
          3,
          'Rajesh\nPuducherry',
          '9-186, Prakash Nagar, Hyderabad,\nTelangana, 500032',
          selectedDropdown3,
          (value) {
            setState(() {
              selectedDropdown3 = value!;
            });
          },
          isLast: true,
        ),
      ],
    );
  }

  Widget _buildDropLocationItem(
    double width,
    double height,
    int number,
    String title,
    String address,
    String selectedValue,
    Function(String?) onChanged, {
    bool isLast = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: width * 0.08,
              height: width * 0.08,
              decoration: const BoxDecoration(
                color: Colors.black,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                '$number',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: width * 0.04,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (!isLast)
              Container(
                width: 2,
                height: height * 0.08,
                color: Colors.grey.shade300,
              ),
          ],
        ),
        SizedBox(width: width * 0.04),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: width * 0.04,
                            fontWeight: FontWeight.bold,
                            height: 1.3,
                          ),
                        ),
                        SizedBox(height: height * 0.005),
                        Text(
                          address,
                          style: TextStyle(
                            fontSize: width * 0.032,
                            color: Colors.grey.shade600,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: width * 0.03,
                      vertical: height * 0.008,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: DropdownButton<String>(
                      value: selectedValue,
                      underline: const SizedBox(),
                      isDense: true,
                      icon: Icon(
                        Icons.arrow_drop_down,
                        size: width * 0.05,
                      ),
                      style: TextStyle(
                        fontSize: width * 0.035,
                        color: Colors.grey.shade700,
                      ),
                      items: ['Pending', 'In Progress', 'Completed']
                          .map((String value) {
                        return DropdownMenuItem<String>(
                          value: value,
                          child: Text(value),
                        );
                      }).toList(),
                      onChanged: onChanged,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSaveButton(double width, double height) {
    return Container(
      padding: EdgeInsets.all(width * 0.05),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: () {
            Navigator.pop(context);
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF0077C8),
            padding: EdgeInsets.symmetric(vertical: height * 0.018),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
          ),
          child: Text(
            'Save Details',
            style: TextStyle(
              fontSize: width * 0.045,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
