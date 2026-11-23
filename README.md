# DYYYAlbum

给 DYYY（抖音 Tweak）的下载流程加一个「保存到相簿」选择弹窗的伴随 dylib。

- 点长按面板里的下载（视频 / 图片 / 实况 / 封面 / 评论图片等）时先弹出相簿选择
- 选择后会记住上次用的相簿（带 ✓ 标记）
- 支持「新建相簿…」
- 下载保存时自动把资产加进所选相簿（同时仍会出现在「最近项目」）
- 不修改 DYYY 本体，独立 dylib，用 TrollFools 之类工具和 DYYY 一起注入抖音即可

## 构建

GitHub Actions 自动构建，产物在 Artifacts 里的 `DYYYAlbum-dylib`。
