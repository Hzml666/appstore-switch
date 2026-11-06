# sswitch

Switch the macOS App Store account from the terminal — one command, ~8 seconds, no window of its own.

macOS only lets the App Store be signed in to **one** Apple ID at a time. If you juggle a
region-specific account (US / HK / JP…) with your main one, the built-in flow is
*click avatar → sign out → scroll to the bottom → sign in → retype everything*.
`sswitch` does all of that for you and gets out of the way.

```console
$ sswitch hk
completed: you@example.com   # 8.4s

$ sswitch cn
completed: main@example.com  # 9.1s
```

## Install

```console
$ git clone https://github.com/Hzml666/appstore-switch.git
$ cd appstore-switch
$ make install          # builds with swiftc and copies to /usr/local/bin
```

Requirements: macOS 13 or newer, Xcode Command Line Tools (`swiftc`).

## Use

```console
$ sswitch add hk  you@example.com      # prompts for the password, stores it in the keychain
$ sswitch add cn  main@example.com
$ sswitch list
hk      you@example.com
cn      main@example.com

$ sswitch hk                           # switch
$ sswitch cn
$ sswitch rm hk                        # forget an account
```

Credentials live in the login keychain under the service `appstoreswitch.cli` as a single
JSON item per account. Nothing is written to disk in plain text, nothing is sent anywhere.

### Trigger it from a hotkey

Shortcuts.app → new shortcut → **Run Shell Script** → `/usr/local/bin/sswitch hk`
→ assign a keyboard shortcut (e.g. ⌃⌥H). Do the same for the other account.

### Exit codes

| code | meaning |
| --- | --- |
| 0 | switched |
| 2 | bad usage / unknown account |
| 3 | switch attempted but Apple rejected it, timed out, or needs a manual step |

Every run writes a line-by-line trace to `~/Library/Logs/sswitch.log`.

## Permissions

First run asks for two grants; both are one-time:

1. **Accessibility** — needed to read and drive the App Store window.
2. **Automation → System Events** — used for exactly one thing: typing the password.
   macOS enables *Secure Input* while a password field has focus, and that mode silently
   drops synthetic `CGEvent` keyboard events from any third-party process. `System Events`
   keystrokes are the only mechanism that still reaches the field. Everything else
   (menus, buttons, text fields) is driven directly through the Accessibility API.

If the grant is missing, the switch fails cleanly with `password field not found` or a
rejected sign-in; System Settings → Privacy & Security will list `sswitch` (or the app that
launched it) so you can enable it.

## Why this is more involved than it looks

Notes from building it, in case you are writing something similar:

- **The account button has no accessibility actions.** `AppStore.accountButton` reports an
  empty `AXActionNames` list, so `AXPress` does nothing. Sign-in has to go through the
  `商店` / `Store` menu; sign-out lives in the popover behind a real mouse click.
- **The sign-in sheet is nested.** `window → AXSheet → AXSheet → AXScrollArea → AXTextField`.
  Querying `text fields of sheet 1 of window 1` returns nothing — you have to walk
  `entire contents` (or the AX children tree) instead.
- **The UI language follows the store region.** After signing in to an HK account the
  whole App Store turns Traditional Chinese (`登入` / `登出`), so every label match has to
  accept Simplified, Traditional, and English, and `退出登录` must be tested before `登录`
  (it contains it).
- **Autocomplete rewrites the Apple ID.** Pasting or typing an address that resembles a
  previously used one gets silently "corrected" (`…@163.com` → `…@qq.com`), and Apple then
  answers with a useless *"unknown error"*. Writing the value through `AXValue` and reading
  it back is the reliable path.
- **Pressing Return does not always submit.** If the field is not focused, Return submits
  the stale editor contents. Click the sheet's primary button instead.
- **Secure Input**, as described above — `AXValue` writes to `AXSecureTextField` are ignored
  too, so keystrokes are the only option.

## Limitations

- Two-factor authentication still needs you: the tool leaves the sheet open and waits up to
  two minutes for the 6-digit code, then reports the outcome.
- A brand-new device may show a terms/verification page; that also needs one manual click.
- Apple throttles repeated sign-ins. Ten switches in a minute can start failing for a while.
- Only the **App Store** account is switched. Your iCloud account is untouched.

## 中文说明

macOS 的 App Store 同一时间只能登一个 Apple 账号。港区/美区账号和主账号来回切很烦，
`sswitch` 把「退出 → 重新登录 → 填账号密码」这一串动作压缩成一条命令，8 秒左右完成，
全程不弹自己的窗口，跑完把焦点还给你原来的应用。

```console
make install
sswitch add hk 你的港区账号
sswitch add cn 你的大陆账号
sswitch hk      # 切港区
sswitch cn      # 切大陆
```

首次运行需要给「辅助功能」权限（控制 App Store 窗口）和「自动化 → System Events」权限
（只用来往密码框里打字，因为 macOS 的安全输入会丢弃其它进程合成的键盘事件）。

双重认证需要你自己输 6 位验证码，窗口会留给你最多两分钟。这个工具只切 App Store 账号，
不动你的 iCloud。

## License

MIT — see [LICENSE](LICENSE).
