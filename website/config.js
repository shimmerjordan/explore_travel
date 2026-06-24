/* =============================================================================
 *  Explore Journal — 宣传站点配置 / Landing-site configuration
 *  -----------------------------------------------------------------------------
 *  这是你唯一需要改动的文件（再加上往 assets/ 放图片）。
 *  This is the ONLY file you normally edit (plus dropping images into assets/).
 *
 *  改图片：把图片放进 website/assets/，然后在下面填路径。
 *  改视频：把 B 站视频的 BV 号填进 videos 数组即可内置播放。
 * ========================================================================== */
window.SITE_CONFIG = {
  // ── 链接 / Links ────────────────────────────────────────────────────────
  repoUrl: 'https://github.com/shimmerjordan/explore_travel',
  releasesUrl: 'https://github.com/shimmerjordan/explore_travel/releases/latest',

  // ── 品牌 / Brand ─────────────────────────────────────────────────────────
  brandColor: '#26A69A',   // 主色（也可在 styles.css 的 :root 改）
  logo: 'assets/logo.png', // 站点左上角 logo（已放了一份 App 图标）

  // ── Hero 主视觉图 / Hero image ────────────────────────────────────────────
  // 留空字符串 = 用内置的渐变 + 地球占位图。
  // 填路径（如 'assets/hero.png'）= 用你的真机截图 / 宣传图。
  heroImage: '',

  // ── B 站视频 / Bilibili videos ────────────────────────────────────────────
  // 只需填 bvid（B 站地址里 /video/BVxxxxx 的那一段）。可放多个。
  //   poster 可选：填了用你的自定义封面图；不填则显示占位封面，
  //   点击后才真正加载 B 站播放器（更快、更省流、保护隐私）。
  //   page 可选：多 P 视频指定分 P，默认 1。
  videos: [
    {
      bvid: 'BV1GJ411x7h7',           // ← 换成你的演示视频 BV 号
      titleZh: '功能演示',
      titleEn: 'Feature walkthrough',
      poster: '',                      // e.g. 'assets/video-cover.png'
      page: 1,
    },
    // { bvid: 'BVxxxxxxxxxx', titleZh: '导入 Fog of World', titleEn: 'Importing Fog of World', poster: '' },
  ],

  // ── 截图画廊 / Screenshot gallery ─────────────────────────────────────────
  // 把截图放进 assets/ 再在这里列出。任何一项缺图都会显示占位卡片，
  // 不会让页面塌掉，方便你先上线骨架、之后再补图。
  screenshots: [
    { src: 'assets/shot-map.png',    captionZh: '迷雾地图：走到哪点亮哪',     captionEn: 'Fog-of-war map' },
    { src: 'assets/shot-globe.png',  captionZh: '3D 地球 · 足迹热力',         captionEn: '3D globe with footprint heat-map' },
    { src: 'assets/shot-journal.png',captionZh: '富文本旅行日志',             captionEn: 'Rich travel journal' },
    { src: 'assets/shot-ai.png',     captionZh: 'AI 行程规划',                captionEn: 'AI trip planning' },
    { src: 'assets/shot-explore.png',captionZh: '探索进度 · 真实面积统计',     captionEn: 'Exploration progress' },
    { src: 'assets/shot-group.png',  captionZh: '好友实时位置 / 语音',        captionEn: 'Live group sharing' },
  ],
};
