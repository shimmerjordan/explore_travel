/* =============================================================================
 *  Explore Journal — landing renderer (no framework, no build step)
 *  内容来自 config.js + i18n.js；这里只做渲染、语言切换、B 站懒加载。
 * ========================================================================== */
(function () {
  'use strict';

  var CFG = window.SITE_CONFIG || {};
  var I18N = window.I18N || {};
  var STORAGE_KEY = 'ej_lang';

  // 当前语言：localStorage → 浏览器语言 → 默认中文。
  var lang = localStorage.getItem(STORAGE_KEY);
  if (lang !== 'zh' && lang !== 'en') {
    lang = (navigator.language || 'zh').toLowerCase().indexOf('zh') === 0 ? 'zh' : 'en';
  }

  // ── tiny DOM helper ──────────────────────────────────────────────────────
  function el(tag, props, text) {
    var n = document.createElement(tag);
    if (props) {
      for (var k in props) {
        if (k === 'class') n.className = props[k];
        else if (k === 'html') n.innerHTML = props[k];
        else n.setAttribute(k, props[k]);
      }
    }
    if (text != null) n.appendChild(document.createTextNode(text));
    return n;
  }
  function $(id) { return document.getElementById(id); }
  function setText(id, v) { var n = $(id); if (n) n.textContent = v; }
  function setHref(id, v) { var n = $(id); if (n && v) n.setAttribute('href', v); }
  function pick(v) { return lang === 'zh' ? v.titleZh || v.captionZh : v.titleEn || v.captionEn; }

  // ── brand color injection ─────────────────────────────────────────────────
  if (CFG.brandColor) {
    document.documentElement.style.setProperty('--brand', CFG.brandColor);
  }
  if (CFG.logo) {
    var logos = document.querySelectorAll('.nav__logo, .footer__logo');
    for (var i = 0; i < logos.length; i++) logos[i].setAttribute('src', CFG.logo);
  }

  // ── hero background image (optional) ────────────────────────────────────────
  function applyHeroBg() {
    var bg = $('heroBg');
    if (!bg) return;
    if (CFG.heroImage) {
      bg.style.backgroundImage = 'url("' + CFG.heroImage + '")';
      bg.classList.add('hero__bg--img');
    }
  }

  // ── links ───────────────────────────────────────────────────────────────
  function applyLinks() {
    setHref('navGithub', CFG.repoUrl);
    setHref('heroApp', CFG.appUrl);
    setHref('heroSecondary', CFG.repoUrl);
    setHref('heroPrimary', CFG.releasesUrl);
    setHref('dlReleases', CFG.releasesUrl);
    setHref('footRepo', CFG.repoUrl);
  }

  // ── render: static copy ───────────────────────────────────────────────────
  function renderCopy(t) {
    document.documentElement.setAttribute('lang', lang);

    // nav
    var navLinks = document.querySelectorAll('.nav__links a[data-nav]');
    for (var i = 0; i < navLinks.length; i++) {
      var key = navLinks[i].getAttribute('data-nav');
      navLinks[i].textContent = t.nav[key] || key;
    }

    // hero
    setText('heroBadge', t.hero.badge);
    setText('heroTitle', t.hero.title);
    setText('heroSubtitle', t.hero.subtitle);
    setText('heroDesc', t.hero.desc);
    setText('heroApp', t.hero.ctaApp);
    setText('heroPrimary', t.hero.ctaPrimary);
    setText('heroSecondary', t.hero.ctaSecondary);
    setText('heroVideo', t.hero.ctaVideo);

    // section heads
    var titles = document.querySelectorAll('[data-title]');
    for (var j = 0; j < titles.length; j++) {
      var tk = titles[j].getAttribute('data-title');
      titles[j].textContent = t.sectionTitles[tk] || '';
    }
    var subs = document.querySelectorAll('[data-sub]');
    for (var s = 0; s < subs.length; s++) {
      var sk = subs[s].getAttribute('data-sub');
      subs[s].textContent = t.sectionTitles[sk + 'Sub'] || '';
    }

    // download
    setText('dlAndroid', t.download.android);
    setText('dlAndroidNote', t.download.androidNote);
    setText('dlIos', t.download.ios);
    setText('dlIosNote', t.download.iosNote);
    setText('dlReleases', t.download.releasesBtn);
    setText('dlTip', t.download.tip);
    var iosIcon = document.querySelectorAll('.dl__card .dl__icon')[1];
    if (iosIcon) iosIcon.textContent = '';

    // footer
    setText('footTagline', t.footer.tagline);
    setText('footMadeWith', t.footer.madeWith);
    setText('footLicense', t.footer.license);
    setText('footInspired', t.footer.inspired);

    // lang toggle shows the language you switch TO
    var other = lang === 'zh' ? 'en' : 'zh';
    setText('langToggle', I18N[other].langName);
  }

  // ── render: feature cards ───────────────────────────────────────────────────
  function renderFeatures(t) {
    var grid = $('featureGrid');
    if (!grid) return;
    grid.innerHTML = '';
    (t.features || []).forEach(function (f) {
      var card = el('div', { class: 'card' });
      card.appendChild(el('div', { class: 'card__icon' }, f.icon));
      card.appendChild(el('h3', { class: 'card__title' }, f.title));
      card.appendChild(el('p', { class: 'card__desc' }, f.desc));
      grid.appendChild(card);
    });
  }

  // ── render: compare ──────────────────────────────────────────────────────
  function renderCompare(t) {
    var grid = $('compareGrid');
    if (!grid) return;
    grid.innerHTML = '';
    (t.compare || []).forEach(function (c) {
      var item = el('div', { class: 'compare__item' });
      item.appendChild(el('h3', { class: 'compare__title' }, c.title));
      item.appendChild(el('p', { class: 'compare__desc' }, c.desc));
      grid.appendChild(item);
    });
  }

  // ── render: Bilibili videos (click-to-load) ─────────────────────────────────
  function biliSrc(bvid, page, autoplay) {
    return 'https://player.bilibili.com/player.html'
      + '?bvid=' + encodeURIComponent(bvid)
      + '&page=' + (page || 1)
      + '&autoplay=' + (autoplay ? 1 : 0)
      + '&high_quality=1&danmaku=0';
  }
  function renderVideos(t) {
    var grid = $('videoGrid');
    if (!grid) return;
    grid.innerHTML = '';
    var vids = CFG.videos || [];
    if (!vids.length) {
      grid.appendChild(el('p', { class: 'section__sub' }, '—'));
      return;
    }
    vids.forEach(function (v) {
      var card = el('div', { class: 'video' });
      var frame = el('div', { class: 'video__frame' });

      var poster = el('div', { class: 'video__poster video__poster--placeholder' });
      if (v.poster) {
        poster.style.backgroundImage = 'url("' + v.poster + '")';
        poster.classList.remove('video__poster--placeholder');
      }
      poster.appendChild(el('div', { class: 'video__playbtn' }));
      poster.appendChild(el('div', { class: 'video__playlabel' }, t.videoPlay));
      frame.appendChild(poster);

      frame.addEventListener('click', function () {
        var ifr = document.createElement('iframe');
        ifr.src = biliSrc(v.bvid, v.page, true);
        ifr.setAttribute('allowfullscreen', 'true');
        ifr.setAttribute('scrolling', 'no');
        ifr.setAttribute('frameborder', 'no');
        ifr.setAttribute('allow', 'autoplay; fullscreen; encrypted-media; picture-in-picture');
        ifr.title = pick(v) || 'Bilibili';
        frame.innerHTML = '';
        frame.appendChild(ifr);
      });

      var meta = el('div', { class: 'video__meta' });
      meta.appendChild(el('span', { class: 'video__title' }, pick(v) || ''));
      meta.appendChild(el('span', { class: 'video__from' }, t.videoFrom));

      card.appendChild(frame);
      card.appendChild(meta);
      grid.appendChild(card);
    });
  }

  // ── render: screenshots (graceful placeholder on missing image) ─────────────
  function renderShots(t) {
    var grid = $('shotGrid');
    if (!grid) return;
    grid.innerHTML = '';
    (CFG.screenshots || []).forEach(function (sh) {
      var card = el('div', { class: 'shot' });
      var img = new Image();
      img.className = 'shot__img';
      img.alt = pick(sh) || '';
      img.loading = 'lazy';
      img.onerror = function () {
        var ph = el('div', { class: 'shot__img shot__img--ph' }, t.shotPlaceholder);
        if (img.parentNode) img.parentNode.replaceChild(ph, img);
      };
      img.src = sh.src;
      card.appendChild(img);
      card.appendChild(el('div', { class: 'shot__cap' }, pick(sh) || ''));
      grid.appendChild(card);
    });
  }

  // ── render everything for the current language ──────────────────────────────
  function render() {
    var t = I18N[lang];
    renderCopy(t);
    renderFeatures(t);
    renderCompare(t);
    renderVideos(t);
    renderShots(t);
  }

  // ── language toggle ────────────────────────────────────────────────────────
  function bindToggle() {
    var btn = $('langToggle');
    if (!btn) return;
    btn.addEventListener('click', function () {
      lang = lang === 'zh' ? 'en' : 'zh';
      localStorage.setItem(STORAGE_KEY, lang);
      render();
    });
  }

  // ── boot ───────────────────────────────────────────────────────────────────
  applyHeroBg();
  applyLinks();
  render();
  bindToggle();
})();
