// 乔木 Kindle 助手官网：导航阴影、滚动显现、版本切换、弹窗，以及从 GitHub 读取最新版下载地址。
(() => {
  const nav = document.querySelector('.nav');
  const onScroll = () => nav.classList.toggle('scrolled', scrollY > 8);
  addEventListener('scroll', onScroll, { passive: true }); onScroll();

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

  // 最新版：发布包文件名带版本号，静态链接指向当前版本，这里用 GitHub API 换成最新一版。
  fetch('https://api.github.com/repos/joeseesun/kindle-push-macos/releases/latest', { headers: { Accept: 'application/vnd.github+json' } })
    .then(r => r.ok ? r.json() : Promise.reject(r.status))
    .then(rel => {
      const zip = (rel.assets || []).find(a => /macos-arm64\.zip$/.test(a.name));
      if (!zip) return;
      const v = rel.tag_name;
      document.querySelectorAll('[data-dl]').forEach(a => a.href = zip.browser_download_url);
      document.querySelectorAll('[data-ver]').forEach(s => s.textContent = v);
      document.querySelectorAll('[data-name]').forEach(s => s.textContent = zip.name);
      document.querySelectorAll('[data-size]').forEach(s => s.textContent = (zip.size / 1048576).toFixed(1) + ' MB');
      const sums = (rel.assets || []).find(a => a.name === 'SHA256SUMS');
      if (sums) document.querySelectorAll('[data-sums]').forEach(a => a.href = sums.browser_download_url);
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
