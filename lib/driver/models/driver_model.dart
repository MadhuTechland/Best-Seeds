class Driver {
  final int id;
  final String name;
  final String mobile;
  final String? profileImage;
  final int status;
  final String token;

  Driver({
    required this.id,
    required this.name,
    required this.mobile,
    this.profileImage,
    required this.status,
    required this.token,
  });

  factory Driver.fromApi(Map<String, dynamic> json, String token) {
    return Driver(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      mobile: json['mobile'] ?? '',
      profileImage: json['profile_image'],
      status: json['status'] ?? 1,
      token: token,
    );
  }

  factory Driver.fromJson(Map<String, dynamic> json) {
    return Driver(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      mobile: json['mobile'] ?? '',
      profileImage: json['profile_image'],
      status: json['status'] ?? 1,
      token: json['token'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mobile': mobile,
        'profile_image': profileImage,
        'status': status,
        'token': token,
      };

  bool get hasProfile => name.isNotEmpty;

  String get fullProfileImageUrl {
    if (profileImage == null || profileImage!.isEmpty) return '';
    if (profileImage!.startsWith('http')) return profileImage!;
    return 'https://aliceblue-wallaby-326294.hostingersite.com/$profileImage';
  }
}
