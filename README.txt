Codex 用量桌面显示（Windows）

你现在有一个桌面小组件，会显示 Codex 的 5小时/7天 用量。

文件说明：
1) 启动Codex用量桌显.bat  双击启动（黑色命令行窗口已隐藏）
2) codex_usage_widget.ps1    桌面悬浮窗（右下角）
3) codex_usage_fetch.py      负责请求接口并返回用量
4) last_usage.json           最近一次成功数据缓存（自动生成到 AppData）
5) widget_config.json        你的样式配置（自动生成到 AppData）
6) tests/                    Python 核心逻辑测试

可调功能：
1) 右键悬浮窗 -> 透明度（20%~100%）
2) 右键悬浮窗 -> 图层：
   - 桌面最顶端（始终置顶）
   - 活动窗口后（不置顶，跟普通窗口层级）

背景颜色会自动跟随系统任务栏风格（明/暗主题）。
以上设置会自动保存，下次启动保持不变。
刷新会在后台执行，网络慢时不会卡住悬浮窗。
配置和缓存位置：%LOCALAPPDATA%\CodexUsageWidget

使用方法：
1. 先确认你已在本机完成 Codex CLI / Codex 桌面相关环境登录，并生成 ~/.codex/auth.json 或 ~/.hermes/auth.json
   仅网页版 ChatGPT 登录通常无法使用，因为本工具读取本地认证文件，不读取浏览器 cookie
2. 双击“启动Codex用量桌显.bat”
3. 右下角会出现悬浮窗：
   - 5h：已用X% / 剩余Y%
   - 7d：已用A% / 剩余B%
4. 每60秒自动刷新一次
5. 右键可切换图层（桌面最顶端/活动窗口后）
6. 双击悬浮窗可关闭

说明：
1. 本工具依赖本机已有 Codex/ChatGPT 登录信息。
2. 这里的登录信息是 ~/.codex/auth.json 或 ~/.hermes/auth.json，不是浏览器网页登录 cookie。
3. 如果 access token 过期，脚本会刷新 token，并在写回认证文件前生成 .bak 备份。
4. usage 接口不是公开稳定 API，官方客户端更新后可能需要跟着调整。

开发/打包：
1. 运行检查：powershell -ExecutionPolicy Bypass -File scripts\check.ps1
2. 构建 zip：powershell -ExecutionPolicy Bypass -File scripts\build_release.ps1
3. 构建带 exe 的 zip：powershell -ExecutionPolicy Bypass -File scripts\build_release.ps1 -InstallPyInstaller
