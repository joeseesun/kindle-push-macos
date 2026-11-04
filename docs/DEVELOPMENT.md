# 开发与打包

SwiftPM 工程位于 `mac-app/`。SwiftUI 负责窗口、文件导入和队列；Python bridge 负责转换、设备发现、SSH 传输。直接发送无需 Python 第三方依赖，Pandoc 独立安装。可选 EPUB 翻译使用隔离环境中的 `bbook_maker==1.3.2`，详见 [TRANSLATION.md](TRANSLATION.md)。

```text
mac-app/Sources/KindlePush/
  App/        生命周期与菜单
  Views/      主界面、连接区、文章行
  Stores/     队列、状态、批量发送
  Services/   本机子进程 JSON 通信
  Models/     值模型
wifi-push/
  kindle_push.py        转换与传输
  markdown_support.py   Obsidian 语法预处理
  ebook.css             墨水屏阅读样式
  app_bridge.py         JSON 接口与设备发现
  setup_device.py       首次 USB 配置及主机配对
  kindle-receive.sh      设备端受限接收协议
  test_*.py             转换、配对、发现等测试
```

## 本地开发

```sh
./script/build_and_run.sh --verify
python3 -m unittest discover -s wifi-push -p 'test_*.py' -v
```

`--build-only` 不关闭正在运行的应用；其他开发启动模式会关闭旧进程后重启。

## 发布

```sh
./script/package_release.sh
```

脚本执行 release 构建（Developer ID 签名、hardened runtime、安全时间戳，Sparkle 由内到外签名），把 `.app` 提交苹果公证并 staple，再生成：

- `release/v<版本>/KindlePush-<版本>-macos-arm64.zip`：官网从 releases/latest 取这个名字，命名不要改；
- `KindlePush-<版本>-macos-arm64.dmg` 和固定名 `KindlePush.dmg`（单独公证并 staple）；
- `appcast.xml`：Sparkle 更新源，用钥匙串里的 EdDSA 私钥（`ed25519`）签名，公钥在 `mac-app/Assets/sparkle-public-key.txt`；
- `SHA256SUMS`。

这些文件全部上传到 GitHub release；`SUFeedURL` 指向 `releases/latest/download/appcast.xml`。公证用钥匙串配置 `notary`（`xcrun notarytool store-credentials notary`）。更新说明放在 `release/notes-v<版本>.md`（`## 中文 … ## English …`，中文部分进更新窗口）。`SKIP_NOTARIZE=1` 只做本地检查。发布包不包含 Python、Pandoc、个人配对数据或文章。

版本定义在 `script/build_and_run.sh` 的 Info.plist 模板中：`CFBundleShortVersionString` 和 `CFBundleVersion`。主界面从 bundle 读取版本。

目前只提供 arm64 实测包。Intel 用户可尝试在 Intel Mac 本地构建，依赖路径已兼容 `/usr/local/bin`，但不能视为完成实机测试。

图标使用内置 imagegen 生成，原始 PNG、ICNS、提示词位于 `mac-app/Assets`。

## 已验证与未验证

- Markdown 结构、元数据、图片、提示块、嵌入笔记及失败保护由测试覆盖。
- 发现逻辑覆盖旧地址失效、陌生 SSH 服务、设备身份不一致和扫描范围上限。
- Kindle 实机验证过 SSH 连接、当前局域网发现、文件发送及 SHA-256 读回一致。
- 未逐项验证所有 Kindle 型号、Intel Mac、每一种 KOReader 样式和每种 Markdown 扩展。EPUB 的实际分页由阅读器决定。

不要把真实文章、SSH 密钥、USB 备份、生成的用户配置或带私人内容的截图加入提交。
