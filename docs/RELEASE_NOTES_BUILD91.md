# build 91 源码更新

日期：2026-10-08。这是公开源码更新，不是已公证的二进制发行说明。

## 更新范围

- 「我的 AI」作为刘海首页：紧凑等尺寸卡片、官方图标、会员 / API / 配音区分、双额度窗口及清晰连接入口。
- 接入 Codex、Cursor / Cursor 中的 Grok、豆包工作、DeepSeek API、MiniMax 中国站钱包和 Meta Muse 的对应读取路径；Audio 适配器保留，真实付费账户仍需首次连接及持续同步验收。
- 改善新鲜度、过期与错误处理，拒绝用缓存、样例或其他账户的值冒充当前余额。
- 保留独立网站登录，读取失败不要求重复登录；修复 Muse 收起后页面未完成布局导致读取失败的问题。
- 修复嵌入式登录的首次点击输入与标准粘贴路由，后台刷新不抢输入焦点。
- 卡片拖动排序、邻项补位；面板可移动、缩放、保存几何状态、收起和双击还原。官方登录页使用可用空间，不再被固定小视口和外层滚动挤压。
- 跟随支持的前台 AI 应用，显示它自己的额度与图标；未验证的任务状态保持未知。
- 保留任务、笔记、本地时间规划和展示模式；加强草稿、保存失败、连续保存和正常退出保护。

## 公开版兼容

保留 `PaulNotchCore` / `PaulNotchApp` 结构，不运行第二套应用。保留 Bundle ID、默认数据位置和 Swift 6 摄像头隔离修复。链接联网抓取继续关闭；个人打包记录、账户数据、Cookie、私钥、安装副本和原始日志不进入 PR。

固定证书个人配置与通用发行不同，参见 [连接与发行边界](QUOTA_CONNECTIONS.md)。没有提供 Developer ID 公证下载包，也没有替用户完成第三方账户登录。

公开版连接能力使用专门的 opt-in 策略，不再被维护者个人配置模式误拦截。API 后台静默读取与显式恢复授权仍分开；预览拒绝真实凭证和网站连接，固定组件身份检查未改变。

## 验证方法

```sh
swift build --disable-sandbox
swift build -c release --disable-sandbox
swift test --disable-sandbox
zsh scripts/test-public-runtime.sh
zsh scripts/test-public-boundaries.sh
zsh scripts/test-adversarial.sh
git diff --check
```

`test-adversarial.sh` 运行 33 组独立验证和任务 / 音乐 / Codex / 首页附加检查，使用合成数据、临时工作区和私有测试 Keychain，不读取真实 API Key。原生窗口和输入组需要交互式 macOS 会话。

Command Line Tools 的 `swift test` 可能只构建、执行 0 个 XCTest；必须如实记录，不能代替独立验证。维护者个人安装的真实用量 / 退出重开验收，不能替代这个公开分支的测试，也不能推广为所有账户或 Mac 重启均已实测。

## 本轮公开分支结果

- Debug / Release 编译成功；`swift test --disable-sandbox` 构建成功，本机 CLT 未执行 XCTest。
- 33 组完整独立回归与 5 组附加检查通过。
- 8 组补充验证通过：连接生命周期、MiniMax 钱包、Codex 路径发现、额度首页、自助连接 UI、0 / 4 / 7 / 12 / 30 账户布局、公告视口及环境变化。
- 公开启动与隔离预览的 6 项行为检查通过；后台 Keychain 静默、显式恢复及迁移检查通过。普通公开运行误被拒绝的回归先失败，修复后通过。
- 公开源码边界、脚本语法和差异空白检查通过。没有将测试日志、临时工作区或账户数据写入提交。

上述是本轮合成 / 原生回归与源码构建结果，不声称所有真实第三方账户已重新登录、OS 重启已实测或云端 CI 已通过。
