import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_comm/main.dart';

Future<void> _openPage(WidgetTester tester) async {
  const MethodChannel('usb_serial')
      .setMockMethodCallHandler((call) async => <Object>[]);
  const MethodChannel('usb_serial/usb_events')
      .setMockMethodCallHandler((call) async => null);
  tester.binding.window.physicalSizeTestValue = const Size(360, 800);
  tester.binding.window.devicePixelRatioTestValue = 1;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    const MethodChannel('usb_serial').setMockMethodCallHandler(null);
    const MethodChannel('usb_serial/usb_events').setMockMethodCallHandler(null);
    tester.binding.window.clearPhysicalSizeTestValue();
    tester.binding.window.clearDevicePixelRatioTestValue();
    tester.binding.window.clearViewInsetsTestValue();
  });
  await tester.pumpWidget(const PhoneCommApp());
  await tester.pump(const Duration(milliseconds: 100));
}

Finder _key(String name) => find.byKey(ValueKey(name));

Finder _sendButton() => find.ancestor(
    of: find.text('发送'),
    matching: find.byWidgetPredicate((widget) => widget is ElevatedButton));

Finder _repeatButton() => find.ancestor(
    of: find.text('定时'),
    matching: find.byWidgetPredicate((widget) => widget is OutlinedButton));

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('TCP UI state did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  testWidgets('network setup validates endpoints before connecting',
      (tester) async {
    await _openPage(tester);
    await tester.tap(_key('mode-client'));
    await tester.pump();
    expect(tester.widget<ElevatedButton>(_sendButton()).onPressed, isNull);

    await tester.enterText(_key('tcp-port'), '65536');
    await tester.tap(_key('network-connect'));
    await tester.pump();
    expect(find.text('端口请输入 1–65535 的整数'), findsOneWidget);
    await tester.enterText(_key('tcp-port'), '9000');
    await tester.tap(_key('network-connect'));
    await tester.pump();
    expect(find.text('请输入 IP 地址或域名，不含协议和路径'), findsOneWidget);
    await tester.enterText(_key('tcp-host'), 'tcp://127.0.0.1');
    await tester.tap(_key('network-connect'));
    await tester.pump();
    expect(find.text('请输入 IP 地址或域名，不含协议和路径'), findsOneWidget);

    await tester.tap(_key('mode-server'));
    await tester.pump();
    expect(_key('tcp-host'), findsNothing);
    await tester.enterText(_key('tcp-port'), '0');
    await tester.tap(_key('network-connect'));
    await tester.pump();
    expect(find.text('端口请输入 1–65535 的整数'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('client endpoint stays editable when a phone keyboard opens',
      (tester) async {
    await _openPage(tester);
    await tester.tap(_key('mode-client'));
    await tester.pump();
    await tester.tap(_key('tcp-host'));
    tester.binding.window.viewInsetsTestValue = const _KeyboardInsets(300);
    await tester.pump();
    final host = tester.widget<TextField>(_key('tcp-host'));
    expect(host.controller!.selection.isValid, isTrue);
    expect(_key('tcp-host').hitTestable(), findsOneWidget);
    expect(_key('network-connect').hitTestable(), findsOneWidget);
    expect(_key('send-input').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape can scroll to controls in all communication modes',
      (tester) async {
    await _openPage(tester);
    tester.binding.window.physicalSizeTestValue = const Size(800, 360);
    await tester.pump();
    for (final mode in ['usb', 'server', 'client']) {
      await tester.ensureVisible(_key('mode-$mode'));
      await tester.pump();
      await tester.tap(_key('mode-$mode'));
      await tester.pump();
      if (mode != 'usb') {
        await tester.ensureVisible(_key('tcp-port'));
        await tester.pump();
        await tester.enterText(_key('tcp-port'), '0');
        await Scrollable.ensureVisible(tester.element(_key('network-connect')),
            alignment: 0.5);
        await tester.pump();
        expect(_key('network-connect').hitTestable(), findsOneWidget,
            reason: '$mode button ${tester.getRect(_key('network-connect'))}');
        await tester.tap(_key('network-connect'));
        await tester.pump();
        expect(find.text('端口请输入 1–65535 的整数'), findsOneWidget);
      }
      await tester.ensureVisible(_key('send-input'));
      await tester.pump();
      expect(_key('send-input').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('TCP client shares logs and sending and stops on mode change',
      (tester) async {
    await _openPage(tester);
    ServerSocket? server;
    Socket? peer;
    Directory? cache;
    File? pickedFile;
    final fileBytes = List<int>.generate(8193, (index) => index % 256);
    final received = <int>[];
    var closed = false;
    await tester.runAsync(() async {
      cache = await Directory.systemTemp.createTemp('phone_comm_tcp_ui_');
      pickedFile =
          await File('${cache!.path}/payload.bin').writeAsBytes(fileBytes);
      server = await ServerSocket.bind('127.0.0.1', 0);
      server!.listen((socket) {
        peer = socket;
        socket.listen(received.addAll, onDone: () => closed = true);
      });
    });
    const MethodChannel('phone_comm/files').setMockMethodCallHandler(
        (call) async => call.method == 'pickFile' ? pickedFile!.path : null);
    addTearDown(() async {
      const MethodChannel('phone_comm/files').setMockMethodCallHandler(null);
      peer?.destroy();
      await server?.close();
      if (await pickedFile!.exists()) await pickedFile!.delete();
      await cache!.delete();
    });
    await tester.tap(_key('mode-client'));
    await tester.pump();
    await tester.enterText(_key('tcp-host'), '127.0.0.1');
    await tester.enterText(_key('tcp-port'), '${server!.port}');
    await tester.runAsync(() async {
      await tester.tap(_key('network-connect'));
      await _waitFor(() => peer != null);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.text('断开'), findsOneWidget);
    expect(tester.widget<ElevatedButton>(_sendButton()).onPressed, isNotNull);

    await tester.enterText(_key('send-input'), 'phone-to-peer');
    await tester.runAsync(() async {
      await tester.tap(_sendButton());
      await _waitFor(
          () => received.length == utf8.encode('phone-to-peer').length);
      peer!.add(utf8.encode('peer-to-phone'));
      await peer!.flush();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(utf8.decode(received), 'phone-to-peer');
    expect(find.text('peer-to-phone'), findsOneWidget);
    expect(find.text('RX:13  TX:13'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('发送文件'));
      await _waitFor(() =>
          received.length == 13 + fileBytes.length &&
          !pickedFile!.existsSync());
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(received.sublist(13), fileBytes);
    expect(find.text('文件发送完成：8193 字节'), findsWidgets);
    expect(find.text('RX:13  TX:8206'), findsOneWidget);
    expect(tester.widget<ElevatedButton>(_sendButton()).onPressed, isNotNull);

    await tester.tap(_repeatButton());
    await tester.pump();
    expect(find.text('停止定时'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(_key('mode-usb'));
      await _waitFor(() => closed);
    });
    await tester.pump();
    expect(find.text('停止定时'), findsNothing);
    expect(find.text('串口设置'), findsOneWidget);
    expect(tester.widget<ElevatedButton>(_sendButton()).onPressed, isNull);
    final sentBefore = received.length;
    await tester.pump(const Duration(seconds: 2));
    expect(received.length, sentBefore);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

class _KeyboardInsets implements ui.WindowPadding {
  const _KeyboardInsets(this.bottom);

  @override
  final double bottom;
  @override
  double get top => 0;
  @override
  double get left => 0;
  @override
  double get right => 0;
}
