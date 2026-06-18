import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/server.dart';
import '../../theme.dart';
import '../animated_card.dart';

class ServerCard extends StatelessWidget {
  final Server server;
  final bool isSelected;
  final VoidCallback? onTap;
  final int index;

  const ServerCard({
    super.key,
    required this.server,
    this.isSelected = false,
    this.onTap,
    this.index = 0,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedCard(
      index: index,
      margin: const EdgeInsets.symmetric(vertical: 8),
      color: isSelected 
          ? GraniTheme.xrayActive.withOpacity(0.1)
          : GraniTheme.cardBackground,
      borderRadius: BorderRadius.circular(GraniTheme.radiusMedium),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(GraniTheme.radiusMedium),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Флаг страны
              if (server.flagUrl != null)
                Container(
                  width: 40,
                  height: 30,
                  margin: const EdgeInsets.only(right: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: CachedNetworkImage(
                      imageUrl: server.flagUrl!,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        color: Colors.grey[200],
                        child: const Icon(Icons.flag, size: 20),
                      ),
                      errorWidget: (context, url, error) {
                        // Логируем ошибку для отладки, но не показываем пользователю
                        debugPrint('ServerCard: Ошибка загрузки флага: $url, error: $error');
                        return Container(
                          color: Colors.grey[200],
                          child: const Icon(Icons.flag, size: 20),
                        );
                      },
                      // Добавляем обработку ошибок декодирования
                      httpHeaders: const {
                        'Accept': 'image/png,image/jpeg,image/webp,*/*',
                      },
                      // Используем memCacheWidth для оптимизации
                      memCacheWidth: 80,
                      memCacheHeight: 60,
                    ),
                  ),
                ),
              
              // Информация о сервере
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server.displayName,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: isSelected ? GraniTheme.xrayActive : GraniTheme.primaryText,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          Icons.signal_cellular_alt,
                          size: 16,
                          color: Colors.grey[600],
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${server.currentLoad}% загрузка',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Icon(
                          Icons.speed,
                          size: 16,
                          color: Colors.grey[600],
                        ),
                        const SizedBox(width: 4),
                        Text(
                          server.ping != null
                              ? '${server.ping!.toStringAsFixed(0)} ms'
                              : '—',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              
              // Индикатор выбора
              if (isSelected)
                Icon(
                  Icons.check_circle,
                  color: GraniTheme.xrayActive,
                  size: 24,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
