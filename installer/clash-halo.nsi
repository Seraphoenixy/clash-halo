; Clash Halo 安装包脚本（NSIS 3.x）。
;
; 由 scripts/build-installer.ps1 编译，所有路径与版本号从命令行传入：
;
;   makensis -INPUTCHARSET UTF8 -DPAYLOAD=... -DOUT_FILE=... -DAPP_VERSION=... clash-halo.nsi
;
; 本文件是不带 BOM 的 UTF-8。NSIS 默认按系统 ANSI 代码页解码脚本，中文会变成
; 语法错误，所以必须加 -INPUTCHARSET UTF8（构建脚本负责这件事）。手写命令行漏掉
; 它时看到的是 "Bad text encoding"，那是编码问题，不是脚本语法问题。
;
; 装到哪里：%LOCALAPPDATA%\Programs\ClashHalo，当前用户，不需要管理员。
; 这个应用本来就是每用户一份：数据目录在 %LOCALAPPDATA%\clash-halo，开机自启写
; HKCU\...\Run，单实例锁与托盘图标也都按用户划分。装到 Program Files 只会让每次
; 安装、升级、卸载都多一次 UAC 授权，换不来任何隔离——数据仍然在用户目录里。
;
; 本脚本最重要的部分是 StopInstalled：在动旧文件之前，必须先让旧版本的宿主自己
; 退出。理由写在那里。

Unicode true

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "WinVer.nsh"

; --- 由命令行传入 ---
!ifndef PAYLOAD
  !error "PAYLOAD 未定义：请用 scripts/build-installer.ps1 编译，或自己传 -DPAYLOAD=<运行目录>"
!endif
!ifndef OUT_FILE
  !error "OUT_FILE 未定义：传 -DOUT_FILE=<安装包路径>"
!endif
!ifndef APP_VERSION
  !define APP_VERSION "0.0.0"
!endif
; 文件属性里的版本必须是四段数字（x.x.x.x），与 APP_VERSION 分开传。
!ifndef APP_FILE_VERSION
  !define APP_FILE_VERSION "0.0.0.0"
!endif
; 安装程序与卸载程序的图标。NSIS 自带一个蓝色地球，用在这里会让用户看到「一个
; 不认识的东西要装东西」，而应用窗口、任务栏和开始菜单里都是紫色猫头。用命令行
; 传入而不是写死路径，是因为这个 .ico 属于 Flutter 外壳的资源
; （apps/flutter/windows/runner/resources），安装脚本不该知道它的位置。
!ifdef APP_ICON
  !define MUI_ICON "${APP_ICON}"
  !define MUI_UNICON "${APP_ICON}"
!endif

!define APP_NAME "Clash Halo"
!define APP_PUBLISHER "Clash Halo Project"
; 注册表与开机自启项的名字。Run 键下的值名必须与
; native/windows/internal/autolaunch 里的 runValueName 一致，否则卸载时删的不是
; 应用写的那个值，自启项会继续指向已经不存在的程序。
!define APP_ID "ClashHalo"
!define APP_AUTORUN_VALUE "ClashHalo"
!define RUN_KEY "Software\Microsoft\Windows\CurrentVersion\Run"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}"

Name "${APP_NAME} ${APP_VERSION}"
OutFile "${OUT_FILE}"
; 带空格的目录名，与开始菜单项、「应用和功能」里的 DisplayName 保持一致：
; 用户在资源管理器里找的是「Clash Halo」，不是一个叫 ClashHalo 的目录。
InstallDir "$LOCALAPPDATA\Programs\Clash Halo"
; 升级装回原位置：用户改过一次安装目录后，第二次安装不该把它忘了。
InstallDirRegKey HKCU "${UNINST_KEY}" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 64
BrandingText "${APP_NAME} ${APP_VERSION}"
ShowInstDetails show
ShowUninstDetails show

VIProductVersion "${APP_FILE_VERSION}"
VIAddVersionKey /LANG=2052 "ProductName" "${APP_NAME}"
VIAddVersionKey /LANG=2052 "FileDescription" "${APP_NAME} 安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "ProductVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "CompanyName" "${APP_PUBLISHER}"
VIAddVersionKey /LANG=2052 "LegalCopyright" "GPL-3.0-or-later"

; 新文件先落到这里，再拷进安装目录。存在的理由见 StopInstalled。
!define STAGEBIN "$PLUGINSDIR\stage"

Var DataDir
Var OldVersion
Var AllUnlocked
Var Handle
Var Attempt

; ---------------------------------------------------------------------------
; 页面
; ---------------------------------------------------------------------------
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\clash-halo.exe"
!define MUI_FINISHPAGE_RUN_TEXT "运行 ${APP_NAME}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

; ---------------------------------------------------------------------------
; 数据目录
;
; 与应用自己的解析顺序一致（apps/flutter/lib/main.dart 的 resolveDataDir 与
; halo-host 的 resolveDir）：程序旁边的 portable.flag 优先，否则
; %LOCALAPPDATA%\clash-halo。安装包自己不写 portable.flag，但升级一个便携目录时
; 它可能已经在那儿；那时停进程必须用同一个数据目录，否则会去跟一个不存在的管道
; 握手，然后「成功」返回，而真正在跑的那个宿主根本没被叫到。
;
; 安装与卸载都要用这三个函数，而 NSIS 要求卸载区调用的函数名以 un. 开头，所以
; 函数体写成宏，两边各生成一份。手抄第二份的代价是两处判据慢慢分叉，而卸载那边
; 分叉的后果是「卸载后系统代理仍指向已删除的内核」。
; ---------------------------------------------------------------------------
!macro ResolveDataDirBody
  StrCpy $DataDir "$LOCALAPPDATA\clash-halo"
  ${If} ${FileExists} "$INSTDIR\portable.flag"
    StrCpy $DataDir "$INSTDIR\user-data"
  ${EndIf}
!macroend

Function ResolveDataDir
  !insertmacro ResolveDataDirBody
FunctionEnd

Function un.ResolveDataDir
  !insertmacro ResolveDataDirBody
FunctionEnd

; 检查 $INSTDIR 里的三个可执行文件是否都还能写进 $AllUnlocked（"1"/"0"）
;
; 正在运行的映像只允许共享读，所以用追加模式打开它会失败——这是唯一可靠的判据。
; ${FileExists} 对正在运行的可执行文件同样返回真，看不出占用。
; 文件不存在按「未占用」算：不存在的文件会被追加模式创建出来，所以先判存在。
!macro CheckUnlockedBody
  StrCpy $AllUnlocked "1"
  ${If} ${FileExists} "$INSTDIR\halo-host.exe"
    FileOpen $Handle "$INSTDIR\halo-host.exe" a
    ${If} ${Errors}
      StrCpy $AllUnlocked "0"
    ${Else}
      FileClose $Handle
    ${EndIf}
  ${EndIf}
  ${If} ${FileExists} "$INSTDIR\clash-halo.exe"
    FileOpen $Handle "$INSTDIR\clash-halo.exe" a
    ${If} ${Errors}
      StrCpy $AllUnlocked "0"
    ${Else}
      FileClose $Handle
    ${EndIf}
  ${EndIf}
  ${If} ${FileExists} "$INSTDIR\sing-box.exe"
    FileOpen $Handle "$INSTDIR\sing-box.exe" a
    ${If} ${Errors}
      StrCpy $AllUnlocked "0"
    ${Else}
      FileClose $Handle
    ${EndIf}
  ${EndIf}
!macroend

Function CheckUnlocked
  !insertmacro CheckUnlockedBody
FunctionEnd

Function un.CheckUnlocked
  !insertmacro CheckUnlockedBody
FunctionEnd

; 等到可执行文件都不再被占用，最多 15 秒（30 × 500ms）。
; --shutdown 是等到管道关闭才返回的，但进程还要一小段时间才真正退出，那段时间里
; 它的映像仍被占用——所以必须等，不能收到回复就直接覆盖。
!macro WaitForUnlockBody
  StrCpy $Attempt 0
  ${Do}
    Call CheckUnlocked
    ${If} $AllUnlocked == "1"
      ${ExitDo}
    ${EndIf}
    ${If} $Attempt >= 30
      ${ExitDo}
    ${EndIf}
    IntOp $Attempt $Attempt + 1
    Sleep 500
  ${Loop}
!macroend

Function WaitForUnlock
  !insertmacro WaitForUnlockBody
FunctionEnd

; 卸载区调用的是 un.WaitForUnlock，它内部又要调 un.CheckUnlocked，所以这一份
; 不能复用上面的宏体（宏体里写死了 Call CheckUnlocked）。
Function un.WaitForUnlock
  StrCpy $Attempt 0
  ${Do}
    Call un.CheckUnlocked
    ${If} $AllUnlocked == "1"
      ${ExitDo}
    ${EndIf}
    ${If} $Attempt >= 30
      ${ExitDo}
    ${EndIf}
    IntOp $Attempt $Attempt + 1
    Sleep 500
  ${Loop}
FunctionEnd

; ---------------------------------------------------------------------------
; 停止已安装的版本
;
; 为什么必须走宿主自己的退出路径，而不是 taskkill：
;
;   * 宿主的 App.Shutdown 会停掉 sing-box、拆掉 TUN、并把系统代理还原成它接管
;     之前的值。直接杀掉进程这些都不做，代理注册表项就停在「指向一个已经不在的
;     内核」上；装完新版本、内核还没起来之前，这台机器是没有网的。
;   * 界面收到 host.exiting 后自己关窗口，所以停掉宿主也就关掉了界面，不必另外
;     去杀 clash-halo.exe。而它必须关闭，否则它占着 clash-halo.exe 与 data\app.so，
;     新文件写不进去。
;
; 为什么用暂存目录里的新 halo-host.exe，而不是已安装的那个：
;
;   安装包可能比机器上的版本新，旧版本未必认识 --shutdown。新副本已经在
;   $STAGEBIN 里，它只说管道协议（host.shutdown），对所有版本的宿主都成立；而且
;   --shutdown 在解析内核之前就返回，不要求旁边有 sing-box.exe。
;
; 失败时不做兜底强杀：一个不肯退出的宿主，用 taskkill 结束只会留下一个指向死内核
; 的系统代理。宁可停下来让用户从托盘退出后再装。
; ---------------------------------------------------------------------------
Function StopInstalled
  StrCpy $AllUnlocked "1"
  ${IfNot} ${FileExists} "$INSTDIR\halo-host.exe"
    DetailPrint "未发现已安装的版本，跳过程序停止。"
    Return
  ${EndIf}

  Call ResolveDataDir
  DetailPrint "停止正在运行的 ${APP_NAME}…"
  nsExec::ExecToLog '"${STAGEBIN}\halo-host.exe" --shutdown --dir "$DataDir"'
  Pop $0
  DetailPrint "--shutdown 退出码：$0"
  Call WaitForUnlock

  ${If} $AllUnlocked == "1"
    DetailPrint "程序已停止，占用文件已释放。"
    Return
  ${EndIf}

  ${If} ${Silent}
    ; 静默安装没有人能点「确定」：用非零退出码失败，让调用方看得见。
    DetailPrint "无法停止正在运行的 ${APP_NAME}。"
    SetErrorLevel 2
    Quit
  ${EndIf}

  MessageBox MB_ICONSTOP|MB_OK \
    "无法停止正在运行的 ${APP_NAME}，安装已取消。$\r$\n$\r$\n\
     请从托盘菜单选择「退出」，等窗口关闭后重新运行安装程序。$\r$\n$\r$\n\
     直接结束进程会留下指向已停止内核的系统代理，这台机器将无法上网。"
  Abort
FunctionEnd

; ---------------------------------------------------------------------------
; 安装
; ---------------------------------------------------------------------------
Section "${APP_NAME}" SecMain
  ${IfNot} ${AtLeastWin10}
    MessageBox MB_ICONSTOP|MB_OK "${APP_NAME} 需要 Windows 10 或更高版本。"
    Abort
  ${EndIf}

  ; --- 1. 只暂存 halo-host.exe ---
  ; 目的只有一个：在动旧版本之前，磁盘上已经有一个能说话的宿主。其余文件在停止
  ; 程序之后直接写进安装目录。
  ;
  ; 不要用 CopyFiles 把它们搬过去：CopyFiles 的第二个参数是 mask，不是目标目录，
  ; 写成 `CopyFiles "/SILENT src\*.*" "$INSTDIR"` 会把 $INSTDIR 当成 mask，于是
  ; 一个文件都不拷，而且不报错——安装目录里只剩下 data 与卸载程序，装完才发现。
  RMDir /r "${STAGEBIN}"
  SetOutPath "${STAGEBIN}"
  File "${PAYLOAD}\halo-host.exe"

  ; --- 2. 停掉旧版本 ---
  Call StopInstalled

  ; --- 3. 落地 ---
  ; 记下升级前的版本，结束日志要说清是首次安装还是从哪个版本升级。
  ReadRegStr $OldVersion HKCU "${UNINST_KEY}" "DisplayVersion"

  CreateDirectory "$INSTDIR"
  SetOutPath "$INSTDIR"
  File "${PAYLOAD}\clash-halo.exe"
  File "${PAYLOAD}\halo-tun-service.exe"
  File "${PAYLOAD}\sing-box.exe"
  File "${PAYLOAD}\flutter_windows.dll"
  File "${PAYLOAD}\libcronet.dll"
  File "${PAYLOAD}\native_assets.json"
  ; 命令行工具是可选的：没有它图形界面照常使用。
  File /nonfatal "${PAYLOAD}\halo-cli.exe"
  File "${PAYLOAD}\halo-host.exe"
  ; 按需提权的助手已退役。旧版本装过它，升级时删掉，避免留下一个不再使用的
  ; 高权限可执行文件。
  Delete "$INSTDIR\halo-tun-helper.exe"
  RMDir /r "${STAGEBIN}"

  ; data 整棵替换，不做合并。旧的 flutter_assets 里可能还留着已经删掉的资源，而
  ; app.so 与图标字体子集必须是这次的产物，否则界面显示的是上一版
  ; （见 docs/agents/build.md 里「图标缺失」的两种成因）。
  RMDir /r "$INSTDIR\data"
  SetOutPath "$INSTDIR\data"
  File /r "${PAYLOAD}\data\*.*"

  ; --- 4. 卸载程序与快捷方式 ---
  WriteUninstaller "$INSTDIR\uninstall.exe"
  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortCut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\clash-halo.exe"
  CreateShortCut "$SMPROGRAMS\${APP_NAME}\卸载 ${APP_NAME}.lnk" "$INSTDIR\uninstall.exe"

  ; --- 5. 注册表 ---
  ; 每用户注册：卸载列表里的这一项属于安装它的用户，与其他账户无关。
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\clash-halo.exe"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "${APP_PUBLISHER}"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKCU "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${UNINST_KEY}" "EstimatedSize" "$0"

  ; 开机自启项不在这里写：它由应用里的开关决定（autoLaunch.set）。安装包替用户
  ; 打开它，等于替用户做了这个决定。

  ${If} $OldVersion == ""
    DetailPrint "安装完成：${APP_NAME} ${APP_VERSION}"
  ${Else}
    DetailPrint "升级完成：${APP_NAME} $OldVersion → ${APP_VERSION}"
  ${EndIf}
SectionEnd

; ---------------------------------------------------------------------------
; 卸载
; ---------------------------------------------------------------------------
Section "Uninstall"
  ; 先问要不要连数据一起删。订阅、节点与设置是用户的，删掉无法恢复，所以默认
  ; 保留；静默卸载（/S）没有人能回答，同样保留。
  StrCpy $0 "1"
  ${IfNot} ${Silent}
    ${If} ${FileExists} "$INSTDIR\user-data\clash-halo.db"
      StrCpy $1 "$INSTDIR\user-data"
    ${Else}
      StrCpy $1 "$LOCALAPPDATA\clash-halo"
    ${EndIf}
    ${If} ${FileExists} "$1\clash-halo.db"
      MessageBox MB_YESNO|MB_ICONQUESTION|MB_DEFBUTTON2 \
        "是否同时删除订阅、节点与设置？$\r$\n$\r$\n\
         选择「否」会保留这些数据，以后重新安装时继续使用。" \
        IDNO keep_data
      StrCpy $0 "0"
      keep_data:
    ${EndIf}
  ${EndIf}

  ; 停止正在运行的程序，理由与安装时相同：删掉文件而让宿主活着，等于让内核与
  ; 系统代理失去管理者。
  ${If} ${FileExists} "$INSTDIR\halo-host.exe"
    Call un.ResolveDataDir
    DetailPrint "停止正在运行的 ${APP_NAME}…"
    nsExec::ExecToLog '"$INSTDIR\halo-host.exe" --shutdown --dir "$DataDir"'
    Pop $1
    DetailPrint "--shutdown 退出码：$1"
    Call un.WaitForUnlock
    ${If} $AllUnlocked != "1"
      ${IfNot} ${Silent}
        MessageBox MB_ICONSTOP|MB_OK \
          "无法停止正在运行的 ${APP_NAME}，卸载已取消。$\r$\n$\r$\n\
           请从托盘菜单选择「退出」，等窗口关闭后重新卸载。"
        Abort
      ${EndIf}
      DetailPrint "警告：程序仍在运行，部分文件可能无法删除。"
    ${EndIf}
  ${EndIf}

  ; 快捷方式
  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\卸载 ${APP_NAME}.lnk"
  RMDir "$SMPROGRAMS\${APP_NAME}"

  ; 开机自启项：值名与 native/windows/internal/autolaunch 的 runValueName 一致。
  ; 必须删，否则它继续指向一个已经被删掉的 exe。
  DeleteRegValue HKCU "${RUN_KEY}" "${APP_AUTORUN_VALUE}"
  DeleteRegKey HKCU "${UNINST_KEY}"

  ; 文件。逐个删除而不是 RMDir /r，是为了在用户把别的东西放进安装目录时留下它们。
  RMDir /r "$INSTDIR\data"
  Delete "$INSTDIR\clash-halo.exe"
  Delete "$INSTDIR\halo-host.exe"
  Delete "$INSTDIR\halo-tun-helper.exe"
  Delete "$INSTDIR\halo-tun-service.exe"
  Delete "$INSTDIR\sing-box.exe"
  Delete "$INSTDIR\halo-cli.exe"
  Delete "$INSTDIR\flutter_windows.dll"
  Delete "$INSTDIR\libcronet.dll"
  Delete "$INSTDIR\native_assets.json"
  ; 便携标记只出现在「直接解压运行」的目录里；装了安装包之后它不该留下。
  Delete "$INSTDIR\portable.flag"

  ${If} $0 == "1"
    Delete "$INSTDIR\user-data\clash-halo.db"
    Delete "$INSTDIR\user-data\clash-halo.db-wal"
    Delete "$INSTDIR\user-data\clash-halo.db-shm"
    RMDir /r "$INSTDIR\user-data"
    RMDir /r "$LOCALAPPDATA\clash-halo"
  ${EndIf}

  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"
SectionEnd
