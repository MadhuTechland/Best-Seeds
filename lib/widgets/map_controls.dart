import 'package:flutter/material.dart';

/// A circular floating action button for map controls
class MapControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color iconColor;
  final Color backgroundColor;
  final double? size;

  const MapControlButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.iconColor = Colors.black,
    this.backgroundColor = Colors.white,
    this.size,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final buttonSize = size ?? width * 0.03;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(buttonSize),
        decoration: BoxDecoration(
          color: backgroundColor,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(
          icon,
          size: width * 0.05,
          color: iconColor,
        ),
      ),
    );
  }
}

/// A back button specifically for map views
class MapBackButton extends StatelessWidget {
  final VoidCallback onTap;

  const MapBackButton({
    super.key,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MapControlButton(
      icon: Icons.arrow_back,
      onTap: onTap,
    );
  }
}

/// A "my location" / center button for maps
class MapCenterButton extends StatelessWidget {
  final VoidCallback onTap;
  final Color iconColor;

  const MapCenterButton({
    super.key,
    required this.onTap,
    this.iconColor = const Color(0xFF0077C8),
  });

  @override
  Widget build(BuildContext context) {
    return MapControlButton(
      icon: Icons.my_location,
      onTap: onTap,
      iconColor: iconColor,
    );
  }
}

/// A layers button for toggling map types
class MapLayersButton extends StatelessWidget {
  final VoidCallback onTap;

  const MapLayersButton({
    super.key,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(width * 0.02),
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.layers,
          size: width * 0.045,
          color: Colors.black,
        ),
      ),
    );
  }
}

/// A fullscreen/expand button for maps
class MapExpandButton extends StatelessWidget {
  final VoidCallback onTap;

  const MapExpandButton({
    super.key,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(width * 0.02),
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.fullscreen,
          size: width * 0.045,
          color: Colors.black,
        ),
      ),
    );
  }
}
