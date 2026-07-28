# Explore Journal — 宣传网站 / Landing site

纯静态网站（HTML/CSS/JS，无构建步骤）。受 [fogofworld.app](https://fogofworld.app/) 启发，
双语（中文 / English，右上角切换），图片与 Bilibili 视频全部通过 **`config.js`** 配置。

A zero-build static site. Bilingual with a language toggle. All images and
Bilibili videos are configured in **`config.js`** — no code edits needed.

## 目录 / Files

| 文件 | 作用 |
|------|------|
| `index.html` | 页面骨架（容器，由 JS 填充） |
| `config.js`  | **你主要改这个**：图片路径、B 站 BV 号、GitHub/下载链接、主色 |
| `i18n.js`    | 全部中英文文案 + 功能列表 |
| `styles.css` | 样式（主色见 `:root --brand`） |
| `app.js`     | 渲染、语言切换、B 站懒加载（无框架） |
| `assets/`    | 图片：logo、favicon、hero、截图、视频封面 |

## 改图片 / Change images

1. 把图片放进 `assets/`（建议截图用 9:16 竖屏，约 1080×1920）。
2. 在 `config.js` 里填路径：
   - `heroImage` — 首屏主视觉（留空 = 用内置渐变）。
   - `screenshots[]` — 截图画廊，每项 `{ src, captionZh, captionEn }`。
   - 缺图不会让页面塌掉，会显示占位卡片。

## 加 B 站视频 / Add a Bilibili video

只需 BV 号（视频链接 `…/video/BVxxxxxx` 里那段）：

```js
videos: [
  { bvid: 'BV1xxxxxxxxx', titleZh: '功能演示', titleEn: 'Demo', poster: '' },
],
```

- `poster` 可选：填了用自定义封面；不填显示占位封面。
- 点击封面才加载 B 站 `<iframe>`（更快、更省流）。
- `page` 可选：多 P 视频指定分 P。

## 本地预览 / Local preview

任意静态服务器即可（不要直接 `file://` 打开，B 站 iframe 需要 http(s)）：

```bash
cd website
python3 -m http.server 48082
# 打开 http://localhost:48082
```

## 部署 / Deploy

任意静态托管。**GitHub Pages** 示例：

- 把 `website/` 内容推到 `gh-pages` 分支根目录，或在仓库设置里把 Pages 源指向 `/website`。
- 或用 Cloudflare Pages / Vercel / Netlify：构建命令留空，输出目录设为 `website`。

> 注意：本目录是**宣传网站**，与 Flutter 的 `web/`（App 的 Web 构建产物）无关，互不影响。
