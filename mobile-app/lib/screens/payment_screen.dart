import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme.dart';
import '../widgets/custom_widgets.dart';
import '../services/auth_service.dart';
import '../l10n/l10n.dart';

/// Экран выбора тарифа. При появлении обновляет статус с сервера:
/// если доступ выдан (триал или подписка), переходит на /main.
class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  /// Обновление статуса — только по явному действию (кнопка «Обновить»).
  /// Авто-редирект из initState убран по плану оптимизации.
  Future<void> _refreshAndNavigate() async {
    if (!mounted) return;
    final authService = Provider.of<AuthService>(context, listen: false);
    await authService.refreshUserStatus();
    if (!mounted) return;
    if (authService.hasActiveSubscription ||
        (authService.trialSecondsLeft ?? 0) > 0) {
      Navigator.pushReplacementNamed(context, '/main');
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Color(0xFFFFFFFF),
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFFF7F9FA),
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: GraniTheme.primaryBackground,
        body: SafeArea(
          child: Column(
            children: [
              // Logo
              const Padding(
                padding: EdgeInsets.only(top: 40),
                child: LogoWidget(),
              ),

              // Main Image
              Expanded(
                flex: 2,
                child: Center(
                  child: SizedBox(
                    width: 150,
                    height: 150,
                    child: Image.asset(
                      'assets/images/figma/pic1_welcome_babushka.png',
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          color: Colors.grey[300],
                          child: const Icon(Icons.person, size: 60),
                        );
                      },
                    ),
                  ),
                ),
              ),

              // Bottom Card with Payment Options
              Expanded(
                flex: 3,
                child: Container(
                  margin: const EdgeInsets.symmetric(
                      horizontal: GraniTheme.paddingLarge),
                  decoration: GraniTheme.graniSurfaceDecoration(
                    radius: GraniTheme.radiusSurface,
                  ),
                  child: Column(
                    children: [
                      // Header Text
                      Padding(
                        padding: const EdgeInsets.all(GraniTheme.paddingXLarge),
                        child: Column(
                          children: [
                            Text(
                              l10n.trialExpiredTitle,
                              style: GraniTheme.headingSmall,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: GraniTheme.paddingSmall),
                            Text(
                              l10n.trialExpiredSubtitle,
                              style: GraniTheme.bodyLarge,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),

                      // Tariff Options
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: GraniTheme.paddingLarge),
                          child: Column(
                            children: [
                              // 1 Month Tariff
                              _buildTariffCard(
                                title: l10n.paymentTariffTitleOneMonth,
                                price: l10n.paymentTariffPriceMonthly,
                                description: l10n.paymentTariffDescMonthly,
                                isSelected: false,
                                onTap: () {
                                  Navigator.pushNamed(context, '/subscription');
                                },
                              ),

                              const SizedBox(height: GraniTheme.paddingLarge),

                              // 6 Months Tariff
                              _buildTariffCard(
                                title: l10n.paymentTariffTitleSixMonths,
                                price: l10n.paymentTariffPriceSixMonth,
                                description: l10n.paymentTariffDescSixMonth,
                                isSelected: true,
                                isPopular: true,
                                onTap: () {
                                  Navigator.pushNamed(context, '/subscription');
                                },
                              ),

                              const SizedBox(height: GraniTheme.paddingLarge),

                              // 1 Year Tariff
                              _buildTariffCard(
                                title: l10n.paymentTariffTitleOneYear,
                                price: l10n.paymentTariffPriceYearly,
                                description: l10n.paymentTariffDescYearly,
                                isSelected: false,
                                onTap: () {
                                  Navigator.pushNamed(context, '/subscription');
                                },
                              ),

                              const SizedBox(height: GraniTheme.paddingLarge),

                              // Кнопка тестирования (скрытая)
                              GestureDetector(
                                onLongPress: () {
                                  Navigator.pushNamed(context, '/test');
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  child: Text(
                                    l10n.termsOfUseLink,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF7F8C8D),
                                      decoration: TextDecoration.underline,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Protocol Indicators
                      Padding(
                        padding: const EdgeInsets.all(GraniTheme.paddingLarge),
                        child: Wrap(
                          spacing: GraniTheme.paddingLarge,
                          runSpacing: GraniTheme.paddingMedium,
                          children: const [
                            ProtocolIndicator(
                              protocol: 'Xray',
                              isActive: true,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTariffCard({
    required String title,
    required String price,
    required String description,
    required bool isSelected,
    bool isPopular = false,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 76,
        decoration: GraniTheme.graniSurfaceDecoration(
          radius: GraniTheme.radiusXLarge,
          borderOpacity: isSelected ? 0.96 : 0.82,
        ),
        child: Stack(
          children: [
            // Background
            Container(
              margin: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                gradient: GraniTheme.surfaceControlGradient,
                borderRadius: BorderRadius.circular(GraniTheme.radiusXLarge),
                border: Border.all(
                  color: GraniTheme.surfaceControlBorder.withOpacity(0.72),
                ),
              ),
            ),

            // Selected indicator
            if (isSelected)
              Positioned(
                left: 9,
                top: 6,
                child: Container(
                  width: 169,
                  height: 65,
                  decoration: BoxDecoration(
                    color: isPopular
                        ? GraniTheme.tariffYellow
                        : GraniTheme.tariffTeal,
                    borderRadius:
                        BorderRadius.circular(GraniTheme.radiusXLarge),
                    boxShadow: [
                      BoxShadow(
                        color: isPopular
                            ? const Color(0xFF886D1A)
                            : const Color(0xFF546467),
                        blurRadius: 0,
                        offset: const Offset(2, 2),
                      ),
                      BoxShadow(
                        color: isPopular
                            ? const Color(0xFFF8E8BA)
                            : const Color(0xFFC3E0E5),
                        blurRadius: 1,
                        offset: const Offset(-2, -2),
                      ),
                    ],
                  ),
                ),
              ),

            // Content
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(GraniTheme.paddingLarge),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            title,
                            style: GraniTheme.tariffTitle.copyWith(
                              color: isSelected
                                  ? GraniTheme.white
                                  : GraniTheme.buttonSecondary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            description,
                            style: GraniTheme.tariffDescription,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Text(
                      price,
                      style: GraniTheme.tariffPrice,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
