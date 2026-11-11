package com.clashhalo.halo

import android.Manifest
import android.app.ActivityManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.provider.OpenableColumns
import com.clashhalo.vpn.HaloVpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.charset.StandardCharsets
import org.json.JSONObject

/**
 * Android 侧平台通道：把 VPN 权限、启停与状态暴露给 Dart。
 *
 * 配置经固定路径传递（getDir("halo") 与 :vpn 进程共享，同 uid），通道只传内容
 * 不传路径。服务运行在独立 :vpn 进程，状态经同目录的 vpn-state.json 读取；
 * 跨进程绑定 Binder 只能拿到 BinderProxy，无法转换为进程内类，因此不使用绑定。
 * 启停使用显式 Intent：ACTION_START / ACTION_STOP。
 */
class MainActivity : FlutterActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingBackupExport: PendingBackupExport? = null
    private var pendingBackupImport: MethodChannel.Result? = null

    private data class PendingBackupExport(
        val result: MethodChannel.Result,
        val content: String,
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
            call,
            result,
            ->
            when (call.method) {
                "dataDir" -> result.success(getDir("halo-data", MODE_PRIVATE).absolutePath)
                "exportBackup" -> {
                    val fileName = call.argument<String>("fileName") ?: "halo-backup.chb"
                    val content = call.argument<String>("content")
                    if (content == null) {
                        result.error("backup_content", "缺少备份内容", null)
                        return@setMethodCallHandler
                    }
                    if (pendingBackupExport != null || pendingBackupImport != null) {
                        result.error("backup_busy", "另一个文件操作正在进行", null)
                        return@setMethodCallHandler
                    }
                    pendingBackupExport = PendingBackupExport(result, content)
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, fileName)
                    }
                    try {
                        startActivityForResult(intent, REQUEST_EXPORT_BACKUP)
                    } catch (e: Exception) {
                        pendingBackupExport = null
                        result.error("backup_export", e.message ?: e.toString(), null)
                    }
                }
                "importBackup" -> {
                    if (pendingBackupExport != null || pendingBackupImport != null) {
                        result.error("backup_busy", "另一个文件操作正在进行", null)
                        return@setMethodCallHandler
                    }
                    pendingBackupImport = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                    }
                    try {
                        startActivityForResult(intent, REQUEST_IMPORT_BACKUP)
                    } catch (e: Exception) {
                        pendingBackupImport = null
                        result.error("backup_import", e.message ?: e.toString(), null)
                    }
                }
                "permissionGranted" -> result.success(VpnService.prepare(this) == null)
                "requestPermission" -> {
                    val intent = VpnService.prepare(this)
                    if (intent == null) {
                        result.success(true)
                    } else {
                        pendingPermissionResult = result
                        startActivityForResult(intent, REQUEST_VPN)
                    }
                }
                "start" -> {
                    val config = call.argument<String>("config")
                    if (config == null) {
                        result.error("config", "缺少 config 参数", null)
                        return@setMethodCallHandler
                    }
                    try {
                        writeConfig(config)
                        // Android 13+ hides notifications until this is granted.
                        // The foreground service still runs either way; asking
                        // here keeps the VPN status visible.
                        ensureNotificationPermission()
                        // 返回请求时刻：Dart 用它过滤上一次运行留下的旧状态。
                        val requestedAt = System.currentTimeMillis()
                        startForegroundService(
                            Intent(this, HaloVpnService::class.java)
                                .setAction(HaloVpnService.ACTION_START),
                        )
                        result.success(requestedAt)
                    } catch (e: Exception) {
                        result.error("vpn_start", e.message ?: e.toString(), null)
                    }
                }
                "stop" -> {
                    val requestedAt = System.currentTimeMillis()
                    try {
                        startService(
                            Intent(this, HaloVpnService::class.java)
                                .setAction(HaloVpnService.ACTION_STOP),
                        )
                    } catch (e: Exception) {
                        // 服务已经停止，或后台启动被系统拒绝：直接销毁即可。
                        runCatching {
                            stopService(Intent(this, HaloVpnService::class.java))
                        }
                    }
                    result.success(requestedAt)
                }
                "status" -> result.success(readStatus())
                else -> result.notImplemented()
            }
        }
    }

    /** 原子写入配置：:vpn 进程不会读到写了一半的文档。 */
    private fun writeConfig(config: String) {
        val dir = getDir("halo", MODE_PRIVATE)
        val target = File(dir, "config.json")
        val temp = File(dir, "config.json.tmp")
        temp.writeText(config)
        if (!temp.renameTo(target)) {
            target.writeText(config)
            temp.delete()
        }
    }

    /**
     * 读取 :vpn 进程写下的状态。
     *
     * Starting/Started 记录带 pid；pid 已不存在时说明服务已被系统或用户结束，
     * 不能继续显示为已连接。Failed 记录保留到下一次启动或用户主动停止，这样
     * 启动失败的原因在服务退出后仍能看到。
     */
    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_NOTIFICATIONS,
        )
    }

    private fun readStatus(): Map<String, Any> {
        val file = File(getDir("halo", MODE_PRIVATE), HaloVpnService.STATE_FILE)
        val json = runCatching { JSONObject(file.readText()) }.getOrNull()
            ?: return mapOf(
                "state" to "Stopped",
                "message" to "服务未运行",
                "updatedAt" to 0L,
            )
        val state = json.optString("state", "Stopped")
        val message = json.optString("message", "")
        val pid = json.optInt("pid", -1)
        val updatedAt = json.optLong("updatedAt", 0L)
        val alive = isProcessAlive(pid)
        if ((state == "Starting" || state == "Started") && !alive) {
            return mapOf(
                "state" to "Stopped",
                "message" to "服务未运行",
                "updatedAt" to updatedAt,
            )
        }
        return mapOf(
            "state" to state,
            "message" to message,
            "updatedAt" to updatedAt,
        )
    }

    /**
     * The state file records the :vpn pid. /proc visibility differs between
     * SELinux domains even for the same UID, so ask ActivityManager for the
     * app's own process list first and fall back to /proc.
     */
    private fun isProcessAlive(pid: Int): Boolean {
        if (pid <= 0) return false
        val processes = getSystemService(ActivityManager::class.java)
            .runningAppProcesses
        if (processes != null) {
            return processes.any { it.pid == pid }
        }
        return File("/proc/$pid").exists()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQUEST_VPN -> {
                pendingPermissionResult?.success(resultCode == RESULT_OK)
                pendingPermissionResult = null
            }
            REQUEST_EXPORT_BACKUP -> completeBackupExport(resultCode, data)
            REQUEST_IMPORT_BACKUP -> completeBackupImport(resultCode, data)
        }
    }

    private fun completeBackupExport(resultCode: Int, data: Intent?) {
        val pending = pendingBackupExport ?: return
        pendingBackupExport = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            pending.result.success(null)
            return
        }
        Thread {
            val outcome = runCatching {
                contentResolver.openOutputStream(uri)?.use { stream ->
                    stream.write(pending.content.toByteArray(StandardCharsets.UTF_8))
                } ?: error("无法打开目标文件")
                mapOf("name" to displayName(uri), "uri" to uri.toString())
            }
            runOnUiThread {
                outcome.fold(
                    { pending.result.success(it) },
                    { pending.result.error("backup_export", it.message ?: "备份写入失败", null) },
                )
            }
        }.start()
    }

    private fun completeBackupImport(resultCode: Int, data: Intent?) {
        val pending = pendingBackupImport ?: return
        pendingBackupImport = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            pending.success(null)
            return
        }
        Thread {
            val outcome = runCatching {
                val text = contentResolver.openInputStream(uri)?.use { stream ->
                    stream.readBytes().toString(StandardCharsets.UTF_8)
                } ?: error("无法打开备份文件")
                mapOf("name" to displayName(uri), "text" to text)
            }
            runOnUiThread {
                outcome.fold(
                    { pending.success(it) },
                    { pending.error("backup_import", it.message ?: "备份读取失败", null) },
                )
            }
        }.start()
    }

    private fun displayName(uri: Uri): String {
        var name: String? = null
        runCatching {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) name = cursor.getString(index)
                }
            }
        }
        return name ?: uri.lastPathSegment ?: uri.toString()
    }

    companion object {
        private const val CHANNEL = "clash_halo/android_vpn"
        private const val REQUEST_VPN = 2001
        private const val REQUEST_NOTIFICATIONS = 2002
        private const val REQUEST_EXPORT_BACKUP = 2003
        private const val REQUEST_IMPORT_BACKUP = 2004
    }
}
