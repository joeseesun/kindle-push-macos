# 首次配置

这是给**已经越狱且已运行过 KOReader**的 Kindle 使用的推送工具。本文不包含越狱教程，不修改固件，不安装更新包。

## 1. 准备 Mac

安装 [Homebrew](https://brew.sh/) 后，在终端运行：

```sh
brew install python pandoc
git clone https://github.com/chasepal/kindle-push-macos.git
cd kindle-push-macos
```

也可以下载仓库源代码 ZIP，解压后在终端进入该目录。下面的命令都在仓库根目录运行。Python 需要 3.10+，Pandoc 需要 3.8+；版本较旧时先 `brew upgrade python pandoc`。

从 Releases 下载应用 ZIP，解压并把 `乔木 Kindle 助手.app` 放入 `/Applications`。应用运行时会查找 `/opt/homebrew/bin` 或 `/usr/local/bin` 中的 Python 和 Pandoc；不要删除这些组件。

## 2. 用 USB 安装接收配置

1. 在 KOReader 菜单选择「退出」，回到 Kindle 原生书库。
2. 使用支持数据传输的 USB 线连接 Mac。Kindle 屏幕应显示「USB 驱动器模式」。
3. 在 Finder 确认 Kindle 磁盘出现，然后执行：

```sh
python3 wifi-push/setup_device.py usb-install --mount /Volumes/Kindle
```

如果磁盘名不同，把 `/Volumes/Kindle` 改成实际挂载路径。脚本先检查 `documents`、`koreader/dropbear` 和 `koreader/settings.reader.lua`，不符合就停止。

脚本会：

- 在本机生成专用 ED25519 客户端密钥，已有密钥则复用。
- 备份被修改的文件到 `~/Library/Application Support/KindlePush/backups/时间戳/`。
- 写入 `koreader/settings/SSH/kindle-receive.sh` 和受限公钥。
- 配置 KOReader SSH 为 2222 端口、仅公钥认证、随 KOReader 启动。
- 保留其他阅读设置及已有 SSH 公钥。注意：原先依赖密码的 SSH 登录将因“仅公钥”设置而不能使用。

脚本不会弹出磁盘。请在 Finder 手动安全弹出 Kindle，再拔线。

## 3. 配对 Kindle 的设备身份

1. Mac 与 Kindle 连同一个可信 Wi-Fi。
2. Kindle 打开 KOReader，确认「工具/齿轮 → 网络 → SSH 服务器」已启动。
3. 在 Kindle「网络信息」找到 IPv4，例如 `192.168.1.42`。
4. 在 Mac 运行，替换成你自己的地址：

```sh
python3 wifi-push/setup_device.py pair-host 192.168.1.42
```

首次会显示主机指纹并要求输入 `yes`。请确认 IP 与 Kindle 屏幕显示一致，再确认。这是首次信任（TOFU），不应在不可信局域网盲目配对。脚本随后使用专用公钥验证接收服务，成功后才保存 IP。

后续会固定此 ED25519 主机身份，IP 改变不会自动信任另一台设备。配对成功后即可打开应用。

## 4. 日常使用

拖入文章 → 点「发送到 Kindle」→ 等待「已发送」→ 在 Kindle `documents/我的文章` 打开。发送成功包含读回校验。

重新拖入同一文章、或右键列表项「再次发送」，可更新 Kindle 上的对应 EPUB。正文修改后可能影响旧阅读位置和批注；需要保留旧版时，先把文章另存新文件名。

## 重新配对 / 换 Kindle

应用 v1.1.0 只管理一台 Kindle。先保留本机 `KindlePush` 配置备份，再退出应用，将 `known_hosts` 和 `config.json` 移到备份目录；对新设备重新执行 USB 安装与 `pair-host`。不要因为报身份不一致就直接删除记录，应先确认是否确实更换/重装了设备。

升级同一台 Kindle 上的本应用通常不需要重新配对。不要删除或分享 `id_ed25519` 私钥。
