import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/tracking_logger.dart';

/// Live-tailing viewer for the driver-side tracking log ring buffer.
///
/// Pulls fresh logs from SharedPreferences every 2 seconds so the
/// developer can watch location updates arriving in real time. Logs
/// come from both the main isolate (UI, lifecycle) and the background
/// location isolate (stream, sendPosition, watchdog) so nothing on the
/// tracking path is invisible.
class TrackingLogsScreen extends StatefulWidget {
  const TrackingLogsScreen({super.key});

  @override
  State<TrackingLogsScreen> createState() => _TrackingLogsScreenState();
}

class _TrackingLogsScreenState extends State<TrackingLogsScreen> {
  List<String> _logs = const <String>[];
  Timer? _refreshTimer;
  bool _autoScroll = true;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadLogs();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _loadLogs(),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadLogs() async {
    final fresh = await TrackingLogger.getLogs();
    if (!mounted) return;
    // Reverse so newest is at the top — easier to follow a live trail.
    setState(() => _logs = fresh.reversed.toList());
    if (_autoScroll && _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear tracking logs?'),
        content: const Text(
            'This empties the local log buffer for this device. '
            'Past logs already sent to the backend are not affected.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await TrackingLogger.clear();
      await _loadLogs();
    }
  }

  Future<void> _copyAll() async {
    if (_logs.isEmpty) return;
    // _logs is newest-first; copy in chronological order so pasted
    // output reads top-to-bottom like a normal log file.
    final joined = _logs.reversed.join('\n');
    await Clipboard.setData(ClipboardData(text: joined));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied ${_logs.length} log lines'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Color _colorFor(String line) {
    if (line.contains('✗')) return const Color(0xFFE53935); // red
    if (line.contains('✓')) return const Color(0xFF43A047); // green
    if (line.contains('⟲') || line.contains('⏰')) {
      return const Color(0xFFEF6C00); // orange
    }
    if (line.contains('◉') || line.contains('▶') || line.contains('■')) {
      return const Color(0xFF1E88E5); // blue
    }
    return const Color(0xFF424242); // default
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B1B1B),
        foregroundColor: Colors.white,
        title: Text('Tracking Logs (${_logs.length})'),
        actions: [
          IconButton(
            tooltip: _autoScroll ? 'Auto-scroll ON' : 'Auto-scroll OFF',
            icon: Icon(_autoScroll
                ? Icons.vertical_align_top
                : Icons.vertical_align_center),
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy),
            onPressed: _copyAll,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loadLogs,
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_outline),
            onPressed: _confirmClear,
          ),
        ],
      ),
      body: _logs.isEmpty
          ? const Center(
              child: Text(
                'No logs yet.\nStart a journey to begin capturing.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
            )
          : ListView.separated(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              itemCount: _logs.length,
              separatorBuilder: (_, __) =>
                  const Divider(color: Color(0xFF2A2A2A), height: 1),
              itemBuilder: (context, index) {
                final line = _logs[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: SelectableText(
                    line,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.35,
                      color: _colorFor(line),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
