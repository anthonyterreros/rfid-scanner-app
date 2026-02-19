import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:test_app/services/socket_service.dart';

class StatePage extends StatelessWidget {
  const StatePage({super.key});

  @override
  Widget build(BuildContext context) {
    final socketService = Provider.of<SocketService>(context);

    return Scaffold(body: Center(child: Text('Page')));
  }
}
