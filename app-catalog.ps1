# app-catalog.ps1
# 共享应用清单：被 install-desktop-apps.ps1（命令行版）与 install-apps-gui.ps1（图形版）dot-source 使用。
# 每个 winget 包 ID 都用 `winget search --exact --id` 核实过，并与本机实际安装版本比对过。
# OptIn=$true 表示默认不勾选（与桌面现状不完全对应的项）。
#
# 可选字段 Location：为某个应用**固定**安装路径（优先级高于界面里设置的统一路径），例如
#   [pscustomobject]@{ Name='微信'; Id='Tencent.WeChat.Universal'; Shortcut='微信'; Note=''; Location='D:\Apps\WeChat' }
# 不写该字段 = 跟随界面设置（默认位置，或界面里指定的统一路径 + 子文件夹）。
# 注意：仅当安装包声明支持自定义位置时才生效（winget 的 --location）；MSIX/商店类不支持。

$Catalog = @(
    [pscustomobject]@{ Name='Microsoft Edge';      Id='Microsoft.Edge';                                 Shortcut='Microsoft Edge';      Note='' }
    [pscustomobject]@{ Name='Visual Studio Code';  Id='Microsoft.VisualStudioCode';                     Shortcut='Visual Studio Code';  Note='' }
    [pscustomobject]@{ Name='Steam';               Id='Valve.Steam';                                    Shortcut='Steam';               Note='装完后 3DMark 需在 Steam 内单独安装' }
    [pscustomobject]@{ Name='balenaEtcher';        Id='Balena.Etcher';                                  Shortcut='balenaEtcher';        Note='' }
    [pscustomobject]@{ Name='FreeCAD';             Id='FreeCAD.FreeCAD';                                Shortcut='FreeCAD';             Note='' }
    [pscustomobject]@{ Name='Oracle VirtualBox';   Id='Oracle.VirtualBox';                              Shortcut='Oracle VirtualBox';   Note='eNSP 依赖它；升级需要管理员权限' }
    [pscustomobject]@{ Name='Upscayl';             Id='Upscayl.Upscayl';                                Shortcut='Upscayl';             Note='' }
    [pscustomobject]@{ Name='微信';                 Id='Tencent.WeChat.Universal';                       Shortcut='微信';                 Note='4.x 版，对应你桌面指向的 Program Files\Tencent\Weixin' }
    [pscustomobject]@{ Name='QQ';                  Id='Tencent.QQ.NT';                                  Shortcut='QQ';                  Note='NT 版，与你桌面的 QQNT 一致' }
    [pscustomobject]@{ Name='网易云音乐';           Id='NetEase.CloudMusic';                             Shortcut='网易云音乐';           Note='升级需要管理员权限' }
    [pscustomobject]@{ Name='百度网盘';             Id='Baidu.BaiduNetdisk';                             Shortcut='百度网盘';             Note='' }
    [pscustomobject]@{ Name='哔哩哔哩';             Id='Bilibili.Bilibili';                              Shortcut='哔哩哔哩';             Note='升级需要管理员权限' }
    [pscustomobject]@{ Name='Bambu Studio';        Id='Bambulab.Bambustudio';                           Shortcut='Bambu Studio';        Note='' }
    [pscustomobject]@{ Name='Focusrite Control 2'; Id='FocusriteAudioEngineeringLtd.FocusriteControl2'; Shortcut='Focusrite Control 2'; Note='声卡控制面板；升级需要管理员权限' }
    [pscustomobject]@{ Name='Kimi';                Id='MoonshotAI.Kimi';                                Shortcut='Kimi';                Note='' }
    [pscustomobject]@{ Name='夸克';                 Id='Alibaba.Quark';                                  Shortcut='夸克';                 Note='' }
    [pscustomobject]@{ Name='小熊猫C++';            Id='RoyQu.RedPanda-C++';                             Shortcut='小熊猫C++';            Note='' }
    [pscustomobject]@{ Name='Clash Verge';         Id='ClashVergeRev.ClashVergeRev';                    Shortcut='Clash Verge';         Note='' }
    # ---- 2026-10-18 按桌面新增快捷方式补充 ----
    [pscustomobject]@{ Name='Blender';             Id='BlenderFoundation.Blender';                      Shortcut='Blender 5.2';         Note='3D 建模；winget 5.2.2 与你已装一致' }
    [pscustomobject]@{ Name='Kdenlive';            Id='KDE.Kdenlive';                                   Shortcut='Kdenlive';            Note='视频剪辑' }
    [pscustomobject]@{ Name='Synthesizer V Studio 2 Pro'; Id='Dreamtonics.SynthesizerVStudio2Pro';      Shortcut='Synthesizer V Studio 2 Pro'; Note='winget 索引 2.1.2 落后于你装的 2.2.1，勾选可能降级；平时走官网更新'; OptIn=$true }
    [pscustomobject]@{ Name='荣耀互联';             Id='XPFFG4NV5JTK92';                                 Shortcut='荣耀互联';             Note='来自 Microsoft Store（需商店登录）；可能识别不到你已装的 ARP 版'; OptIn=$true }
    [pscustomobject]@{ Name='Microsoft 365 (Word/Excel/PPT/Access/Publisher)'; Id='Microsoft.Office';   Shortcut='Word';                Note='一条顶五个 Office 快捷方式；企业版 C2R 安装器、数 GB、需订阅或批量许可，重装前先卸旧版'; OptIn=$true }
    # ---- 无 winget 官方包、或 winget 版本落后，默认不勾 ----
    [pscustomobject]@{ Name='Rufus';               Id='Rufus.Rufus';                                    Shortcut='';                    Note='桌面上是便携版 rufus-4.15.exe；需要安装版时单独勾选'; OptIn=$true }
    [pscustomobject]@{ Name='图吧工具箱(WinUI3)';    Id='luolangaga.tubatools';                           Shortcut='图吧工具箱';           Note='与你桌面的 2026 经典版不是同一个包'; OptIn=$true }
)

# 需手动处理 / 有意不自动化的项（图形界面里以「说明」形式展示，不参与勾选）
$Manual = @(
    [pscustomobject]@{ Name='OpenCode (桌面版)';  Reason='winget 索引还停在 1.19.3，而你已装 2.0.26（应用自更新）；用 winget 装会降级，请走应用内更新' }
    [pscustomobject]@{ Name='Ultimate Vocal Remover'; Reason='winget 无此包；你已装在 C:\UVR5-Full（Roformer + DirectML 版），更新走 GitHub Releases + 代理' }
    [pscustomobject]@{ Name='MuMu 模拟器';        Reason='winget/Store 里只有 ARM 版，你的机器是 x64；请用网易官方安装包' }
    [pscustomobject]@{ Name='火绒安全软件';        Reason='winget 仅收录 msstore 版本，可靠性一般；建议用官网安装包' }
    [pscustomobject]@{ Name='eNSP';             Reason='winget 无此包；华为官网下载，且依赖 VirtualBox + Wireshark + 旧版 WinPcap' }
    [pscustomobject]@{ Name='biubiu 加速器';       Reason='仅 msstore 条目且信息不明，建议官网' }
    [pscustomobject]@{ Name='机械革命控制中心';     Reason='OEM 机型专用工具，winget 无收录；按机型从机械革命官网下载' }
    [pscustomobject]@{ Name='3DMark';           Reason='桌面快捷方式是 steam://rungameid/223850，需装好 Steam 后在 Steam 内安装' }
    [pscustomobject]@{ Name='DeepSeek Harness'; Reason='winget 无此产品（搜到的 DSH Desktop 是别家的），请用官方安装包' }
    [pscustomobject]@{ Name='DragonKMS';        Reason='Windows/Office 的 KMS 激活（绕过授权）工具，不提供自动安装' }
)