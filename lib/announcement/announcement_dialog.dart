import 'package:bestseeds/announcement/announcement_model.dart';
import 'package:flutter/material.dart';

/// The popup an announcement appears in the first time it reaches this user.
///
/// Image (when there is one), title, scrollable description and a close icon —
/// closing is the only way out, and it marks the announcement read so it moves
/// quietly into Profile > Announcements.
class AnnouncementDialog extends StatelessWidget {
  final AnnouncementModel announcement;

  const AnnouncementDialog({super.key, required this.announcement});

  static const Color _brand = Color(0xFF0077C8);

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.75;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Stack(
          children: [
            SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (announcement.image != null)
                    SizedBox(
                      width: double.infinity,
                      height: 180,
                      child: Image.network(
                        announcement.image!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: _brand.withValues(alpha: 0.08),
                          child: const Icon(Icons.campaign_rounded,
                              size: 44, color: _brand),
                        ),
                        loadingBuilder: (context, child, progress) {
                          if (progress == null) return child;
                          return Container(
                            color: Colors.grey.shade100,
                            alignment: Alignment.center,
                            child: const CircularProgressIndicator(
                                strokeWidth: 2),
                          );
                        },
                      ),
                    )
                  else
                    // No image — keep clear of the floating close button.
                    const SizedBox(height: 44),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: _brand.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.campaign_rounded,
                                  size: 18, color: _brand),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                announcement.title,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.black87,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          announcement.description,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.5,
                            color: Colors.grey.shade800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Close (X)
            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.black.withValues(alpha: 0.45),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.of(context).pop(),
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.close_rounded,
                        size: 20, color: Colors.white),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
