import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:test_app/pages/bluetooth_scanner.dart';
import 'package:test_app/pages/home.dart';
import 'package:test_app/pages/photo_upload.dart';
import 'package:test_app/pages/status.dart';
import 'package:test_app/services/socket_service.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => SocketService())],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Material App',
        initialRoute: 'bluetooth-scanner',
        routes: {
          'home': (context) => HomePage(),
          'status': (context) => StatePage(),
          'photo-upload': (context) => PhotoUploadPage(),
          'bluetooth-scanner': (context) => BluetoothScannerPage(),
        },
      ),
    );
  }
}
