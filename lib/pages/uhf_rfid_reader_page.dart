import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:excel/excel.dart' as xl;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

// NUS UUIDs
class NusUuids {
  static const String service = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const String rxChar = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
  static const String txChar = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
  static bool match(String a, String b) => a.toLowerCase() == b.toLowerCase();
}

// Protocolo UHF (0xBB..0x7E) – Vanch VH-C77P / JRD-4035
class UhfCmd {
  static const int H = 0xBB, E = 0x7E;
  static const int bankEPC = 0x01, bankTID = 0x02, bankUser = 0x03;

  static int _cs(List<int> d) {
    int s = 0;
    for (final b in d) s += b;
    return s & 0xFF;
  }

  static List<int> _f(List<int> p) => [H, ...p, _cs(p), E];

  // Inventario
  static List<int> get singlePoll => _f([0x00, 0x22, 0x00, 0x00]);
  static List<int> multiPoll([int n = 0xFFFF]) =>
      _f([0x00, 0x27, 0x00, 0x03, 0x22, (n >> 8) & 0xFF, n & 0xFF]);
  static List<int> get stopPoll => _f([0x00, 0x28, 0x00, 0x00]);

  // Leer memoria  bank: TID=0x02, User=0x03  startWord, wordCount
  static List<int> readMem(
    int bank, {
    int start = 0,
    int words = 6,
    int pwd = 0,
  }) => _f([
    0x00,
    0x39,
    0x00,
    0x09,
    (pwd >> 24) & 0xFF,
    (pwd >> 16) & 0xFF,
    (pwd >> 8) & 0xFF,
    pwd & 0xFF,
    bank,
    (start >> 8) & 0xFF,
    start & 0xFF,
    (words >> 8) & 0xFF,
    words & 0xFF,
  ]);

  static List<int> readTID({int w = 6}) => readMem(bankTID, words: w);
  static List<int> readUser({int w = 4}) => readMem(bankUser, words: w);

  // Config
  static List<int> get version => _f([0x00, 0x03, 0x00, 0x01, 0x00]);
  static List<int> setPower(int cdBm) =>
      _f([0x00, 0xB6, 0x00, 0x02, (cdBm >> 8) & 0xFF, cdBm & 0xFF]);
  static List<int> setRegion(int r) => _f([0x00, 0x07, 0x00, 0x01, r]);

  // Parser
  static UhfFrame? parse(List<int> f) {
    if (f.length < 7 || f.first != H || f.last != E) return null;
    final pl = (f[3] << 8) | f[4];
    if (f.length < 5 + pl + 2) return null;
    final cs = _cs(f.sublist(1, 5 + pl));
    if (cs != f[5 + pl]) return null;
    return UhfFrame(type: f[1], cmd: f[2], payload: f.sublist(5, 5 + pl));
  }
}

class UhfFrame {
  final int type, cmd;
  final List<int> payload;
  UhfFrame({required this.type, required this.cmd, required this.payload});
  bool get isNotify => type == 0x02;
  bool get isResp => type == 0x01;
  bool get isInv => cmd == 0x22 || cmd == 0x27;
  bool get isRead => cmd == 0x39;
  bool get isErr => type == 0x01 && cmd == 0xFF;
}

// Modelo tag UHF
class UhfTag {
  final String epc, pc, crc, raw;
  final int rssi;
  final DateTime timestamp;
  String tid, userData;

  UhfTag({
    required this.epc,
    required this.pc,
    required this.rssi,
    required this.crc,
    required this.timestamp,
    required this.raw,
    this.tid = '',
    this.userData = '',
  });

  static UhfTag? fromInv(UhfFrame f) {
    if (!f.isInv) return null;
    final p = f.payload;
    if (p.length < 6) return null;
    final r = p[0];
    final rssi = r > 127 ? r - 256 : r;
    String hx(List<int> b) => b
        .map((x) => x.toRadixString(16).padLeft(2, '0'))
        .join('')
        .toUpperCase();
    return UhfTag(
      epc: hx(p.sublist(3, p.length - 2)),
      pc: hx(p.sublist(1, 3)),
      rssi: rssi,
      crc: hx(p.sublist(p.length - 2)),
      timestamp: DateTime.now(),
      raw: p
          .map((x) => x.toRadixString(16).padLeft(2, '0'))
          .join(' ')
          .toUpperCase(),
    );
  }
}

class BleLogEntry {
  final DateTime timestamp;
  final String direction, description, rawHex;
  final int byteCount;
  BleLogEntry({
    required this.timestamp,
    required this.direction,
    required this.description,
    required this.rawHex,
    required this.byteCount,
  });
}

// ─── Page ──────────────────────────────────────────────────────────────────
class UhfRfidReaderPage extends StatefulWidget {
  final BluetoothDevice device;
  const UhfRfidReaderPage({super.key, required this.device});
  @override
  State<UhfRfidReaderPage> createState() => _UhfRfidReaderPageState();
}

class _UhfRfidReaderPageState extends State<UhfRfidReaderPage> {
  final List<UhfTag> _tags = [];
  final Map<String, UhfTag> _unique = {};
  final List<BleLogEntry> _logs = [];
  final ScrollController _scroll = ScrollController();
  final List<int> _rxBuf = [];

  bool _listening = false,
      _exporting = false,
      _fabOpen = false,
      _readingExtra = false,
      _connected = true;
  BluetoothCharacteristic? _txChr, _rxChr;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  // Read-extra state
  final List<String> _pendingReads = [];
  String? _curReadEpc;
  int _readPhase = 0; // 0=idle 1=TID 2=User

  @override
  void initState() {
    super.initState();
    _watchConn();
    _discover();
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    _connSub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _log(String dir, String desc, {String hex = '', int bc = 0}) {
    if (!mounted) return;
    setState(
      () => _logs.insert(
        0,
        BleLogEntry(
          timestamp: DateTime.now(),
          direction: dir,
          description: desc,
          rawHex: hex,
          byteCount: bc,
        ),
      ),
    );
  }

  void _watchConn() {
    _connSub = widget.device.connectionState.listen((s) {
      if (!mounted) return;
      final c = s == BluetoothConnectionState.connected;
      setState(() => _connected = c);
      _log('SYS', c ? 'Conectado' : 'Desconectado');
      if (s == BluetoothConnectionState.disconnected) {
        _notifySub?.cancel();
        setState(() => _listening = false);
        _snack('Desconectado', err: true);
      }
    });
  }

  Future<void> _discover() async {
    try {
      _log('TX', 'Descubriendo servicios...');
      final svcs = await widget.device.discoverServices();
      _log('RX', '${svcs.length} servicios');
      for (final s in svcs)
        for (final c in s.characteristics) {
          final p = <String>[];
          if (c.properties.read) p.add('R');
          if (c.properties.write) p.add('W');
          if (c.properties.notify) p.add('N');
          _log('RX', '  ${c.uuid.toString().toUpperCase()} [${p.join(",")}]');
        }
      BluetoothService? nus;
      for (final s in svcs)
        if (NusUuids.match(s.uuid.toString(), NusUuids.service)) {
          nus = s;
          break;
        }
      if (nus == null) {
        _log('SYS', '⚠ NUS no encontrado');
        _snack('NUS no encontrado', err: true);
        return;
      }
      for (final c in nus.characteristics) {
        if (NusUuids.match(c.uuid.toString(), NusUuids.txChar))
          _txChr = c;
        else if (NusUuids.match(c.uuid.toString(), NusUuids.rxChar))
          _rxChr = c;
      }
      if (_txChr == null) {
        _log('SYS', '⚠ TX char no encontrada');
        return;
      }
      _log('SYS', 'NUS listo ✓ TX=${_txChr != null} RX=${_rxChr != null}');
      await _txChr!.setNotifyValue(true);
      _notifySub = _txChr!.onValueReceived.listen(
        _onBytes,
        onError: (e) => _log('SYS', '✖ $e'),
      );
      _log('SYS', 'Notify activado ✓');
    } catch (e) {
      _log('SYS', '✖ $e');
      _snack('Error: $e', err: true);
    }
  }

  Future<void> _send(List<int> b, String label) async {
    if (_rxChr == null) {
      _log('SYS', '⚠ Sin RX char');
      return;
    }
    final h = b
        .map((x) => x.toRadixString(16).padLeft(2, '0'))
        .join(' ')
        .toUpperCase();
    _log('TX', '$label (${b.length}B)', hex: h, bc: b.length);
    try {
      await _rxChr!.write(
        b,
        withoutResponse: _rxChr!.properties.writeWithoutResponse,
      );
    } catch (e) {
      _log('SYS', '✖ Envío: $e');
    }
  }

  void _onBytes(List<int> bytes) {
    if (bytes.isEmpty || !mounted) return;
    _log(
      'RX',
      '${bytes.length}B',
      hex: bytes
          .map((x) => x.toRadixString(16).padLeft(2, '0'))
          .join(' ')
          .toUpperCase(),
      bc: bytes.length,
    );
    _rxBuf.addAll(bytes);
    while (_rxBuf.length >= 7) {
      final si = _rxBuf.indexOf(0xBB);
      if (si < 0) {
        _rxBuf.clear();
        break;
      }
      if (si > 0) _rxBuf.removeRange(0, si);
      if (_rxBuf.length < 7) break;
      final pl = (_rxBuf[3] << 8) | _rxBuf[4], total = 5 + pl + 2;
      if (_rxBuf.length < total) break;
      if (_rxBuf[total - 1] != 0x7E) {
        _rxBuf.removeAt(0);
        continue;
      }
      final fb = _rxBuf.sublist(0, total);
      _rxBuf.removeRange(0, total);
      final frame = UhfCmd.parse(fb);
      if (frame != null)
        _handleFrame(frame);
      else
        _log('SYS', '⚠ Checksum error');
    }
  }

  void _handleFrame(UhfFrame f) {
    // Inventario
    if (f.isNotify && f.isInv) {
      final tag = UhfTag.fromInv(f);
      if (tag != null) {
        setState(() {
          _tags.insert(0, tag);
          _unique[tag.epc] = tag;
        });
        _log('SYS', '📦 EPC:${tag.epc} RSSI:${tag.rssi}dBm');
        _autoScroll();
      }
      return;
    }
    // Read data response
    if (f.isResp && f.isRead) {
      final data = f.payload
          .map((x) => x.toRadixString(16).padLeft(2, '0'))
          .join('')
          .toUpperCase();
      if (_readPhase == 1 && _curReadEpc != null) {
        final t = _unique[_curReadEpc];
        if (t != null) setState(() => t.tid = data);
        _log('SYS', '🏷️ TID:$data');
        _readPhase = 2;
        _send(UhfCmd.readUser(w: 4), 'Read User');
      } else if (_readPhase == 2 && _curReadEpc != null) {
        final t = _unique[_curReadEpc];
        if (t != null) setState(() => t.userData = data);
        _log('SYS', '👤 User:$data');
        _readPhase = 0;
        _curReadEpc = null;
        _readingExtra = false;
        _nextPendingRead();
      }
      return;
    }
    // Error
    if (f.isErr) {
      final ec = f.payload.isNotEmpty ? f.payload[0] : -1;
      _log('SYS', '⚠ Error 0x${ec.toRadixString(16)} fase=$_readPhase');
      if (_readPhase == 1) {
        _readPhase = 2;
        _send(UhfCmd.readUser(w: 4), 'Read User');
      } else if (_readPhase == 2) {
        _readPhase = 0;
        _curReadEpc = null;
        _readingExtra = false;
        _nextPendingRead();
      }
      return;
    }
    // Fin multi-inventario
    if (f.isResp && f.cmd == 0x27) {
      _log('SYS', 'Inventario fin (${_tags.length} tags)');
      return;
    }
    _log(
      'SYS',
      'Frame t=0x${f.type.toRadixString(16)} c=0x${f.cmd.toRadixString(16)}',
    );
  }

  void _nextPendingRead() {
    if (_pendingReads.isEmpty) {
      _readingExtra = false;
      return;
    }
    _curReadEpc = _pendingReads.removeAt(0);
    _readPhase = 1;
    _readingExtra = true;
    _send(UhfCmd.readTID(w: 6), 'Read TID');
  }

  void _readAllExtra() {
    final p = _unique.entries
        .where((e) => e.value.tid.isEmpty)
        .map((e) => e.key)
        .toList();
    if (p.isEmpty) {
      _snack('Todos los tags ya tienen TID');
      return;
    }
    _pendingReads.addAll(p);
    _log('SYS', 'Leyendo TID+User para ${p.length} tags...');
    _nextPendingRead();
  }

  Future<void> _startScan() async {
    _rxBuf.clear();
    await _send(UhfCmd.multiPoll(), 'Start Inventario');
    if (mounted) setState(() => _listening = true);
  }

  Future<void> _stopScan() async {
    await _send(UhfCmd.stopPoll, 'Stop Inventario');
    await Future.delayed(const Duration(milliseconds: 200));
    if (mounted) setState(() => _listening = false);
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
          '¿Eliminar ${_tags.length} lecturas?',
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
                _unique.clear();
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
      if (_scroll.hasClients)
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
    });
  }

  void _showLogs() {
    setState(() => _fabOpen = false);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _BleLogsSheet(
        logs: _logs,
        onClear: () {
          setState(() => _logs.clear());
          Navigator.pop(context);
          _snack('Logs limpiados');
        },
        formatTime: _fmtT,
        formatDate: _fmtD,
      ),
    );
  }

  Future<void> _export() async {
    setState(() => _fabOpen = false);
    if (_tags.isEmpty) {
      _snack('Sin datos', err: true);
      return;
    }
    setState(() => _exporting = true);
    try {
      final ex = xl.Excel.createExcel();
      final sh = ex['Lecturas UHF'];
      ex.delete('Sheet1');
      final hs = [
        '#',
        'EPC',
        'TID',
        'User Data',
        'RSSI',
        'PC',
        'Fecha',
        'Hora',
        'Raw',
      ];
      for (int c = 0; c < hs.length; c++) {
        final cell = sh.cell(
          xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0),
        );
        cell.value = xl.TextCellValue(hs[c]);
        cell.cellStyle = _hdrStyle;
      }
      for (int i = 0; i < _tags.length; i++) {
        final t = _tags[i];
        final r = i + 1;
        final rd = [
          xl.IntCellValue(_tags.length - i),
          xl.TextCellValue(t.epc),
          xl.TextCellValue(t.tid.isNotEmpty ? t.tid : '—'),
          xl.TextCellValue(t.userData.isNotEmpty ? t.userData : '—'),
          xl.IntCellValue(t.rssi),
          xl.TextCellValue(t.pc),
          xl.TextCellValue(_fmtD(t.timestamp)),
          xl.TextCellValue(_fmtT(t.timestamp)),
          xl.TextCellValue(t.raw),
        ];
        for (int c = 0; c < rd.length; c++)
          sh
                  .cell(
                    xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r),
                  )
                  .value =
              rd[c];
      }
      sh.setColumnWidth(1, 36);
      sh.setColumnWidth(2, 28);
      sh.setColumnWidth(3, 28);
      sh.setColumnWidth(8, 52);
      final bytes = ex.encode();
      if (bytes == null) throw Exception('Encode error');
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/uhf_${DateTime.now().millisecondsSinceEpoch}.xlsx',
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
        subject: 'UHF RFID — ${_fmtD(DateTime.now())}',
        text: '${_tags.length} tags',
      );
    } catch (e) {
      _snack('Error: $e', err: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String _fmtD(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  String _fmtT(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
  void _snack(String m, {bool err = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(m),
          backgroundColor: err ? _C.error : _C.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          duration: Duration(seconds: err ? 4 : 2),
        ),
      );
  }

  String get _devName => widget.device.platformName.isNotEmpty
      ? widget.device.platformName
      : widget.device.remoteId.str;

  // ─── BUILD ─────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (_fabOpen) setState(() => _fabOpen = false);
      },
      child: Scaffold(
        backgroundColor: _C.bg,
        appBar: _appBar(),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            _stats(),
            const _Div(),
            Expanded(child: _list()),
          ],
        ),
        floatingActionButton: _fab(),
      ),
    );
  }

  PreferredSizeWidget _appBar() => AppBar(
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
      'Lector UHF RFID',
      style: TextStyle(
        color: _C.textPrimaryAppBar,
        fontSize: 17,
        fontWeight: FontWeight.w700,
      ),
    ),
    actions: [
      if (_tags.isNotEmpty)
        IconButton(
          icon: Icon(Icons.delete_sweep_outlined, color: _C.textSecondary),
          onPressed: _clearTags,
        ),
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: TextButton.icon(
          onPressed: _connected ? (_listening ? _stopScan : _startScan) : null,
          icon: Icon(
            _listening ? Icons.pause_circle_outline : Icons.play_circle_outline,
            size: 18,
            color: _listening ? _C.warning : _C.success,
          ),
          style: TextButton.styleFrom(
            backgroundColor: Colors.grey[100],
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            side: BorderSide(color: _listening ? _C.warning : _C.success),
          ),
          label: Text(
            _listening ? 'Pausar' : 'Escanear',
            style: TextStyle(
              color: _listening ? _C.warning : _C.success,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ],
  );

  Widget _header() => Container(
    margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: [_C.accent.withOpacity(0.18), _C.accent.withOpacity(0.06)],
      ),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: (_connected ? _C.accent : _C.error).withOpacity(0.35),
      ),
    ),
    child: Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: (_connected ? _C.accent : _C.error).withOpacity(0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(
            _connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            color: _connected ? _C.accent : _C.error,
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
                      color: _connected ? _C.success : _C.error,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _connected ? 'Conectado' : 'Desconectado',
                    style: TextStyle(
                      color: _connected ? _C.success : _C.error,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                _devName,
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
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _listening
                ? _PulsingDot(color: _C.success)
                : Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _C.border,
                      shape: BoxShape.circle,
                    ),
                  ),
            const SizedBox(height: 4),
            Text(
              _listening ? 'ACTIVO' : 'PAUSADO',
              style: TextStyle(
                color: _listening ? _C.success : _C.textSecondary,
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

  Widget _stats() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    child: Row(
      children: [
        _Stat(
          icon: Icons.tag,
          label: 'Total',
          value: '${_tags.length}',
          color: _C.accent,
        ),
        const SizedBox(width: 10),
        _Stat(
          icon: Icons.fingerprint,
          label: 'Únicos',
          value: '${_unique.length}',
          color: _C.success,
        ),
        const SizedBox(width: 10),
        _Stat(
          icon: Icons.schedule,
          label: 'Última',
          value: _tags.isEmpty ? '—' : _fmtT(_tags.first.timestamp),
          color: _C.warning,
        ),
      ],
    ),
  );

  Widget _list() {
    if (_tags.isEmpty)
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
              'Sin lecturas UHF',
              style: TextStyle(
                color: _C.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _listening
                  ? 'Acerca etiquetas UHF al VH-C77P'
                  : 'Presiona "Escanear" para iniciar',
              textAlign: TextAlign.center,
              style: TextStyle(color: _C.textSecondary, fontSize: 13),
            ),
          ],
        ),
      );
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 110),
      itemCount: _tags.length,
      itemBuilder: (_, i) => _tile(_tags[i], i),
    );
  }

  Widget _tile(UhfTag tag, int i) {
    final isNew = i == 0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
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
                  '${_tags.length - i}',
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
                      Text(
                        'EPC: ',
                        style: TextStyle(color: _C.textSecondary, fontSize: 10),
                      ),
                      Expanded(
                        child: Text(
                          tag.epc,
                          style: TextStyle(
                            color: _C.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'monospace',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  if (tag.tid.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Text(
                            'TID: ',
                            style: TextStyle(
                              color: _C.textSecondary,
                              fontSize: 10,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              tag.tid,
                              style: TextStyle(
                                color: _C.success,
                                fontSize: 10,
                                fontFamily: 'monospace',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (tag.userData.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Text(
                            'USR: ',
                            style: TextStyle(
                              color: _C.textSecondary,
                              fontSize: 10,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              tag.userData,
                              style: TextStyle(
                                color: _C.warning,
                                fontSize: 10,
                                fontFamily: 'monospace',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Icon(
                        Icons.signal_cellular_alt,
                        size: 11,
                        color: _C.textSecondary,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '${tag.rssi}dBm',
                        style: TextStyle(color: _C.textSecondary, fontSize: 10),
                      ),
                      const SizedBox(width: 10),
                      Icon(
                        Icons.access_time,
                        size: 11,
                        color: _C.textSecondary,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        _fmtT(tag.timestamp),
                        style: TextStyle(color: _C.textSecondary, fontSize: 10),
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

  Widget _fab() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        transitionBuilder: (c, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.3),
              end: Offset.zero,
            ).animate(a),
            child: c,
          ),
        ),
        child: _fabOpen
            ? Column(
                key: const ValueKey('o'),
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _Fb(
                    icon: Icons.memory,
                    label: _readingExtra
                        ? 'Leyendo...'
                        : 'Leer TID+User (${_unique.length})',
                    color: _readingExtra || _unique.isEmpty
                        ? _C.border
                        : _C.warning,
                    onTap: _readingExtra || _unique.isEmpty
                        ? null
                        : () {
                            setState(() => _fabOpen = false);
                            _readAllExtra();
                          },
                    isLoading: _readingExtra,
                  ),
                  const SizedBox(height: 10),
                  _Fb(
                    icon: Icons.terminal,
                    label: 'Ver Logs (${_logs.length})',
                    color: _C.accent,
                    onTap: _showLogs,
                  ),
                  const SizedBox(height: 10),
                  _Fb(
                    icon: Icons.file_download_outlined,
                    label: _tags.isEmpty
                        ? 'Sin datos'
                        : 'Exportar (${_tags.length})',
                    color: _tags.isEmpty ? _C.border : _C.export,
                    onTap: _tags.isEmpty || _exporting ? null : _export,
                    isLoading: _exporting,
                  ),
                  const SizedBox(height: 12),
                ],
              )
            : const SizedBox.shrink(key: ValueKey('c')),
      ),
      FloatingActionButton(
        onPressed: () => setState(() => _fabOpen = !_fabOpen),
        backgroundColor: _C.accent,
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

// ─── Widgets auxiliares ────────────────────────────────────────────────────
class _Fb extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final bool isLoading;
  const _Fb({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
    this.isLoading = false,
  });
  @override
  Widget build(BuildContext c) => Material(
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
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
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

class _Div extends StatelessWidget {
  const _Div();
  @override
  Widget build(BuildContext c) => Container(
    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    height: 1,
    color: _C.border,
  );
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final Color color;
  const _Stat({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });
  @override
  Widget build(BuildContext c) => Expanded(
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
      begin: 0.4,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => FadeTransition(
    opacity: _a,
    child: Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    ),
  );
}

// ─── Logs Sheet ────────────────────────────────────────────────────────────
class _BleLogsSheet extends StatefulWidget {
  final List<BleLogEntry> logs;
  final VoidCallback onClear;
  final String Function(DateTime) formatTime, formatDate;
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
  String _f = 'ALL';
  final ScrollController _sc = ScrollController();
  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  List<BleLogEntry> get _fl => _f == 'ALL'
      ? widget.logs
      : widget.logs.where((l) => l.direction == _f).toList();
  Color _dc(String d) {
    switch (d) {
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

  IconData _di(String d) {
    switch (d) {
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
  Widget build(BuildContext c) {
    final fl = _fl;
    return Container(
      height: MediaQuery.of(c).size.height * 0.85,
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
                        'Logs BLE (UHF)',
                        style: TextStyle(
                          color: _C.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${widget.logs.length} entradas • ${fl.length} visibles',
                        style: TextStyle(color: _C.textSecondary, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline, color: _C.error, size: 20),
                  onPressed: widget.onClear,
                ),
                IconButton(
                  icon: Icon(Icons.close, color: _C.textSecondary, size: 20),
                  onPressed: () => Navigator.pop(c),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _LF(
                  label: 'Todo',
                  act: _f == 'ALL',
                  color: _C.textPrimary,
                  onTap: () => setState(() => _f = 'ALL'),
                ),
                const SizedBox(width: 6),
                _LF(
                  label: 'RX',
                  act: _f == 'RX',
                  color: _C.success,
                  onTap: () => setState(() => _f = 'RX'),
                ),
                const SizedBox(width: 6),
                _LF(
                  label: 'TX',
                  act: _f == 'TX',
                  color: _C.accent,
                  onTap: () => setState(() => _f = 'TX'),
                ),
                const SizedBox(width: 6),
                _LF(
                  label: 'SYS',
                  act: _f == 'SYS',
                  color: _C.warning,
                  onTap: () => setState(() => _f = 'SYS'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Container(height: 1, color: _C.border),
          Expanded(
            child: fl.isEmpty
                ? Center(
                    child: Text(
                      'Sin logs',
                      style: TextStyle(color: _C.textSecondary),
                    ),
                  )
                : ListView.builder(
                    controller: _sc,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    itemCount: fl.length,
                    itemBuilder: (_, i) {
                      final e = fl[i];
                      final dc = _dc(e.direction);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: _C.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: _C.border.withOpacity(0.5),
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
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _di(e.direction),
                                          size: 10,
                                          color: dc,
                                        ),
                                        const SizedBox(width: 3),
                                        Text(
                                          e.direction,
                                          style: TextStyle(
                                            color: dc,
                                            fontSize: 9,
                                            fontWeight: FontWeight.w800,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    widget.formatTime(e.timestamp),
                                    style: TextStyle(
                                      color: _C.textSecondary,
                                      fontSize: 10,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                  if (e.byteCount > 0) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      '${e.byteCount}B',
                                      style: TextStyle(
                                        color: _C.textSecondary.withOpacity(
                                          0.6,
                                        ),
                                        fontSize: 9,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                e.description,
                                style: TextStyle(
                                  color: _C.textPrimary,
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  height: 1.4,
                                ),
                              ),
                              if (e.rawHex.isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: _C.bg,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    e.rawHex,
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
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _LF extends StatelessWidget {
  final String label;
  final bool act;
  final Color color;
  final VoidCallback onTap;
  const _LF({
    required this.label,
    required this.act,
    required this.color,
    required this.onTap,
  });
  @override
  Widget build(BuildContext c) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: act ? color.withOpacity(0.15) : _C.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: act ? color.withOpacity(0.4) : _C.border),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: act ? color : _C.textSecondary,
          fontSize: 11,
          fontWeight: act ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    ),
  );
}

final _hdrStyle = xl.CellStyle(
  fontFamily: xl.getFontFamily(xl.FontFamily.Arial),
  bold: true,
  fontColorHex: xl.ExcelColor.white,
  backgroundColorHex: xl.ExcelColor.fromHexString('#1154B4'),
  horizontalAlign: xl.HorizontalAlign.Center,
);

abstract class _C {
  static const bgAppBar = Color(0xFF2563EB),
      bg = Color(0xFFF5F7FA),
      surface = Color(0xFFFFFFFF),
      border = Color(0xFFE2E6ED);
  static const accent = Color(0xFF2563EB),
      success = Color(0xFF16A34A),
      warning = Color(0xFFD97706),
      error = Color(0xFFDC2626),
      export = Color(0xFF16A34A);
  static const textPrimary = Color(0xFF1A1D27),
      textPrimaryAppBar = Color.fromRGBO(255, 255, 255, 1),
      textSecondary = Color(0xFF6B7280),
      textSecondaryAppBar = Color.fromRGBO(224, 224, 224, 1);
}
