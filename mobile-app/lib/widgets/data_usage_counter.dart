import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/vpn_service.dart';
import '../theme.dart';

/// Виджет для отображения счетчика мегабайтов (входящий/исходящий трафик)
/// Согласно Figma: connection_stats_label показывает статистику использования трафика
class DataUsageCounter extends StatelessWidget {
  final double scaleX;
  final double scaleY;

  const DataUsageCounter({
    super.key,
    required this.scaleX,
    required this.scaleY,
  });

  /// Форматирует байты в мегабайты с 2 знаками после запятой
  String _formatBytesToMB(int bytes) {
    if (bytes == 0) return '0';
    final mb = bytes / (1024 * 1024);
    if (mb < 0.01) return '<0.01';
    return mb.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<VpnService>(
      builder: (context, vpnService, child) {
        final isConnected = vpnService.isConnected;
        final totalBytesReceived = vpnService.totalBytesReceived;
        final totalBytesSent = vpnService.totalBytesSent;
        final totalBytes = totalBytesReceived + totalBytesSent;
        
        // Если не подключено, показываем 0
        if (!isConnected) {
          return Text(
            '0 МБ',
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontWeight: FontWeight.w400, // Regular
              fontSize: 12 * scaleX,
              letterSpacing: -0.48 * scaleX, // -0.48px tracking
              height: 0.9, // line-height
              color: const Color(0xFF002C3D), // #002c3d
            ),
          );
        }
        
        // Форматируем общий трафик в мегабайтах
        final totalMB = _formatBytesToMB(totalBytes);
        
        // Из Figma: connection_stats_label показывает статистику
        // Формат: "X МБ" или "X.X МБ"
        return Text(
          '$totalMB МБ',
          style: TextStyle(
            fontFamily: 'Montserrat',
            fontWeight: FontWeight.w400, // Regular
            fontSize: 12 * scaleX,
            letterSpacing: -0.48 * scaleX, // -0.48px tracking
            height: 0.9, // line-height
            color: const Color(0xFF002C3D), // #002c3d
          ),
        );
      },
    );
  }
}

