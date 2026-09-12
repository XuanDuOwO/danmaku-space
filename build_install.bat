@echo off
chcp 65001 >nul
REM ============================================================================
REM  弹幕转发 App —— 一键构建并安装到模拟器
REM  用法：在已安装 Flutter + Android SDK + JDK 的本机命令行直接双击/运行本文件
REM  依赖：flutter / adb 在 PATH；模拟器 emulator-5554 已启动
REM ============================================================================
setlocal

REM TUNA Dart 镜像（末尾必须带斜杠），绕过坏代理 127.0.0.1:4033
set "PUB_HOSTED_URL=https://mirrors.tuna.tsinghua.edu.cn/dart-pub/"
set "NO_PROXY=127.0.0.1,localhost"
set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"

cd /d %~dp0
echo [1/3] flutter pub get ...
call flutter.bat pub get
if errorlevel 1 goto :fail

echo [2/3] flutter build apk --release ...
call flutter.bat build apk --release
if errorlevel 1 goto :fail

echo [3/3] adb install -r 到 emulator-5554 ...
adb -s emulator-5554 install -r build\app\outputs\flutter-apk\app-release.apk
if errorlevel 1 (
  echo [!] adb 安装失败，可能模拟器未启动或未识别。APK 已生成在：
  echo     build\app\outputs\flutter-apk\app-release.apk
  goto :eof
)
echo [OK] 构建并安装完成。
goto :eof

:fail
echo [X] 构建失败，请检查 flutter / android sdk / jdk 环境。
exit /b 1
