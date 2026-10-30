import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:usb_serial/usb_serial.dart';

import 'tcp_transport.dart';

void main() => runApp(const PhoneCommApp());

const _fileChannel = MethodChannel('phone_comm/files');

enum _ConnectionMode { usb, server, client }

const _ink = Color(0xFF18324B);
const _linkBlue = Color(0xFF1765C1);
const _connectedGreen = Color(0xFF16846B);

Uint8List parseHex(String input) {
  final value = input.replaceAll(RegExp(r'\s+'), '');
  if (value.isEmpty ||
      value.length.isOdd ||
      !RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) {
    throw const FormatException('请输入偶数个十六进制字符，例如 01 A0 FF');
  }
  return Uint8List.fromList(List<int>.generate(
    value.length ~/ 2,
    (index) => int.parse(value.substring(index * 2, index * 2 + 2), radix: 16),
  ));
}

String toHex(List<int> bytes) => bytes
    .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');

String formatTimestamp(DateTime time) {
  String pad(int value, int width) => value.toString().padLeft(width, '0');
  return '${pad(time.year, 4)}-${pad(time.month, 2)}-${pad(time.day, 2)} '
      '${pad(time.hour, 2)}:${pad(time.minute, 2)}:${pad(time.second, 2)}.'
      '${pad(time.millisecond, 3)}';
}

String normalizeRecordFileName(String input) {
  final name = input.trim();
  final fileName = name.contains('.') ? name : '$name.txt';
  if (name.isEmpty ||
      fileName.length > 100 ||
      name == '.' ||
      name == '..' ||
      RegExp(r'[\\/:*?"<>|\x00-\x1F]').hasMatch(name)) {
    throw const FormatException('请输入有效文件名（最多100字，不含路径和特殊符号）');
  }
  return fileName;
}

String formatLogLine(String direction, DateTime time,
    {List<int>? data, String? message, bool includeTimestamp = true}) {
  final prefix = includeTimestamp ? '${formatTimestamp(time)} ' : '';
  final value = message ??
      '${toHex(data ?? const [])}  |  '
          '${jsonEncode(utf8.decode(data ?? const [], allowMalformed: true))}';
  return '$prefix$direction $value\n';
}

Uint8List encodeText(String input, {bool escapes = false}) {
  if (!escapes) return Uint8List.fromList(utf8.encode(input));
  final bytes = BytesBuilder(copy: false);
  var start = 0;
  for (var i = 0; i < input.length; i++) {
    if (input.codeUnitAt(i) != 92) continue;
    bytes.add(utf8.encode(input.substring(start, i)));
    if (++i >= input.length) throw const FormatException('转义符后缺少字符');
    switch (input[i]) {
      case 'n':
        bytes.addByte(10);
        break;
      case 'r':
        bytes.addByte(13);
        break;
      case 't':
        bytes.addByte(9);
        break;
      case '\\':
        bytes.addByte(92);
        break;
      case 'x':
        if (i + 2 >= input.length ||
            !RegExp(r'^[0-9a-fA-F]{2}$')
                .hasMatch(input.substring(i + 1, i + 3))) {
          throw const FormatException(r'十六进制转义应为 \xHH');
        }
        bytes.addByte(int.parse(input.substring(i + 1, i + 3), radix: 16));
        i += 2;
        break;
      default:
        throw FormatException('不支持的转义：${input[i]}');
    }
    start = i + 1;
  }
  bytes.add(utf8.encode(input.substring(start)));
  return bytes.toBytes();
}

class _LogEntry {
  _LogEntry(this.direction, this.time, {this.data, this.message});

  final String direction;
  final DateTime time;
  final Uint8List? data;
  final String? message;
}

class _SendHistory {
  _SendHistory(this.text, this.hex);

  final String text;
  final bool hex;
}

class _RecordingOptions {
  _RecordingOptions(this.name, this.includeTimestamp, this.append);

  final String name;
  final bool includeTimestamp;
  final bool append;
}

const _baudRates = [
  9600,
  19200,
  38400,
  57600,
  115200,
  128000,
  230400,
  256000,
  460800,
  500000,
  576000,
  921600,
  1000000,
  1152000,
  1500000,
  2000000,
  2500000,
  3000000,
];

class PhoneCommApp extends StatelessWidget {
  const PhoneCommApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'PhoneComm 通信助手',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          primarySwatch: Colors.blue,
          primaryColor: _linkBlue,
          colorScheme: const ColorScheme.light(
              primary: _linkBlue, secondary: _connectedGreen, onSurface: _ink),
          scaffoldBackgroundColor: const Color(0xFFF3F6FA),
          appBarTheme: const AppBarTheme(
              backgroundColor: Colors.white,
              foregroundColor: _ink,
              elevation: 0),
          elevatedButtonTheme: ElevatedButtonThemeData(
              style: ElevatedButton.styleFrom(
                  minimumSize: const Size(88, 48), elevation: 0)),
          outlinedButtonTheme: OutlinedButtonThemeData(
              style: OutlinedButton.styleFrom(minimumSize: const Size(72, 48))),
          inputDecorationTheme: const InputDecorationTheme(
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder()),
          cardTheme: const CardTheme(elevation: 0),
          chipTheme: ChipThemeData.fromDefaults(
            primaryColor: _linkBlue,
            secondaryColor: const Color(0xFFD8E8FC),
            labelStyle: const TextStyle(fontSize: 13, color: _ink),
          ).copyWith(backgroundColor: const Color(0xFFF0F3F7)),
        ),
        home: const SerialPage(),
      );
}

class SerialPage extends StatefulWidget {
  const SerialPage({Key? key}) : super(key: key);

  @override
  State<SerialPage> createState() => _SerialPageState();
}

class _SerialPageState extends State<SerialPage> {
  final _sendController = TextEditingController();
  final _sendFocusNode = FocusNode();
  final _hostController = TextEditingController();
  final _tcpPortController = TextEditingController(text: '9000');
  final _periodController = TextEditingController(text: '1000');
  final _logScrollController = ScrollController();
  final _entries = <_LogEntry>[];
  final _history = <_SendHistory>[];
  List<UsbDevice> _devices = [];
  UsbDevice? _selectedDevice;
  UsbPort? _port;
  late final TcpTransport _tcp;
  bool _tcpWasConnected = false;
  _ConnectionMode _mode = _ConnectionMode.usb;
  List<String> _localAddresses = [];
  String? _networkError;
  StreamSubscription<Uint8List>? _receiveSubscription;
  StreamSubscription<UsbEvent>? _usbSubscription;
  String? _connectedDeviceName;
  String _status = '请连接 USB 转串口模块并扫描设备';
  int _baudRate = 115200;
  int _dataBits = UsbPort.DATABITS_8;
  int _stopBits = UsbPort.STOPBITS_1;
  int _parity = UsbPort.PARITY_NONE;
  int _flowControl = UsbPort.FLOW_CONTROL_OFF;
  int _rxBytes = 0;
  int _txBytes = 0;
  int _generation = 0;
  bool _busy = false;
  bool _sending = false;
  bool _hexSend = false;
  bool _hexReceive = false;
  bool _interpretEscapes = true;
  bool _showTime = true;
  bool _autoScroll = true;
  bool _wrapLines = true;
  bool _showReceive = true;
  bool _dtr = false;
  bool _rts = false;
  bool _repeat = false;
  bool _recording = false;
  bool _recordBusy = false;
  bool _recordFailed = false;
  bool _recordTimestamp = true;
  String? _recordName;
  StringBuffer _recordBuffer = StringBuffer();
  Future<void> _recordWrite = Future<void>.value();
  String _lineEnding = '无';
  Timer? _refreshTimer;
  Timer? _repeatTimer;

  bool get _connected =>
      _mode == _ConnectionMode.usb ? _port != null : _tcp.isConnected;

  bool get _active => _connected || _tcp.isListening;

  @override
  void initState() {
    super.initState();
    _tcp = TcpTransport(
        onData: _onReceived,
        onStateChanged: (message) {
          if (!mounted || _mode == _ConnectionMode.usb) return;
          if (_tcpWasConnected && !_tcp.isConnected) {
            ++_generation;
            _stopRepeat();
          }
          _tcpWasConnected = _tcp.isConnected;
          setState(() => _status = message);
          _record(_LogEntry('SYS', DateTime.now(), message: message));
        });
    _usbSubscription = UsbSerial.usbEventStream?.listen((event) {
      if (_mode == _ConnectionMode.usb &&
          event.event == UsbEvent.ACTION_USB_DETACHED &&
          event.device?.deviceName == _selectedDevice?.deviceName) {
        _disconnect('设备已拔出');
      }
      _scanDevices();
    }, onError: (Object error) => _showError('USB 事件错误：$error'));
    _scanDevices();
  }

  Future<void> _scanDevices() async {
    try {
      final devices = await UsbSerial.listDevices();
      if (!mounted) return;
      final selectedName = _selectedDevice?.deviceName;
      final selected =
          devices.where((device) => device.deviceName == selectedName);
      setState(() {
        _devices = devices;
        _selectedDevice = selected.isNotEmpty
            ? selected.first
            : (devices.isEmpty ? null : devices.first);
      });
      if (_connectedDeviceName != null &&
          !devices.any((device) => device.deviceName == _connectedDeviceName)) {
        await _disconnect('设备已断开');
      }
    } catch (error) {
      _showError('扫描失败：$error');
    }
  }

  Future<void> _connect() async {
    final device = _selectedDevice;
    if (device == null || _busy) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _status = '正在请求 USB 权限并连接…';
    });

    UsbPort? port;
    try {
      port = await device.create();
      if (port == null) throw StateError('不支持此 USB 设备');
      if (generation != _generation) return;
      if (!await port.open()) throw StateError('串口打开失败');
      if (generation != _generation) return;
      await port.setPortParameters(
        _baudRate,
        _dataBits,
        _stopBits,
        _parity,
      );
      if (_flowControl != UsbPort.FLOW_CONTROL_OFF) {
        await port.setFlowControl(_flowControl);
      }
      await port.setDTR(_dtr);
      if (_rts) await port.setRTS(true);
      if (generation != _generation || !mounted) return;
      _receiveSubscription = port.inputStream?.listen(
        _onReceived,
        onError: (Object error) => _disconnect('读取失败：$error'),
        onDone: () => _disconnect('串口已关闭'),
      );
      setState(() {
        _port = port;
        _connectedDeviceName = device.deviceName;
        _busy = false;
        final parity = const ['N', 'O', 'E', 'M', 'S'][_parity];
        final stop = _stopBits == UsbPort.STOPBITS_1_5 ? '1.5' : '$_stopBits';
        _status = '已连接 · $_baudRate $_dataBits$parity$stop';
      });
      _record(_LogEntry('SYS', DateTime.now(),
          message: '已连接 ${device.productName ?? device.deviceName}'));
      port = null; // Ownership moved to _port.
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _busy = false;
          _status = '连接失败：$error';
        });
      }
    } finally {
      if (port != null) {
        try {
          await port.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _disconnect([String message = '已断开']) async {
    ++_generation;
    _stopRepeat();
    final port = _port;
    final subscription = _receiveSubscription;
    _port = null;
    _receiveSubscription = null;
    _connectedDeviceName = null;
    _tcpWasConnected = false;
    final closingTcp = _tcp.close();
    if (mounted) {
      setState(() {
        _busy = false;
        _status = message;
      });
      _record(_LogEntry('SYS', DateTime.now(), message: message));
    }
    await subscription?.cancel();
    await closingTcp;
    if (port != null) {
      try {
        await port.close();
      } catch (error) {
        _showError('关闭串口失败：$error');
      }
    }
  }

  void _selectMode(_ConnectionMode mode) {
    if (_mode == mode) return;
    FocusScope.of(context).unfocus();
    _disconnect();
    setState(() {
      _mode = mode;
      _networkError = null;
      _status = mode == _ConnectionMode.usb
          ? '请选择 USB 设备并打开串口'
          : mode == _ConnectionMode.server
              ? '设置端口后开始监听，等待远端连接'
              : '输入远端地址和端口后连接';
    });
    if (mode == _ConnectionMode.server) _refreshAddresses();
  }

  Future<void> _refreshAddresses() async {
    try {
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      if (!mounted) return;
      setState(() => _localAddresses = interfaces
          .expand((interface) => interface.addresses)
          .map((address) => address.address)
          .toSet()
          .toList());
    } catch (error) {
      _showError('获取本机地址失败：$error');
    }
  }

  Future<void> _connectNetwork() async {
    final port = int.tryParse(_tcpPortController.text.trim());
    final host = _hostController.text.trim();
    if (port == null ||
        port < 1 ||
        port > 65535 ||
        (_mode == _ConnectionMode.client &&
            (host.isEmpty || RegExp(r'\s|://|/').hasMatch(host)))) {
      setState(() => _networkError = port == null || port < 1 || port > 65535
          ? '端口请输入 1–65535 的整数'
          : '请输入 IP 地址或域名，不含协议和路径');
      return;
    }
    FocusScope.of(context).unfocus();
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _networkError = null;
      _status =
          _mode == _ConnectionMode.server ? '正在启动监听…' : '正在连接 $host:$port…';
    });
    try {
      if (_mode == _ConnectionMode.server) {
        await _tcp.listen(port);
      } else {
        await _tcp.connect(host, port);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _networkError = '连接失败：$error');
        _showError('连接失败：$error');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _write(Uint8List bytes) async {
    if (_mode == _ConnectionMode.usb) {
      final port = _port;
      if (port == null) throw StateError('串口已断开');
      await port.write(bytes);
    } else {
      await _tcp.write(bytes);
    }
  }

  Future<void> _send() async {
    if (!_connected || _sending) return;
    final generation = _generation;
    try {
      final input = _sendController.text;
      final payload = input.isEmpty
          ? Uint8List(0)
          : (_hexSend
              ? parseHex(input)
              : encodeText(input, escapes: _interpretEscapes));
      final suffix = _lineEnding == 'CRLF'
          ? '\r\n'
          : _lineEnding == 'CR'
              ? '\r'
              : _lineEnding == 'LF'
                  ? '\n'
                  : '';
      final bytes = Uint8List.fromList([...payload, ...utf8.encode(suffix)]);
      if (bytes.isEmpty) return;
      setState(() => _sending = true);
      await _write(bytes);
      if (generation != _generation || !mounted) return;
      _txBytes += bytes.length;
      _record(_LogEntry('TX', DateTime.now(), data: bytes));
      if (input.isNotEmpty) {
        _history
            .removeWhere((item) => item.text == input && item.hex == _hexSend);
        _history.insert(0, _SendHistory(input, _hexSend));
        if (_history.length > 20) _history.removeLast();
      }
    } catch (error) {
      if (generation == _generation) {
        _showError('发送失败：$error');
        _stopRepeat();
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _onReceived(Uint8List bytes) {
    _rxBytes += bytes.length;
    _record(_LogEntry('RX', DateTime.now(), data: Uint8List.fromList(bytes)));
  }

  void _record(_LogEntry entry) {
    _entries.add(entry);
    if (_entries.length > 800) _entries.removeRange(0, _entries.length - 800);
    if (_recording && !_recordFailed) {
      _recordBuffer.write(formatLogLine(entry.direction, entry.time,
          data: entry.data,
          message: entry.message,
          includeTimestamp: _recordTimestamp));
    }
    _scheduleRefresh();
  }

  void _queueRecordWrite(String text) {
    if (text.isEmpty) return;
    _recordWrite = _recordWrite.then((_) async {
      if (_recordFailed) return;
      await _fileChannel.invokeMethod<void>('appendRecording', {'text': text});
    }).catchError((Object error) {
      _recordFailed = true;
      if (mounted) {
        setState(() {
          _recording = false;
          _status = '记录失败：$error';
        });
      }
    });
  }

  void _flushRecording() {
    final text = _recordBuffer.toString();
    _recordBuffer = StringBuffer();
    _queueRecordWrite(text);
  }

  void _scheduleRefresh() {
    _refreshTimer ??= Timer(const Duration(milliseconds: 80), () {
      _refreshTimer = null;
      if (!mounted) return;
      _flushRecording();
      setState(() {});
      if (_autoScroll) _scrollToLatest();
    });
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _logScrollController.hasClients) {
        _logScrollController
            .jumpTo(_logScrollController.position.maxScrollExtent);
      }
    });
  }

  void _stopRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
    if (mounted && _repeat) setState(() => _repeat = false);
  }

  void _toggleRepeat() {
    if (_repeat) {
      _stopRepeat();
      return;
    }
    final period = int.tryParse(_periodController.text.trim());
    if (period == null || period < 100 || period > 60000) {
      _showError('定时间隔请输入 100–60000 毫秒');
      return;
    }
    if (!_connected) {
      _showError('请先建立通信连接');
      return;
    }
    setState(() => _repeat = true);
    _repeatTimer =
        Timer.periodic(Duration(milliseconds: period), (_) => _send());
    _send();
  }

  Future<void> _sendFile() async {
    if (!_connected || _sending) return;
    final generation = _generation;
    _stopRepeat();
    String? path;
    RandomAccessFile? source;
    try {
      path = await _fileChannel.invokeMethod<String>('pickFile');
      if (path == null ||
          !mounted ||
          generation != _generation ||
          !_connected) {
        return;
      }
      setState(() {
        _sending = true;
        _status = '正在发送文件…';
      });
      source = await File(path).open();
      var sent = 0;
      while (true) {
        if (generation != _generation || !_connected) {
          throw StateError('通信连接已断开');
        }
        final chunk = await source.read(4096);
        if (generation != _generation || !_connected) {
          throw StateError('通信连接已断开');
        }
        if (chunk.isEmpty) break;
        await _write(Uint8List.fromList(chunk));
        if (generation != _generation) throw StateError('通信连接已断开');
        sent += chunk.length;
        _txBytes += chunk.length;
        _status = '正在发送文件：$sent 字节';
        _scheduleRefresh();
      }
      _record(_LogEntry('SYS', DateTime.now(), message: '文件发送完成：$sent 字节'));
      if (mounted) setState(() => _status = '文件发送完成：$sent 字节');
    } catch (error) {
      if (generation == _generation) _showError('文件发送失败：$error');
    } finally {
      try {
        await source?.close();
      } catch (_) {}
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _saveLog() async {
    if (_entries.isEmpty) return;
    final text = StringBuffer();
    for (final entry in List<_LogEntry>.of(_entries)) {
      text.write(formatLogLine(entry.direction, entry.time,
          data: entry.data, message: entry.message));
    }
    try {
      final saved = await _fileChannel
          .invokeMethod<bool>('saveLog', {'text': text.toString()});
      if (saved == true) _showError('日志已保存');
    } catch (error) {
      _showError('保存日志失败：$error');
    }
  }

  Future<void> _toggleRecording() async {
    if (_recordBusy) return;
    if (_recording) {
      setState(() {
        _recording = false;
        _recordBusy = true;
      });
      _flushRecording();
      await _recordWrite;
      try {
        await _fileChannel.invokeMethod<bool>('stopRecording');
        if (!_recordFailed) _showError('记录已停止：$_recordName');
      } catch (error) {
        _showError('停止记录失败：$error');
      } finally {
        if (mounted) setState(() => _recordBusy = false);
      }
      return;
    }

    var nameInput = 'serial-log.txt';
    var includeTimestamp = true;
    var append = true;
    String? nameError;
    final options = await showDialog<_RecordingOptions>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, refresh) => AlertDialog(
          title: const Text('开始实时记录'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('保存到 下载/PhoneComm/'),
              TextFormField(
                initialValue: nameInput,
                onChanged: (value) => nameInput = value,
                decoration:
                    InputDecoration(labelText: '文件名', errorText: nameError),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('文件包含时间戳'),
                value: includeTimestamp,
                onChanged: (value) =>
                    refresh(() => includeTimestamp = value ?? false),
              ),
              RadioListTile<bool>(
                contentPadding: EdgeInsets.zero,
                title: const Text('追加到同名文件'),
                value: true,
                groupValue: append,
                onChanged: (value) => refresh(() => append = value ?? true),
              ),
              RadioListTile<bool>(
                contentPadding: EdgeInsets.zero,
                title: const Text('清空同名文件'),
                value: false,
                groupValue: append,
                onChanged: (value) => refresh(() => append = value ?? false),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消')),
            TextButton(
              onPressed: () {
                try {
                  final name = normalizeRecordFileName(nameInput);
                  Navigator.pop(dialogContext,
                      _RecordingOptions(name, includeTimestamp, append));
                } on FormatException catch (error) {
                  refresh(() => nameError = error.message);
                }
              },
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || options == null) return;

    setState(() => _recordBusy = true);
    try {
      final location =
          await _fileChannel.invokeMethod<String>('startRecording', {
        'name': options.name,
        'append': options.append,
      });
      if (!mounted) return;
      setState(() {
        _recordName = options.name;
        _recordTimestamp = options.includeTimestamp;
        _recordFailed = false;
        _recording = true;
        _status = '正在记录：$location';
      });
    } catch (error) {
      _showError('开始记录失败：$error');
    } finally {
      if (mounted) setState(() => _recordBusy = false);
    }
  }

  Future<void> _appendRecentToRecording() async {
    if (!_recording || _entries.isEmpty) return;
    _flushRecording();
    final entries = List<_LogEntry>.of(_entries);
    _queueRecordWrite(entries
        .map((entry) => formatLogLine(entry.direction, entry.time,
            data: entry.data,
            message: entry.message,
            includeTimestamp: _recordTimestamp))
        .join());
    await _recordWrite;
    if (!_recordFailed) _showError('最近 ${entries.length} 条已追加到 $_recordName');
  }

  Future<void> _setDtr(bool value) async {
    try {
      await _port?.setDTR(value);
      if (mounted) setState(() => _dtr = value);
    } catch (error) {
      _showError('设置 DTR 失败：$error');
    }
  }

  Future<void> _setRts(bool value) async {
    try {
      await _port?.setRTS(value);
      if (mounted) setState(() => _rts = value);
    } catch (error) {
      _showError('设置 RTS 失败：$error');
    }
  }

  void _showError(String message) {
    if (mounted) setState(() => _status = message);
  }

  @override
  void dispose() {
    ++_generation;
    _refreshTimer?.cancel();
    _repeatTimer?.cancel();
    if (_recording) {
      _flushRecording();
      _recordWrite
          .then((_) => _fileChannel.invokeMethod<bool>('stopRecording'))
          .catchError((Object _) {});
    }
    _usbSubscription?.cancel();
    _receiveSubscription?.cancel();
    _port?.close();
    _tcp.close();
    _sendController.dispose();
    _sendFocusNode.dispose();
    _hostController.dispose();
    _tcpPortController.dispose();
    _periodController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  Widget _settingDropdown(
    String label,
    int value,
    Map<int, String> values,
    bool enabled,
    ValueChanged<int> onChanged,
  ) =>
      DropdownButtonFormField<int>(
        value: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: values.entries
            .map((item) =>
                DropdownMenuItem<int>(value: item.key, child: Text(item.value)))
            .toList(),
        onChanged: enabled
            ? (value) {
                if (value != null) onChanged(value);
              }
            : null,
      );

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, refresh) {
          void update(VoidCallback change) {
            setState(change);
            refresh(() {});
          }

          final editable = _port == null && !_busy;
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.of(sheetContext).size.height * 0.82,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (_mode == _ConnectionMode.usb) ...[
                    const Text('串口设置',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    if (!editable)
                      const Text('修改串口参数前请先断开连接',
                          style: TextStyle(color: Colors.orange)),
                    Row(children: [
                      Expanded(
                        child: _settingDropdown(
                            '数据位',
                            _dataBits,
                            const {5: '5', 6: '6', 7: '7', 8: '8'},
                            editable,
                            (value) => update(() => _dataBits = value)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _settingDropdown(
                            '停止位',
                            _stopBits,
                            const {1: '1', 3: '1.5', 2: '2'},
                            editable,
                            (value) => update(() => _stopBits = value)),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: _settingDropdown(
                            '校验位',
                            _parity,
                            const {
                              0: '无',
                              1: '奇',
                              2: '偶',
                              3: 'Mark',
                              4: 'Space'
                            },
                            editable,
                            (value) => update(() => _parity = value)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _settingDropdown(
                            '流控',
                            _flowControl,
                            const {
                              0: '无',
                              1: 'RTS/CTS',
                              2: 'DTR/DSR',
                              3: 'XON/XOFF'
                            },
                            editable,
                            (value) => update(() => _flowControl = value)),
                      ),
                    ]),
                    const Divider(height: 32),
                  ],
                  const Text('接收设置',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动滚屏'),
                    value: _autoScroll,
                    onChanged: (value) => update(() => _autoScroll = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('接收自动换行'),
                    value: _wrapLines,
                    onChanged: (value) => update(() => _wrapLines = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('显示接收数据'),
                    value: _showReceive,
                    onChanged: (value) => update(() => _showReceive = value),
                  ),
                  const Divider(height: 32),
                  const Text('发送设置',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('解析转义符'),
                    subtitle: const Text(r'支持 \r、\n、\t、\\ 和 \xHH'),
                    value: _interpretEscapes,
                    onChanged: _hexSend
                        ? null
                        : (value) => update(() => _interpretEscapes = value),
                  ),
                  DropdownButtonFormField<String>(
                    value: _lineEnding,
                    decoration: const InputDecoration(labelText: '发送附加'),
                    items: const ['无', 'CR', 'LF', 'CRLF']
                        .map((value) =>
                            DropdownMenuItem(value: value, child: Text(value)))
                        .toList(),
                    onChanged: (value) {
                      if (value != null) update(() => _lineEnding = value);
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _periodController,
                    keyboardType: TextInputType.number,
                    enabled: !_repeat,
                    decoration: const InputDecoration(
                        labelText: '定时发送间隔（毫秒）',
                        helperText: '100–60000，关闭定时发送后可修改'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _modeSelector() => Material(
        color: Colors.white,
        child: Row(
          children: _ConnectionMode.values.map((mode) {
            final selected = _mode == mode;
            final label = const ['USB 串口', 'TCP 服务端', 'TCP 客户端'][mode.index];
            return Expanded(
              child: Semantics(
                selected: selected,
                button: true,
                child: InkWell(
                  key: ValueKey('mode-${mode.name}'),
                  onTap: () => _selectMode(mode),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 58),
                    decoration: BoxDecoration(
                      color: selected ? const Color(0xFFE9F1FC) : null,
                      border: Border(
                          bottom: BorderSide(
                              width: 3,
                              color:
                                  selected ? _linkBlue : Colors.transparent)),
                    ),
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                              const [
                                Icons.usb,
                                Icons.router,
                                Icons.lan
                              ][mode.index],
                              size: 19,
                              color: selected ? _linkBlue : _ink),
                          const SizedBox(height: 3),
                          Text(label,
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  color: selected ? _linkBlue : _ink)),
                        ]),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      );

  Widget _networkPanel() {
    final server = _mode == _ConnectionMode.server;
    final enabled = !_active && !_busy;
    final state = _connected
        ? '已连接'
        : _tcp.isListening
            ? '等待接入'
            : '未连接';
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFDCE5EF))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(server ? '等待远端接入' : '连接远端设备',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: _ink)),
          const Spacer(),
          Icon(Icons.circle,
              size: 8,
              color: _connected
                  ? _connectedGreen
                  : _tcp.isListening
                      ? const Color(0xFFB56A12)
                      : Colors.grey),
          const SizedBox(width: 6),
          Text(state,
              style: TextStyle(
                  fontSize: 12, color: _connected ? _connectedGreen : _ink)),
        ]),
        const SizedBox(height: 12),
        if (!server) ...[
          TextField(
            key: const ValueKey('tcp-host'),
            controller: _hostController,
            enabled: enabled,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
                labelText: '远端 IP / 域名', hintText: '例如 192.168.1.10'),
          ),
          const SizedBox(height: 12),
        ],
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
              child: TextField(
            key: const ValueKey('tcp-port'),
            controller: _tcpPortController,
            enabled: enabled,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: server ? '监听端口' : '远端端口'),
            onSubmitted: (_) => enabled ? _connectNetwork() : null,
          )),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            key: const ValueKey('network-connect'),
            onPressed: () =>
                _active || _busy ? _disconnect() : _connectNetwork(),
            icon: Icon(
                _active || _busy
                    ? Icons.stop
                    : server
                        ? Icons.wifi_tethering
                        : Icons.link,
                size: 18),
            label: Text(_busy
                ? '取消'
                : server
                    ? (_active ? '停止监听' : '开始监听')
                    : (_active ? '断开' : '连接')),
          ),
        ]),
        if (_networkError != null)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_networkError!,
                  style:
                      const TextStyle(color: Color(0xFFB3261E), fontSize: 12))),
        if (server)
          Row(children: [
            Expanded(
                child: SelectableText(
                    _localAddresses.isEmpty
                        ? '暂无本机 IPv4，请检查 Wi-Fi 或热点'
                        : '本机 IPv4：${_localAddresses.join(' / ')}',
                    style: const TextStyle(fontSize: 12, color: _ink))),
            IconButton(
                tooltip: '刷新本机地址',
                onPressed: _refreshAddresses,
                icon: const Icon(Icons.refresh, size: 20)),
          ])
        else
          const SizedBox(height: 8),
        Text(
            _tcp.peer != null
                ? '对端 ${_tcp.peer}'
                : server
                    ? '单客户端接入；断开后继续等待'
                    : '连接成功后可发送文本、HEX 或文件',
            style: const TextStyle(fontSize: 12, color: Color(0xFF52677A))),
      ]),
    );
  }

  Widget _connectionPanel() => Card(
        margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            Row(children: [
              const Icon(Icons.usb, color: Color(0xFF0876B8), size: 20),
              const SizedBox(width: 6),
              const Text('串口设置',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const Spacer(),
              Text(_port == null ? '未连接' : '已连接',
                  style: TextStyle(
                      color: _port == null ? Colors.grey : Colors.green,
                      fontWeight: FontWeight.w600)),
            ]),
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<UsbDevice>(
                  value: _selectedDevice,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'USB 设备'),
                  items: _devices
                      .map((device) => DropdownMenuItem(
                            value: device,
                            child: Text(
                              device.productName ?? device.deviceName,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ))
                      .toList(),
                  onChanged: _busy || _port != null
                      ? null
                      : (device) => setState(() => _selectedDevice = device),
                ),
              ),
              IconButton(
                  tooltip: '扫描设备',
                  onPressed: _busy ? null : _scanDevices,
                  icon: const Icon(Icons.refresh)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  value: _baudRate,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '波特率'),
                  items: _baudRates
                      .map((rate) =>
                          DropdownMenuItem(value: rate, child: Text('$rate')))
                      .toList(),
                  onChanged: _port != null || _busy
                      ? null
                      : (rate) => setState(() => _baudRate = rate ?? _baudRate),
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: _busy || (_port == null && _selectedDevice == null)
                    ? null
                    : () {
                        if (_port == null) {
                          _connect();
                        } else {
                          _disconnect();
                        }
                      },
                child: Text(_port == null ? '打开' : '关闭'),
              ),
            ]),
            Row(children: [
              FilterChip(
                label: const Text('DTR'),
                selected: _dtr,
                onSelected: _flowControl == UsbPort.FLOW_CONTROL_DSR_DTR
                    ? null
                    : _setDtr,
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('RTS'),
                selected: _rts,
                onSelected: _flowControl == UsbPort.FLOW_CONTROL_RTS_CTS
                    ? null
                    : _setRts,
              ),
              const Spacer(),
              Text(
                  '$_dataBits 位 · ${_stopBits == UsbPort.STOPBITS_1_5 ? '1.5' : _stopBits} 停止位',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
          ]),
        ),
      );

  Widget _logItem(_LogEntry entry) {
    final data = entry.data;
    final value = entry.message ??
        (data == null
            ? ''
            : _hexReceive
                ? toHex(data)
                : utf8.decode(data, allowMalformed: true));
    final color = entry.direction == 'RX'
        ? const Color(0xFF0876B8)
        : entry.direction == 'TX'
            ? const Color(0xFFDE7A10)
            : Colors.grey;
    final content = SelectableText(value,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFECF0F5)))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_showTime)
          Text(formatTimestamp(entry.time),
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 30,
            child: Text(entry.direction,
                style: TextStyle(
                    fontSize: 11, color: color, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _wrapLines
                ? content
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal, child: content),
          ),
        ]),
      ]),
    );
  }

  Widget _logPanel() {
    final visibleEntries = _showReceive
        ? _entries
        : _entries.where((entry) => entry.direction != 'RX').toList();
    return Expanded(
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFDCE5EF)),
        ),
        child: visibleEntries.isEmpty
            ? const Center(
                child:
                    Text('连接后在此查看收发数据', style: TextStyle(color: Colors.grey)))
            : ListView.builder(
                controller: _logScrollController,
                itemCount: visibleEntries.length,
                itemBuilder: (context, index) =>
                    _logItem(visibleEntries[index]),
              ),
      ),
    );
  }

  Widget _composer() => Container(
        key: const ValueKey('send-composer'),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFDCE5EF))),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const Text('数据发送',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const Spacer(),
            ChoiceChip(
              label: const Text('ASCII'),
              selected: !_hexSend,
              onSelected: (_) => setState(() => _hexSend = false),
            ),
            const SizedBox(width: 6),
            ChoiceChip(
              label: const Text('HEX'),
              selected: _hexSend,
              onSelected: (_) => setState(() => _hexSend = true),
            ),
            PopupMenuButton<_SendHistory>(
              tooltip: '发送历史',
              enabled: _history.isNotEmpty,
              icon: const Icon(Icons.history),
              onSelected: (item) {
                _sendController.text = item.text;
                setState(() => _hexSend = item.hex);
              },
              itemBuilder: (_) => _history
                  .map((item) => PopupMenuItem<_SendHistory>(
                      value: item,
                      child: Row(children: [
                        Text(item.hex ? 'HEX' : 'TXT'),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(item.text.replaceAll('\n', ' '),
                                overflow: TextOverflow.ellipsis)),
                      ])))
                  .toList(),
            ),
            IconButton(
              tooltip: '发送文件',
              onPressed: !_connected || _sending ? null : _sendFile,
              icon: const Icon(Icons.attach_file),
            ),
          ]),
          TextField(
            key: const ValueKey('send-input'),
            controller: _sendController,
            focusNode: _sendFocusNode,
            minLines: 1,
            maxLines: 2,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: _hexSend ? '例如 01 A0 FF' : '输入要发送的文本',
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Text('附加 $_lineEnding',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const Spacer(),
            OutlinedButton.icon(
              onPressed:
                  !_connected || (_sending && !_repeat) ? null : _toggleRepeat,
              icon: Icon(_repeat ? Icons.stop : Icons.timer, size: 18),
              label: Text(_repeat ? '停止定时' : '定时'),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: !_connected || _sending ? null : _send,
              icon: const Icon(Icons.send, size: 18),
              label: const Text('发送'),
            ),
          ]),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    final editingMessage = keyboardOpen && _sendFocusNode.hasFocus;
    return Scaffold(
      backgroundColor: const Color(0xFFF3F6FA),
      appBar: AppBar(
        title: const Text('PhoneComm',
            style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5)),
        actions: [
          IconButton(
              tooltip: '更多设置',
              onPressed: () {
                FocusScope.of(context).unfocus();
                _showSettings();
              },
              icon: const Icon(Icons.tune)),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          // 横屏或键盘占满屏幕时，允许滚动到连接与发送控件。
          final minimumHeight =
              keyboardOpen ? (editingMessage ? 300.0 : 420.0) : 680.0;
          return SingleChildScrollView(
            child: SizedBox(
              height: constraints.maxHeight < minimumHeight
                  ? minimumHeight
                  : constraints.maxHeight,
              child: Column(children: [
                if (!editingMessage) _modeSelector(),
                if (!editingMessage)
                  _mode == _ConnectionMode.usb
                      ? _connectionPanel()
                      : _networkPanel(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 8, 4),
                  child: Column(children: [
                    Row(children: [
                      const Text('数据日志',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                      const Spacer(),
                      IconButton(
                          tooltip: _showTime ? '隐藏界面时间戳' : '显示界面时间戳',
                          onPressed: () =>
                              setState(() => _showTime = !_showTime),
                          color: _showTime ? Colors.blue : Colors.grey,
                          icon: const Icon(Icons.access_time)),
                      IconButton(
                          tooltip: _autoScroll ? '关闭自动滚屏' : '开启自动滚屏',
                          onPressed: () {
                            setState(() => _autoScroll = !_autoScroll);
                            if (_autoScroll) _scrollToLatest();
                          },
                          icon: Icon(_autoScroll
                              ? Icons.vertical_align_bottom
                              : Icons.pause_circle_outline)),
                      IconButton(
                          tooltip: _recording ? '停止实时记录' : '开始实时记录',
                          onPressed: _recordBusy ? null : _toggleRecording,
                          color: _recording ? Colors.red : null,
                          icon: Icon(_recording
                              ? Icons.stop_circle_outlined
                              : Icons.fiber_manual_record_outlined)),
                      PopupMenuButton<String>(
                        tooltip: '日志操作',
                        icon: const Icon(Icons.more_vert),
                        onSelected: (action) {
                          if (action == 'save') {
                            _saveLog();
                          } else if (action == 'append') {
                            _appendRecentToRecording();
                          } else if (action == 'clear') {
                            setState(_entries.clear);
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                              value: 'save',
                              enabled: _entries.isNotEmpty,
                              child: const Text('导出最近800条到文件')),
                          PopupMenuItem(
                              value: 'append',
                              enabled: _recording && _entries.isNotEmpty,
                              child: const Text('追加最近800条到记录文件')),
                          const PopupMenuItem(
                              value: 'clear', child: Text('清除日志')),
                        ],
                      ),
                    ]),
                    Row(children: [
                      if (_recording)
                        Expanded(
                          child: Text('● 正在记录 $_recordName',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.red, fontSize: 12)),
                        )
                      else
                        const Spacer(),
                      ChoiceChip(
                        label: const Text('ASCII'),
                        selected: !_hexReceive,
                        onSelected: (_) => setState(() => _hexReceive = false),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const Text('HEX'),
                        selected: _hexReceive,
                        onSelected: (_) => setState(() => _hexReceive = true),
                      ),
                    ]),
                  ]),
                ),
                _logPanel(),
                Offstage(
                    key: const ValueKey('composer-visibility'),
                    offstage: keyboardOpen && !editingMessage,
                    child: _composer()),
                if (!keyboardOpen)
                  Container(
                    height: 38,
                    padding: const EdgeInsets.only(left: 12),
                    color: const Color(0xFFE6EDF5),
                    child: Row(children: [
                      Expanded(
                          child: Text(_status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12))),
                      Text('RX:$_rxBytes  TX:$_txBytes',
                          style: const TextStyle(
                              fontSize: 12, fontFamily: 'monospace')),
                      IconButton(
                          tooltip: '计数清零',
                          padding: EdgeInsets.zero,
                          iconSize: 18,
                          onPressed: () => setState(() {
                                _rxBytes = 0;
                                _txBytes = 0;
                              }),
                          icon: const Icon(Icons.restart_alt)),
                    ]),
                  ),
              ]),
            ),
          );
        }),
      ),
    );
  }
}
