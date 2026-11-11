# libbox 的 Go 侧通过 JNI 反射调用 go.Seq 的方法（如 getRef）；R8 从 Java
# 视角看不到这些调用，会把它们连同 Seq$Ref 一起裁掉，运行时在 :vpn 进程里
# 以 "failed to find method Seq.getRef" SIGABRT。绑定量与内核（libbox.so）
# 是同一次 bind 严格配套的，必须整体保留。
# 手工拆包 AAR（libs/libbox.jar）会丢掉 AAR 自带的 consumer proguard.txt，
# 所以在这里补回等价规则。
-keep class go.** { *; }
-keep class io.nekohasekai.libbox.** { *; }
