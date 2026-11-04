## 中文

翻译更快、更准：

- **长章节拆段并行**：整本翻译前，把长章节切成几段，和其他章一起并行翻译，译完拼回原章。整本书不再被最长的一章拖住。
- **同时翻译 1–64 路**：在设置里自由填写，默认 16 路。服务商额度高可以调大，频繁限流就调低。
- **自动统一人名**：开译前先整理全书的人名、地名和机构名，定好译名，并标出人物性别，各章译名一致，「他」「她」不再混淆。实测人名一致率从 76% 提高到 95%。你自己的术语表优先。
- **更好的默认译文要求**：自然地道、避免翻译腔；完整翻译、不概括、不纠错、不删改；每次请求都注明书名和作者。
- **不再无故停顿**：服务偶尔不回应时，最多等 60–150 秒就重试（原来 300 秒）。
- **中文标点**：译完自动把中文里的半角标点换成全角，直引号换成“”。
- 小模型每批最多 10 段，减少批次出错后的重译；随机度调低，译文更稳定。

## English

Faster, more consistent translation:

- Long chapters are cut into parts, translated in parallel with the rest, and joined back, so a book no longer waits on its longest chapter.
- Parallel requests: any number from 1 to 64 (default 16).
- A book-wide glossary of names (with gender notes) is built before translating, so every chapter uses the same names. Your own glossary wins.
- A stuck request is retried after 60–150 s instead of 300 s.
- Stronger default instructions (complete, faithful, no translationese), Chinese punctuation clean-up, smaller batches for small models and a lower temperature.
