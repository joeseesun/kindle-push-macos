# 格式支持

KOReader 能打开的格式都支持（对照 KOReader 源码 `credocument.lua`、`pdfdocument.lua`、`djvudocument.lua`、`picdocument.lua` 的注册列表）。

| 格式 | 处理方式 |
| --- | --- |
| EPUB | 校验结构后原样发送 |
| Markdown | 转成 EPUB，见下文 |
| TXT | 转成 EPUB：自动识别 UTF-8 / GB18030 / Big5 编码，每行一段，「第一章」「序章」「Chapter 1」等行变成章节标题和目录 |
| HTML、XHTML、DOCX、ODT、RTF | Pandoc 转成带目录、阅读样式的 EPUB；原文件中 Pandoc 不支持的样式会提示但不中断 |
| PDF、XPS、DjVu | 校验文件头后原样发送 |
| CBZ、CBR、CBT 漫画 | 原样发送 |
| MOBI、AZW、AZW3、PRC、PDB、TCR | 原样发送；带 DRM 的 MOBI/AZW 会提示无法打开。AZW3 改名为 `.azw`（KOReader 按这个扩展名打开 KF8） |
| FB2、FB3、CHM、DOC、DOCM | 原样发送，由 KOReader 的 crengine 排版 |
| fb2.zip、txt.zip、html.zip、htm.zip、htmlz、rtf.zip、md.zip | 原样发送，KOReader 直接打开压缩包 |
| PNG、JPG、GIF、WEBP、TIFF | 原样发送，KOReader 可当作单页查看 |

原样发送的格式需要 v2 接收端（PDF、MOBI 等，见 README「发送 PDF、MOBI 等原生格式」）。中英对照翻译只支持 EPUB。

## Markdown → EPUB


转换引擎为 Pandoc，输出 EPUB 3。字体大小、页边距等最终仍可由 KOReader 的阅读设置覆盖。

| 内容 | v1.1.0 行为 |
| --- | --- |
| 中文段落、H1–H6 标题 | 转为可重排正文，生成 EPUB 导航目录 |
| 粗体、斜体、删除线 | 保留语义格式 |
| 有序/无序/任务列表 | 转为列表，任务状态按 EPUB 阅读器支持显示 |
| 引用、分隔线、脚注 | 保留；引用使用细边线，不依赖彩色背景 |
| 表格 | 固定表格布局、单元格换行；列很多时仍建议改成列表 |
| 行内代码、围栏代码块 | 保留内容；长行换行，关闭彩色语法高亮以适合墨水屏 |
| YAML 的 title、author、lang | 保留；缺省标题取文件名，缺省语言为 zh-CN |
| 普通 Markdown 本地图片 | 打包入 EPUB，限制显示宽度 |
| `![[图片.png]]`、`![[图片.png\|300]]` | 在文章目录/知识库中解析，统一按屏宽缩放，忽略指定像素宽度 |
| `[[笔记\|显示名称]]` | 取显示文字，不会自动生成跨书籍跳转 |
| `![[另一篇笔记]]` | 展开整篇正文，去掉其 YAML，解析其相对图片；限制 5 层并检查循环 |
| `> [!tip]` 等提示块 | 转成带标题的引用块；展开折叠提示，不保留交互状态 |
| Obsidian `%%注释%%` | 正文中的注释移除；围栏/行内代码中的内容保留 |
| 已有 EPUB | 校验结构后原样发送，不重新排版 |

## 会停止并提示的问题

- 图片或嵌入笔记缺失。
- 简写附件名称存在多个匹配，无法确定使用哪一份。
- 循环嵌入、嵌入深度超过 5 层。
- 按标题/块嵌入（`![[笔记#标题]]`、`![[笔记#^块]]`）尚未支持，请改为整篇或先复制所需段落。
- 内嵌 PDF、视频、音频等非图片附件。
- Pandoc 其他转换警告、无效 EPUB、生成文件超过 100 MB。

失败不会覆盖上一次成功生成的本机 EPUB。普通缺失图片不会被悄悄省略。

## 仍有边界

Mermaid / Dataview / DataviewJS 不执行，保留代码并显示提示。需要图表时，先在 Obsidian 导出图片再引用。

复杂公式、复杂 HTML、Obsidian 插件生成的内容、CSS snippet、跨笔记锚点不能保证和 Obsidian 一样。公式转换由 Pandoc 处理，不能转换时会报错；重要公式建议导出图片并实机检查。

远程图片可能需要网络，下载失败会停止。WEBP/SVG 等图片的显示还取决于 KOReader 版本；追求最广兼容时使用 PNG/JPEG。嵌入笔记中复杂的引用式图片语法、特殊文件名也建议先改为普通内联图片路径。

预处理器覆盖常见独立围栏代码和行内代码；深层引用/列表中的特殊 Markdown 扩展不保证完全等同于 Obsidian。文章原文始终不修改。

## 检查示例

仓库的 [排版示例](../examples/排版示例.md) 包含中文正文、提示块、列表、表格、代码、图片和脚注。可先转换、发送，再按自己的 KOReader 字体设置检查效果：

```sh
python3 wifi-push/kindle_push.py --convert-only examples/排版示例.md
```
