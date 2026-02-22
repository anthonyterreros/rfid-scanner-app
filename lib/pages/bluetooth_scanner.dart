import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:test_app/pages/rfid_reader_page.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Page
// ─────────────────────────────────────────────────────────────────────────────

class BluetoothScannerPage extends StatefulWidget {
  const BluetoothScannerPage({super.key});

  @override
  State<BluetoothScannerPage> createState() => _BluetoothScannerPageState();
}

// Quitamos SingleTickerProviderStateMixin — ya no hay AnimationController
class _BluetoothScannerPageState extends State<BluetoothScannerPage> {
  // ─── State ───────────────────────────────────────────────────────────────
  final Map<DeviceIdentifier, ScanResult> _scanResultsMap = {};
  List<ScanResult> get _scanResults {
    final list = _scanResultsMap.values.toList();
    list.sort((a, b) => b.rssi.compareTo(a.rssi));
    return list;
  }

  BluetoothDevice? _connectedDevice;
  bool _isConnecting = false;
  String? _connectingDeviceId;
  String? _permissionError;

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothAdapterState>? _adapterSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;

  // ─── Lifecycle ───────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _adapterSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (mounted) setState(() => _adapterState = state);
      if (state != BluetoothAdapterState.on) {
        _connectionStateSubscription?.cancel();
        if (mounted) setState(() => _connectedDevice = null);
      }
    });
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _adapterSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    super.dispose();
  }

  // ─── Permissions ─────────────────────────────────────────────────────────
  Future<bool> _requestPermissions() async {
    setState(() => _permissionError = null);

    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();

      final denied = statuses.entries
          .where((e) => !e.value.isGranted)
          .map((e) => e.key.toString().split('.').last)
          .toList();

      if (denied.isNotEmpty) {
        final permanentlyDenied = statuses.entries.any(
          (e) => e.value.isPermanentlyDenied,
        );
        setState(() {
          _permissionError = permanentlyDenied
              ? 'Permisos denegados permanentemente. Ve a Ajustes > Permisos.'
              : 'Permisos requeridos: ${denied.join(', ')}';
        });
        return false;
      }
    } else if (Platform.isIOS) {
      final status = await Permission.bluetooth.request();
      if (!status.isGranted) {
        setState(
          () => _permissionError =
              'Permiso de Bluetooth denegado. Actívalo en Ajustes.',
        );
        return false;
      }
    }
    return true;
  }

  // ─── Scanning ────────────────────────────────────────────────────────────
  Future<void> _startScan() async {
    if (_adapterState != BluetoothAdapterState.on) {
      _showSnack('Activa el Bluetooth para continuar', isError: true);
      return;
    }

    final granted = await _requestPermissions();
    if (!granted) return;

    // Cancelar suscripción anterior para no duplicar listeners
    await _scanSubscription?.cancel();
    setState(() => _scanResultsMap.clear());

    // Escuchar resultados — el Map evita duplicados por remoteId
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        for (final r in results) {
          _scanResultsMap[r.device.remoteId] = r;
        }
      });
    }, onError: (e) => _showSnack('Error de escaneo: $e', isError: true));

    // CLAVE: el FAB usa StreamBuilder sobre FlutterBluePlus.isScanning,
    // por lo que el botón cambia en cuanto el stream emite true/false,
    // sin depender de ninguna variable local ni setState adicional.
    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        androidUsesFineLocation: true,
      );
    } catch (e) {
      _showSnack('No se pudo iniciar el escaneo: $e', isError: true);
    }
  }

  Future<void> _stopScan() async {
    await FlutterBluePlus.stopScan();
    // No necesitamos setState aquí — el StreamBuilder reacciona solo
  }

  // ─── Connection ──────────────────────────────────────────────────────────
  Future<void> _connect(BluetoothDevice device) async {
    if (_isConnecting || _connectedDevice != null) return;

    // Detener el escaneo antes de conectar (crítico en Android)
    print(device);
    if (FlutterBluePlus.isScanningNow) await _stopScan();
    await Future.delayed(const Duration(milliseconds: 300));

    setState(() {
      _isConnecting = true;
      _connectingDeviceId = device.remoteId.str;
    });

    for (int attempt = 1; attempt <= 2; attempt++) {
      try {
        await device.connect(
          timeout: const Duration(seconds: 10),
          autoConnect: false,
        );

        // Escuchar desconexiones inesperadas
        _connectionStateSubscription?.cancel();
        _connectionStateSubscription = device.connectionState.listen((state) {
          if (!mounted) return;
          if (state == BluetoothConnectionState.disconnected) {
            setState(() => _connectedDevice = null);
            _showSnack('Dispositivo desconectado');
          }
        });

        if (mounted) {
          setState(() => _connectedDevice = device);
          _showSnack('Conectado a ${_deviceName(device)}');
        }
        break; // éxito — salir del loop
      } on FlutterBluePlusException catch (e) {
        print(e);
        if (e.code == 147 && attempt < 3) {
          // GATT_CONNECTION_TIMEOUT — esperar y reintentar
          _showSnack('Reintentando conexión ($attempt/3)...', isError: false);
          await Future.delayed(Duration(seconds: attempt * 2));
          continue;
        }
        _showSnack('Error al conectar: ${_friendlyError(e)}', isError: true);
        break;
      } catch (e) {
        _showSnack('Error inesperado: $e', isError: true);
        break;
      }
    }

    if (mounted) {
      setState(() {
        _isConnecting = false;
        _connectingDeviceId = null;
      });
    }
  }

  Future<void> _disconnect() async {
    if (_connectedDevice == null) return;
    final name = _deviceName(_connectedDevice!);
    try {
      _connectionStateSubscription?.cancel();
      await _connectedDevice!.disconnect();
      if (mounted) {
        setState(() => _connectedDevice = null);
        _showSnack('Desconectado de $name');
      }
    } on FlutterBluePlusException catch (e) {
      _showSnack('Error al desconectar: ${_friendlyError(e)}', isError: true);
    }
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────
  String _deviceName(BluetoothDevice d) =>
      d.platformName.isNotEmpty ? d.platformName : d.remoteId.str;

  String _friendlyError(FlutterBluePlusException e) {
    switch (e.code) {
      case 8:
        return 'Timeout — acerca el dispositivo e intenta de nuevo';
      case 133:
        return 'GATT 133 — reinicia el Bluetooth e intenta de nuevo';
      case 6:
        return 'Cancelado por el dispositivo';
      default:
        return e.description ?? 'Código ${e.code}';
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? _AppColors.error : _AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          duration: Duration(seconds: isError ? 4 : 2),
        ),
      );
  }

  String _signalLabel(int rssi) {
    if (rssi >= -60) return 'Fuerte';
    if (rssi >= -75) return 'Buena';
    if (rssi >= -90) return 'Débil';
    return 'Muy débil';
  }

  IconData _signalIcon(int rssi) {
    if (rssi >= -60) return Icons.signal_cellular_alt;
    if (rssi >= -75) return Icons.signal_cellular_alt_2_bar;
    if (rssi >= -90) return Icons.signal_cellular_alt_1_bar;
    return Icons.signal_cellular_0_bar;
  }

  Color _signalColor(int rssi) {
    if (rssi >= -60) return _AppColors.success;
    if (rssi >= -75) return _AppColors.warning;
    return _AppColors.error;
  }

  // ─── Build ───────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _AppColors.bg,
      appBar: _buildAppBar(),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_connectedDevice != null) _buildConnectedBanner(),
          if (_adapterState != BluetoothAdapterState.on) _buildAdapterWarning(),
          if (_permissionError != null) _buildPermissionError(),
          Expanded(child: _buildBody()),
        ],
      ),
      // ── FAB con StreamBuilder ──────────────────────────────────────────
      // Reacciona directamente al stream del stack BLE, sin variable local.
      // Así el botón cambia instantáneamente cuando startScan/stopScan
      // modifica el estado interno de FlutterBluePlus.
      floatingActionButton: StreamBuilder<bool>(
        stream: FlutterBluePlus.isScanning,
        initialData: false,
        builder: (context, snapshot) {
          final isScanning = snapshot.data ?? false;
          return FloatingActionButton.extended(
            onPressed: isScanning ? _stopScan : _startScan,
            backgroundColor: isScanning ? _AppColors.error : _AppColors.accent,
            elevation: 4,
            icon: Icon(
              isScanning ? Icons.stop_rounded : Icons.search_rounded,
              color: Colors.white,
            ),
            label: Text(
              isScanning ? 'Detener' : 'Escanear',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          );
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _AppColors.bgAppBar,
      elevation: 0,
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: _AppColors.textSecondaryAppBar,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.bluetooth, color: _AppColors.accent, size: 22),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'BT Scanner',
                style: TextStyle(
                  color: _AppColors.textPrimaryAppBar,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
              Text(
                '${_scanResults.length} dispositivo${_scanResults.length != 1 ? 's' : ''}',
                style: TextStyle(
                  color: _AppColors.textSecondaryAppBar,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
      // Indicador de escaneo en el AppBar — también via StreamBuilder
      actions: [
        StreamBuilder<bool>(
          stream: FlutterBluePlus.isScanning,
          initialData: false,
          builder: (context, snapshot) {
            if (!(snapshot.data ?? false)) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: _AppColors.accent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _AppColors.accent,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Escaneando',
                      style: TextStyle(
                        color: _AppColors.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildAdapterWarning() => _InfoBanner(
    color: _AppColors.error,
    icon: Icons.bluetooth_disabled,
    message: 'Bluetooth desactivado. Actívalo para escanear.',
  );

  Widget _buildPermissionError() => _InfoBanner(
    color: _AppColors.warning,
    icon: Icons.warning_amber_rounded,
    message: _permissionError!,
    trailing: TextButton(
      onPressed: openAppSettings,
      child: Text(
        'Ajustes',
        style: TextStyle(color: _AppColors.warning, fontSize: 12),
      ),
    ),
  );

  Widget _buildConnectedBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _AppColors.success.withOpacity(0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _AppColors.success.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _AppColors.success.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.bluetooth_connected,
              color: _AppColors.success,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CONECTADO',
                  style: TextStyle(
                    color: _AppColors.success,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
                Text(
                  _deviceName(_connectedDevice!),
                  style: TextStyle(
                    color: _AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _connectedDevice!.remoteId.str,
                  style: TextStyle(
                    color: _AppColors.textSecondary,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: _disconnect,
            icon: Icon(Icons.link_off, size: 15, color: _AppColors.error),
            label: Text(
              'Desconectar',
              style: TextStyle(color: _AppColors.error, fontSize: 12),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              backgroundColor: _AppColors.error.withOpacity(0.1),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final results = _scanResults;
    if (results.isEmpty) {
      return StreamBuilder<bool>(
        stream: FlutterBluePlus.isScanning,
        initialData: false,
        builder: (context, snapshot) {
          final isScanning = snapshot.data ?? false;
          if (isScanning) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: _AppColors.accent),
                  SizedBox(height: 16),
                  Text(
                    'Buscando dispositivos...',
                    style: TextStyle(
                      color: _AppColors.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            );
          }
          return _buildEmptyState();
        },
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
      itemCount: results.length,
      itemBuilder: (_, i) => _buildDeviceTile(results[i]),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: _AppColors.accent.withOpacity(0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.bluetooth_searching,
              size: 52,
              color: _AppColors.accent.withOpacity(0.5),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Sin dispositivos',
            style: TextStyle(
              color: _AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Presiona Escanear para buscar\ndispositivos Bluetooth cercanos',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _AppColors.textSecondary,
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceTile(ScanResult result) {
    final device = result.device;
    final isConnected = _connectedDevice?.remoteId == device.remoteId;
    final isConnectingThis =
        _connectingDeviceId == device.remoteId.str && _isConnecting;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isConnected
            ? _AppColors.success.withOpacity(0.07)
            : _AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isConnected
              ? _AppColors.success.withOpacity(0.4)
              : _AppColors.border,
          width: isConnected ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: isConnected
                    ? _AppColors.success.withOpacity(0.15)
                    : _AppColors.accent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                color: isConnected ? _AppColors.success : _AppColors.accent,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _deviceName(device),
                    style: TextStyle(
                      color: _AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    device.remoteId.str,
                    style: TextStyle(
                      color: _AppColors.textSecondary,
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Icon(
                        _signalIcon(result.rssi),
                        size: 12,
                        color: _signalColor(result.rssi),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${result.rssi} dBm  •  ${_signalLabel(result.rssi)}',
                        style: TextStyle(
                          color: _signalColor(result.rssi),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (isConnected)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ActionChip(
                    label: 'Con.',
                    color: _AppColors.success,
                    icon: Icons.check_circle_outline,
                    enabled: false,
                  ), // ← igual que antes
                  const SizedBox(width: 6),
                  _ActionChip(
                    // ← nuevo
                    label: 'RFID',
                    color: _AppColors.accent,
                    icon: Icons.nfc,
                    enabled: true,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            RfidReaderPage(device: _connectedDevice!),
                      ),
                    ),
                  ),
                ],
              )
            else if (isConnectingThis)
              Padding(
                padding: const EdgeInsets.all(8),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: _AppColors.accent,
                  ),
                ),
              )
            else
              _ActionChip(
                label: 'Conectar',
                color: _AppColors.accent,
                icon: Icons.link_rounded,
                enabled: _connectedDevice == null && !_isConnecting,
                onTap: () => _connect(device),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widgets auxiliares
// ─────────────────────────────────────────────────────────────────────────────

class _InfoBanner extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String message;
  final Widget? trailing;

  const _InfoBanner({
    required this.color,
    required this.icon,
    required this.message,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontSize: 12, height: 1.4),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;

  const _ActionChip({
    required this.label,
    required this.color,
    required this.icon,
    this.enabled = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = enabled ? color : color.withOpacity(0.4);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.withOpacity(0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: c),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: c,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Paleta
// ─────────────────────────────────────────────────────────────────────────────

abstract class _AppColorsDark {
  static const bg = Color(0xFF0F1117);
  static const surface = Color(0xFF1A1D27);
  static const border = Color(0xFF252836);
  static const accent = Color(0xFF4B9EFF);
  static const success = Color(0xFF34C97B);
  static const warning = Color(0xFFFFC947);
  static const error = Color(0xFFFF5C72);
  static const textPrimary = Color(0xFFEEF0F6);
  static const textSecondary = Color(0xFF7B82A0);
}

abstract class _AppColors {
  static const bgAppBar = Color(0xFF2563EB);
  static const bg = Color(0xFFF5F7FA);
  static const surface = Color(0xFFFFFFFF);
  static const border = Color(0xFFE2E6ED);
  static const accent = Color(0xFF2563EB);
  static const success = Color(0xFF16A34A);
  static const warning = Color(0xFFD97706);
  static const error = Color(0xFFDC2626);
  static const export = Color(0xFF16A34A);
  static const textPrimary = Color(0xFF1A1D27);
  static const textPrimaryAppBar = Color.fromRGBO(255, 255, 255, 1);
  static const textSecondary = Color(0xFF6B7280);
  static const textSecondaryAppBar = Color.fromRGBO(224, 224, 224, 1);
}
