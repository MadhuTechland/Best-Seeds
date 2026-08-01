/// An admin announcement targeted at the driver or vendor audience.
///
/// Served by GET /api/{driver|vendor}/announcements (list) and
/// GET /api/{driver|vendor}/announcements/popup (the one to show as a dialog).
class AnnouncementModel {
  final int id;
  final String title;
  final String description;
  final String? image;
  final bool isRead;
  final String? createdAt;

  AnnouncementModel({
    required this.id,
    required this.title,
    required this.description,
    this.image,
    this.isRead = false,
    this.createdAt,
  });

  factory AnnouncementModel.fromJson(Map<String, dynamic> json) {
    final image = json['image']?.toString();

    return AnnouncementModel(
      id: int.tryParse('${json['id']}') ?? 0,
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      image: (image == null || image.isEmpty) ? null : image,
      isRead: json['is_read'] == true,
      createdAt: json['created_at']?.toString(),
    );
  }

  AnnouncementModel copyWith({bool? isRead}) {
    return AnnouncementModel(
      id: id,
      title: title,
      description: description,
      image: image,
      isRead: isRead ?? this.isRead,
      createdAt: createdAt,
    );
  }

  DateTime? get createdDateTime {
    if (createdAt == null) return null;
    return DateTime.tryParse(createdAt!)?.toLocal();
  }
}
