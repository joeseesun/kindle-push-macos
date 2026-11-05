// 乔木 Kindle 助手官网：导航阴影、滚动显现、版本切换、弹窗，以及从 GitHub 读取最新版下载地址。
(() => {
  const nav = document.querySelector('.nav');
  const onScroll = () => nav.classList.toggle('scrolled', scrollY > 8);
  addEventListener('scroll', onScroll, { passive: true }); onScroll();

  // 「交给 Agent」的复制按钮：复制提示词原文，按钮上说一声已复制。
  document.querySelectorAll('[data-copy]').forEach(btn => btn.addEventListener('click', async () => {
    const text = document.getElementById(btn.dataset.copy)?.textContent || '';
    try { await navigator.clipboard.writeText(text); } catch {
      const area = Object.assign(document.createElement('textarea'), { value: text });
      document.body.append(area); area.select(); document.execCommand('copy'); area.remove();
    }
    const label = btn.textContent; btn.textContent = '已复制';
    setTimeout(() => btn.textContent = label, 1600);
  }));

  // 滚动显现
  const els = document.querySelectorAll('.section .wrap > *, .hero-shot');
  if ('IntersectionObserver' in window && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
    const io = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } }), { rootMargin: '0px 0px -8% 0px' });
    els.forEach(el => { el.classList.add('reveal'); io.observe(el); });
  }

  // 原文 / 中英对照 / 仅中文
  const page = document.querySelector('.bi-page');
  document.querySelectorAll('.ver button').forEach(b => b.addEventListener('click', () => {
    document.querySelectorAll('.ver button').forEach(x => x.setAttribute('aria-selected', String(x === b)));
    page.dataset.mode = b.dataset.v;
  }));

  // 弹窗
  document.querySelectorAll('[data-modal]').forEach(b => b.addEventListener('click', () => document.getElementById(b.dataset.modal).showModal()));
  document.querySelectorAll('dialog').forEach(d => {
    d.querySelector('[data-close]').addEventListener('click', () => d.close());
    d.addEventListener('click', e => { if (e.target === d) d.close(); });
  });

  // 下载按钮固定指向 releases/latest/download/KindlePush.dmg（发版脚本每次都上传这个固定文件名），
  // 这里不改链接，只补上最新版本号、DMG 大小和 zip 版地址。
  fetch('https://api.github.com/repos/joeseesun/kindle-push-macos/releases/latest', { headers: { Accept: 'application/vnd.github+json' } })
    .then(r => r.ok ? r.json() : Promise.reject(r.status))
    .then(rel => {
      const assets = rel.assets || [];
      const dmg = assets.find(a => a.name === 'KindlePush.dmg');
      const zip = assets.find(a => /macos-arm64\.zip$/.test(a.name));
      document.querySelectorAll('[data-ver]').forEach(s => s.textContent = rel.tag_name);
      if (dmg) document.querySelectorAll('[data-size]').forEach(s => s.textContent = (dmg.size / 1048576).toFixed(1) + ' MB');
      if (zip) document.querySelectorAll('[data-zip]').forEach(a => a.href = zip.browser_download_url);
      // 首屏「新增」取发版说明「## 中文」下第一条的加粗标题，发版说明怎么写，这里就怎么显示。
      const zh = (rel.body || '').split(/^## English/m)[0];
      const head = (zh.match(/^- \*\*(.+?)\*\*/m) || [])[1];
      if (head) document.querySelectorAll('[data-news]').forEach(s => s.textContent = rel.tag_name.replace(/^v/, '') + ' 新增：' + head.replace(/[：:]$/, ''));
    })
    .catch(() => {});

  // 乔木 SimpleUI 只发测试版（pre-release），/releases/latest 取不到，改读列表里最新的非草稿版本。
  fetch('https://api.github.com/repos/joeseesun/qiaomu-simpleui/releases?per_page=5', { headers: { Accept: 'application/vnd.github+json' } })
    .then(r => r.ok ? r.json() : Promise.reject(r.status))
    .then(list => {
      const rel = list.find(r => !r.draft && (r.assets || []).some(a => a.name === 'simpleui.koplugin.zip'));
      if (!rel) return;
      const zip = rel.assets.find(a => a.name === 'simpleui.koplugin.zip');
      document.querySelectorAll('[data-sui-dl]').forEach(a => a.href = zip.browser_download_url);
      document.querySelectorAll('[data-sui-ver]').forEach(s => s.textContent = rel.tag_name);
    })
    .catch(() => {});
})();
