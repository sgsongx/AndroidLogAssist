# 模块职责

范围：当前 Android Flutter 工程；Flutter 3.0.5 配置见 `.fvmrc`。一方应用代码在 `lib/` 和 `android/app/src/main/kotlin/`；`third_party/usb_serial` 是本地第三方插件副本，不把它的辅助 `echo_port.dart`、`transaction.dart` 当作应用模块。

## Flutter 通信页面

- 路径/职责：`lib/main.dart` 的 `main()`、`PhoneCommApp`、`SerialPage`、`_SerialPageState` 提供 USB 串口/TCP 服务端/TCP 客户端选择、参数设置、连接状态、收发、日志和文件操作界面。一次使用一个通信方式，切换时清理原连接、停止定时发送并中断未完成的文件发送，保留日志。
- 所有权：页面持有 `UsbPort? _port`、`_receiveSubscription`、`_usbSubscription`、控制器、`_entries`、`_history`、计数器、记录状态和 `Timer`。`_connect()` 将临时端口转交 `_port`；`_disconnect()` 与 `dispose()` 清理连接/订阅/定时器。页面不拥有 Android USB 权限和文件 URI。
- 入口/接口：`_scanDevices()`、`_connect()`、`_disconnect()`、`_send()`、`_onReceived()`、`_sendFile()`、`_saveLog()`、`_toggleRecording()`、`_appendRecentToRecording()`；公开纯函数 `parseHex()`、`toHex()`、`encodeText()`、`formatTimestamp()`。`_generation` 用于丢弃过期连接/文件发送流程。
- 依赖：`UsbSerial`/`UsbPort`、`TcpTransport`；`phone_comm/files` 方法通道。三种通信方式共用接收处理、文本/HEX 编码、文件/定时发送、计数及日志记录。
- 范围：界面日志保留最近 800 条，发送历史仅在页面内存；实时记录按收到的日志持续写入文件。接收文本对每个字节块独立解码，跨块 UTF-8 字符可能显示异常。TCP 可能拆包或合包，不把单次回调当协议帧；页面不实现 USB/TCP 自动转发。

## TCP 传输

- 路径/职责：`lib/tcp_transport.dart` 的 `TcpTransport` 使用 Dart `Socket`/`ServerSocket` 实现客户端连接与服务端监听，不引入第三方依赖。
- 所有权：传输对象拥有监听 Socket、当前客户端 Socket 和订阅；`close()` 清理它们，并使尚未完成的连接结果失效。页面负责在切换方式和销毁时关闭传输。
- 入口/接口：`connect(host, port)`、`listen(port)`、`write(bytes)`、`close()`；`isConnected`、`isListening`、`peer`、`port` 提供连接状态；`onData(Uint8List)` 送入页面统一接收流程，`onStateChanged(String)` 更新状态和系统日志。
- 范围：服务端监听所有 IPv4 网卡，一次接受一个客户端，多余连接会关闭；客户端断开后保持监听。客户端连接有超时，不自动重连。端口由页面验证为 `1–65535`；监听 IP 显示当前非回环 IPv4 地址。TCP 无身份认证或 TLS，仅用于可信网络中的前台调试。

## 本地 USB 串口插件

- 路径/职责：`third_party/usb_serial/lib/usb_serial.dart` 提供 Dart 的 `UsbSerial`、`UsbDevice`、`UsbPort`；`android/src/main/java/dev/bessems/usbserial/UsbSerialPlugin.java` 负责设备枚举、USB 广播和权限；`UsbSerialPortAdapter.java` 负责每个端口的读写和参数设置。
- 所有权：Android 插件拥有 `UsbManager`、USB 广播接收器和端口适配器；端口适配器持有 `UsbDeviceConnection` 及底层 `UsbSerialDevice`。页面仅持有 Dart 侧 `UsbPort` 句柄。依据：`UsbSerialPlugin.register`、`openDevice`，`UsbSerialPortAdapter` 构造与 `close`。
- 入口/接口：`UsbSerial.listDevices()`、`UsbDevice.create()`、`UsbPort.open()`/`write()`/`inputStream`，以及 `UsbSerial.usbEventStream`。底层依赖 `com.github.felHR85:UsbSerial:6.1.0`，见插件 `android/build.gradle`。
- 边界：这是第三方代码的本地副本，修改时核对原许可 `third_party/usb_serial/LICENSE`；主工程 `analysis_options.yaml` 排除了该目录的 Dart 分析。

## Android 文件桥接与应用壳

- 路径/职责：`android/app/src/main/kotlin/com/example/phone_comm/MainActivity.kt` 继承 `FlutterActivity`，提供 `pickFile`、`saveLog`、`startRecording`、`appendRecording`、`stopRecording` 等 `phone_comm/files` 方法；`android/app/src/main/AndroidManifest.xml` 声明 USB Host、网络 `INTERNET` 权限和启动 Activity。
- 所有权：`MainActivity` 保存一次待完成的文档选择器结果，并在 `onActivityResult()` 中处理；打开文件后在缓存目录生成临时文件，页面 `_sendFile()` 使用后删除。记录流由单线程执行器串行写入并在停止或页面销毁时关闭。它不处理串口数据。
- 入口/接口：`configureFlutterEngine()` 注册方法通道，`onActivityResult()` 分发 `ACTION_OPEN_DOCUMENT`/`ACTION_CREATE_DOCUMENT` 的结果；Android 10+ 通过 MediaStore 写入 `下载/PhoneComm/`，旧版写入应用专属文档目录。依据：`MainActivity.kt`。

## 测试与构建

- `test/hex_test.dart` 覆盖 HEX、转义编码及记录格式；`test/mobile_layout_test.dart` 模拟窄屏；`test/log_recording_test.dart` 覆盖自动滚屏及记录交互；`test/tcp_transport_test.dart` 使用真实回环 Socket 检查 TCP 生命周期和字节收发。测试通过不能替代目标手机上的网络和 USB 验证。
- `pubspec.yaml` 引入 Flutter 和本地插件；`android/build.gradle`、`android/app/build.gradle`、`android/gradle/wrapper/gradle-wrapper.properties` 定义 Android 构建。命令及本次验证见 [构建说明](../build-guide/build.md)。
