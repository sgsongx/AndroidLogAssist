import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_comm/main.dart';

void main() {
  testWidgets(
      'send editor and input connection survive keyboard layout changes',
      (tester) async {
    const MethodChannel('usb_serial')
        .setMockMethodCallHandler((call) async => <Object>[]);
    const MethodChannel('usb_serial/usb_events')
        .setMockMethodCallHandler((call) async => null);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      const MethodChannel('usb_serial').setMockMethodCallHandler(null);
      const MethodChannel('usb_serial/usb_events')
          .setMockMethodCallHandler(null);
    });
    tester.binding.window.physicalSizeTestValue = const Size(360, 800);
    tester.binding.window.devicePixelRatioTestValue = 1;
    addTearDown(() {
      tester.binding.window.clearPhysicalSizeTestValue();
      tester.binding.window.clearDevicePixelRatioTestValue();
      tester.binding.window.clearViewInsetsTestValue();
    });

    await tester.pumpWidget(const PhoneCommApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('串口设置'), findsOneWidget);
    expect(find.text('数据日志'), findsOneWidget);
    expect(find.text('数据发送'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final sendField = find.byKey(const ValueKey('send-input'));
    final editor =
        find.descendant(of: sendField, matching: find.byType(EditableText));
    for (final mode in ['usb', 'server', 'client']) {
      await tester.tap(find.byKey(ValueKey('mode-$mode')));
      await tester.pump();
      await tester.tap(sendField);
      await tester.pump();
      tester.testTextInput.enterText('abc');
      await tester.pump();
      final editorState = tester.state<EditableTextState>(editor);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      tester.testTextInput.log.clear();

      tester.binding.window.viewInsetsTestValue = const _TestWindowPadding(300);
      await tester.pump();
      expect(tester.state<EditableTextState>(editor), same(editorState),
          reason:
              '$mode must retain the active editor when the keyboard opens');
      expect(tester.widget<EditableText>(editor).focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(
          tester.testTextInput.log
              .where((call) => call.method == 'TextInput.clearClient'),
          isEmpty);
      for (final text in ['abcD', 'abcDE', 'abcDEF完整输入123']) {
        tester.testTextInput.enterText(text);
        await tester.pump();
        expect(tester.widget<TextField>(sendField).controller!.text, text);
      }

      tester.testTextInput.hide();
      tester.binding.window.clearViewInsetsTestValue();
      await tester.pump();
      expect(tester.state<EditableTextState>(editor), same(editorState),
          reason: '$mode must retain the editor when the keyboard closes');
      expect(tester.widget<TextField>(sendField).controller!.text,
          'abcDEF完整输入123');
      await tester.tap(sendField);
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      tester.testTextInput.enterText('abcDEF完整输入123-reopened');
      await tester.pump();
      expect(tester.widget<TextField>(sendField).controller!.text,
          'abcDEF完整输入123-reopened');
      expect(tester.takeException(), isNull);
    }
  });
}

class _TestWindowPadding implements ui.WindowPadding {
  const _TestWindowPadding(this.bottom);

  @override
  final double bottom;
  @override
  double get top => 0;
  @override
  double get left => 0;
  @override
  double get right => 0;
}
