import 'package:flutter/material.dart';

import 'simple_vpn_controller.dart';

class SimpleVpnScreen extends StatefulWidget {
  const SimpleVpnScreen({super.key});

  @override
  State<SimpleVpnScreen> createState() => _SimpleVpnScreenState();
}

class _SimpleVpnScreenState extends State<SimpleVpnScreen> {
  late final SimpleVpnController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SimpleVpnController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final state = _controller.state;
        final isConnected = state == SimpleVpnState.connected;
        final isBusy = _controller.isBusy;
        final buttonText = isConnected
            ? 'Отключить'
            : isBusy
                ? 'Подключаем...'
                : 'Подключить';
        final statusText = switch (state) {
          SimpleVpnState.connected => 'Подключено',
          SimpleVpnState.connecting => 'Подключение',
          SimpleVpnState.disconnecting => 'Отключение',
          SimpleVpnState.error => 'Ошибка подключения',
          SimpleVpnState.disconnected => 'Отключено',
        };

        return Scaffold(
          backgroundColor: const Color(0xFFF7F9FA),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Image.asset(
                        'assets/images/figma/logo_grani_new.png',
                        height: 32,
                        errorBuilder: (_, __, ___) => const Text(
                          'GRANI',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0,
                          ),
                        ),
                      ),
                      const Spacer(),
                      _StatusDot(active: isConnected, busy: isBusy),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    statusText,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF101828),
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _controller.serverName,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 16,
                      color: Color(0xFF667085),
                      letterSpacing: 0,
                    ),
                  ),
                  if (_controller.error != null) ...[
                    const SizedBox(height: 18),
                    Text(
                      _controller.error!,
                      textAlign: TextAlign.center,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFFB42318),
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                  const Spacer(),
                  SizedBox(
                    height: 58,
                    child: FilledButton(
                      onPressed: isBusy ? null : _controller.toggle,
                      style: FilledButton.styleFrom(
                        backgroundColor: isConnected
                            ? const Color(0xFF344054)
                            : const Color(0xFF175CD3),
                        disabledBackgroundColor: const Color(0xFF98A2B3),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: isBusy
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              buttonText,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 18),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.active, required this.busy});

  final bool active;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final color = busy
        ? const Color(0xFFF79009)
        : active
            ? const Color(0xFF12B76A)
            : const Color(0xFF98A2B3);
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}
