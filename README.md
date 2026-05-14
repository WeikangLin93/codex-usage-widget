# Codex Usage Widget / Codex 用量桌面小组件

一个用于 **Windows 桌面右下角悬浮显示** 的 Codex 用量小组件。  
A lightweight **Windows desktop floating widget** for monitoring Codex usage.

---

## 功能特点 / Features

- 显示 5 小时窗口与 7 天窗口的用量百分比（已用/剩余）  
  Shows usage for both 5-hour and 7-day windows (used/remaining).
- 每 60 秒自动刷新  
  Auto-refreshes every 60 seconds.
- 支持透明度调节（20%~100%）  
  Adjustable opacity (20%~100%).
- 支持图层切换（始终置顶 / 普通层级）  
  Layer mode switch (always-on-top / normal).
- 自动跟随系统明暗主题颜色  
  Adapts to system light/dark theme.
- 游戏模式（自动检测全屏 + 手动强制显示/隐藏，手动优先）  
  Game mode (auto full-screen detection + manual force show/hide, manual override has priority).
- 网络异常时使用本地缓存数据显示  
  Falls back to cached data when network requests fail.

---

## 项目结构 / Project Structure

- `codex_usage_widget.ps1`：桌面悬浮窗主程序  
  Main PowerShell widget UI.
- `codex_usage_fetch.py`：请求 Codex usage 接口并返回 JSON  
  Fetches Codex usage data and returns JSON.
- `启动Codex用量桌显.bat`：一键启动入口（Windows）  
  One-click launcher on Windows.
- `widget_config.json`：界面配置（自动生成）  
  UI config file (auto-generated).
- `last_usage.json`：最近一次成功数据缓存（自动生成）  
  Last successful usage cache (auto-generated).

---

## 使用方法 / How to Use

### 中文
1. 确保你已在本机完成 Codex 登录（本项目会读取本机认证信息）。
2. 双击 `启动Codex用量桌显.bat`。
3. 右下角出现悬浮窗后，可右键调整透明度与图层。
4. 双击悬浮窗可关闭。

### English
1. Make sure Codex is already authenticated on your machine.
2. Double-click `启动Codex用量桌显.bat`.
3. Right-click the widget to change opacity and layer mode.
4. Double-click the widget to close it.

---

## 依赖 / Requirements

- Windows 10/11
- PowerShell 5+
- Python 3.x

---

## 说明 / Notes

- 本项目读取本机已有认证文件，不需要在代码里硬编码 token。  
  This project uses local existing auth files and does not require hardcoding tokens in code.
- 建议不要提交个人认证文件到仓库。  
  Do not commit personal auth credentials to the repository.

---

## License

MIT（可按需改成你自己的许可证）  
MIT (you can change this to your preferred license).
