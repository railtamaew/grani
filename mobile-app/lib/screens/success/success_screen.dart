import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/auth_service.dart';
import '../../config/app_config.dart';
import '../../config/theme.dart';
import '../../widgets/custom_widgets.dart';

class SuccessScreen extends StatefulWidget {
  const SuccessScreen({super.key});

  @override
  State<SuccessScreen> createState() => _SuccessScreenState();
}

class _SuccessScreenState extends State<SuccessScreen> with TickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _progressAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );
    _progressAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              const SizedBox(height: 60),
              
              // Логотип
              _buildLogo(),
              
              const SizedBox(height: 40),
              
              // Маскот с большим пальцем
              _buildMascot(),
              
              const SizedBox(height: 40),
              
              // Заголовок успеха
              _buildTitle(),
              
              const SizedBox(height: 12),
              
              // Описание
              _buildDescription(),
              
              const Spacer(),
              
              // Карточка с щитом и прогресс-кольцом
              _buildSuccessCard(),
              
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return const LogoWidget();
  }

  Widget _buildMascot() {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: const Color(0xFF34495E),
        borderRadius: BorderRadius.circular(40),
      ),
      child: const Icon(
        Icons.thumb_up,
        color: Colors.white,
        size: 40,
      ),
    );
  }

  Widget _buildTitle() {
    return const Text(
      'Успешно!',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.bold,
        color: Color(0xFF2C3E50),
        height: 1.2,
      ),
    );
  }

  Widget _buildDescription() {
    return const Text(
      'Идет настройка безопасного подключения',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 12,
        color: Color(0xFF7F8C8D),
        height: 1.3,
      ),
    );
  }

  Widget _buildSuccessCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        children: [
          // Щит с галочкой и прогресс-кольцо
          SizedBox(
            width: 120,
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Прогресс-кольцо
                AnimatedBuilder(
                  animation: _progressAnimation,
                  builder: (context, child) {
                    return SizedBox(
                      width: 120,
                      height: 120,
                      child: CircularProgressIndicator(
                        value: _progressAnimation.value,
                        strokeWidth: 8,
                        backgroundColor: const Color(0xFFE8F5E8),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFF27AE60),
                        ),
                      ),
                    );
                  },
                ),
                
                // Щит с галочкой
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: const Color(0xFF27AE60),
                    borderRadius: BorderRadius.circular(40),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF27AE60).withOpacity(0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.check,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 20),
          
          // Текст статуса
          const Text(
            'Подключение установлено',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF27AE60),
            ),
          ),
          
          const SizedBox(height: 8),
          
          const Text(
            'Ваше соединение защищено',
            style: TextStyle(
              fontSize: 12,
              color: Color(0xFF7F8C8D),
            ),
          ),
        ],
      ),
    );
  }
}
