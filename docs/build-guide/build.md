# 构建与验证

在工程根目录 `E:\Studying\Project\PhoneComm` 执行。`.fvmrc` 指定 Flutter 3.0.5；本次运行 `fvm flutter --version` 显示 Dart 2.17.6。`pubspec.yaml` 使用本地 `third_party/usb_serial`；`android/build.gradle` 声明 Android Gradle Plugin 7.1.2、Kotlin 1.6.10，`android/gradle/wrapper/gradle-wrapper.properties` 使用 Gradle 7.4.2，`android/gradle.properties` 指向本机 JDK 11。`android/app/build.gradle` 设 `compileSdkVersion 33`，`minSdkVersion`/`targetSdkVersion` 来自 Flutter SDK，应用 ID 是 `com.example.phone_comm`。

```powershell
fvm flutter pub get
fvm flutter analyze
fvm flutter test
fvm flutter build apk --debug
fvm flutter run
```

- 2026-09-29：`fvm flutter --version`、`fvm flutter analyze` 成功，分析无问题；`fvm flutter test` 成功，3 个测试通过。
- 2026-10-30：TCP 功能完成后 `fvm flutter analyze` 无问题，`fvm flutter test` 13 项通过，`fvm flutter build apk --debug` 成功。没有升级 Flutter 或新增依赖。
- Debug APK 预期路径为 `build/app/outputs/flutter-apk/app-debug.apk`（`README.md`）。运行需 Android SDK、JDK、Gradle 依赖可用；部署与 USB 串口收发需目标手机及模块。串口侧电平/回环检查见 `README.md`。
- `test/hex_test.dart` 检查编码和记录格式；`test/log_recording_test.dart` 检查滚屏和记录；`test/mobile_layout_test.dart` 检查三种模式的键盘开关保留同一编辑器及输入连接。`test/tcp_transport_test.dart` 用真实回环 Socket 检查双向通信、单客户端、重连和清理；`test/tcp_ui_test.dart` 检查输入校验、竖横屏布局、实际 TCP 收发、8193 字节分块文件发送、缓存清理和切换模式停止定时发送。

## 本次手机验证

- Android 16 / API 36 手机已连接。原应用 `com.example.phone_comm` 与本机调试密钥签名不同，直接覆盖安装被系统拒绝；保留旧应用及数据，另行构建并安装 `com.example.phone_comm.tcp`，桌面名称为“PhoneComm 通信助手”。工程的应用 ID 仍为 `com.example.phone_comm`，临时构建变更已还原。
- 常规 APK：`build/app/outputs/flutter-apk/app-debug.apk`。本次已安装的并行 APK：`build/verification/tcp/phonecomm-tcp-debug.apk`；两者来自相同 Dart 源码。
- 手机当前没有 Wi-Fi IPv4；使用 `adb forward tcp:19001 tcp:9000` 验证手机服务端，文本 RX/TX 各 18 字节一致；远端关闭后手机继续监听。使用 `adb reverse tcp:19002 tcp:19002` 验证手机客户端接收文本并准确发送 `00 A0 FF 0D 0A`，远端关闭后恢复未连接状态。验证结束已移除本次端口映射并恢复屏幕自动旋转。
- TCP 接收内容 `FILE_RECORD_TCP` 实时写入原生记录文件，包含毫秒时间戳及精确 HEX；已从手机拉取并检查，副本为 `build/verification/tcp/tcp-device-record.txt`。
- 实机发现并修复键盘弹出时发送编辑器重建的问题；完整输入与收发复验通过。回归测试还检查了编辑器实例不变；隔离副本移除修复后测试失败。
- 本次未验证真实 Wi-Fi/公网路由、USB 模块收发、锁屏后台及长时间运行；未构建 Release 包。TCP 当前为单客户端、无认证加密的前台调试接口。

当前 `README.md` 给出网络无法访问 Flutter 默认制品站时的镜像变量。`.vscode/tasks.json` 中任务名为“Wi-Fi 无线调试配对”，实际执行的是 `adb connect`，不执行 `adb pair`；无线调试需先单独配对并使用手机显示的连接端口。此处是配置审计发现，未修改该任务。
