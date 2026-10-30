import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class TcpTransport {
  TcpTransport({required this.onData, required this.onStateChanged});

  final void Function(Uint8List) onData;
  final void Function(String) onStateChanged;
  ServerSocket? _server;
  StreamSubscription<Socket>? _serverSubscription;
  Socket? _socket;
  StreamSubscription<Uint8List>? _socketSubscription;
  int _generation = 0;

  bool get isConnected => _socket != null;
  bool get isListening => _server != null;
  String? get peer {
    final socket = _socket;
    if (socket == null) return null;
    final address = socket.remoteAddress.address;
    return '${socket.remoteAddress.type == InternetAddressType.IPv6 ? '[$address]' : address}:${socket.remotePort}';
  }

  int? get port => _server?.port;

  Future<void> connect(String host, int port) async {
    if (host.trim().isEmpty) throw const FormatException('请输入远端地址');
    if (port < 1 || port > 65535) {
      throw const FormatException('端口范围为 1–65535');
    }
    final generation = ++_generation;
    await _closeResources();
    if (generation != _generation) return;
    final socket = await Socket.connect(host.trim(), port,
        timeout: const Duration(seconds: 8));
    if (generation != _generation) {
      socket.destroy();
      return;
    }
    _attach(socket, generation);
    onStateChanged('已连接 $peer');
  }

  Future<void> listen(int port) async {
    if (port < 0 || port > 65535) {
      throw const FormatException('端口范围为 0–65535');
    }
    final generation = ++_generation;
    await _closeResources();
    if (generation != _generation) return;
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    if (generation != _generation) {
      await server.close();
      return;
    }
    _server = server;
    _serverSubscription = server.listen((socket) {
      if (generation != _generation || _socket != null) {
        socket.destroy();
        return;
      }
      // shortcut: 单客户端避免发送目标歧义，需并发会话时再增加客户端选择。
      _attach(socket, generation);
      onStateChanged('客户端已连接 $peer');
    }, onError: (Object error) {
      _stopListening(generation, 'TCP 监听失败：$error');
    }, onDone: () {
      if (identical(_server, server)) {
        _stopListening(generation, 'TCP 监听已停止');
      }
    });
    onStateChanged('正在监听 0.0.0.0:${server.port}，等待客户端');
  }

  void _attach(Socket socket, int generation) {
    _socket = socket;
    _socketSubscription = socket.listen((bytes) {
      if (generation == _generation && identical(_socket, socket)) {
        onData(bytes);
      }
    }, onError: (Object error) {
      _detach(socket, 'TCP 连接错误：$error');
    }, onDone: () {
      _detach(socket, isListening ? '客户端已断开，继续等待连接' : 'TCP 连接已断开');
    }, cancelOnError: true);
  }

  void _detach(Socket socket, String message) {
    if (!identical(_socket, socket)) return;
    _socket = null;
    final subscription = _socketSubscription;
    _socketSubscription = null;
    subscription?.cancel();
    socket.destroy();
    onStateChanged(message);
  }

  Future<void> _stopListening(int generation, String message) async {
    if (generation != _generation) return;
    final closingGeneration = ++_generation;
    await _closeResources();
    if (closingGeneration == _generation) onStateChanged(message);
  }

  Future<void> write(Uint8List bytes) async {
    final socket = _socket;
    if (socket == null) throw StateError('TCP 尚未连接');
    try {
      socket.add(bytes);
      await socket.flush();
    } catch (error) {
      _detach(socket, 'TCP 发送失败：$error');
      rethrow;
    }
  }

  Future<void> close() async {
    ++_generation;
    await _closeResources();
  }

  Future<void> _closeResources() async {
    final socket = _socket;
    final socketSubscription = _socketSubscription;
    final server = _server;
    final serverSubscription = _serverSubscription;
    _socket = null;
    _socketSubscription = null;
    _server = null;
    _serverSubscription = null;
    socket?.destroy();
    await socketSubscription?.cancel();
    await serverSubscription?.cancel();
    await server?.close();
  }
}
