// HaloVpnService — Android VPN 侧脚手架（未验证）。
//
// 方案 §5 要求 VPN 运行在独立 :vpn 进程中，不初始化 FlutterEngine，也不加载
// UI 依赖。此文件建立进程边界、前台通知与 Binder 契约，但 **没有** 接入
// libbox：本仓库未构建移动库，也没有在任何设备上运行过它。
//
// 因此所有“启动代理”入口都显式返回 Unverified，界面必须如实显示该状态。
// 真机激活、连接保护与网络切换行为均未验证（方案 §14 第 1、2 项）。

package com.clashhalo.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.os.Process

/**
 * VPN 状态。Unverified 是默认且唯一可如实报告的“已配置”状态，因为缺少
 * 已构建的 libbox 与真机验证。
 */
enum class VpnState {
    Stopped,
    Unverified,
    Failed;

    val isActive: Boolean get() = this == Unverified || this == Failed
}

/**
 * 进程内 Binder 契约。UI 进程通过它查询状态与请求启动/停止。
 *
 * 设计要点（方案 §5）：
 * - 只暴露有限操作，不接受任意路径或任意命令行；
 * - 不返回任何可用于绕过 VPN 权限的对象；
 * - 状态查询是幂等的，UI 重开后可直接恢复显示。
 */
class VpnBinder : Binder() {
    @Volatile
    var state: VpnState = VpnState.Stopped
        private set

    @Volatile
    var message: String = "尚未在本设备验证"
        private set

    /** 查询当前状态；UI 重开后用它恢复界面。 */
    fun snapshot(): Map<String, Any> = mapOf(
        "state" to state.name,
        "message" to message,
        "permissionGranted" to permissionGranted,
        "isolatedProcess" to true,
    )

    internal var permissionGranted: Boolean = false

    /**
     * 请求建立 VPN。本版本**不会**调用 VpnService.Builder：缺少 libbox，
     * 建立一条无法承载流量的 TUN 只会让系统显示“已连接”而实际不通，属于
     * 方案禁止的虚假能力声明。
     */
    fun requestStart(): Map<String, Any> {
        if (!permissionGranted) {
            state = VpnState.Failed
            message = "缺少 VPN 授权"
            return snapshot()
        }
        state = VpnState.Unverified
        message = "TUN 未激活：本版本未构建 libbox，未在真机验证"
        return snapshot()
    }

    fun requestStop(): Map<String, Any> {
        state = VpnState.Stopped
        message = "已停止"
        return snapshot()
    }
}

/**
 * 独立 :vpn 进程中的 VpnService。
 *
 * 该 Service 已在 AndroidManifest 中声明 `android:process=":vpn"`，
 * 且不导出（`android:exported="false"`），只能由本应用绑定。
 */
class HaloVpnService : VpnService() {
    private val binder = VpnBinder()

    override fun onCreate() {
        super.onCreate()
        createChannel()
        // 契约要求 VPN 进程不初始化 FlutterEngine：此处不加载任何 Flutter 类。
        binder.permissionGranted = VpnService.prepare(this) == null
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                startForeground(NOTIFICATION_ID, buildNotification(binder.state))
            }
            ACTION_STOP -> {
                binder.requestStop()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onDestroy() {
        binder.requestStop()
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Clash Halo VPN",
            NotificationManager.IMPORTANCE_LOW,
        ).apply { description = "显示 VPN 运行状态并提供停止入口" }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(state: VpnState): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, Class.forName("com.clashhalo.halo.MainActivity"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, HaloVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Clash Halo")
            .setContentText(if (state.isActive) "已连接（未验证）" else "未连接")
            .setSmallIcon(android.R.drawable.stat_sys_vpn_ic)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "停止", stop).build())
            .setOngoing(true)
            .build()
    }

    override fun onRevoke() {
        // 用户或其他 VPN 撤销/接管时不得假装仍在代理（方案 §5）。
        binder.requestStop()
        stopSelf()
        super.onRevoke()
    }

    companion object {
        const val ACTION_START = "com.clashhalo.vpn.START"
        const val ACTION_STOP = "com.clashhalo.vpn.STOP"
        const val CHANNEL_ID = "halo-vpn"
        const val NOTIFICATION_ID = 1001

        /** 本进程的调试标识，用于在日志中确认它确实独立于 UI 进程。 */
        fun processTag(): String = "vpn pid=${Process.myPid()}"
    }
}
