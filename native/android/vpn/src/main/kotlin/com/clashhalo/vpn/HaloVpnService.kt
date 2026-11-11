// HaloVpnService — Android VPN 实现（libbox 集成）。
//
// 进程边界约束（方案 §5）：本服务运行在独立 :vpn 进程，不初始化 FlutterEngine。
// UI 进程经显式 Intent 请求启停，经同一应用目录下的 vpn-state.json 读取状态；
// 配置经固定路径（filesDir/halo/config.json）传递，不接受任意路径或命令行。
// 状态文件采用临时文件 + rename 原子替换，避免读到半个 JSON。
//
// 内核为 libbox（sing-box v1.14.4 移动库，从锁定源码构建，见 native/android/README.md）。
// 生命周期与官方 sing-box-for-android 同构：CommandServer 持有 StartedService，
// OpenTun 用 VpnService.Builder 建 TUN 并把 fd 交给 libbox。
//
// 未验证项（真机验证前不得宣称可用）：后台存活、UI 退出后 VPN 独立存活、
// 网络切换恢复。验证通过后更新 docs/验证记录.md。

package com.clashhalo.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Process
import android.system.OsConstants
import android.util.Log
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.io.File
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface as JavaNetworkInterface
import java.util.concurrent.Executors
import org.json.JSONObject

/** VPN 运行状态；UI 进程经 Binder 读取。 */
enum class VpnState {
    Stopped,
    Starting,
    Started,
    Failed;

    val isActive: Boolean get() = this == Starting || this == Started
}

/**
 * 独立 :vpn 进程中的 VpnService，同时充当 libbox 的 PlatformInterface 与
 * CommandServerHandler。
 */
class HaloVpnService :
    VpnService(),
    PlatformInterface,
    CommandServerHandler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()

    @Volatile
    private var state: VpnState = VpnState.Stopped

    @Volatile
    private var message: String = "未连接"

    /** 最近一次状态迁移的时刻；UI 用它判断状态是否对应本次启动请求。 */
    @Volatile
    private var updatedAt: Long = 0L

    @Volatile
    private var commandServer: CommandServer? = null

    @Volatile
    private var tunPfd: ParcelFileDescriptor? = null

    @Volatile
    private var stopping: Boolean = false

    @Volatile
    private var coreClosed: Boolean = false

    @Volatile
    private var foregroundStarted: Boolean = false

    @Volatile
    private var underlyingNetwork: Network? = null

    /** 内核自己的 TUN 接口名；出站接口列表必须排除它。 */
    @Volatile
    private var myInterface: String? = null

    private var defaultListener: InterfaceUpdateListener? = null

    private var networkCallbackRegistered: Boolean = false

    /**
     * 上联网登记表。
     *
     * HarmonyOS 4（Android 12 兼容层）在 VPN 成为默认网络后，会把物理网络从
     * [ConnectivityManager.allNetworks] 与 getNetworkCapabilities/getLinkProperties
     * 的可见集合里隐藏；只靠 allNetworks 枚举会得到空列表，内核随即报
     * "no available network interface" 并暂停全部出站。回调拿到的 [Network] 不受
     * 这个过滤影响，所以在 onAvailable/onCapabilitiesChanged 里维护一份备用。
     */
    private val knownNetworks =
        java.util.concurrent.ConcurrentHashMap<Network, NetworkCapabilities>()

    /** 上一次成功解析的默认接口；上联网短暂不可读时沿用，避免上报空名。 */
    private var lastDefaultInterfaceName: String = ""

    private var lastDefaultInterfaceIndex: Int = -1

    override fun onCreate() {
        super.onCreate()
        createChannel()
        // 这里不初始化 libbox：查询状态、停止一个未运行的服务都不应加载
        // 78MB 原生库。setup 与 CommandServer 在第一次真正启动时创建。
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopBox()
            return START_NOT_STICKY
        }
        // ACTION_START 与空 intent（系统重启拉起）都走启动路径。
        stopping = false
        coreClosed = false
        publishState(VpnState.Starting, "正在启动…")
        try {
            startForeground(NOTIFICATION_ID, buildNotification())
            foregroundStarted = true
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed", e)
            fail("无法启动前台服务：${e.message ?: e.toString()}")
            return START_NOT_STICKY
        }
        executor.execute { startBox() }
        return START_STICKY
    }

    override fun onDestroy() {
        stopping = true
        // 先停内核再关命令服务：closeService 会撤销 TUN，释放系统的 VPN 绑定；
        // 只 stopSelf 而不关内核时，系统绑定会让服务进程与 tun0 一起留下。
        closeCore()
        val server = commandServer
        commandServer = null
        // 失败状态保留给 UI 读取；只有正常运行时被销毁才改写为已停止。
        if (state == VpnState.Starting || state == VpnState.Started) {
            publishState(VpnState.Stopped, "已停止", notify = false)
        }
        try {
            executor.execute {
                runCatching { server?.close() }
                    .onFailure { Log.w(TAG, "close command server failed", it) }
            }
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            runCatching { server?.close() }
        }
        executor.shutdown()
        super.onDestroy()
    }

    override fun onRevoke() {
        // 用户或其他 VPN 撤销/接管时不得假装仍在代理（方案 §5）。
        stopBox()
        super.onRevoke()
    }

    // ---- 状态与状态文件 ----
    //
    // 服务运行在独立 :vpn 进程。UI 进程经同一应用目录下的 vpn-state.json
    // 读取状态；跨进程绑定 Binder 只能拿到 BinderProxy，无法转成进程内类。
    // 状态文件同时解决 UI 重启与进程被杀后的状态恢复；pid 用于判断记录
    // 对应的进程是否仍然存活。

    @Synchronized
    private fun publishState(next: VpnState, text: String, notify: Boolean = true) {
        state = next
        message = text
        updatedAt = System.currentTimeMillis()
        writeStateFile()
        if (notify && foregroundStarted) {
            runCatching { notificationManager().notify(NOTIFICATION_ID, buildNotification()) }
                .onFailure { Log.w(TAG, "update notification failed", it) }
        }
    }

    private fun writeStateFile() {
        try {
            val dir = getDir("halo", MODE_PRIVATE)
            val target = File(dir, STATE_FILE)
            val temp = File(dir, "$STATE_FILE.tmp")
            val json = JSONObject()
                .put("state", state.name)
                .put("message", message)
                .put("pid", Process.myPid())
                .put("updatedAt", updatedAt)
            temp.writeText(json.toString())
            if (!temp.renameTo(target)) {
                target.writeText(json.toString())
                temp.delete()
            }
        } catch (e: Exception) {
            Log.w(TAG, "writeStateFile failed", e)
        }
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    /**
     * Stops the core and revokes the TUN.
     *
     * `stopSelf()` alone is not enough: while the VPN is established the
     * system holds a binding to this service, so the service (and tun0) stay
     * alive until `closeService` releases that binding. The close runs on the
     * executor because `serviceStop()` may itself arrive from a CommandServer
     * callback thread; closing from that callback would wait on the callback.
     */
    private fun closeCore() {
        if (coreClosed) return
        coreClosed = true
        try {
            executor.execute {
                runCatching { commandServer?.closeService() }
                    .onFailure { Log.w(TAG, "closeService failed", it) }
                // The kernel uses this fd but does not own it; the platform
                // holds the ParcelFileDescriptor. Leaving it open keeps tun0
                // alive (and the system VPN binding with it) after closeService.
                closeTun()
            }
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            runCatching { commandServer?.closeService() }
            closeTun()
        }
    }

    private fun closeTun() {
        val pfd = tunPfd
        tunPfd = null
        runCatching { pfd?.close() }
            .onFailure { Log.w(TAG, "close tun failed", it) }
    }

    // ---- 启停状态机（executor 单线程上推进，避免 libbox 并发启动） ----

    private fun configFile(): File = File(getDir("halo", MODE_PRIVATE), "config.json")

    private fun ensureLibbox() {
        if (!setupDone) {
            val options = SetupOptions()
            // setup 只 mkdirs WorkingPath；BasePath 用于 command.sock 的 listen，
            // 目录不存在会以 "bind: no such file or directory" 崩掉服务创建。
            options.basePath = File(getDir("halo", MODE_PRIVATE), "libbox")
                .apply { mkdirs() }.absolutePath
            options.workingPath = File(cacheDir, "halo-work")
                .apply { mkdirs() }.absolutePath
            options.tempPath = File(cacheDir, "halo-tmp")
                .apply { mkdirs() }.absolutePath
            options.fixAndroidStack = false
            options.debug = false
            Libbox.setup(options)
            setupDone = true
        }
        if (commandServer == null) {
            // 重复创建会让第二次 command.sock bind 失败，所以只在服务真正
            // 启动时建一次；停止后由 onDestroy 关闭。
            commandServer = Libbox.newCommandServer(this, this).also { it.start() }
        }
    }

    private fun startBox() {
        try {
            if (stopping) return
            ensureLibbox()
            if (VpnService.prepare(this) != null) {
                fail("缺少 VPN 授权：请先在系统弹窗中允许")
                return
            }
            val config = configFile()
            if (!config.isFile) {
                fail("配置不存在：请先在应用内选择节点并启动")
                return
            }
            publishState(VpnState.Starting, "正在启动内核…")
            val content = config.readText()
            // Go 侧无条件解引用 options（options.AutoRedirect 等），不接受 null。
            val override = io.nekohasekai.libbox.OverrideOptions()
            override.includePackage = StringArray(emptyList<String>().iterator())
            override.excludePackage = StringArray(emptyList<String>().iterator())
            commandServer?.startOrReloadService(content, override)
            if (stopping) return
            publishState(VpnState.Started, "已连接")
        } catch (e: Exception) {
            Log.e(TAG, "startBox failed", e)
            fail(e.message ?: e.toString())
        }
    }

    private fun reloadBox() {
        executor.execute { startBox() }
    }

    private fun fail(text: String) {
        Log.e(TAG, text)
        publishState(VpnState.Failed, text)
        closeCore()
        mainHandler.post {
            stopping = true
            if (foregroundStarted) {
                stopForeground(STOP_FOREGROUND_REMOVE)
                foregroundStarted = false
            }
            stopSelf()
        }
    }

    private fun stopBox() {
        stopping = true
        publishState(VpnState.Stopped, "已停止", notify = false)
        closeCore()
        mainHandler.post {
            if (foregroundStarted) {
                stopForeground(STOP_FOREGROUND_REMOVE)
                foregroundStarted = false
            }
            stopSelf()
        }
    }

    // ---- libbox PlatformInterface ----

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        if (!protect(fd)) {
            Log.w(TAG, "protect($fd) failed — core outbound would loop into the tunnel")
        }
    }

    /** 用 VpnService.Builder 建 TUN，返回 fd 交给 libbox（方案禁止空 TUN 假连接：此处之后内核才启动）。 */
    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("android: missing vpn permission")

        val builder = Builder()
            .setSession("Clash Halo")
            .setMtu(options.mtu)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        val inet4 = options.inet4Address
        while (inet4.hasNext()) {
            val prefix = inet4.next()
            builder.addAddress(prefix.address(), prefix.prefix())
        }
        val inet6 = options.inet6Address
        while (inet6.hasNext()) {
            val prefix = inet6.next()
            builder.addAddress(prefix.address(), prefix.prefix())
        }

        if (options.autoRoute) {
            val dns = options.dnsServerAddress
            while (dns.hasNext()) {
                builder.addDnsServer(dns.next())
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val route4 = options.inet4RouteAddress
                if (route4.hasNext()) {
                    while (route4.hasNext()) {
                        val p = route4.next()
                        builder.addRoute(p.address(), p.prefix())
                    }
                } else {
                    builder.addRoute("0.0.0.0", 0)
                }
                val route6 = options.inet6RouteAddress
                if (route6.hasNext()) {
                    while (route6.hasNext()) {
                        val p = route6.next()
                        builder.addRoute(p.address(), p.prefix())
                    }
                } else {
                    builder.addRoute("::", 0)
                }
                val exclude4 = options.inet4RouteExcludeAddress
                while (exclude4.hasNext()) {
                    val p = exclude4.next()
                    // excludeRoute 只有 IpPrefix 重载（API 33+）。
                    builder.excludeRoute(IpPrefix(InetAddress.getByName(p.address()), p.prefix()))
                }
                val exclude6 = options.inet6RouteExcludeAddress
                while (exclude6.hasNext()) {
                    val p = exclude6.next()
                    builder.excludeRoute(IpPrefix(InetAddress.getByName(p.address()), p.prefix()))
                }
            } else {
                val range4 = options.inet4RouteRange
                while (range4.hasNext()) {
                    val p = range4.next()
                    builder.addRoute(p.address(), p.prefix())
                }
                val range6 = options.inet6RouteRange
                while (range6.hasNext()) {
                    val p = range6.next()
                    builder.addRoute(p.address(), p.prefix())
                }
            }
            val include = options.includePackage
            while (include.hasNext()) {
                runCatching { builder.addAllowedApplication(include.next()) }
            }
            val exclude = options.excludePackage
            while (exclude.hasNext()) {
                runCatching { builder.addDisallowedApplication(exclude.next()) }
            }
        }

        val pfd = builder.establish()
            ?: error("android: the application is not prepared or is revoked")
        // 持有 ParcelFileDescriptor 本体：只存 int 的话对象被 GC 时 fd 会被关闭。
        tunPfd = pfd
        // Android 10+ 用 underlying network 告知系统 VPN 的实际上层链路；
        // 影响按网络计量与部分 OEM 的连通性判断（华为后台/切换场景）。
        underlyingNetwork?.let { network ->
            runCatching { setUnderlyingNetworks(arrayOf(network)) }
                .onFailure { Log.w(TAG, "setUnderlyingNetworks failed", it) }
        }
        return pfd.fd
    }

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        // minSdk 29: getConnectionOwnerUid is available on every supported device.
        val uid = getSystemService(ConnectivityManager::class.java).getConnectionOwnerUid(
            ipProtocol,
            InetSocketAddress(sourceAddress, sourcePort),
            InetSocketAddress(destinationAddress, destinationPort),
        )
        if (uid == Process.INVALID_UID) error("android: connection owner not found")
        val owner = ConnectionOwner()
        owner.userId = uid
        return owner
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        defaultListener = listener
        notifyDefaultInterface(listener)
        if (networkCallbackRegistered) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            // 只盯非 VPN 网络：本应用自己的流量默认走自己的 VPN，
            // registerDefaultNetworkCallback 会把 tun0 当"默认网络"上报，
            // 内核随之把出站绑进隧道形成自环。
            val request = android.net.NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            val connectivity = getSystemService(ConnectivityManager::class.java)
            try {
                connectivity.registerNetworkCallback(
                    request,
                    networkCallback,
                )
                networkCallbackRegistered = true
                // 注册前就在线的上联网不会再补发 onAvailable，先登记一遍，
                // 避免回调表为空时又退回被 HarmonyOS 过滤过的 allNetworks。
                for (network in connectivity.allNetworks) {
                    val caps = connectivity.getNetworkCapabilities(network) ?: continue
                    if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
                    knownNetworks[network] = caps
                }
                notifyDefaultInterface(listener)
            } catch (e: Exception) {
                // 重载路径可能重复注册同一个回调；这种情况下继续使用已有
                // 注册即可，不能让异常冒泡到内核启动流程。
                Log.w(TAG, "registerNetworkCallback failed", e)
            }
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        defaultListener = null
        knownNetworks.clear()
        lastDefaultInterfaceName = ""
        lastDefaultInterfaceIndex = -1
        if (!networkCallbackRegistered) return
        networkCallbackRegistered = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(
                    networkCallback,
                )
            } catch (e: Exception) {
                Log.w(TAG, "unregisterNetworkCallback failed", e)
            }
        }
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            rememberNetwork(network)
            defaultListener?.let { notifyDefaultInterface(it) }
        }

        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                knownNetworks[network] = capabilities
            }
            defaultListener?.let { notifyDefaultInterface(it) }
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            // 蜂窝网络换 IP 时只有 LinkProperties 变；不重新通知，内核会继续用
            // 旧地址dial，表现为 "dial rmnet0: i/o timeout"。这里先刷新登记表。
            rememberNetwork(network)
            defaultListener?.let { notifyDefaultInterface(it) }
        }

        override fun onLost(network: Network) {
            knownNetworks.remove(network)
            defaultListener?.let { notifyDefaultInterface(it) }
        }
    }

    /** 记录一个非 VPN 上联网；能力对象缺失时补查一次。 */
    private fun rememberNetwork(network: Network) {
        val connectivity = getSystemService(ConnectivityManager::class.java)
        val caps = connectivity.getNetworkCapabilities(network) ?: return
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return
        knownNetworks[network] = caps
    }

    /** 本应用的活跃默认网络可能是自己的 VPN；选最优的非 VPN 上联网。 */
    private fun bestUnderlyingNetwork(): Network? {
        val connectivity = getSystemService(ConnectivityManager::class.java)
        val active = connectivity.activeNetwork
        val activeCaps = active?.let { connectivity.getNetworkCapabilities(it) }
        if (activeCaps != null &&
            !activeCaps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
            activeCaps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        ) {
            return active
        }
        // allNetworks 在 HarmonyOS 4 上可能只剩 VPN；回调登记表才是可靠的来源。
        val candidates = LinkedHashSet<Network>()
        candidates.addAll(knownNetworks.keys)
        runCatching { candidates.addAll(connectivity.allNetworks) }
        var best: Network? = null
        var bestScore = -1
        for (candidate in candidates) {
            val caps = knownNetworks[candidate]
                ?: connectivity.getNetworkCapabilities(candidate)
                ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
            var score = 0
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) score += 10
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) score += 8
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) score += 5
            if (score > bestScore) {
                bestScore = score
                best = candidate
            }
        }
        return best
    }

    private fun notifyDefaultInterface(listener: InterfaceUpdateListener) {
        // 官方语义（DefaultNetworkMonitor）：默认网络缺失时报 ("", -1, false, false)。
        try {
            val connectivity = getSystemService(ConnectivityManager::class.java)
            val network = bestUnderlyingNetwork()
            updateUnderlyingNetwork(network)
            val link = network?.let { connectivity.getLinkProperties(it) }
            val name = link?.interfaceName
            val javaIf = name?.let { JavaNetworkInterface.getByName(it) }
            if (name != null && javaIf != null) {
                lastDefaultInterfaceName = name
                lastDefaultInterfaceIndex = javaIf.index
                Log.i(TAG, "notifyDefaultInterface: $name/${javaIf.index}")
                listener.updateDefaultInterface(
                    lastDefaultInterfaceName,
                    lastDefaultInterfaceIndex,
                    false,
                    false,
                )
                return
            }
            // VPN 建立后的一小段时间里，HarmonyOS 4 可能读不到上联网的
            // LinkProperties。这时上报空接口会让内核清空默认接口并暂停全部
            // 出站（连不上的直接后果）；沿用上一次成功的接口更接近真实状态。
            if (lastDefaultInterfaceName.isNotEmpty()) {
                Log.i(TAG, "notifyDefaultInterface: fallback ${lastDefaultInterfaceName}")
                listener.updateDefaultInterface(
                    lastDefaultInterfaceName,
                    lastDefaultInterfaceIndex,
                    false,
                    false,
                )
                return
            }
            Log.i(TAG, "notifyDefaultInterface: no underlying network")
            listener.updateDefaultInterface("", -1, false, false)
        } catch (e: Exception) {
            Log.w(TAG, "notifyDefaultInterface", e)
        }
    }

    /**
     * 把选中的上联网声明给系统。VPN 建立后系统据此判断“VPN 下面是谁”，
     * 用于按网络计量与部分 OEM 的后台/切换策略。
     */
    private fun updateUnderlyingNetwork(network: Network?) {
        if (underlyingNetwork == network) return
        underlyingNetwork = network
        if (tunPfd == null) return
        try {
            setUnderlyingNetworks(network?.let { arrayOf(it) })
        } catch (e: Exception) {
            Log.w(TAG, "setUnderlyingNetworks failed", e)
        }
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        // MVP：返回系统接口列表（名称/索引/MTU/地址）。libbox 用它选择出站接口。
        val connectivity = getSystemService(ConnectivityManager::class.java)
        val result = mutableListOf<io.nekohasekai.libbox.NetworkInterface>()
        val seen = HashSet<String>()

        // 回调登记表优先：HarmonyOS 4 会在 VPN 建立后把物理网络从 allNetworks
        // 和 getLinkProperties 的可见集合里隐藏，只枚举 allNetworks 会得到空表。
        val networks = LinkedHashSet<Network>()
        networks.addAll(knownNetworks.keys)
        runCatching { networks.addAll(connectivity.allNetworks) }
        for (network in networks) {
            val link = connectivity.getLinkProperties(network) ?: continue
            val name = link.interfaceName ?: continue
            if (myInterface != null && name == myInterface) continue
            if (!seen.add(name)) continue
            val caps = knownNetworks[network]
                ?: connectivity.getNetworkCapabilities(network)
            val javaIf = JavaNetworkInterface.getByName(name) ?: continue
            result.add(buildInterface(javaIf, caps, link))
        }

        // 最后一道保险：内核接口枚举不经过 ConnectivityManager 的可见性过滤。
        // 空表会让 sing-box 的 NetworkManager 报 "no available network interface"
        // 并暂停全部出站，比缺少类型/网关的接口条目严重得多。
        if (result.isEmpty()) {
            val kernel = runCatching { JavaNetworkInterface.getNetworkInterfaces() }
                .getOrNull()
            if (kernel != null) {
                for (javaIf in kernel) {
                    val up = runCatching { javaIf.isUp }.getOrDefault(false)
                    if (!up) continue
                    if (myInterface != null && javaIf.name == myInterface) continue
                    if (!seen.add(javaIf.name)) continue
                    result.add(buildInterface(javaIf, null, null))
                }
            }
        }
        Log.i(TAG, "getInterfaces: ${result.size} -> ${result.joinToString { it.name }}")
        return InterfaceArray(result.iterator())
    }

    /**
     * 把一个 Java 接口转成 libbox 的接口条目。
     *
     * [link] 为空表示数据来自内核枚举而不是 ConnectivityManager：此时没有
     * 能力/网关/MTU 之外的元数据，只按接口名推断类型。
     */
    private fun buildInterface(
        javaIf: JavaNetworkInterface,
        caps: NetworkCapabilities?,
        link: LinkProperties?,
    ): io.nekohasekai.libbox.NetworkInterface {
        val item = io.nekohasekai.libbox.NetworkInterface()
        item.name = javaIf.name
        item.index = javaIf.index
        runCatching { item.mtu = javaIf.mtu }
        item.addresses = StringArray(
            // hostAddress 对链路本地 IPv6 带 zone（fe80::..%wlan0），Go 的
            // netip.ParsePrefix 拒绝带 zone 的前缀；用裸字节重建剥掉它
            // （与官方 sing-box-for-android 的 InterfaceAddress.toPrefix 一致）。
            javaIf.interfaceAddresses.map { addr ->
                val host = if (addr.address is Inet6Address) {
                    Inet6Address.getByAddress(addr.address.address).hostAddress
                } else {
                    addr.address.hostAddress
                }
                "$host/${addr.networkPrefixLength}"
            }.iterator(),
        )
        item.dnsServer = StringArray(
            (link?.dnsServers ?: emptyList()).mapNotNull { dns ->
                dns.hostAddress?.let { stripZone(it) }
            }.iterator(),
        )
        item.gateway = StringArray(
            (link?.routes ?: emptyList()).mapNotNull { it.gateway }
                .filterNot { it.isAnyLocalAddress }
                .mapNotNull { gw -> gw.hostAddress?.let { stripZone(it) } }.iterator(),
        )
        item.type = when {
            caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true ->
                io.nekohasekai.libbox.Libbox.InterfaceTypeWIFI
            caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true ->
                io.nekohasekai.libbox.Libbox.InterfaceTypeCellular
            caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true ->
                io.nekohasekai.libbox.Libbox.InterfaceTypeEthernet
            javaIf.name.startsWith("wlan") ->
                io.nekohasekai.libbox.Libbox.InterfaceTypeWIFI
            javaIf.name.startsWith("rmnet") ||
                javaIf.name.startsWith("ccmni") ||
                javaIf.name.startsWith("pdp") ->
                io.nekohasekai.libbox.Libbox.InterfaceTypeCellular
            javaIf.name.startsWith("eth") ->
                io.nekohasekai.libbox.Libbox.InterfaceTypeEthernet
            else -> io.nekohasekai.libbox.Libbox.InterfaceTypeOther
        }
        // NetworkManager.UpdateInterfaces 只保留 Flags&IFF_UP 的接口；不设
        // flags（恒 0）会让整个接口缓存变空，所有拨号报
        // "no available network interface"。语义照抄官方 sing-box-for-android。
        var dumpFlags = 0
        if (javaIf.isUp) dumpFlags = dumpFlags or OsConstants.IFF_UP or OsConstants.IFF_RUNNING
        if (javaIf.isLoopback) dumpFlags = dumpFlags or OsConstants.IFF_LOOPBACK
        if (javaIf.isPointToPoint) dumpFlags = dumpFlags or OsConstants.IFF_POINTOPOINT
        if (javaIf.supportsMulticast()) dumpFlags = dumpFlags or OsConstants.IFF_MULTICAST
        item.flags = dumpFlags
        return item
    }

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun clearDNSCache() {}

    override fun readWIFIState(): WIFIState? = null

    override fun registerMyInterface(name: String?) {
        myInterface = name
    }

    override fun sendNotification(notification: io.nekohasekai.libbox.Notification) {
        // MVP：前台通知由本服务自绘，内核通知忽略。
    }

    override fun cancelNotification(identifier: String?, typeID: Int) {}

    override fun startNeighborMonitor(listener: io.nekohasekai.libbox.NeighborUpdateListener) {
        error("not supported")
    }

    override fun closeNeighborMonitor(listener: io.nekohasekai.libbox.NeighborUpdateListener) {}

    override fun usePlatformShell(): Boolean = false

    override fun checkPlatformShell() {
        error("not supported")
    }

    override fun openShellSession(
        user: io.nekohasekai.libbox.PlatformUser?,
        command: String?,
        environ: io.nekohasekai.libbox.StringIterator?,
        term: String?,
        rows: Int,
        cols: Int,
    ): io.nekohasekai.libbox.ShellSession = error("not supported")

    override fun lookupUser(username: String?): io.nekohasekai.libbox.PlatformUser =
        error("not supported")

    override fun lookupSFTPServer(): String = error("not supported")

    override fun readSystemSSHHostKey(): String = error("not supported")

    override fun tailscaleHostname(): String = Build.MODEL

    override fun usePlatformBridge(): Boolean = false

    override fun createBridge(
        options: io.nekohasekai.libbox.BridgeOptions?,
    ): io.nekohasekai.libbox.BridgeSession = error("not supported")

    override fun localDNSTransport(): io.nekohasekai.libbox.LocalDNSTransport? = null

    // ---- libbox CommandServerHandler ----

    override fun serviceStop() {
        stopBox()
    }

    override fun serviceReload() {
        reloadBox()
    }

    override fun getSystemProxyStatus(): SystemProxyStatus? = null

    override fun setSystemProxyEnabled(enabled: Boolean) {}

    override fun triggerNativeCrash() {
        error("disabled")
    }

    override fun writeDebugMessage(message: String) {
        Log.d(TAG, message)
    }

    override fun connectSSHAgent(): Int = error("not supported")

    // ---- 通知 ----

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

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            packageManager.getLaunchIntentForPackage(packageName)
                ?: Intent().setClassName(packageName, "com.clashhalo.halo.MainActivity")
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
            .setContentText(
                when (state) {
                    VpnState.Started -> message.ifEmpty { "已连接" }
                    VpnState.Starting -> message.ifEmpty { "正在启动…" }
                    VpnState.Failed -> message.ifEmpty { "启动失败" }
                    VpnState.Stopped -> "未连接"
                },
            )
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "停止", stop).build())
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .build()
    }

    // ---- 迭代器适配（gomobile 接口） ----

    private fun stripZone(hostAddress: String): String {
        val zoneStart = hostAddress.indexOf('%')
        return if (zoneStart >= 0) hostAddress.substring(0, zoneStart) else hostAddress
    }

    private class StringArray(
        private val iterator: Iterator<String>,
    ) : io.nekohasekai.libbox.StringIterator {
        override fun len(): Int = 0 // 内核不使用
        override fun hasNext(): Boolean = iterator.hasNext()
        override fun next(): String = iterator.next()
    }

    private class InterfaceArray(
        private val iterator: Iterator<io.nekohasekai.libbox.NetworkInterface>,
    ) : NetworkInterfaceIterator {
        override fun hasNext(): Boolean = iterator.hasNext()
        override fun next(): io.nekohasekai.libbox.NetworkInterface = iterator.next()
    }

    companion object {
        private const val TAG = "HaloVpn"
        const val ACTION_START = "com.clashhalo.vpn.START"
        const val ACTION_STOP = "com.clashhalo.vpn.STOP"
        const val CHANNEL_ID = "halo-vpn"
        const val NOTIFICATION_ID = 1001

        /** UI 进程读取的状态文件；与 config.json 同目录，仅本应用可读。 */
        const val STATE_FILE = "vpn-state.json"

        @Volatile
        private var setupDone = false
    }
}
