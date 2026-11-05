# 首次配置

这是给**已经越狱且已运行过 KOReader**的 Kindle 使用的推送工具。本文不包含越狱教程，不修改固件，不安装更新包。

## 1. 准备 Mac

安装 [Homebrew](https://brew.sh/) 后，在终端运行：

```sh
brew install python pandoc
```

Python 需要 3.10+，Pandoc 需要 3.8+；版本较旧时先 `brew upgrade python pandoc`。应用运行时会查找 `/opt/homebrew/bin` 或 `/usr/local/bin` 中的 Python 和 Pandoc，不要删除这些组件。

从 [Releases](https://github.com/joeseesun/kindle-push-macos/releases/latest) 下载 `KindlePush.dmg`，把 `乔木 Kindle 助手.app` 拖进「应用程序」。

## 2. 在应用里添加 Kindle

打开应用，点右上角的连接状态，再点「添加 Kindle」（菜单栏「Kindle › 添加 Kindle…」也可以）。窗口里有两步：

**第 1 步：用 USB 写入接收配置**

1. 在 KOReader 菜单选择「退出」，回到 Kindle 原生书库。
2. 用支持数据传输的 USB 线连接 Mac。Kindle 屏幕显示「USB 驱动器模式」后，窗口里会出现这台 Kindle。
3. 点「写入」，完成后点「推出」，再拔线。

写入时应用会：

- 在本机生成专用 ED25519 客户端密钥，已有密钥则复用。
- 备份被修改的文件到 `~/Library/Application Support/KindlePush/backups/时间戳/`。
- 写入 `koreader/settings/SSH/kindle-receive.sh` 和受限公钥。
- 配置 KOReader SSH 为 2222 端口、仅公钥认证、随 KOReader 启动。
- 保留其他阅读设置及已有 SSH 公钥。注意：原先依赖密码的 SSH 登录将因“仅公钥”设置而不能使用。

窗口没有出现 Kindle 时，确认 Kindle 已经运行过 KOReader（磁盘里有 `koreader/dropbear` 和 `koreader/settings.reader.lua`）。

**第 2 步：在 Wi-Fi 里配对**

1. Kindle 打开 KOReader，连到和 Mac 相同的可信 Wi-Fi。
2. 点「寻找新的 Kindle」。应用列出同一网络里还没配对的 Kindle，以及它的设备指纹。
3. 起个名字，点「配对」。

找不到时，在 Kindle「网络信息」里看 IPv4（例如 `192.168.1.42`），输入后点「查找」。访客网络通常会隔离设备。

这是首次信任（TOFU）：应用记住这台 Kindle 的主机身份，以后 IP 变了也能认出它，但不会自动信任别的设备。不要在不可信的局域网里配对。配对时应用先用专用公钥确认接收端能应答，成功后才保存。

## 3. 命令行配置（可选）

不想用窗口时，也可以在仓库根目录用命令行完成同样的两步：

```sh
python3 wifi-push/setup_device.py usb-install --mount /Volumes/Kindle
python3 wifi-push/setup_device.py pair-host 192.168.1.42 --name "我的 Kindle"
```

`pair-host` 会显示主机指纹并要求输入 `yes`。

## 4. 日常使用

拖入文章 → 点「发送到 Kindle」→ 等待「已发送」→ 在 Kindle `documents/我的文章` 打开。发送成功包含读回校验。

重新拖入同一文章、或右键列表项「再次发送」，可更新 Kindle 上的对应 EPUB。正文修改后可能影响旧阅读位置和批注；需要保留旧版时，先把文章另存新文件名。

## 配对更多 Kindle

一台 Mac 可以配对多台 Kindle。对每台新的 Kindle 再做一次「添加 Kindle」的两步即可，原有的配对不受影响。所有 Kindle 共用本机这一把客户端密钥，但每台的主机身份分开记录，发给一台的书不会落到另一台上。

点右上角的连接状态，能看到所有已配对的 Kindle 以及谁在线。点一台，之后的书就发给它；每行右侧的「⋯」可以改名或取消配对。启动时应用先连上次选的那台；它不在这个 Wi-Fi 里时，会改连附近另一台已配对的 Kindle，并提示你。

## 重新配对 / 换 Kindle

同一台 Kindle 换了 IP，不需要重新配对，点「重新寻找」即可。对同一台 Kindle 重跑 `pair-host` 只会更新它的地址。

Kindle 重装 KOReader 或重新越狱后，它的主机身份可能会变，应用会报「设备与已配对 Kindle 不一致」。先确认确实是自己重装了，然后在连接面板里用这台右侧的「⋯」取消配对，再按上面的步骤重新配对。不要因为报身份不一致就直接配对，应先确认是否确实更换或重装了设备。

升级同一台 Kindle 上的本应用通常不需要重新配对。不要删除或分享 `id_ed25519` 私钥。
