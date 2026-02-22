import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:excel/excel.dart' as xl;
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

  // Intenta extraer un UID legible de los bytes crudos del lector RFID.
  // Los lectores BLE suelen enviar el UID como HEX en los primeros N bytes.
  static RfidTag fromBytes(List<int> bytes, int rssi) {
    final raw = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ')
        .toUpperCase();
    // UID: primeros 4–7 bytes según el protocolo del lector
    final uidBytes = bytes.length >= 4
        ? bytes.sublist(0, bytes.length >= 7 ? 7 : 4)
        : bytes;
    final uid = uidBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(':')
        .toUpperCase();
    return RfidTag(uid: uid, timestamp: DateTime.now(), rssi: rssi, raw: raw);
  }
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
  final ScrollController _scrollController = ScrollController();

  bool _isListening = false;
  bool _isExporting = false;
  int _currentRssi = 0;

  BluetoothCharacteristic? _notifyCharacteristic;
  StreamSubscription<List<int>>? _notifySubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  bool _deviceConnected = true;

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

  // ─── BLE connection watcher ──────────────────────────────────────────────
  void _watchConnection() {
    _connectionSubscription = widget.device.connectionState.listen((state) {
      if (!mounted) return;
      setState(
        () => _deviceConnected = state == BluetoothConnectionState.connected,
      );
      if (state == BluetoothConnectionState.disconnected) {
        _notifySubscription?.cancel();
        setState(() => _isListening = false);
        _showSnack('Dispositivo desconectado', isError: true);
      }
    });
  }

  // ─── GATT discovery ──────────────────────────────────────────────────────
  Future<void> _discoverAndListen() async {
    try {
      final services = await widget.device.discoverServices();

      // Busca la primera característica que soporte NOTIFY o INDICATE.
      // Los lectores RFID BLE populares (p.ej. ACM/Zebra/Chainway) suelen
      // exponer sus datos en la característica 0xFFF1 o 0xFFE1 del servicio
      // 0xFFF0 / 0xFFE0, pero la búsqueda genérica aquí cubre cualquier marca.
      BluetoothCharacteristic? found;
      for (final svc in services) {
        for (final chr in svc.characteristics) {
          if (chr.properties.notify || chr.properties.indicate) {
            found = chr;
            break;
          }
        }
        if (found != null) break;
      }

      if (found == null) {
        _showSnack(
          'No se encontró característica de notificación',
          isError: true,
        );
        return;
      }

      _notifyCharacteristic = found;
      await _startListening();
    } catch (e) {
      _showSnack('Error al descubrir servicios: $e', isError: true);
    }
  }

  // ─── Notify subscription ─────────────────────────────────────────────────
  Future<void> _startListening() async {
    if (_notifyCharacteristic == null) return;
    try {
      await _notifyCharacteristic!.setNotifyValue(true);
      _notifySubscription = _notifyCharacteristic!.onValueReceived.listen((
        bytes,
      ) {
        if (bytes.isEmpty || !mounted) return;
        final tag = RfidTag.fromBytes(bytes, _currentRssi);
        setState(() => _tags.insert(0, tag)); // más reciente arriba
        _autoScroll();
      }, onError: (e) => _showSnack('Error de lectura: $e', isError: true));
      if (mounted) setState(() => _isListening = true);
    } catch (e) {
      _showSnack('No se pudo activar notificaciones: $e', isError: true);
    }
  }

  Future<void> _stopListening() async {
    try {
      await _notifyCharacteristic?.setNotifyValue(false);
    } catch (_) {}
    await _notifySubscription?.cancel();
    if (mounted) setState(() => _isListening = false);
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
              setState(() => _tags.clear());
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

  // ─── Export to Excel ─────────────────────────────────────────────────────
  Future<void> _exportToExcel() async {
    if (_tags.isEmpty) {
      _showSnack('No hay lecturas para exportar', isError: true);
      return;
    }
    setState(() => _isExporting = true);

    try {
      final excel = xl.Excel.createExcel();

      // ── Hoja principal ──────────────────────────────────────────────────
      final xl.Sheet sheet = excel['Lecturas RFID'];
      excel.delete('Sheet1'); // eliminar hoja default

      // Estilos
      final headerFill = xl.CellStyle(
        backgroundColorHex: xl.ExcelColor.fromHexString('#1154B4'),
        // azul oscuro
      );
      final headerFont = xl.CellStyle(
        fontFamily: xl.getFontFamily(xl.FontFamily.Arial),
        bold: true,
        fontColorHex: xl.ExcelColor.white,
        backgroundColorHex: xl.ExcelColor.fromHexString('#1154B4'),
        horizontalAlign: xl.HorizontalAlign.Center,
      );
      final evenRowStyle = xl.CellStyle(
        fontFamily: xl.getFontFamily(xl.FontFamily.Arial),
        backgroundColorHex: xl.ExcelColor.fromHexString('#EEF3FB'),
      );
      final oddRowStyle = xl.CellStyle(
        fontFamily: xl.getFontFamily(xl.FontFamily.Arial),
        backgroundColorHex: xl.ExcelColor.white,
      );
      final monoStyle = xl.CellStyle(
        fontFamily: 'Courier New',
        backgroundColorHex: xl.ExcelColor.fromHexString('#EEF3FB'),
      );

      // ── Encabezados ─────────────────────────────────────────────────────
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

      // ── Datos ────────────────────────────────────────────────────────────
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
          xl.IntCellValue(_tags.length - i), // número (más reciente = mayor)
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

      // ── Fila de resumen ──────────────────────────────────────────────────
      final summaryRow = _tags.length + 2;
      sheet
          .cell(
            xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: summaryRow),
          )
          .value = xl.TextCellValue(
        'Total de lecturas:',
      );
      sheet
          .cell(
            xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: summaryRow),
          )
          .value = xl.TextCellValue(
        '=COUNTA(B2:B${_tags.length + 1})',
      );

      // ── Ancho de columnas ────────────────────────────────────────────────
      sheet.setColumnWidth(0, 6); // #
      sheet.setColumnWidth(1, 26); // UID
      sheet.setColumnWidth(2, 14); // Fecha
      sheet.setColumnWidth(3, 12); // Hora
      sheet.setColumnWidth(4, 14); // RSSI
      sheet.setColumnWidth(5, 52); // Raw HEX

      // ── Hoja de resumen ──────────────────────────────────────────────────
      final xl.Sheet summary = excel['Resumen'];
      _buildSummarySheet(summary);

      // ── Guardar y compartir ──────────────────────────────────────────────
      final bytes = excel.encode();
      if (bytes == null)
        throw Exception('No se pudo codificar el archivo Excel');

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
      if (mounted) setState(() => _isExporting = false);
    }
  }

  void _buildSummarySheet(xl.Sheet sheet) {
    // Conteo por UID único
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
      final tagsForUid = _tags.where((t) => t.uid == uid).toList();
      tagsForUid.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      sheet
          .cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: i + 1))
          .value = xl.TextCellValue(
        uid,
      );
      sheet
          .cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: i + 1))
          .value = xl.IntCellValue(
        sorted[i].value,
      );
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
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
    return Scaffold(
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
      floatingActionButton: _buildFAB(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _C.surface,
      elevation: 0,
      leading: IconButton(
        icon: Icon(Icons.arrow_back_ios_new, color: _C.textSecondary, size: 18),
        onPressed: () => Navigator.pop(context),
      ),
      title: Text(
        'Lector RFID',
        style: TextStyle(
          color: _C.textPrimary,
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
        // Toggle escucha
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: TextButton.icon(
            onPressed: _deviceConnected
                ? (_isListening ? _stopListening : _startListening)
                : null,
            icon: Icon(
              _isListening
                  ? Icons.pause_circle_outline
                  : Icons.play_circle_outline,
              size: 18,
              color: _isListening ? _C.warning : _C.success,
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

  // ── Cabecera con info del dispositivo conectado ──────────────────────────
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
          // Indicador de estado
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: (_deviceConnected ? _C.accent : _C.error).withOpacity(
                0.15,
              ),
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
              ],
            ),
          ),
          // Estado de escucha
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

  // ── Barra de estadísticas ────────────────────────────────────────────────
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

  // ── Lista de tags ────────────────────────────────────────────────────────
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
            // Número de orden
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
                  // UID
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
                  // Raw HEX
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
                        style: TextStyle(color: _C.textSecondary, fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (isNew)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
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

  // ── FAB exportar ─────────────────────────────────────────────────────────
  Widget _buildFAB() {
    return FloatingActionButton.extended(
      onPressed: _tags.isEmpty || _isExporting ? null : _exportToExcel,
      backgroundColor: _tags.isEmpty
          ? _C.border
          : (_isExporting ? _C.warning : _C.export),
      elevation: _tags.isEmpty ? 0 : 4,
      icon: _isExporting
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.file_download_outlined, color: Colors.white),
      label: Text(
        _isExporting
            ? 'Exportando...'
            : _tags.isEmpty
            ? 'Sin datos'
            : 'Exportar Excel (${_tags.length})',
        style: TextStyle(
          color: _tags.isEmpty ? _C.textSecondary : Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Estilos de celda reutilizables (definidos fuera para evitar recrearlos)
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

/// Punto animado que pulsa para indicar actividad
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
    _anim = Tween<double>(
      begin: 0.4,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
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
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Paleta
// ─────────────────────────────────────────────────────────────────────────────

abstract class _C {
  static const bg = Color(0xFF0F1117);
  static const surface = Color(0xFF1A1D27);
  static const border = Color(0xFF252836);
  static const accent = Color(0xFF4B9EFF);
  static const success = Color(0xFF34C97B);
  static const warning = Color(0xFFFFC947);
  static const error = Color(0xFFFF5C72);
  static const export = Color(0xFF22C55E);
  static const textPrimary = Color(0xFFEEF0F6);
  static const textSecondary = Color(0xFF7B82A0);
}
