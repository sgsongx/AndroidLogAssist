# PhoneComm 通信调试 Demo

Android 手机支持 USB 串口、TCP 服务端和 TCP 客户端三种通信方式，共用文本/HEX 收发、文件发送、定时发送、收发计数和日志记录。每次使用一种方式；切换方式会关闭原连接或监听、停止定时发送并中断未完成的文件发送，已有日志继续保留。TCP 使用 Dart 自带的 `dart:io`，无需新增依赖，也不需要接入 USB 模块；应用不会自动在 USB 和 TCP 之间转发数据。

USB 串口通过 USB-C/OTG 连接模块，提供设备扫描、授权、连接和波特率等参数设置。USB 权限由系统在连接时弹窗申请；无需给手机安装 PC 串口驱动。`third_party/usb_serial` 是 [usb_serial 0.5.2](https://pub.dev/packages/usb_serial/versions/0.5.2) 的本地副本，补上该版本缺少的 `dart:typed_data` 导入，并复用应用的 Android Gradle 插件；原许可见该目录 `LICENSE`。

```powershell
fvm flutter pub get
fvm flutter run
```

当前网络若无法连接 Flutter 默认制品站，可按 [Flutter 官方镜像说明](https://docs.flutter.dev/community/china) 在当前 PowerShell 会话中设置 `$env:FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn'`，然后执行 `fvm flutter build apk --debug`。APK 输出为 `build/app/outputs/flutter-apk/app-debug.apk`。

手机 USB 口被模块占用时，可以安装调试 APK 或用 Android 11+ 无线 ADB 部署。运行前确认手机支持 USB Host、OTG 线可传数据、模块芯片受插件支持，并检查目标板电平。首次验证建议先断开目标板，仅短接模块串口侧 TX/RX 做回环：打开 HEX 发送，发送 `01 A0 FF`，日志应收到同样的 HEX 字节。接目标板前先确认 TTL/RS-232/RS-485 类型以及 3.3 V/5 V 电平。

## TCP 连接与验证

手机和电脑连接同一局域网，端口默认为 `9000`，可设置为 `1–65535`。电脑作为服务端时，需要允许该端口通过防火墙；Wi-Fi 的客户端隔离也会阻止互连。TCP 无加密或身份认证，请在可信网络中使用，不要把监听端口直接暴露到公网。

- **手机作为服务端**：选“TCP 服务端”，确认手机 IPv4 地址和端口，点“开始监听”。监听绑定所有 IPv4 网卡，电脑连接界面中显示的可达手机地址。当前仅接收一个客户端；其他连接会被关闭。客户端断开后继续监听，点“停止监听”才关闭服务端。仅监听、尚无客户端时不能发送。
- **手机作为客户端**：选“TCP 客户端”，填写电脑的 IP 地址或主机名和端口，点“连接”。连接失败或超时后检查地址、服务端和防火墙，再手动重试；断开后不会自动重连。

以下命令只使用电脑 Python 标准库。手机作为服务端时，把 `PHONE_IP` 换成界面显示的手机地址，运行后可在手机输入回复并点“发送”，电脑将打印回复：

```powershell
python -c "import socket; s=socket.create_connection(('PHONE_IP',9000),8); s.settimeout(60); s.sendall(b'hello phone\n'); print(s.recv(4096)); s.close()"
```

手机作为客户端时，先在电脑运行以下命令，再让手机连接电脑的局域网地址和 `9000` 端口。手机应收到 `hello phone`，在手机发送一条回复后电脑会打印收到的字节：

```powershell
python -c "import socket; server=socket.socket(); server.bind(('0.0.0.0',9000)); server.listen(1); print('waiting on port 9000',flush=True); s,peer=server.accept(); print(peer,flush=True); s.settimeout(60); s.sendall(b'hello phone\n'); print(s.recv(4096)); s.close(); server.close()"
```

TCP 是连续字节流，单次发送与单条 RX 日志没有一一对应关系，可能拆包或合包。检查原始内容时使用 HEX；应用不添加协议帧或业务应答。以上为验证步骤，执行结果应分别记录，不能仅凭成功连接判断双向收发通过。

数据日志区的时钟控制界面时间戳，向下箭头控制收到新记录时是否滚到底部。圆形记录按钮可输入文件名，选择文件时间戳及追加或清空同名文件；再次点击停止。实时文件保存在 Android 10+ 的 `下载/PhoneComm/`，旧版 Android 保存在应用专属文档目录。日志菜单可将内存中最近 800 条另存为文件，也可将它们追加到正在记录的文件。界面时间戳开关不影响文件时间戳；两者均显示到毫秒。安装新 APK 后需重新打开串口、连接 TCP 或开始监听；只有存在有效的数据连接才能发送。

此 Demo 仅支持 Android 前台交互；界面日志仅保留最近 800 条，实时记录按收到的日志持续写入文件。文本预览按每次收到的字节块解码，跨块 UTF-8 字符可能显示为替换字符，HEX 字节不受影响。高波特率持续收数、具体硬件兼容性、长时间 TCP 收发和锁屏后台运行仍须实机验证。USB 硬件前提见 [可行性报告](USB_SERIAL_FEASIBILITY.md)。
