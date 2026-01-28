class User {
  final int id;
  final String name;
  final String mobile;
  final String bestSeedsId;
  final String token;
  final bool isProfileComplete;
  final String role;
  final String? alternateMobile;
  final String? address;
  final String? pincode;
  final String? profileImage;

  User({
    required this.id,
    required this.name,
    required this.mobile,
    required this.bestSeedsId,
    required this.token,
    required this.isProfileComplete,
    required this.role,
    this.alternateMobile,
    this.address,
    this.pincode,
    this.profileImage,
  });

  factory User.fromApi(Map<String, dynamic> vendor, String token) {
    return User(
      id: vendor['id'],
      name: vendor['name'] ?? '',
      mobile: vendor['mobile'] ?? '',
      bestSeedsId: vendor['best_seeds_id'] ?? '',
      token: token,
      isProfileComplete: vendor['is_profile_complete'] ?? false,
      role: 'Employee',
      alternateMobile: vendor['alternate_mobile'],
      address: vendor['address'],
      pincode: vendor['pincode'],
      profileImage: vendor['profile_image'],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mobile': mobile,
        'best_seeds_id': bestSeedsId,
        'token': token,
        'is_profile_complete': isProfileComplete,
        'role': role,
        'alternate_mobile': alternateMobile,
        'address': address,
        'pincode': pincode,
        'profile_image': profileImage,
      };

  String get fullProfileImageUrl {
    if (profileImage == null || profileImage!.isEmpty) return '';
    if (profileImage!.startsWith('http')) return profileImage!;
    return 'https://aliceblue-wallaby-326294.hostingersite.com/$profileImage';
  }
}
