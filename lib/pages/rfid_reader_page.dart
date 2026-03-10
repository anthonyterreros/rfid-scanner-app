import 'dart:async';
import 'dart:io';

import 'package:excel/excel.dart' as xl;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Modelo de lectura RFID
// ─────────────────────────────────────────────────────────────────────────────

class RfidTag {
  final String uid;
  final DateTime timestamp;
  final int rssi;
  final String raw;

  RfidTag({
    required this.uid,
    required this.timestamp,
    required this.rssi,
    required this.raw,
  });

  static String bytesToHex(List<int> bytes) {
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ')
        .toUpperCase();
  }

  /// Temporal:
  /// hasta confirmar el protocolo exacto del VH-C77P,
  /// usamos el frame completo como UID bruto.
  static RfidTag fromRawFrame(List<int> bytes, int rssi) {
    final raw = bytesToHex(bytes);
    final uid = raw.replaceAll(' ', '');
    return RfidTag(
      uid: uid,
      timestamp: DateTime.now(),
      rssi: rssi,
      raw: raw,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Modelo de log BLE
// ─────────────────────────────────────────────────────────────────────────────

class BleLogEntry {
  final DateTime timestamp;
  final String direction; // RX, TX, SYS
  final String description;
  final String rawHex;
  final int byteCount;

  BleLogEntry({
    required this.timestamp,
    required this.direction,
    required this.description,
    required this.rawHex,
    required this.byteCount,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Page
// ─────────────────────────────────────────────────────────────────────────────

class RfidReaderPage extends StatefulWidget {
  final BluetoothDevice device;

  const RfidReaderPage({super.key, required this.device});

  @override
  State<RfidReaderPage> createState() => _RfidReaderPageState();
}

class _RfidReaderPageState extends State<RfidReaderPage> {
  // ─── State ───────────────────────────────────────────────────────────────
  final List<RfidTag> _tags = [];
  final Map<String, RfidTag> _uniqueTagsMap = {};
  final List<BleLogEntry> _logs = [];
  final ScrollController _scrollController = ScrollController();

  bool _isListening = false;
  bool _isExporting = false;
  bool _isFabExpanded = false;
  bool _deviceConnected = true;
  bool _bleReady = false;

  int _currentRssi = 0;
  int _rxFrameCount = 0;

  BluetoothCharacteristic? _notifyCharacteristic;
  BluetoothCharacteristic? _writeCharacteristic;

  StreamSubscription<List<int>>? _notifySubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;

  final List<int> _rxBuffer = [];

  static const String _nusServiceUuid =
      '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const String _nusWriteUuid =
      '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
  static const String _nusNotifyUuid =
      '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

  // ─── Lifecycle ───────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _watchConnection();
    _discoverAndListen();
  }

  @override
  void dispose() {
    _notifySubscription?.cancel();
    _connectionSubscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  // ─── Logging helper ──────────────────────────────────────────────────────
  void _addLog({
    required String direction,
    required String description,
    String rawHex = '',
    int byteCount = 0,
  }) {
    if (!mounted) return;

    setState(() {
      _logs.insert(
        0,
        BleLogEntry(
          timestamp: DateTime.now(),
          direction: direction,
          description: description,
          rawHex: rawHex,
          byteCount: byteCount,
        ),
      );
    });
  }

  // ─── BLE connection watcher ──────────────────────────────────────────────
  void _watchConnection() {
    _connectionSubscription = widget.device.connectionState.listen((state) {
      if (!mounted) return;

      final connected = state == BluetoothConnectionState.connected;

      setState(() {
        _deviceConnected = connected;
      });

      _addLog(
        direction: 'SYS',
        description:
            connected ? 'Conexión establecida' : 'Dispositivo desconectado',
      );

      if (!connected) {
        _notifySubscription?.cancel();
        _notifySubscription = null;

        setState(() {
          _isListening = false;
          _bleReady = false;
        });

        _showSnack('Dispositivo desconectado', isError: true);
      }
    });
  }

  // ─── Descubrimiento GATT con NUS fijo ────────────────────────────────────
  Future<void> _discoverAndListen() async {
    try {
      _addLog(direction: 'TX', description: 'Descubriendo servicios GATT...');
      final services = await widget.device.discoverServices();

      _addLog(
        direction: 'RX',
        description: '${services.length} servicios descubiertos',
      );

      BluetoothService? nusService;

      for (final svc in services) {
        _addLog(
          direction: 'RX',
          description:
              'Servicio: ${svc.uuid.toString().toUpperCase()} (${svc.characteristics.length} características)',
        );

        for (final chr in svc.characteristics) {
          final props = <String>[];
          if (chr.properties.read) props.add('READ');
          if (chr.properties.write) props.add('WRITE');
          if (chr.properties.writeWithoutResponse) props.add('WRITE_NR');
          if (chr.properties.notify) props.add('NOTIFY');
          if (chr.properties.indicate) props.add('INDICATE');

          _addLog(
            direction: 'RX',
            description:
                '  └─ Char: ${chr.uuid.toString().toUpperCase()} [${props.join(", ")}]',
          );
        }

        if (svc.uuid.toString().toLowerCase() == _nusServiceUuid) {
          nusService = svc;
        }
      }

      if (nusService == null) {
        _addLog(
          direction: 'SYS',
          description: '⚠ No se encontró el servicio NUS',
        );
        _showSnack('Servicio NUS no encontrado', isError: true);
        return;
      }

      BluetoothCharacteristic? notifyChar;
      BluetoothCharacteristic? writeChar;

      for (final chr in nusService.characteristics) {
        final uuid = chr.uuid.toString().toLowerCase();

        if (uuid == _nusNotifyUuid) {
          notifyChar = chr;
        } else if (uuid == _nusWriteUuid) {
          writeChar = chr;
        }
      }

      if (notifyChar == null) {
        _addLog(
          direction: 'SYS',
          description: '⚠ No se encontró NUS notify',
        );
        _showSnack('NUS notify no encontrado', isError: true);
        return;
      }

      if (writeChar == null) {
        _addLog(
          direction: 'SYS',
          description: '⚠ No se encontró NUS write',
        );
        _showSnack('NUS write no encontrado', isError: true);
        return;
      }

      _notifyCharacteristic = notifyChar;
      _writeCharacteristic = writeChar;
      _bleReady = true;

      _addLog(
        direction: 'SYS',
        description:
            'NUS listo ✓ Notify=${_notifyCharacteristic!.uuid.toString().toUpperCase()} Write=${_writeCharacteristic!.uuid.toString().toUpperCase()}',
      );

      if (mounted) setState(() {});
      _showSnack('NUS listo');
    } catch (e) {
      _addLog(direction: 'SYS', description: '✖ Error GATT: $e');
      _showSnack('Error al descubrir servicios: $e', isError: true);
    }
  }

  // ─── Enviar comando al lector ────────────────────────────────────────────
  Future<void> sendCommand(List<int> bytes, {String label = 'Comando'}) async {
    if (_writeCharacteristic == null) {
      _addLog(
        direction: 'SYS',
        description: '⚠ No hay characteristic WRITE disponible',
      );
      return;
    }

    try {
      final hexStr = bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ')
          .toUpperCase();

      _addLog(
        direction: 'TX',
        description: '$label (${bytes.length} bytes)',
        rawHex: hexStr,
        byteCount: bytes.length,
      );

      await _writeCharacteristic!.write(
        bytes,
        withoutResponse: _writeCharacteristic!.properties.writeWithoutResponse,
      );

      _addLog(direction: 'SYS', description: '$label enviado ✓');
    } catch (e) {
      _addLog(direction: 'SYS', description: '✖ Error al enviar comando: $e');
      _showSnack('Error al enviar comando: $e', isError: true);
    }
  }

  // ─── Comandos de prueba ──────────────────────────────────────────────────
  Future<void> _sendStartA0() async {
    await sendCommand(
      [0xA0, 0x03, 0x01, 0x00, 0xA4],
      label: 'START A0',
    );
  }

  Future<void> _sendStopA0() async {
    await sendCommand(
      [0xA0, 0x03, 0x01, 0x01, 0xA5],
      label: 'STOP A0',
    );
  }

  Future<void> _sendStartBB() async {
    await sendCommand(
      [0xBB, 0x00, 0x27, 0x00, 0x27, 0x7E],
      label: 'START BB',
    );
  }

  Future<void> _sendStopBB() async {
    await sendCommand(
      [0xBB, 0x00, 0x28, 0x00, 0x28, 0x7E],
      label: 'STOP BB',
    );
  }

  // ─── Inicio de escucha ───────────────────────────────────────────────────
  Future<void> _startListening() async {
    if (!_bleReady || _notifyCharacteristic == null) {
      _showSnack('BLE/NUS aún no está listo', isError: true);
      return;
    }

    if (_isListening) return;

    try {
      _rxBuffer.clear();

      _addLog(
        direction: 'TX',
        description:
            'Activando NOTIFY en ${_notifyCharacteristic!.uuid.toString().toUpperCase()}',
      );

      await _notifyCharacteristic!.setNotifyValue(true);

      _addLog(direction: 'SYS', description: 'Notificaciones NUS activadas ✓');

      await _notifySubscription?.cancel();

      _notifySubscription = _notifyCharacteristic!.onValueReceived.listen(
        (bytes) {
          if (bytes.isEmpty || !mounted) return;

          _rxFrameCount++;

          final hexStr = bytes
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(' ')
              .toUpperCase();

          _addLog(
            direction: 'RX',
            description: 'Frame recibido #$_rxFrameCount (${bytes.length} bytes)',
            rawHex: hexStr,
            byteCount: bytes.length,
          );

          _handleIncomingBytes(bytes);
        },
        onError: (e) {
          _addLog(direction: 'SYS', description: '✖ Error de lectura: $e');
          _showSnack('Error de lectura: $e', isError: true);
        },
      );

      if (mounted) {
        setState(() => _isListening = true);
      }

      _showSnack('Escucha iniciada');
    } catch (e) {
      _addLog(direction: 'SYS', description: '✖ Error al activar NOTIFY: $e');
      _showSnack('No se pudo activar notificaciones: $e', isError: true);
    }
  }

  void _handleIncomingBytes(List<int> bytes) {
    final tag = RfidTag.fromRawFrame(bytes, _currentRssi);
    _addUniqueTag(tag);
  }

  void _addUniqueTag(RfidTag tag) {
    final exists = _uniqueTagsMap.containsKey(tag.uid);

    if (exists) {
      _addLog(
        direction: 'SYS',
        description: 'Tag repetido ignorado: ${tag.uid}',
      );
      return;
    }

    _uniqueTagsMap[tag.uid] = tag;

    setState(() {
      _tags.insert(0, tag);
    });

    _addLog(
      direction: 'SYS',
      description: 'Nuevo tag detectado: ${tag.uid}',
      rawHex: tag.raw,
      byteCount: tag.raw.split(' ').length,
    );

    _autoScroll();
  }

  // ─── Detener escucha ─────────────────────────────────────────────────────
  Future<void> _stopListening() async {
    try {
      await _notifySubscription?.cancel();
      _notifySubscription = null;
      _rxBuffer.clear();

      if (_notifyCharacteristic != null) {
        await _notifyCharacteristic!.setNotifyValue(false);
      }

      if (mounted) {
        setState(() => _isListening = false);
      }

      _addLog(direction: 'SYS', description: 'Escucha detenida');
    } catch (e) {
      _addLog(direction: 'SYS', description: '✖ Error al detener escucha: $e');
      _showSnack('No se pudo detener la escucha: $e', isError: true);
    }
  }

  void _clearTags() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _C.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Limpiar lecturas',
          style: TextStyle(color: _C.textPrimary, fontWeight: FontWeight.w700),
        ),
        content: Text(
          '¿Eliminar todas las ${_tags.length} lecturas registradas?',
          style: TextStyle(color: _C.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancelar', style: TextStyle(color: _C.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _tags.clear();
                _uniqueTagsMap.clear();
              });
              Navigator.pop(context);
            },
            child: Text('Limpiar', style: TextStyle(color: _C.error)),
          ),
        ],
      ),
    );
  }

  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ─── Logs bottom sheet ───────────────────────────────────────────────────
  void _showLogsSheet() {
    setState(() => _isFabExpanded = false);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _BleLogsSheet(
        logs: _logs,
        onClear: () {
          setState(() => _logs.clear());
          Navigator.pop(context);
          _showSnack('Logs limpiados');
        },
        formatTime: _formatTime,
        formatDate: _formatDate,
      ),
    );
  }

  // ─── Export to Excel ─────────────────────────────────────────────────────
  Future<void> _exportToExcel() async {
    setState(() => _isFabExpanded = false);

    if (_tags.isEmpty) {
      _showSnack('No hay lecturas para exportar', isError: true);
      return;
    }

    setState(() => _isExporting = true);

    try {
      final excel = xl.Excel.createExcel();

      final xl.Sheet sheet = excel['Lecturas RFID'];
      excel.delete('Sheet1');

      final evenRowStyle = xl.CellStyle(
        fontFamily: xl.getFontFamily(xl.FontFamily.Arial),
        backgroundColorHex: xl.ExcelColor.fromHexString('#EEF3FB'),
      );

      final oddRowStyle = xl.CellStyle(
        fontFamily: xl.getFontFamily(xl.FontFamily.Arial),
        backgroundColorHex: xl.ExcelColor.white,
      );

      final headers = [
        '#',
        'UID / Código',
        'Fecha',
        'Hora',
        'RSSI (dBm)',
        'Datos Crudos (HEX)',
      ];

      for (int col = 0; col < headers.length; col++) {
        final cell = sheet.cell(
          xl.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 0),
        );
        cell.value = xl.TextCellValue(headers[col]);
        cell.cellStyle = headerStyle;
      }

      for (int i = 0; i < _tags.length; i++) {
        final tag = _tags[i];
        final rowIdx = i + 1;
        final isEven = rowIdx % 2 == 0;
        final baseStyle = isEven ? evenRowStyle : oddRowStyle;

        final baseMonoStyle = isEven
            ? xl.CellStyle(
                fontFamily: 'Courier New',
                backgroundColorHex: xl.ExcelColor.fromHexString('#EEF3FB'),
              )
            : xl.CellStyle(
                fontFamily: 'Courier New',
                backgroundColorHex: xl.ExcelColor.white,
              );

        final rowData = [
          xl.IntCellValue(_tags.length - i),
          xl.TextCellValue(tag.uid),
          xl.TextCellValue(_formatDate(tag.timestamp)),
          xl.TextCellValue(_formatTime(tag.timestamp)),
          xl.IntCellValue(tag.rssi),
          xl.TextCellValue(tag.raw),
        ];

        for (int col = 0; col < rowData.length; col++) {
          final cell = sheet.cell(
            xl.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: rowIdx),
          );
          cell.value = rowData[col];
          cell.cellStyle = col == 5 ? baseMonoStyle : baseStyle;
        }
      }

      final summaryRow = _tags.length + 2;

      sheet
          .cell(
            xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: summaryRow),
          )
          .value = xl.TextCellValue('Total de lecturas:');

      sheet
          .cell(
            xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: summaryRow),
          )
          .value = xl.TextCellValue('=COUNTA(B2:B${_tags.length + 1})');

      sheet.setColumnWidth(0, 6);
      sheet.setColumnWidth(1, 26);
      sheet.setColumnWidth(2, 14);
      sheet.setColumnWidth(3, 12);
      sheet.setColumnWidth(4, 14);
      sheet.setColumnWidth(5, 52);

      final xl.Sheet summary = excel['Resumen'];
      _buildSummarySheet(summary);

      final bytes = excel.encode();
      if (bytes == null) {
        throw Exception('No se pudo codificar el archivo Excel');
      }

      final dir = await getTemporaryDirectory();
      final filename = 'rfid_${DateTime.now().millisecondsSinceEpoch}.xlsx';
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(bytes);

      await Share.shareXFiles(
        [
          XFile(
            file.path,
            mimeType:
                'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          ),
        ],
        subject: 'Lecturas RFID — ${_formatDate(DateTime.now())}',
        text: '${_tags.length} etiquetas escaneadas',
      );
    } catch (e) {
      _showSnack('Error al exportar: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  void _buildSummarySheet(xl.Sheet sheet) {
    final Map<String, int> counts = {};
    for (final tag in _tags) {
      counts[tag.uid] = (counts[tag.uid] ?? 0) + 1;
    }

    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final h1 = xl.CellStyle(
      bold: true,
      fontFamily: xl.getFontFamily(xl.FontFamily.Arial),
      backgroundColorHex: xl.ExcelColor.fromHexString('#1154B4'),
      fontColorHex: xl.ExcelColor.white,
    );

    sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0))
      ..value = xl.TextCellValue('UID')
      ..cellStyle = h1;

    sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 0))
      ..value = xl.TextCellValue('Lecturas')
      ..cellStyle = h1;

    sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: 0))
      ..value = xl.TextCellValue('Primera lectura')
      ..cellStyle = h1;

    sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: 0))
      ..value = xl.TextCellValue('Última lectura')
      ..cellStyle = h1;

    for (int i = 0; i < sorted.length; i++) {
      final uid = sorted[i].key;
      final tagsForUid = _tags.where((t) => t.uid == uid).toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

      sheet
          .cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: i + 1))
          .value = xl.TextCellValue(uid);

      sheet
          .cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: i + 1))
          .value = xl.IntCellValue(sorted[i].value);

      sheet
          .cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: i + 1))
          .value = xl.TextCellValue(
        '${_formatDate(tagsForUid.first.timestamp)} ${_formatTime(tagsForUid.first.timestamp)}',
      );

      sheet
          .cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: i + 1))
          .value = xl.TextCellValue(
        '${_formatDate(tagsForUid.last.timestamp)} ${_formatTime(tagsForUid.last.timestamp)}',
      );
    }

    sheet.setColumnWidth(0, 28);
    sheet.setColumnWidth(1, 12);
    sheet.setColumnWidth(2, 20);
    sheet.setColumnWidth(3, 20);
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────
  String _formatDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: isError ? _C.error : _C.success,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: Duration(seconds: isError ? 4 : 2),
        ),
      );
  }

  String get _deviceName => widget.device.platformName.isNotEmpty
      ? widget.device.platformName
      : widget.device.remoteId.str;

  // ─── Build ───────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (_isFabExpanded) {
          setState(() => _isFabExpanded = false);
        }
      },
      child: Scaffold(
        backgroundColor: _C.bg,
        appBar: _buildAppBar(),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildDeviceHeader(),
            _buildStatsBar(),
            const _Divider(),
            Expanded(child: _buildTagList()),
          ],
        ),
        floatingActionButton: _buildExpandableFAB(),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _C.bgAppBar,
      elevation: 0,
      leading: IconButton(
        icon: Icon(
          Icons.arrow_back_ios_new,
          color: _C.textSecondaryAppBar,
          size: 18,
        ),
        onPressed: () => Navigator.pop(context),
      ),
      title: Text(
        'Lector RFID',
        style: TextStyle(
          color: _C.textPrimaryAppBar,
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
      actions: [
        if (_tags.isNotEmpty)
          IconButton(
            icon: Icon(Icons.delete_sweep_outlined, color: _C.textSecondary),
            tooltip: 'Limpiar lecturas',
            onPressed: _clearTags,
          ),
        IconButton(
          icon: const Icon(Icons.playlist_play, color: Colors.white),
          tooltip: 'START A0',
          onPressed: (_deviceConnected && _bleReady) ? _sendStartA0 : null,
        ),
        IconButton(
          icon: const Icon(Icons.stop_circle_outlined, color: Colors.white),
          tooltip: 'STOP A0',
          onPressed: (_deviceConnected && _bleReady) ? _sendStopA0 : null,
        ),
        IconButton(
          icon: const Icon(Icons.send, color: Colors.white),
          tooltip: 'START BB',
          onPressed: (_deviceConnected && _bleReady) ? _sendStartBB : null,
        ),
        IconButton(
          icon: const Icon(Icons.pause_circle_outline, color: Colors.white),
          tooltip: 'STOP BB',
          onPressed: (_deviceConnected && _bleReady) ? _sendStopBB : null,
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: TextButton.icon(
            onPressed: (_deviceConnected && _bleReady)
                ? (_isListening ? _stopListening : _startListening)
                : null,
            icon: Icon(
              _isListening
                  ? Icons.pause_circle_outline
                  : Icons.play_circle_outline,
              size: 18,
              color: _isListening ? _C.warning : _C.success,
            ),
            style: TextButton.styleFrom(
              backgroundColor: Colors.grey[100],
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              side: BorderSide(
                color: _isListening ? _C.warning : _C.success,
                width: 1,
              ),
            ),
            label: Text(
              _isListening ? 'Pausar' : 'Escuchar',
              style: TextStyle(
                color: _isListening ? _C.warning : _C.success,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceHeader() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_C.accent.withOpacity(0.18), _C.accent.withOpacity(0.06)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _deviceConnected
              ? _C.accent.withOpacity(0.35)
              : _C.error.withOpacity(0.35),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color:
                  (_deviceConnected ? _C.accent : _C.error).withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _deviceConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
              color: _deviceConnected ? _C.accent : _C.error,
              size: 24,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: _deviceConnected ? _C.success : _C.error,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _deviceConnected ? 'Conectado' : 'Desconectado',
                      style: TextStyle(
                        color: _deviceConnected ? _C.success : _C.error,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  _deviceName,
                  style: TextStyle(
                    color: _C.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  widget.device.remoteId.str,
                  style: TextStyle(
                    color: _C.textSecondary,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _bleReady ? 'NUS listo' : 'NUS no listo',
                  style: TextStyle(
                    color: _bleReady ? _C.success : _C.warning,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (_isListening)
                _PulsingDot(color: _C.success)
              else
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _C.border,
                    shape: BoxShape.circle,
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                _isListening ? 'ACTIVO' : 'PAUSADO',
                style: TextStyle(
                  color: _isListening ? _C.success : _C.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatsBar() {
    final uniqueUids = _tags.map((t) => t.uid).toSet().length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          _StatChip(
            icon: Icons.tag,
            label: 'Total',
            value: '${_tags.length}',
            color: _C.accent,
          ),
          const SizedBox(width: 10),
          _StatChip(
            icon: Icons.fingerprint,
            label: 'Únicos',
            value: '$uniqueUids',
            color: _C.success,
          ),
          const SizedBox(width: 10),
          _StatChip(
            icon: Icons.schedule,
            label: 'Última',
            value: _tags.isEmpty ? '—' : _formatTime(_tags.first.timestamp),
            color: _C.warning,
          ),
        ],
      ),
    );
  }

  Widget _buildTagList() {
    if (_tags.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: _C.accent.withOpacity(0.07),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.nfc,
                size: 48,
                color: _C.accent.withOpacity(0.45),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Sin lecturas',
              style: TextStyle(
                color: _C.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _isListening
                  ? 'Acerca una etiqueta RFID al lector'
                  : 'Presiona "Escuchar" para comenzar',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _C.textSecondary,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 110),
      itemCount: _tags.length,
      itemBuilder: (_, i) => _buildTagTile(_tags[i], i),
    );
  }

  Widget _buildTagTile(RfidTag tag, int index) {
    final isNew = index == 0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isNew ? _C.accent.withOpacity(0.06) : _C.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isNew ? _C.accent.withOpacity(0.3) : _C.border,
          width: isNew ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: _C.accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Text(
                  '${_tags.length - index}',
                  style: TextStyle(
                    color: _C.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.nfc, size: 13, color: _C.accent),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          tag.uid,
                          style: TextStyle(
                            color: _C.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'monospace',
                            letterSpacing: 0.5,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tag.raw,
                    style: TextStyle(
                      color: _C.textSecondary,
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Icon(
                        Icons.access_time,
                        size: 11,
                        color: _C.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${_formatDate(tag.timestamp)}  ${_formatTime(tag.timestamp)}',
                        style: TextStyle(
                          color: _C.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (isNew)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: _C.success.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'NUEVO',
                  style: TextStyle(
                    color: _C.success,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ─── Expandable FAB ─────────────────────────────────────────────────────
  Widget _buildExpandableFAB() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.3),
                end: Offset.zero,
              ).animate(anim),
              child: child,
            ),
          ),
          child: _isFabExpanded
              ? Column(
                  key: const ValueKey('expanded'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _FabOption(
                      icon: Icons.terminal,
                      label: 'Ver Logs (${_logs.length})',
                      color: _C.accent,
                      onTap: _showLogsSheet,
                    ),
                    const SizedBox(height: 10),
                    _FabOption(
                      icon: Icons.file_download_outlined,
                      label: _tags.isEmpty
                          ? 'Sin datos'
                          : 'Exportar Excel (${_tags.length})',
                      color: _tags.isEmpty ? _C.border : _C.export,
                      onTap: _tags.isEmpty || _isExporting
                          ? null
                          : _exportToExcel,
                      isLoading: _isExporting,
                    ),
                    const SizedBox(height: 12),
                  ],
                )
              : const SizedBox.shrink(key: ValueKey('collapsed')),
        ),
        FloatingActionButton(
          onPressed: () => setState(() => _isFabExpanded = !_isFabExpanded),
          backgroundColor: _C.accent,
          elevation: 4,
          child: AnimatedRotation(
            turns: _isFabExpanded ? 0.125 : 0,
            duration: const Duration(milliseconds: 250),
            child: const Icon(Icons.add, color: Colors.white, size: 28),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FAB option mini-button
// ─────────────────────────────────────────────────────────────────────────────

class _FabOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final bool isLoading;

  const _FabOption({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: _C.surface,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: color.withOpacity(0.3)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.25),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoading)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                )
              else
                Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: onTap == null ? _C.textSecondary : _C.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BLE Logs Bottom Sheet
// ─────────────────────────────────────────────────────────────────────────────

class _BleLogsSheet extends StatefulWidget {
  final List<BleLogEntry> logs;
  final VoidCallback onClear;
  final String Function(DateTime) formatTime;
  final String Function(DateTime) formatDate;

  const _BleLogsSheet({
    required this.logs,
    required this.onClear,
    required this.formatTime,
    required this.formatDate,
  });

  @override
  State<_BleLogsSheet> createState() => _BleLogsSheetState();
}

class _BleLogsSheetState extends State<_BleLogsSheet> {
  String _filter = 'ALL';
  final ScrollController _logScrollCtrl = ScrollController();

  @override
  void dispose() {
    _logScrollCtrl.dispose();
    super.dispose();
  }

  List<BleLogEntry> get _filteredLogs => _filter == 'ALL'
      ? widget.logs
      : widget.logs.where((l) => l.direction == _filter).toList();

  Color _directionColor(String dir) {
    switch (dir) {
      case 'RX':
        return _C.success;
      case 'TX':
        return _C.accent;
      case 'SYS':
        return _C.warning;
      default:
        return _C.textSecondary;
    }
  }

  IconData _directionIcon(String dir) {
    switch (dir) {
      case 'RX':
        return Icons.arrow_downward;
      case 'TX':
        return Icons.arrow_upward;
      case 'SYS':
        return Icons.info_outline;
      default:
        return Icons.circle;
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredLogs;
    final mediaQuery = MediaQuery.of(context);

    return Container(
      height: mediaQuery.size.height * 0.85,
      decoration: BoxDecoration(
        color: _C.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: _C.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 12, 6),
            child: Row(
              children: [
                Icon(Icons.terminal, color: _C.accent, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Logs BLE',
                        style: TextStyle(
                          color: _C.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${widget.logs.length} entradas • ${filtered.length} visibles',
                        style: TextStyle(color: _C.textSecondary, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline, color: _C.error, size: 20),
                  tooltip: 'Limpiar logs',
                  onPressed: widget.onClear,
                ),
                IconButton(
                  icon: Icon(Icons.close, color: _C.textSecondary, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _LogFilterChip(
                  label: 'Todo',
                  isActive: _filter == 'ALL',
                  color: _C.textPrimary,
                  onTap: () => setState(() => _filter = 'ALL'),
                ),
                const SizedBox(width: 6),
                _LogFilterChip(
                  label: 'RX',
                  isActive: _filter == 'RX',
                  color: _C.success,
                  onTap: () => setState(() => _filter = 'RX'),
                ),
                const SizedBox(width: 6),
                _LogFilterChip(
                  label: 'TX',
                  isActive: _filter == 'TX',
                  color: _C.accent,
                  onTap: () => setState(() => _filter = 'TX'),
                ),
                const SizedBox(width: 6),
                _LogFilterChip(
                  label: 'SYS',
                  isActive: _filter == 'SYS',
                  color: _C.warning,
                  onTap: () => setState(() => _filter = 'SYS'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Container(height: 1, color: _C.border),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.receipt_long_outlined,
                          size: 40,
                          color: _C.textSecondary.withOpacity(0.4),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Sin logs',
                          style: TextStyle(
                            color: _C.textSecondary,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _logScrollCtrl,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    itemCount: filtered.length,
                    itemBuilder: (_, i) => _buildLogEntry(filtered[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogEntry(BleLogEntry entry) {
    final dirColor = _directionColor(entry.direction);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: _C.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _C.border.withOpacity(0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: dirColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _directionIcon(entry.direction),
                        size: 10,
                        color: dirColor,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        entry.direction,
                        style: TextStyle(
                          color: dirColor,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          fontFamily: 'monospace',
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  widget.formatTime(entry.timestamp),
                  style: TextStyle(
                    color: _C.textSecondary,
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
                if (entry.byteCount > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    '${entry.byteCount}B',
                    style: TextStyle(
                      color: _C.textSecondary.withOpacity(0.6),
                      fontSize: 9,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              entry.description,
              style: TextStyle(
                color: _C.textPrimary,
                fontSize: 12,
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
            if (entry.rawHex.isNotEmpty) ...[
              const SizedBox(height: 3),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: _C.bg,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  entry.rawHex,
                  style: TextStyle(
                    color: _C.accent.withOpacity(0.8),
                    fontSize: 10,
                    fontFamily: 'monospace',
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Log filter chip
// ─────────────────────────────────────────────────────────────────────────────

class _LogFilterChip extends StatelessWidget {
  final String label;
  final bool isActive;
  final Color color;
  final VoidCallback onTap;

  const _LogFilterChip({
    required this.label,
    required this.isActive,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? color.withOpacity(0.15) : _C.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isActive ? color.withOpacity(0.4) : _C.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? color : _C.textSecondary,
            fontSize: 11,
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Estilos de celda reutilizables
// ─────────────────────────────────────────────────────────────────────────────

final headerStyle = xl.CellStyle(
  fontFamily: xl.getFontFamily(xl.FontFamily.Arial),
  bold: true,
  fontColorHex: xl.ExcelColor.white,
  backgroundColorHex: xl.ExcelColor.fromHexString('#1154B4'),
  horizontalAlign: xl.HorizontalAlign.Center,
);

// ─────────────────────────────────────────────────────────────────────────────
// Widgets auxiliares
// ─────────────────────────────────────────────────────────────────────────────

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        height: 1,
        color: _C.border,
      );
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.2)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: _C.textSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  value,
                  style: TextStyle(
                    color: _C.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  final Color color;

  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);

    _anim = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _anim,
        child: Container(
          width: 10,
          height: 10,
          decoration:
              BoxDecoration(color: widget.color, shape: BoxShape.circle),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Paleta
// ─────────────────────────────────────────────────────────────────────────────

abstract class _C {
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