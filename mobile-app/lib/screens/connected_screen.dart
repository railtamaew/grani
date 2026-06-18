import 'package:flutter/material.dart';
import '../theme.dart';

class ConnectedScreen extends StatelessWidget {
  const ConnectedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GraniTheme.primaryBackground,
      body: Center(
        child: Text(
          'Connected Screen',
          style: TextStyle(color: GraniTheme.primaryText),
        ),
      ),
    );
  }
}
