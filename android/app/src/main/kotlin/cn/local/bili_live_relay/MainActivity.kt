package cn.local.bili_live_relay

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "cn.local.bili_live_relay/open_url"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 亮屏保活：置 / 清 FLAG_KEEP_SCREEN_ON。
                    // 该标志属于窗口，不需要任何权限，Activity 销毁时随窗口一起失效，
                    // 因此不存在「忘记释放导致永不熄屏」的漏电风险。
                    "setKeepScreenOn" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        try {
                            runOnUiThread {
                                if (on) {
                                    window.addFlags(
                                        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                                    )
                                } else {
                                    window.clearFlags(
                                        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                                    )
                                }
                            }
                            result.success(on)
                        } catch (e: Exception) {
                            result.error("keep_screen_failed", e.message, null)
                        }
                    }
                    "openUrl" -> {
                        val url = call.argument<String>("url") ?: ""
                        // 只放行 http(s)，避免被传入 file:// 等意外 scheme
                        if (!url.startsWith("http://") && !url.startsWith("https://")) {
                            result.error("bad_url", "仅支持 http(s) 链接", null)
                            return@setMethodCallHandler
                        }
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("open_failed", e.message, null)
                        }
                    }
                    "getUpdateDir" -> {
                        // 应用专属外部存储目录（无需存储权限，卸载即清理）
                        val dir = File(getExternalFilesDir(null), "update")
                        if (!dir.exists()) dir.mkdirs()
                        result.success(dir.absolutePath)
                    }
                    "installApk" -> {
                        // 通过 FileProvider 授权系统安装器读取 APK 并拉起安装
                        val path = call.argument<String>("path") ?: ""
                        try {
                            val file = File(path)
                            if (!file.exists()) {
                                result.error("no_file", "APK 不存在: $path", null)
                                return@setMethodCallHandler
                            }
                            val uri = FileProvider.getUriForFile(
                                this, "$packageName.fileprovider", file
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("install_failed", e.message, null)
                        }
                    }
                    "cleanUpdateApks" -> {
                        // 清空更新目录里的安装包（安装成败都清理，避免堆积）
                        try {
                            val dir = File(getExternalFilesDir(null), "update")
                            dir.listFiles()?.forEach { it.delete() }
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("clean_failed", e.message, null)
                        }
                    }
                    "startKeepAlive" -> {
                        // 前台保活：切后台 / 锁屏时弹幕连接不被系统杀掉
                        val room = call.argument<String>("room") ?: ""
                        try {
                            val i = Intent(this, KeepAliveService::class.java)
                                .putExtra("room", room)
                            if (Build.VERSION.SDK_INT >= 26) {
                                startForegroundService(i)
                            } else {
                                startService(i)
                            }
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("keepalive_failed", e.message, null)
                        }
                    }
                    "stopKeepAlive" -> {
                        try {
                            stopService(Intent(this, KeepAliveService::class.java))
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("keepalive_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
