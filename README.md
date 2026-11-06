# sswitch

命令行一键切换 macOS 的 App Store 账号 —— 一条命令，8 秒左右，不弹窗口。

macOS 的 App Store 同一时间只能登一个 Apple 账号。如果你有一个港区/美区/日区账号要跟主账号来回切，
原生流程是「点头像 → 退出登录 → 滚到最底 → 登录 → 重输账号密码 → 等双重认证」，两分钟起步，一天来回三次就是六分钟。

`sswitch` 把这串动作全接管了，跑完还把焦点还给你原来的窗口。

```console
$ sswitch hk
completed: you@example.com   # 8.4s

$ sswitch cn
completed: main@example.com  # 9.1s
```

## 安装

```console
$ git clone https://github.com/Hzml666/appstore-switch.git
$ cd appstore-switch
$ make install          # swiftc 编译后装到 /usr/local/bin
```

要求：macOS 13 或更新，已装 Xcode Command Line Tools（需要 `swiftc`）。
也可以直接下 [Release](https://github.com/Hzml666/appstore-switch/releases) 里的通用二进制丢进 `/usr/local/bin`。

## 用法

```console
$ sswitch add hk  you@example.com      # 交互输入密码，存进钥匙串
$ sswitch add cn  main@example.com
$ sswitch list
hk      you@example.com
cn      main@example.com

$ sswitch hk                           # 切过去
$ sswitch cn
$ sswitch rm hk                        # 删掉一个
```

凭据存在登录钥匙串里，service 名 `appstoreswitch.cli`，一个账号一条 JSON。不落盘明文，不上传任何地方。

### 绑个快捷键

打开「快捷指令」→ 新建 → 添加「运行 Shell 脚本」→ 填 `/usr/local/bin/sswitch hk` → 设个快捷键（比如 ⌃⌥H）。
另一个账号照做一遍。以后切账号就是按两下键盘。

### 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 切换成功 |
| 2 | 用法错误 / 账号不存在 |
| 3 | 尝试了但 Apple 拒绝、超时，或需要你手动完成某一步 |

每次运行都会往 `~/Library/Logs/sswitch.log` 写逐行日志。

## 权限

首次运行会要两个授权，都是一次性的：

1. **辅助功能** —— 用来读取和操作 App Store 窗口。
2. **自动化 → System Events** —— 只干一件事：往密码框里打字。
   macOS 在密码框获得焦点时会进入 Secure Input，这个模式下第三方进程合成的键盘事件会被系统直接丢弃。
   System Events 的 `keystroke` 是唯一还能送进去的通道。其余动作（菜单、按钮、文本框）全部走辅助功能 API，不经过它。

如果权限没给，切换会干净地失败（报「找不到密码框」或「登录被拒」）。
去「系统设置 → 隐私与安全性」里能看到 `sswitch`（或启动它的那个 App），勾上就行。

## 为什么要写这么多代码

做这个东西踩的坑，给后面写同类工具的人省点时间：

- **账户按钮没有辅助功能动作。** `AppStore.accountButton` 的 `AXActionNames` 是空的，`AXPress` 调了没反应。
  登录只能从菜单栏「商店 → 登录」走；退出登录则藏在这个按钮弹出的面板里，必须真实鼠标点击才触发。
- **登录表单是嵌套的。** 结构是 `window → AXSheet → AXSheet → AXScrollArea → AXTextField`。
  用 `text fields of sheet 1 of window 1` 这种查法永远返回 0，必须遍历整棵控件树。
- **界面语言跟着商店区域变。** 登进港区账号后整个 App Store 变繁体（`登入` / `登出`），
  所以每个 label 都要兼容简体、繁体、英文三种，而且 `退出登录` 必须先于 `登录` 判断（它包含后者）。
- **自动补全会改写邮箱。** 粘贴或键入一个跟历史账号相似的地址，会被悄悄「纠正」（`@163.com` → `@qq.com`），
  然后 Apple 回你一句毫无信息量的「发生未知错误」。可靠做法是把值写进 `AXValue` 再读回来校验。
- **按回车不一定提交。** 焦点不在字段上时，回车提交的是编辑器里的旧内容。得去点弹窗的主按钮。
- **Secure Input**，如上。`AXValue` 写入 `AXSecureTextField` 同样无效，只剩打字这条路。

## 已知限制

- 双重认证需要你自己输：工具会把弹窗留着等你，最多两分钟，然后报告结果。
- 新设备首次登录可能出现条款/验证页，那一下要手动点。
- Apple 有限流。一分钟内连切十次会开始失败一段时间。
- **只切 App Store 账号**，不碰你的 iCloud 账号。

## English

`sswitch` switches the macOS App Store account from the terminal: one command, ~8 seconds,
no window of its own, focus restored afterwards. Credentials live in the login keychain.
Install with `make install`, then `sswitch add hk you@example.com` and `sswitch hk`.
Requires Accessibility, plus a one-time Automation grant for System Events (the only way to
type into a Secure Input password field). MIT licensed.

## License

MIT —— 见 [LICENSE](LICENSE)。
