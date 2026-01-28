import 'package:flutter/material.dart';

class EditHatcheryDetailsScreen extends StatefulWidget {
  final String bookingId;
  final String title;
  final String time;

  const EditHatcheryDetailsScreen({
    super.key,
    required this.bookingId,
    required this.title,
    required this.time,
  });

  @override
  State<EditHatcheryDetailsScreen> createState() => _EditHatcheryDetailsScreenState();
}

class _EditHatcheryDetailsScreenState extends State<EditHatcheryDetailsScreen> {
  final TextEditingController _piecesController = TextEditingController(text: '12,000');
  final TextEditingController _dropLocationController = TextEditingController(text: '9-186, Prakash Nagar, Hyderabad, Telangan...');
  final TextEditingController _preferredDateController = TextEditingController(text: '28/12/2025');
  final TextEditingController _travelCostController = TextEditingController(text: '₹5,000');
  final TextEditingController _expectedDeliveryController = TextEditingController(text: '29/12/2025');
  final TextEditingController _bookingDescriptionController = TextEditingController(text: '9-186, Prakash Nagar, Hyderabad, Telangan...');
  final TextEditingController _vehicleDescriptionController = TextEditingController(text: '9-186, Prakash Nagar, Hyderabad, Telangan...');

  String selectedSeedType = 'Syaqua';
  final List<String> seedTypes = ['Syaqua', 'Vannamei', 'Tiger Shrimp', 'Black Tiger'];

  @override
  void dispose() {
    _piecesController.dispose();
    _dropLocationController.dispose();
    _preferredDateController.dispose();
    _travelCostController.dispose();
    _expectedDeliveryController.dispose();
    _bookingDescriptionController.dispose();
    _vehicleDescriptionController.dispose();
    super.dispose();
  }

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
                    SizedBox(height: height * 0.015),

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

                    /// Seed Type Dropdown
                    _buildDropdownField(width, height, 'Seed Type', selectedSeedType, seedTypes, (value) {
                      setState(() {
                        selectedSeedType = value!;
                      });
                    }),
                    SizedBox(height: height * 0.025),

                    /// Pieces
                    _buildTextField(width, height, 'Pieces', _piecesController),
                    SizedBox(height: height * 0.025),

                    /// Drop location
                    _buildTextField(width, height, 'Drop location', _dropLocationController),
                    SizedBox(height: height * 0.025),

                    /// Preferred Date
                    _buildTextField(width, height, 'Preferred Date', _preferredDateController),
                    SizedBox(height: height * 0.025),

                    /// Travel Cost
                    _buildTextField(width, height, 'Travel Cost', _travelCostController),
                    SizedBox(height: height * 0.025),

                    /// Expected Delivery Date
                    _buildTextField(width, height, 'Expected Delivery Date', _expectedDeliveryController),
                    SizedBox(height: height * 0.025),

                    /// Booking Description
                    _buildTextArea(width, height, 'Booking Description', _bookingDescriptionController),
                    SizedBox(height: height * 0.025),

                    /// Vehicle Description
                    _buildTextArea(width, height, 'Vehicle Description', _vehicleDescriptionController),
                    SizedBox(height: height * 0.03),

                    /// Driver Buttons
                    Row(
                      children: [
                        Expanded(
                          child: _buildOutlineButton(width, height, 'Assigned Driver', Icons.add),
                        ),
                        SizedBox(width: width * 0.04),
                        Expanded(
                          child: _buildOutlineButton(width, height, 'Add  Driver', Icons.add),
                        ),
                      ],
                    ),
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
            'Edit Hatchery Details',
            style: TextStyle(
              fontSize: width * 0.048,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdownField(
    double width,
    double height,
    String label,
    String selectedValue,
    List<String> items,
    Function(String?) onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: width * 0.04,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
        SizedBox(height: height * 0.01),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: width * 0.04,
            vertical: height * 0.005,
          ),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: selectedValue,
              isExpanded: true,
              icon: Icon(
                Icons.keyboard_arrow_down,
                size: width * 0.06,
                color: Colors.black,
              ),
              style: TextStyle(
                fontSize: width * 0.04,
                color: Colors.grey.shade700,
              ),
              items: items.map((String value) {
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(value),
                );
              }).toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTextField(
    double width,
    double height,
    String label,
    TextEditingController controller,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: width * 0.04,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
        SizedBox(height: height * 0.01),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: width * 0.04,
            vertical: height * 0.005,
          ),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
          ),
          child: TextField(
            controller: controller,
            style: TextStyle(
              fontSize: width * 0.04,
              color: Colors.grey.shade700,
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTextArea(
    double width,
    double height,
    String label,
    TextEditingController controller,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: width * 0.04,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
        SizedBox(height: height * 0.01),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: width * 0.04,
            vertical: height * 0.01,
          ),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
          ),
          child: TextField(
            controller: controller,
            maxLines: 3,
            style: TextStyle(
              fontSize: width * 0.04,
              color: Colors.grey.shade700,
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOutlineButton(double width, double height, String label, IconData icon) {
    return GestureDetector(
      onTap: () {
        _showAddDriverBottomSheet(context);
      },
      child: Container(
        padding: EdgeInsets.symmetric(
          vertical: height * 0.018,
        ),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: width * 0.05,
              color: Colors.black,
            ),
            SizedBox(width: width * 0.02),
            Text(
              label,
              style: TextStyle(
                fontSize: width * 0.038,
                fontWeight: FontWeight.w500,
                color: Colors.black,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddDriverBottomSheet(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    final TextEditingController driverNameController = TextEditingController();
    final TextEditingController driverMobileController = TextEditingController(text: '12,000');
    final TextEditingController vehicleNumberController = TextEditingController(text: '12,000');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          height: height * 0.75,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: Column(
            children: [
              /// ================= Header =================
              Container(
                padding: EdgeInsets.all(width * 0.05),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.grey.shade200,
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Adding Driver Details',
                      style: TextStyle(
                        fontSize: width * 0.048,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),

              /// ================= Content =================
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(width * 0.05),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      /// Booking Info Card
                      Container(
                        padding: EdgeInsets.all(width * 0.04),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '25 Dec 2025',
                              style: TextStyle(
                                fontSize: width * 0.04,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: height * 0.015),
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
                            SizedBox(height: height * 0.015),
                            Text(
                              widget.title,
                              style: TextStyle(
                                fontSize: width * 0.04,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'Syaqua',
                              style: TextStyle(
                                fontSize: width * 0.035,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: height * 0.03),

                      /// Driver Details Section
                      Text(
                        'Driver Details',
                        style: TextStyle(
                          fontSize: width * 0.042,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: height * 0.02),

                      /// Driver Name
                      Text(
                        'Driver Name',
                        style: TextStyle(
                          fontSize: width * 0.038,
                          fontWeight: FontWeight.w500,
                          color: Colors.black87,
                        ),
                      ),
                      SizedBox(height: height * 0.01),
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: width * 0.04,
                          vertical: height * 0.005,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: TextField(
                          controller: driverNameController,
                          style: TextStyle(
                            fontSize: width * 0.04,
                            color: Colors.grey.shade700,
                          ),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(vertical: 12),
                            hintText: '12,000',
                            hintStyle: TextStyle(
                              color: Colors.grey.shade400,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: height * 0.025),

                      /// Driver Mobile Number
                      Text(
                        'Driver Mobile Number',
                        style: TextStyle(
                          fontSize: width * 0.038,
                          fontWeight: FontWeight.w500,
                          color: Colors.black87,
                        ),
                      ),
                      SizedBox(height: height * 0.01),
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: width * 0.04,
                          vertical: height * 0.005,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: TextField(
                          controller: driverMobileController,
                          keyboardType: TextInputType.phone,
                          style: TextStyle(
                            fontSize: width * 0.04,
                            color: Colors.grey.shade700,
                          ),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      SizedBox(height: height * 0.025),

                      /// Vehicle Number
                      Text(
                        'Vehicle Number',
                        style: TextStyle(
                          fontSize: width * 0.038,
                          fontWeight: FontWeight.w500,
                          color: Colors.black87,
                        ),
                      ),
                      SizedBox(height: height * 0.01),
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: width * 0.04,
                          vertical: height * 0.005,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: TextField(
                          controller: vehicleNumberController,
                          style: TextStyle(
                            fontSize: width * 0.04,
                            color: Colors.grey.shade700,
                          ),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      SizedBox(height: height * 0.05),
                    ],
                  ),
                ),
              ),

              /// ================= Assign Driver Button =================
              Container(
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
                      'Assign Driver',
                      style: TextStyle(
                        fontSize: width * 0.045,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
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
