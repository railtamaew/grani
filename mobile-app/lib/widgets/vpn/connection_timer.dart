import 'package:flutter/material.dart';
import 'dart:async';
import '../../theme.dart';

class ConnectionTimer extends StatefulWidget {
  final DateTime startTime;

  const ConnectionTimer({
    super.key,
    required this.startTime,
  });

  @override
  State<ConnectionTimer> createState() => _ConnectionTimerState();
}

class _ConnectionTimerState extends State<ConnectionTimer> {
  late Timer _timer;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _updateDuration();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateDuration();
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  void _updateDuration() {
    setState(() {
      _duration = DateTime.now().difference(widget.startTime);
    });
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String hours = twoDigits(duration.inHours);
    String minutes = twoDigits(duration.inMinutes.remainder(60));
    String seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$hours:$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: GraniTheme.connectedStatus.withOpacity(0.1),
        borderRadius: BorderRadius.circular(GraniTheme.radiusMedium),
        border: Border.all(
          color: GraniTheme.connectedStatus.withOpacity(0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.timer,
            color: GraniTheme.connectedStatus,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            _formatDuration(_duration),
            style: TextStyle(
              color: GraniTheme.connectedStatus,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}
