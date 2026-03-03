import 'package:flutter/material.dart';

class RefreshButton extends StatefulWidget {
  final VoidCallback onTap;

  const RefreshButton({Key? key, required this.onTap}) : super(key: key);

  _RefreshButtonState createState() => _RefreshButtonState();
}

class _RefreshButtonState extends State<RefreshButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 800),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() async {
    _controller.repeat();
    widget.onTap();

    await Future.delayed(Duration(seconds: 1));
    _controller.stop();
    _controller.reset();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return GestureDetector(
        onTap: _handleTap,
        child: Container(
            padding: EdgeInsets.all(width * 0.03),
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
              color: Colors.blue.shade500,
              borderRadius: BorderRadius.circular(12),
            ),
            child: RotationTransition(
                turns: _controller,
                child: Icon(Icons.refresh,
                    color: Colors.white, size: width * 0.06))));
  }
}
