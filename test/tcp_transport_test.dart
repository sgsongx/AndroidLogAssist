import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_comm/tcp_transport.dart';

Future<void> waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('TCP state did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('server exchanges bytes, rejects extra peers and accepts reconnection',
      () async {
    final received = <int>[];
    final states = <String>[];
    final transport =
        TcpTransport(onData: received.addAll, onStateChanged: states.add);
    addTearDown(transport.close);
    await transport.listen(0);
    expect(transport.isListening, isTrue);
    expect(transport.isConnected, isFalse);
    final first = await Socket.connect('127.0.0.1', transport.port!);
    addTearDown(first.destroy);
    final firstReceived = <int>[];
    first.listen(firstReceived.addAll);
    await waitFor(() => transport.isConnected);
    expect(transport.peer, startsWith('127.0.0.1:'));
    first.add([0, 127, 255]);
    await first.flush();
    await waitFor(() => received.length == 3);
    expect(received, [0, 127, 255]);
    await transport.write(Uint8List.fromList([42, 0, 255]));
    await waitFor(() => firstReceived.length == 3);
    expect(firstReceived, [42, 0, 255]);

    final extra = await Socket.connect('127.0.0.1', transport.port!);
    addTearDown(extra.destroy);
    final extraClosed = Completer<void>();
    extra.listen((_) {},
        onDone: extraClosed.complete,
        onError: (Object _) => extraClosed.complete());
    await extraClosed.future.timeout(const Duration(seconds: 3));
    expect(transport.isConnected, isTrue);
    first.destroy();
    await waitFor(() => !transport.isConnected);
    expect(transport.isListening, isTrue);
    final second = await Socket.connect('127.0.0.1', transport.port!);
    addTearDown(second.destroy);
    second.listen((_) {});
    await waitFor(() => transport.isConnected);
    second.add([17]);
    await second.flush();
    await waitFor(() => received.length == 4);
    expect(received.last, 17);
    expect(states.any((state) => state.contains('继续等待')), isTrue);

    final listeningPort = transport.port!;
    await transport.close();
    expect(transport.isListening, isFalse);
    expect(transport.isConnected, isFalse);
    final rebound = await ServerSocket.bind('127.0.0.1', listeningPort);
    await rebound.close();
  });

  test('client exchanges bytes and clears state when remote closes', () async {
    final server = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(server.close);
    final accepted = server.first;
    final received = <int>[];
    final states = <String>[];
    final transport =
        TcpTransport(onData: received.addAll, onStateChanged: states.add);
    addTearDown(transport.close);
    await transport.connect('127.0.0.1', server.port);
    final peer = await accepted;
    addTearDown(peer.destroy);
    final peerReceived = <int>[];
    peer.listen(peerReceived.addAll);
    expect(transport.isConnected, isTrue);
    expect(transport.isListening, isFalse);
    await transport.write(Uint8List.fromList([65, 66]));
    await waitFor(() => peerReceived.length == 2);
    expect(peerReceived, [65, 66]);
    peer.add([67, 255]);
    await peer.flush();
    await waitFor(() => received.length == 2);
    expect(received, [67, 255]);
    peer.destroy();
    await waitFor(() => !transport.isConnected);
    expect(transport.peer, isNull);
    await expectLater(transport.write(Uint8List(1)), throwsStateError);
  });

  test('failed connect and occupied listener leave transport inactive',
      () async {
    final occupied = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(occupied.close);
    final transport = TcpTransport(onData: (_) {}, onStateChanged: (_) {});
    addTearDown(transport.close);
    await expectLater(
        transport.listen(occupied.port), throwsA(isA<SocketException>()));
    expect(transport.isListening, isFalse);
    final closedPort = occupied.port;
    await occupied.close();
    await expectLater(transport.connect('127.0.0.1', closedPort),
        throwsA(isA<SocketException>()));
    expect(transport.isConnected, isFalse);
    await expectLater(transport.connect('', 9000), throwsFormatException);
    await expectLater(
        transport.connect('127.0.0.1', 65536), throwsFormatException);
  });

  test('close invalidates a pending connect or listen', () async {
    final server = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(server.close);
    final transport = TcpTransport(onData: (_) {}, onStateChanged: (_) {});
    addTearDown(transport.close);
    final connecting = transport.connect('127.0.0.1', server.port);
    await transport.close();
    await connecting;
    expect(transport.isConnected, isFalse);
    final listening = transport.listen(0);
    await transport.close();
    await listening;
    expect(transport.isListening, isFalse);
  });
}
