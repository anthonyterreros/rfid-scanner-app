import 'dart:async';
import 'dart:io';
import 'dart:developer' as dev;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:excel/excel.dart' as xl;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// NORDIC UART SERVICE UUIDs
// El VH-C77P expone NUS sobre BLE. Se escribe al RX y se recibe del TX.
// ═══════════════════════════════════════════════════════════════════════════════

class _Nus {
  static const svc = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const rx = '6e400002-b5a3-f393-e0a9-e50e24dcca9e'; // WRITE
  static const tx = '6e400003-b5a3-f393-e0a9-e50e24dcca9e'; // NOTIFY
  static bool eq(String a, String b) => a.toLowerCase() == b.toLowerCase();
}

// ═══════════════════════════════════════════════════════════════════════════════
// PROTOCOLO UHF  0xBB … 0x7E
// ═══════════════════════════════════════════════════════════════════════════════
//
// Estructura de trama:
//   Header(1) | Type(1) | Command(1) | PL_MSB(1) | PL_LSB(1) | Payload(PL) | Checksum(1) | End(1)
//
// ● Header  = 0xBB
// ● End     = 0x7E
// ● Type    = 0x00 (command), 0x01 (response), 0x02 (notification)
// ● Checksum = suma de bytes desde Type hasta último byte del Payload, & 0xFF
//
// Comandos relevantes:
//   0x22 – Single Inventory   → BB 00 22 00 00 22 7E
//   0x27 – Multiple Inventory → BB 00 27 00 03 22 FF FF [cs] 7E  (0xFFFF = continuo)
//   0x28 – Stop Inventory     → BB 00 28 00 00 28 7E
//   0x39 – Read Memory        → BB 00 39 00 09 [pwd(4)] [bank] [addr(2)] [len(2)] [cs] 7E
//   0x03 – Get Version        → BB 00 03 00 01 00 04 7E
//   0xB6 – Set TX Power       → BB 00 B6 00 02 [pwrH] [pwrL] [cs] 7E
//   0x07 – Set Region         → BB 00 07 00 01 [region] [cs] 7E
//
// Respuesta de inventario (notification, type=0x02):
//   BB 02 22 [PL_MSB] [PL_LSB] [RSSI] [PC(2)] [EPC(var)] [CRC(2)] [cs] 7E
//   RSSI = complemento a 2 con signo en dBm  (ej: 0xC9 = -55 dBm)
//
// Memory banks para cmd 0x39:
//   0x00 = Reserved, 0x01 = EPC, 0x02 = TID, 0x03 = User
// ═══════════════════════════════════════════════════════════════════════════════

class UhfCmd {
  static const int _H = 0xBB, _E = 0x7E;

  // Checksum = sum(Type..Payload) & 0xFF
  static int _cs(List<int> d) {
    int s = 0;
    for (final b in d) s += b;
    return s & 0xFF;
  }

  static List<int> _frame(List<int> body) => [_H, ...body, _cs(body), _E];

  // ── Inventario ─────────────────────────────────────────────────────────
  /// Inventario único (una sola ronda, cmd 0x22)
  static List<int> get singleInventory => _frame([0x00, 0x22, 0x00, 0x00]);

  /// Inventario múltiple continuo (cmd 0x27, count=0xFFFF = hasta STOP)
  static List<int> startInventory({int count = 0xFFFF}) {
    return _frame([
      0x00,
      0x27,
      0x00,
      0x03,
      0x22,
      (count >> 8) & 0xFF,
      count & 0xFF,
    ]);
  }

  /// Detener inventario múltiple (cmd 0x28)
  static List<int> get stopInventory => _frame([0x00, 0x28, 0x00, 0x00]);

  // ── Lectura de memoria ─────────────────────────────────────────────────
  /// Lee memoria del tag (cmd 0x39). bank: 0x02=TID, 0x03=User
  /// startWord y wordCount en WORDS (1 word = 2 bytes)
  static List<int> readMemory({
    required int bank,
    int startWord = 0,
    int wordCount = 6,
    int password = 0,
  }) {
    return _frame([
      0x00,
      0x39,
      0x00,
      0x09,
      (password >> 24) & 0xFF,
      (password >> 16) & 0xFF,
      (password >> 8) & 0xFF,
      password & 0xFF,
      bank,
      (startWord >> 8) & 0xFF,
      startWord & 0xFF,
      (wordCount >> 8) & 0xFF,
      wordCount & 0xFF,
    ]);
  }

  static List<int> readTID({int words = 6}) =>
      readMemory(bank: 0x02, wordCount: words);

  static List<int> readUserData({int words = 4}) =>
      readMemory(bank: 0x03, wordCount: words);

  // ── Configuración ──────────────────────────────────────────────────────
  static List<int> get getVersion => _frame([0x00, 0x03, 0x00, 0x01, 0x00]);

  /// power en centésimas de dBm: 2600 = 26.00 dBm
  static List<int> setTxPower(int cdBm) =>
      _frame([0x00, 0xB6, 0x00, 0x02, (cdBm >> 8) & 0xFF, cdBm & 0xFF]);

  /// 0x01=China, 0x02=USA, 0x03=EU, 0x04=Korea
  static List<int> setRegion(int region) =>
      _frame([0x00, 0x07, 0x00, 0x01, region]);

  // ── Parser ─────────────────────────────────────────────────────────────
  static _UhfFrame? parse(List<int> raw) {
    if (raw.length < 7 || raw.first != _H || raw.last != _E) return null;
    final pl = (raw[3] << 8) | raw[4];
    final need = 5 + pl + 2; // header..PL + payload + cs + end
    if (raw.length < need) return null;
    final cs = _cs(raw.sublist(1, 5 + pl));
    if (cs != raw[5 + pl]) return null;
    return _UhfFrame(
      type: raw[1],
      cmd: raw[2],
      payload: raw.sublist(5, 5 + pl),
    );
  }
}

class _UhfFrame {
  final int type, cmd;
  final List<int> payload;
  _UhfFrame({required this.type, required this.cmd, required this.payload});

  bool get isNotification => type == 0x02;
  bool get isResponse => type == 0x01;
  bool get isInventory => cmd == 0x22 || cmd == 0x27;
  bool get isReadData => cmd == 0x39;
  bool get isError => type == 0x01 && cmd == 0xFF;
}

// ═══════════════════════════════════════════════════════════════════════════════
// MODELO – Etiqueta UHF
// ═══════════════════════════════════════════════════════════════════════════════

class UhfTag {
  final String epc;
  final String pc;
  final int rssi;
  final String crc;
  final DateTime timestamp;
  final String rawHex;
  String tid;
  String userData;
  int readCount;

  UhfTag({
    required this.epc,
    required this.pc,
    required this.rssi,
    required this.crc,
    required this.timestamp,
    required this.rawHex,
    this.tid = '',
    this.userData = '',
    this.readCount = 1,
  });

  /// Parsea la notificación de inventario (type=0x02, cmd=0x22 o 0x27)
  /// Payload: [RSSI(1)] [PC(2)] [EPC(variable)] [CRC(2)]
  static UhfTag? fromInventory(_UhfFrame f) {
    if (!f.isInventory) return null;
    final p = f.payload;
    if (p.length < 6) return null;

    final rssiRaw = p[0];
    final rssi = rssiRaw > 127 ? rssiRaw - 256 : rssiRaw;
    final pc = _hex(p.sublist(1, 3));
    final epc = _hex(p.sublist(3, p.length - 2));
    final crc = _hex(p.sublist(p.length - 2));
    final raw = p
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ')
        .toUpperCase();

    return UhfTag(
      epc: epc,
      pc: pc,
      rssi: rssi,
      crc: crc,
      timestamp: DateTime.now(),
      rawHex: raw,
    );
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join('').toUpperCase();
}

// ═══════════════════════════════════════════════════════════════════════════════
// MODELO – Log BLE
// ═══════════════════════════════════════════════════════════════════════════════

class _LogEntry {
  final DateTime ts;
  final String dir; // TX, RX, SYS
  final String desc;
  final String hex;
  final int bytes;
  _LogEntry(this.ts, this.dir, this.desc, {this.hex = '', this.bytes = 0});
}

// ═══════════════════════════════════════════════════════════════════════════════
// PANTALLA PRINCIPAL – UhcRfidReaderScanPage
// ═══════════════════════════════════════════════════════════════════════════════

class UhcRfidReaderScanPage extends StatefulWidget {
  final BluetoothDevice device;
  const UhcRfidReaderScanPage({super.key, required this.device});

  @override
  State<UhcRfidReaderScanPage> createState() => _UhcRfidReaderScanPageState();
}

class _UhcRfidReaderScanPageState extends State<UhcRfidReaderScanPage> {
  // ── Listas de datos ────────────────────────────────────────────────────
  final List<UhfTag> _allTags = []; // cada lectura individual
  final Map<String, UhfTag> _unique = {}; // EPC → tag más reciente
  final List<_LogEntry> _logs = [];

  // ── BLE ────────────────────────────────────────────────────────────────
  BluetoothCharacteristic? _txChar; // NOTIFY – recibe datos
  BluetoothCharacteristic? _rxChar; // WRITE  – envía comandos
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  bool _connected = true;

  // ── Estado UI ──────────────────────────────────────────────────────────
  bool _scanning = false;
  bool _exporting = false;
  bool _fabOpen = false;
  final ScrollController _scroll = ScrollController();

  // ── Buffer de recepción ────────────────────────────────────────────────
  final List<int> _rxBuf = [];

  // ── Lifecycle ──────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _watchConnection();
    _discover();
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    _connSub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  // ═════════════════════════════════════════════════════════════════════════
  // CONEXIÓN BLE
  // ═════════════════════════════════════════════════════════════════════════

  void _addLog(String dir, String desc, {String hex = '', int bc = 0}) {
    if (!mounted) return;
    setState(
      () => _logs.insert(
        0,
        _LogEntry(DateTime.now(), dir, desc, hex: hex, bytes: bc),
      ),
    );
  }

  void _watchConnection() {
    _connSub = widget.device.connectionState.listen((s) {
      if (!mounted) return;
      final ok = s == BluetoothConnectionState.connected;
      setState(() => _connected = ok);
      _addLog('SYS', ok ? 'Dispositivo conectado' : 'Dispositivo desconectado');
      if (!ok) {
        _notifySub?.cancel();
        setState(() => _scanning = false);
        _snack('Desconectado', err: true);
      }
    });
  }

  Future<void> _discover() async {
    try {
      _addLog('SYS', 'Descubriendo servicios GATT…');
      final services = await widget.device.discoverServices();
      _addLog('RX', '${services.length} servicios encontrados');

      // Log de todos los servicios y características
      for (final svc in services) {
        for (final c in svc.characteristics) {
          final props = <String>[];
          if (c.properties.read) props.add('R');
          if (c.properties.write) props.add('W');
          if (c.properties.writeWithoutResponse) props.add('WNR');
          if (c.properties.notify) props.add('N');
          if (c.properties.indicate) props.add('I');
          _addLog(
            'RX',
            '${svc.uuid.toString().substring(4, 8).toUpperCase()}: ${c.uuid.toString().toUpperCase()} [${props.join(",")}]',
          );
        }
      }

      // Buscar NUS
      BluetoothService? nus;
      for (final s in services) {
        if (_Nus.eq(s.uuid.toString(), _Nus.svc)) {
          nus = s;
          break;
        }
      }
      if (nus == null) {
        _addLog('SYS', '⚠ Nordic UART Service (NUS) no encontrado');
        _snack('NUS no encontrado en el dispositivo', err: true);
        return;
      }

      // Buscar TX (NOTIFY) y RX (WRITE)
      for (final c in nus.characteristics) {
        if (_Nus.eq(c.uuid.toString(), _Nus.tx)) _txChar = c;
        if (_Nus.eq(c.uuid.toString(), _Nus.rx)) _rxChar = c;
      }
      if (_txChar == null || _rxChar == null) {
        _addLog(
          'SYS',
          '⚠ Características NUS incompletas (TX=${_txChar != null}, RX=${_rxChar != null})',
        );
        _snack('Características NUS incompletas', err: true);
        return;
      }

      _addLog('SYS', 'NUS encontrado ✓  TX(NOTIFY) ✓  RX(WRITE) ✓');

      // Activar notificaciones
      await _txChar!.setNotifyValue(true);
      _notifySub = _txChar!.onValueReceived.listen(
        _onBytesReceived,
        onError: (e) => _addLog('SYS', '✖ Error NOTIFY: $e'),
      );
      _addLog('SYS', 'Notificaciones activadas ✓ — Listo para inventario');
    } catch (e) {
      _addLog('SYS', '✖ Error descubrimiento: $e');
      _snack('Error: $e', err: true);
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // ENVIAR COMANDO AL LECTOR
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> _send(List<int> cmd, String label) async {
    if (_rxChar == null) {
      _addLog('SYS', '⚠ Característica RX no disponible');
      return;
    }
    final hex = cmd
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ')
        .toUpperCase();
    _addLog('TX', '$label (${cmd.length}B)', hex: hex, bc: cmd.length);
    try {
      await _rxChar!.write(
        cmd,
        withoutResponse: _rxChar!.properties.writeWithoutResponse,
      );
    } catch (e) {
      _addLog('SYS', '✖ Error de envío: $e');
      _snack('Error al enviar: $e', err: true);
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // RECEPCIÓN Y ENSAMBLAJE DE FRAMES
  // ═════════════════════════════════════════════════════════════════════════

  void _onBytesReceived(List<int> bytes) {
    if (bytes.isEmpty || !mounted) return;

    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ')
        .toUpperCase();
    _addLog('RX', '${bytes.length}B recibidos', hex: hex, bc: bytes.length);

    _rxBuf.addAll(bytes);

    // Extraer frames completos del buffer
    while (_rxBuf.length >= 7) {
      // Buscar header 0xBB
      final start = _rxBuf.indexOf(0xBB);
      if (start < 0) {
        _rxBuf.clear();
        break;
      }
      if (start > 0) _rxBuf.removeRange(0, start);
      if (_rxBuf.length < 7) break;

      // Calcular longitud total del frame
      final plLen = (_rxBuf[3] << 8) | _rxBuf[4];
      final frameLen =
          1 +
          1 +
          1 +
          2 +
          plLen +
          1 +
          1; // H + Type + Cmd + PL(2) + payload + CS + E

      if (_rxBuf.length < frameLen) break; // Esperar más bytes

      // Verificar byte End
      if (_rxBuf[frameLen - 1] != 0x7E) {
        _rxBuf.removeAt(0); // Corrupto, saltar
        continue;
      }

      // Extraer y parsear
      final raw = _rxBuf.sublist(0, frameLen);
      _rxBuf.removeRange(0, frameLen);

      final frame = UhfCmd.parse(raw);
      if (frame != null) {
        _processFrame(frame);
      } else {
        _addLog('SYS', '⚠ Frame con checksum inválido');
      }
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // PROCESAR FRAMES DEL LECTOR
  // ═════════════════════════════════════════════════════════════════════════

  void _processFrame(_UhfFrame f) {
    // ── Notificación de inventario ───────────────────────────────────────
    if (f.isNotification && f.isInventory) {
      final tag = UhfTag.fromInventory(f);
      if (tag == null) return;

      setState(() {
        _allTags.insert(0, tag);
        if (_unique.containsKey(tag.epc)) {
          _unique[tag.epc]!.readCount++;
          _unique[tag.epc]!.tid = _unique[tag.epc]!.tid; // preservar TID previo
        } else {
          _unique[tag.epc] = tag;
        }
      });

      _addLog('SYS', '📦 EPC: ${tag.epc}  RSSI: ${tag.rssi} dBm');
      _autoScroll();
      return;
    }

    // ── Respuesta Read Data ──────────────────────────────────────────────
    if (f.isResponse && f.isReadData) {
      final data = f.payload
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join('')
          .toUpperCase();
      _addLog('SYS', '📖 Datos leídos: $data');
      return;
    }

    // ── Error ────────────────────────────────────────────────────────────
    if (f.isError) {
      final code = f.payload.isNotEmpty ? f.payload[0] : 0;
      final msg = code == 0x15
          ? 'Sin tag / CRC error'
          : 'Error 0x${code.toRadixString(16).toUpperCase()}';
      _addLog('SYS', '⚠ $msg');
      return;
    }

    // ── Fin de inventario múltiple ───────────────────────────────────────
    if (f.isResponse && f.cmd == 0x27) {
      _addLog(
        'SYS',
        'Inventario completado (${_allTags.length} lecturas, ${_unique.length} únicos)',
      );
      return;
    }

    // ── Otras respuestas ─────────────────────────────────────────────────
    _addLog(
      'SYS',
      'Frame: type=0x${f.type.toRadixString(16)} cmd=0x${f.cmd.toRadixString(16)} pl=${f.payload.length}B',
    );
  }

  // ═════════════════════════════════════════════════════════════════════════
  // ACCIONES DE INVENTARIO
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> _startInventory() async {
    _rxBuf.clear();
    await _send(
      UhfCmd.startInventory(),
      'Iniciar inventario continuo (cmd 0x27)',
    );
    if (mounted) setState(() => _scanning = true);
  }

  Future<void> _stopInventory() async {
    await _send(UhfCmd.stopInventory, 'Detener inventario (cmd 0x28)');
    await Future.delayed(const Duration(milliseconds: 300));
    if (mounted) setState(() => _scanning = false);
  }

  void _clearAll() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _K.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Limpiar lecturas',
          style: TextStyle(color: _K.textPrimary, fontWeight: FontWeight.w700),
        ),
        content: Text(
          '¿Eliminar ${_allTags.length} lecturas y ${_unique.length} tags únicos?',
          style: TextStyle(color: _K.textSec),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancelar', style: TextStyle(color: _K.textSec)),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _allTags.clear();
                _unique.clear();
              });
              Navigator.pop(context);
            },
            child: Text('Limpiar', style: TextStyle(color: _K.error)),
          ),
        ],
      ),
    );
  }

  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ═════════════════════════════════════════════════════════════════════════
  // LOGS – BOTTOM SHEET
  // ═════════════════════════════════════════════════════════════════════════

  void _showLogs() {
    setState(() => _fabOpen = false);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LogsSheet(
        logs: _logs,
        onClear: () {
          setState(() => _logs.clear());
          Navigator.pop(context);
          _snack('Logs limpiados');
        },
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════
  // EXPORTAR A EXCEL
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> _exportExcel() async {
    setState(() => _fabOpen = false);
    if (_unique.isEmpty) {
      _snack('No hay tags para exportar', err: true);
      return;
    }
    setState(() => _exporting = true);

    try {
      final workbook = xl.Excel.createExcel();

      // ── Hoja "Inventario" ──────────────────────────────────────────────
      final sheet = workbook['Inventario UHF'];
      workbook.delete('Sheet1');

      final headers = [
        '#',
        'EPC',
        'RSSI (dBm)',
        'PC',
        'Lecturas',
        'Primera vez',
        'Raw HEX',
      ];
      for (int c = 0; c < headers.length; c++) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0))
          ..value = xl.TextCellValue(headers[c])
          ..cellStyle = _xlHeader;
      }

      final sorted = _unique.values.toList()
        ..sort((a, b) => b.readCount.compareTo(a.readCount));

      for (int i = 0; i < sorted.length; i++) {
        final t = sorted[i];
        final row = i + 1;
        final even = row % 2 == 0;
        final style = even ? _xlEven : _xlOdd;

        final cells = [
          xl.IntCellValue(row),
          xl.TextCellValue(t.epc),
          xl.IntCellValue(t.rssi),
          xl.TextCellValue(t.pc),
          xl.IntCellValue(t.readCount),
          xl.TextCellValue('${_fmtDate(t.timestamp)} ${_fmtTime(t.timestamp)}'),
          xl.TextCellValue(t.rawHex),
        ];

        for (int c = 0; c < cells.length; c++) {
          sheet.cell(
              xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row),
            )
            ..value = cells[c]
            ..cellStyle = style;
        }
      }

      sheet.setColumnWidth(0, 6);
      sheet.setColumnWidth(1, 36);
      sheet.setColumnWidth(2, 12);
      sheet.setColumnWidth(3, 10);
      sheet.setColumnWidth(4, 10);
      sheet.setColumnWidth(5, 22);
      sheet.setColumnWidth(6, 52);

      // ── Hoja "Todas las lecturas" ──────────────────────────────────────
      final allSheet = workbook['Todas las lecturas'];
      final allHeaders = ['#', 'EPC', 'RSSI', 'Fecha', 'Hora'];
      for (int c = 0; c < allHeaders.length; c++) {
        allSheet.cell(
            xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0),
          )
          ..value = xl.TextCellValue(allHeaders[c])
          ..cellStyle = _xlHeader;
      }
      for (int i = 0; i < _allTags.length; i++) {
        final t = _allTags[i];
        final row = i + 1;
        allSheet
            .cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
            .value = xl.IntCellValue(
          row,
        );
        allSheet
            .cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
            .value = xl.TextCellValue(
          t.epc,
        );
        allSheet
            .cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row))
            .value = xl.IntCellValue(
          t.rssi,
        );
        allSheet
            .cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row))
            .value = xl.TextCellValue(
          _fmtDate(t.timestamp),
        );
        allSheet
            .cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row))
            .value = xl.TextCellValue(
          _fmtTime(t.timestamp),
        );
      }
      allSheet.setColumnWidth(1, 36);

      // ── Guardar y compartir ────────────────────────────────────────────
      final bytes = workbook.encode();
      if (bytes == null) throw Exception('Error al codificar Excel');

      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/inventario_uhf_${DateTime.now().millisecondsSinceEpoch}.xlsx',
      );
      await file.writeAsBytes(bytes);

      await Share.shareXFiles(
        [
          XFile(
            file.path,
            mimeType:
                'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          ),
        ],
        subject: 'Inventario UHF — ${_fmtDate(DateTime.now())}',
        text:
            '${_unique.length} tags únicos, ${_allTags.length} lecturas totales',
      );
    } catch (e) {
      _snack('Error al exportar: $e', err: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // HELPERS
  // ═════════════════════════════════════════════════════════════════════════

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  String _fmtTime(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';

  void _snack(String msg, {bool err = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: err ? _K.error : _K.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          duration: Duration(seconds: err ? 4 : 2),
        ),
      );
  }

  String get _deviceName => widget.device.platformName.isNotEmpty
      ? widget.device.platformName
      : widget.device.remoteId.str;

  // ═════════════════════════════════════════════════════════════════════════
  // BUILD
  // ═════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (_fabOpen) setState(() => _fabOpen = false);
      },
      child: Scaffold(
        backgroundColor: _K.bg,
        appBar: _buildAppBar(),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildDeviceCard(),
            _buildStats(),
            _buildDivider(),
            Expanded(child: _buildTagList()),
          ],
        ),
        floatingActionButton: _buildFAB(),
      ),
    );
  }

  // ── AppBar ─────────────────────────────────────────────────────────────
  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _K.primary,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(
          Icons.arrow_back_ios_new,
          color: Colors.white70,
          size: 18,
        ),
        onPressed: () => Navigator.pop(context),
      ),
      title: const Text(
        'Inventario UHF RFID',
        style: TextStyle(
          color: Colors.white,
          fontSize: 17,
          fontWeight: FontWeight.w700,
        ),
      ),
      actions: [
        if (_allTags.isNotEmpty)
          IconButton(
            icon: Icon(
              Icons.delete_sweep_outlined,
              color: Colors.white.withOpacity(0.7),
            ),
            tooltip: 'Limpiar',
            onPressed: _clearAll,
          ),
      ],
    );
  }

  // ── Tarjeta dispositivo + botones inventario ───────────────────────────
  Widget _buildDeviceCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_K.primary.withOpacity(0.15), _K.primary.withOpacity(0.04)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: (_connected ? _K.primary : _K.error).withOpacity(0.35),
        ),
      ),
      child: Column(
        children: [
          // Info del dispositivo
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: (_connected ? _K.primary : _K.error).withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _connected
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_disabled,
                  color: _connected ? _K.primary : _K.error,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
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
                            color: _connected ? _K.success : _K.error,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _connected ? 'Conectado' : 'Desconectado',
                          style: TextStyle(
                            color: _connected ? _K.success : _K.error,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _deviceName,
                      style: TextStyle(
                        color: _K.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      widget.device.remoteId.str,
                      style: TextStyle(
                        color: _K.textSec,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              if (_scanning) _PulsingDot(color: _K.success),
            ],
          ),
          const SizedBox(height: 14),

          // ── Botones INICIAR / DETENER ──────────────────────────────────
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (!_connected || _scanning)
                      ? null
                      : _startInventory,
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text('Iniciar Inventario'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _K.success,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _K.success.withOpacity(0.3),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (!_connected || !_scanning)
                      ? null
                      : _stopInventory,
                  icon: const Icon(Icons.stop_rounded, size: 20),
                  label: const Text('Detener'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _K.error,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _K.error.withOpacity(0.3),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Stats ──────────────────────────────────────────────────────────────
  Widget _buildStats() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          _StatChip(Icons.tag, 'Lecturas', '${_allTags.length}', _K.primary),
          const SizedBox(width: 10),
          _StatChip(
            Icons.fingerprint,
            'Únicos',
            '${_unique.length}',
            _K.success,
          ),
          const SizedBox(width: 10),
          _StatChip(
            Icons.schedule,
            'Última',
            _allTags.isEmpty ? '—' : _fmtTime(_allTags.first.timestamp),
            _K.warning,
          ),
        ],
      ),
    );
  }

  Widget _buildDivider() => Container(
    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    height: 1,
    color: _K.border,
  );

  // ── Tag List ───────────────────────────────────────────────────────────
  Widget _buildTagList() {
    if (_unique.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: _K.primary.withOpacity(0.07),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.nfc,
                size: 48,
                color: _K.primary.withOpacity(0.4),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Sin etiquetas UHF',
              style: TextStyle(
                color: _K.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _scanning
                  ? 'Acerca etiquetas UHF al lector VH-C77P…'
                  : 'Presiona "Iniciar Inventario" para comenzar',
              textAlign: TextAlign.center,
              style: TextStyle(color: _K.textSec, fontSize: 13, height: 1.5),
            ),
          ],
        ),
      );
    }

    final tags = _unique.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 100),
      itemCount: tags.length,
      itemBuilder: (_, i) => _buildTagTile(tags[i], i),
    );
  }

  Widget _buildTagTile(UhfTag tag, int index) {
    final isFirst = index == 0 && _scanning;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isFirst ? _K.primary.withOpacity(0.06) : _K.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isFirst ? _K.primary.withOpacity(0.3) : _K.border,
          width: isFirst ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            // Número / count
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _K.primary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Text(
                  '${tag.readCount}',
                  style: TextStyle(
                    color: _K.primary,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // EPC
                  Row(
                    children: [
                      Icon(Icons.nfc, size: 13, color: _K.primary),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          tag.epc,
                          style: TextStyle(
                            color: _K.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'monospace',
                            letterSpacing: 0.3,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // RSSI + time
                  Row(
                    children: [
                      Icon(
                        Icons.signal_cellular_alt,
                        size: 11,
                        color: _K.textSec,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '${tag.rssi} dBm',
                        style: TextStyle(color: _K.textSec, fontSize: 10),
                      ),
                      const SizedBox(width: 12),
                      Icon(Icons.access_time, size: 11, color: _K.textSec),
                      const SizedBox(width: 3),
                      Text(
                        _fmtTime(tag.timestamp),
                        style: TextStyle(color: _K.textSec, fontSize: 10),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'PC: ${tag.pc}',
                        style: TextStyle(
                          color: _K.textSec,
                          fontSize: 10,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Badge
            if (isFirst)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: _K.success.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'NEW',
                  style: TextStyle(
                    color: _K.success,
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

  // ── FAB expandible ─────────────────────────────────────────────────────
  Widget _buildFAB() {
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
          child: _fabOpen
              ? Column(
                  key: const ValueKey('open'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _FabOption(
                      icon: Icons.terminal,
                      label: 'Ver Logs (${_logs.length})',
                      color: _K.primary,
                      onTap: _showLogs,
                    ),
                    const SizedBox(height: 10),
                    _FabOption(
                      icon: Icons.file_download_outlined,
                      label: _unique.isEmpty
                          ? 'Sin datos'
                          : 'Exportar Excel (${_unique.length})',
                      color: _unique.isEmpty ? _K.border : _K.success,
                      onTap: _unique.isEmpty || _exporting
                          ? null
                          : _exportExcel,
                      isLoading: _exporting,
                    ),
                    const SizedBox(height: 12),
                  ],
                )
              : const SizedBox.shrink(key: ValueKey('closed')),
        ),
        FloatingActionButton(
          onPressed: () => setState(() => _fabOpen = !_fabOpen),
          backgroundColor: _K.primary,
          elevation: 4,
          child: AnimatedRotation(
            turns: _fabOpen ? 0.125 : 0,
            duration: const Duration(milliseconds: 250),
            child: const Icon(Icons.add, color: Colors.white, size: 28),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// WIDGETS AUXILIARES
// ═══════════════════════════════════════════════════════════════════════════════

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
            color: _K.surface,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: color.withOpacity(0.3)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
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
                  color: onTap == null ? _K.textSec : _K.textPrimary,
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

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final Color color;
  const _StatChip(this.icon, this.label, this.value, this.color);

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
                    color: _K.textSec,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  value,
                  style: TextStyle(
                    color: _K.textPrimary,
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
  late AnimationController _c;
  late Animation<double> _a;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _a = Tween(
      begin: 0.3,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _a,
    child: Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// LOGS BOTTOM SHEET
// ═══════════════════════════════════════════════════════════════════════════════

class _LogsSheet extends StatefulWidget {
  final List<_LogEntry> logs;
  final VoidCallback onClear;
  const _LogsSheet({required this.logs, required this.onClear});

  @override
  State<_LogsSheet> createState() => _LogsSheetState();
}

class _LogsSheetState extends State<_LogsSheet> {
  String _filter = 'ALL';

  List<_LogEntry> get _filtered => _filter == 'ALL'
      ? widget.logs
      : widget.logs.where((l) => l.dir == _filter).toList();

  Color _dirColor(String d) {
    switch (d) {
      case 'RX':
        return _K.success;
      case 'TX':
        return _K.primary;
      case 'SYS':
        return _K.warning;
      default:
        return _K.textSec;
    }
  }

  String _fmtTime(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: _K.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: _K.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 12, 6),
            child: Row(
              children: [
                Icon(Icons.terminal, color: _K.primary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Logs BLE / UHF',
                        style: TextStyle(
                          color: _K.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${widget.logs.length} entradas • ${items.length} visibles',
                        style: TextStyle(color: _K.textSec, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline, color: _K.error, size: 20),
                  onPressed: widget.onClear,
                ),
                IconButton(
                  icon: Icon(Icons.close, color: _K.textSec, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          // Filtros
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                for (final f in ['ALL', 'TX', 'RX', 'SYS']) ...[
                  if (f != 'ALL') const SizedBox(width: 6),
                  _FilterChip(
                    label: f == 'ALL' ? 'Todo' : f,
                    active: _filter == f,
                    color: f == 'ALL' ? _K.textPrimary : _dirColor(f),
                    onTap: () => setState(() => _filter = f),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Container(height: 1, color: _K.border),
          // Lista
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      'Sin logs',
                      style: TextStyle(color: _K.textSec),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final e = items[i];
                      final dc = _dirColor(e.dir);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: _K.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: _K.border.withOpacity(0.5),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: dc.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      e.dir,
                                      style: TextStyle(
                                        color: dc,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w800,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _fmtTime(e.ts),
                                    style: TextStyle(
                                      color: _K.textSec,
                                      fontSize: 10,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                  if (e.bytes > 0) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      '${e.bytes}B',
                                      style: TextStyle(
                                        color: _K.textSec.withOpacity(0.6),
                                        fontSize: 9,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                e.desc,
                                style: TextStyle(
                                  color: _K.textPrimary,
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  height: 1.4,
                                ),
                              ),
                              if (e.hex.isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: _K.bg,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    e.hex,
                                    style: TextStyle(
                                      color: _K.primary.withOpacity(0.8),
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
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool active;
  final Color color;
  final VoidCallback onTap;
  const _FilterChip({
    required this.label,
    required this.active,
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
          color: active ? color.withOpacity(0.15) : _K.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? color.withOpacity(0.4) : _K.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? color : _K.textSec,
            fontSize: 11,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// ESTILOS EXCEL
// ═══════════════════════════════════════════════════════════════════════════════

final _xlHeader = xl.CellStyle(
  fontFamily: xl.getFontFamily(xl.FontFamily.Arial),
  bold: true,
  fontColorHex: xl.ExcelColor.white,
  backgroundColorHex: xl.ExcelColor.fromHexString('#1154B4'),
  horizontalAlign: xl.HorizontalAlign.Center,
);

final _xlEven = xl.CellStyle(
  fontFamily: xl.getFontFamily(xl.FontFamily.Arial),
  backgroundColorHex: xl.ExcelColor.fromHexString('#EEF3FB'),
);

final _xlOdd = xl.CellStyle(
  fontFamily: xl.getFontFamily(xl.FontFamily.Arial),
  backgroundColorHex: xl.ExcelColor.white,
);

// ═══════════════════════════════════════════════════════════════════════════════
// PALETA DE COLORES
// ═══════════════════════════════════════════════════════════════════════════════

abstract class _K {
  static const primary = Color(0xFF2563EB);
  static const bg = Color(0xFFF5F7FA);
  static const surface = Color(0xFFFFFFFF);
  static const border = Color(0xFFE2E6ED);
  static const success = Color(0xFF16A34A);
  static const warning = Color(0xFFD97706);
  static const error = Color(0xFFDC2626);
  static const textPrimary = Color(0xFF1A1D27);
  static const textSec = Color(0xFF6B7280);
}
