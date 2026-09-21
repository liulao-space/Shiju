/* 真实布局探针：在真的 WebKit 里量几何，而不是在 jsdom 里读 CSS 规则。
 *
 * 为什么需要它：panel-contract-test.cjs 跑在 jsdom 里，读得到 computed style，
 * **读不到布局**——clientWidth 恒为 0，元素落在哪、有没有换行、居中没有，一概测不出。
 * 第 5 轮那几条需求（列数跟随 / 标签不换行 / 空状态居中 / 弹层贴锚点）全是布局问题，
 * 契约测试只能保证「规则写对了」，这里保证「画出来是对的」。
 *
 * 返回值是一段 JSON（截图工具 --probe 会把它打到 stdout），
 * 由 Scripts/test-layout.sh 汇总判定。
 *
 * 断言的写法上尽量贴着「需求」而不是「实现」：
 * 比如列数那条断言的是「每列不窄于 268，且再加一列就低于 268」，
 * 而不是「colCount 返回 4」——公式以后换成别的写法，这条仍然该成立。
 */
(() => {
  const out = [];
  const $ = s => document.querySelector(s);
  const $$ = s => Array.from(document.querySelectorAll(s));
  const R = el => el.getBoundingClientRect();
  const T = (n, ok, d) => out.push({ n, ok: !!ok, d: d == null ? '' : String(d) });
  const f = v => (Math.round(v * 10) / 10).toString();

  const MIN_COL_W = 268;   // 每列的最小宽度（需求），不是实现里的那个常量
  const GAP = 12;          // 列间距，与 CSS 的 --gap-grid 同源
  const EDGE = 12;         // 弹层距窗口边缘的最小留白

  window.SNAP.reset();

  /* ---------- 1. 空状态：文案要落在「筛选栏底 → 窗口底」这段的正中 ---------- */
  Shiju.hydrate([]);
  const content = $('.content'), empty = $('#grid .empty');
  if (!empty) {
    T('空状态：渲染出了空态文案', false, '找不到 #grid .empty');
  } else {
    const cr = R(content), er = R(empty);
    const regionMidY = (cr.top + cr.bottom) / 2;
    const regionMidX = (cr.left + cr.right) / 2;
    const blockMidY = (er.top + er.bottom) / 2;
    const blockMidX = (er.left + er.right) / 2;
    T('空状态：垂直居中', Math.abs(blockMidY - regionMidY) <= 2,
      `文案中心 ${f(blockMidY)} / 区域中心 ${f(regionMidY)}（差 ${f(blockMidY - regionMidY)}px）`);
    T('空状态：水平居中', Math.abs(blockMidX - regionMidX) <= 2,
      `文案中心 ${f(blockMidX)} / 区域中心 ${f(regionMidX)}（差 ${f(blockMidX - regionMidX)}px）`);
    // 撑高撑过头会顶出一条滚动条——居中对了但多出个滚动条同样是 bug
    T('空状态：没撑出滚动条', content.scrollHeight <= content.clientHeight + 1,
      `scrollHeight ${content.scrollHeight} vs clientHeight ${content.clientHeight}`);
  }

  /* ---------- 2. 列数：每列不窄于最小值，且已经取到最多 ---------- */
  Shiju.hydrate(window.SNAP.tagsRows);
  const cols = $$('#grid .col');
  const n = cols.length;
  const gridW = R($('#grid')).width;
  T('列数：至少一列', n >= 1, `实际 ${n} 列`);
  if (n >= 1) {
    const widths = cols.map(c => R(c).width);
    const minW = Math.min(...widths), maxW = Math.max(...widths);
    T('列数：每列不窄于最小宽度', minW >= MIN_COL_W - 1,
      `最窄 ${f(minW)}px（下限 ${MIN_COL_W}）`);
    T('列数：各列等宽', maxW - minW <= 1, `最窄 ${f(minW)} / 最宽 ${f(maxW)}`);
    // 「取到最多」的定义：再多塞一列就低于下限了
    const nextW = (gridW - n * GAP) / (n + 1);
    T('列数：已经取到最多', nextW < MIN_COL_W,
      `再加一列只剩 ${f(nextW)}px，低于 ${MIN_COL_W}px 所以不该加`);
  }

  /* ---------- 3. 底栏：标签与按钮必须同一行，按钮不许被挤 ---------- */
  const cards = $$('#grid .card');
  T('底栏：渲染出了卡片', cards.length > 0, `${cards.length} 张`);
  const offRow = [], tooTall = [], squeezed = [], overflow = [];
  cards.forEach((c, i) => {
    const foot = c.querySelector('.card__foot');
    if (!foot) return;
    const fr = R(foot);
    const kids = Array.from(foot.children)
      .filter(k => { const r = R(k); return r.width > 0 && r.height > 0; });   // 空标签组是 display:none

    /* 「同一行」不能拿 top 相等、也不能拿跟底栏中心对齐来判：
       底栏是 align-items:flex-end，标签(16px)和按钮(22px)底边对齐、高度不同，
       中心和 top 本来就差几像素——那是正常错位。
       真正该成立的是「所有子元素的垂直区间有公共重叠」：一旦换行，
       第二行会整个落到第一行下方，重叠就没了。 */
    if (kids.length > 1) {
      const maxTop = Math.max(...kids.map(k => R(k).top));
      const minBottom = Math.min(...kids.map(k => R(k).bottom));
      if (!(maxTop < minBottom)) {
        offRow.push(`#${i} ` + kids.map(k => `${k.className}[${f(R(k).top)}..${f(R(k).bottom)}]`).join(' '));
      }
    }

    // 另一条独立的判据：底栏高度只该有一行那么高
    const tallest = Math.max(...kids.map(k => R(k).height), 0);
    if (fr.height > tallest * 1.6 + 2) tooTall.push(`#${i} 高 ${f(fr.height)}px / 单行 ${f(tallest)}px`);

    const acts = c.querySelector('.acts');
    if (acts) {
      const ar = R(acts), cr = R(c);
      if (ar.width < 40) squeezed.push(`#${i} 宽 ${f(ar.width)}px`);
      if (ar.right > cr.right + 1) overflow.push(`#${i} 溢出 ${f(ar.right - cr.right)}px`);
    }
  });
  T('底栏：标签与按钮在同一行（垂直区间有重叠）', offRow.length === 0, offRow.join(' | '));
  T('底栏：高度只有一行', tooTall.length === 0, tooTall.join(' | '));
  T('底栏：按钮没被压没', squeezed.length === 0, squeezed.join(' | '));
  T('底栏：按钮没溢出卡片', overflow.length === 0, overflow.join(' | '));

  // 多标签的卡片必须出现 +N，否则说明「限数」根本没生效
  T('底栏：多标签会收成 +N', $$('#grid .tagmore').length > 0,
    `找到 ${$$('#grid .tagmore').length} 个 +N`);
  // 单个超长标签要被省略号截断，而不是把底栏撑开
  const longTag = $$('#grid .tag').find(t => R(t).width >= 0 && t.scrollWidth > t.clientWidth + 1);
  T('底栏：超长标签被截断', !!longTag,
    longTag ? `「${longTag.textContent}」${f(R(longTag).width)}px` : '没有任何标签被截断');

  /* ---------- 4. 弹层：贴在锚点下方，且不越出窗口 ---------- */
  const anchorCheck = (btnSel, popSel, label) => {
    const btn = $(btnSel), pop = $(popSel);
    if (!btn || !pop) { T(`${label}：元素存在`, false, `${btnSel} / ${popSel}`); return; }
    btn.click();
    const br = R(btn), pr = R(pop);
    const open = pop.hasAttribute('open');
    T(`${label}：点开后确实展开`, open, `open=${open}`);
    if (!open) return;
    T(`${label}：落在按钮下方`, pr.top >= br.bottom - 0.5,
      `弹层 top ${f(pr.top)} / 按钮 bottom ${f(br.bottom)}`);
    T(`${label}：左沿不晚于锚点左沿`, pr.left <= br.left + 0.5,
      `弹层 left ${f(pr.left)} / 按钮 left ${f(br.left)}`);
    T(`${label}：不越出窗口`,
      pr.left >= EDGE - 0.5 && pr.right <= window.innerWidth - EDGE + 0.5,
      `left ${f(pr.left)} right ${f(pr.right)} 视口宽 ${window.innerWidth}`);
    btn.click();   // 关掉，别影响后面的检查
  };
  anchorCheck('#themeBtn', '#themePop', '主题弹层');
  anchorCheck('#tagBtn', '#tagPop', '标签弹层');

  T('主题弹层：底部说明文案已去掉', !$('#themePop .popover__foot'),
    $('#themePop .popover__foot') ? '还留着 .popover__foot' : '');

  /* ---------- 5. 标签入口：有标签才出现 ---------- */
  Shiju.hydrate(window.SNAP.tagsRows);
  const tb = $('#tagBtn');
  T('标签入口：有标签时可见', !!tb && !tb.hidden, tb ? `hidden=${tb.hidden}` : '找不到 #tagBtn');

  Shiju.hydrate([{ id:'x', text:'一条没有标签的记录。', app:'Notes', kind:'note', at:'刚刚', ts:0 }]);
  const tb2 = $('#tagBtn');
  T('标签入口：一条标签都没有时藏起来', !!tb2 && tb2.hidden,
    tb2 ? `hidden=${tb2.hidden}` : '找不到 #tagBtn');
  T('标签入口：藏起来时真的不占位（.chip[hidden] 规则在）',
    !tb2 || R(tb2).width === 0, tb2 ? `宽 ${f(R(tb2).width)}px` : '');

  /* ---------- 6. 顶栏：多了一个齿轮之后不能把别的东西挤坏 ---------- */
  // 「入口存在」由 jsdom 那条锁了；这里管的是「加上它之后顶栏还站得住吗」——
  // 760px 那种窄面板下，搜索框会不会被压到没法用、按钮会不会溢出窗口。
  Shiju.hydrate(window.SNAP.tagsRows);
  const gear = $('#settingsBtn');
  const themeBtn = $('#themeBtn');
  const searchBox = $('.search');

  if (!gear || !themeBtn) {
    T('顶栏：设置入口与主题按钮都在', false,
      `gear=${!!gear} theme=${!!themeBtn}`);
  } else {
    const gr = R(gear), tr = R(themeBtn);
    T('顶栏：设置入口点得到（有面积）', gr.width > 0 && gr.height > 0,
      `${f(gr.width)}×${f(gr.height)}`);
    T('顶栏：设置入口是方的（宽高一致，一排按钮的基线才不会歪）',
      Math.abs(gr.width - gr.height) <= 1, `${f(gr.width)}×${f(gr.height)}`);
    T('顶栏：设置入口在主题按钮左边', gr.right <= tr.left + 0.5,
      `齿轮 right ${f(gr.right)} / 主题 left ${f(tr.left)}`);
    T('顶栏：两者在同一行（垂直区间有重叠）',
      Math.max(gr.top, tr.top) < Math.min(gr.bottom, tr.bottom),
      `齿轮 ${f(gr.top)}–${f(gr.bottom)} / 主题 ${f(tr.top)}–${f(tr.bottom)}`);
  }

  if (searchBox) {
    // 下限取 90（CSS 给的 min-width 是 96）。最窄窗口下搜索框会缩到 96px——
    // 那是刻意的，它让位给按钮。这条只防「被压到完全没法输入」。
    T('顶栏：搜索框还有可用宽度', R(searchBox).width >= 90,
      `宽 ${f(R(searchBox).width)}px`);
  }

  // 空间不够时该压搜索框，不该压按钮。
  // **这条只在最窄那档（520px，窗口 minSize）会红**：不修的话搜索框顶着
  // 199px 不让缩，压力全给按钮——实测「＋ 记录」只剩 55px，文字被裁掉。
  // 不能用 `scrollWidth > clientWidth` 判「文字被裁」：按钮是 flex 容器、
  // `overflow: visible`，被压时文字是**换行**而不是溢出，那个指标照样说 ok。
  // 直接量「固有宽度」（克隆一份、脱离 flex 后按 max-content 排版）才准。
  const naturalWidth = el => {
    const c = el.cloneNode(true);
    c.style.cssText = 'position:absolute; left:-9999px; top:0; width:max-content;';
    document.body.appendChild(c);
    const w = c.getBoundingClientRect().width;
    c.remove();
    return w;
  };
  const crushed = $$('.topbar > button')
    .filter(b => R(b).width < naturalWidth(b) - 1)
    .map(b => `${b.id}(${f(R(b).width)}px < 需要的 ${f(naturalWidth(b))}px)`);
  T('顶栏：按钮没被压得比内容还窄（让位的是搜索框）', crushed.length === 0,
    crushed.length ? crushed.join(' | ') : `视口宽 ${window.innerWidth}`);

  const spill = $$('.topbar > *').filter(el => {
    const r = R(el);
    return r.width > 0 && (r.right > window.innerWidth + 0.5 || r.left < -0.5);
  }).map(el => `${el.id || el.className}(${f(R(el).left)}→${f(R(el).right)})`);
  T('顶栏：没有元素溢出窗口', spill.length === 0,
    spill.length ? spill.join(' | ') : `视口宽 ${window.innerWidth}`);

  /* ---------- 7. 卡片：只剩正文和标签，星标是右上角的角标 ---------- */
  /* 用户连着提了两次：「卡片上不显示来源和 icon 还有时间」→「卡片上的出处先删除」。
     撤元素容易，撤干净不容易，这里盯的是三件只有真布局才知道的事：
       ① 没有头部之后，正文上方不能留下那 8px 没来由的空档；
       ② 星标（用户按下的状态，必须留着）不占布局，也就不会把正文挤下去；
       ③ 星标不压到正文上——正文是两端对齐的，会一直写到内容盒右沿。 */
  Shiju.hydrate([
    { id:'h1', text:'有出处的一条。', app:'Google Chrome', title:'《有出处》', kind:'page',
      at:'3 分钟前', ts:0, tags:[] },
    { id:'h2', text:'既没出处也没星标的一条。', app:'终端', kind:'terminal',
      at:'4 分钟前', ts:0, tags:[] },
    { id:'h3', text:'加了星标的一条，星标不该压到正文上。', app:'微信', kind:'chat',
      at:'5 分钟前', ts:0, starred:true, tags:['标签'] },
    { id:'h4', text:'脑子里蹦出来的一句。', app:'', kind:'idea',
      at:'6 分钟前', ts:0, tags:[] },
  ]);

  const c1 = $('#grid .card[data-id="h1"]');
  const c2 = $('#grid .card[data-id="h2"]');
  const c3 = $('#grid .card[data-id="h3"]');
  T('卡片：四张样例卡都渲染出来了', !!c1 && !!c2 && !!c3,
    `h1=${!!c1} h2=${!!c2} h3=${!!c3}`);

  T('卡片：网格里再也看不到来源徽标 / 来源名 / 时间',
    $$('#grid .card .badge, #grid .card .src, #grid .card .when').length === 0,
    `还剩 ${$$('#grid .card .badge, #grid .card .src, #grid .card .when').length} 个`);
  T('卡片：出处也不在卡片上了',
    !!c1 && !c1.textContent.includes('《有出处》'), c1 ? `h1 的文字：${c1.textContent}` : '');
  T('卡片：头部容器整个不在了',
    $$('#grid .card .card__head, #grid .card .head__row, #grid .card .card__title').length === 0,
    `还剩 ${$$('#grid .card .card__head, #grid .card .head__row, #grid .card .card__title').length} 个头部节点`);

  // 正文上沿到卡片上沿的距离：内边距 + 边框。忘了那 1px 边框就会量出 1px 的假空档。
  const textTop = c => (c.querySelector('.card__text') ? R(c.querySelector('.card__text')).top : NaN);
  const insetTop = c => {
    const cs = getComputedStyle(c);
    return (parseFloat(cs.paddingTop) || 0) + (parseFloat(cs.borderTopWidth) || 0);
  };
  if (c2) {
    const slack = textTop(c2) - R(c2).top - insetTop(c2);
    T('卡片：正文紧贴内容盒上沿（没有头部留下空档）', slack <= 0.5,
      `实测空档 ${f(slack)}px（应为 0）`);
  }

  const star = c3 && c3.querySelector('.card__star');
  T('卡片：星标还在（它是用户按下的状态，藏起来等于丢了反馈）', !!star,
    c3 ? `h3 上没有 .card__star` : '找不到 h3');
  T('卡片：星标是卡片的直接子元素（所以不占布局，不会把正文挤下去）',
    !!star && star.parentElement === c3, star ? `父节点是 ${star.parentElement.className}` : '');
  T('卡片：没星标的卡片上没有角标', !!c1 && !c1.querySelector('.card__star'));
  if (star) {
    const sr = R(star), cr = R(c3), tr2 = R(c3.querySelector('.card__text'));
    T('卡片：星标落在卡片范围内',
      sr.right <= cr.right + 0.5 && sr.top >= cr.top - 0.5,
      `星标 ${f(sr.left)}–${f(sr.right)} / 卡片 ${f(cr.left)}–${f(cr.right)}`);
    // 「没压到」= 两个盒子不相交（任何一个方向分开就算分开）
    const apart = sr.right <= tr2.left + 0.5 || sr.left >= tr2.right - 0.5
               || sr.bottom <= tr2.top + 0.5 || sr.top >= tr2.bottom - 0.5;
    T('卡片：星标没有压到正文上', apart,
      `星标 [${f(sr.left)},${f(sr.top)}]–[${f(sr.right)},${f(sr.bottom)}]`
      + ` / 正文 [${f(tr2.left)},${f(tr2.top)}]–[${f(tr2.right)},${f(tr2.bottom)}]`);
  }

  // 列表视图同样要验一遍：那张卡片右侧本来有 84px 的操作槽，星标落在槽里；
  // 但**窄窗（≤720px）会把槽撤掉**，所以 CSS 里给有星标的行补了 padding-right。
  // 漏了那一补，角标就压到正文上了——而 520px 那档正是用户能拖到的最窄值。
  const listBtn = $('.seg button[data-view="list"]');
  if (listBtn) {
    listBtn.click();
    const lc = $('#grid .card[data-id="h3"]');
    const ls = lc && lc.querySelector('.card__star');
    const lt = lc && lc.querySelector('.card__text');
    if (!ls || !lt) {
      T('列表视图：有星标的行上还有角标', false,
        `card=${!!lc} star=${!!ls} text=${!!lt}`);
    } else {
      const a = R(ls), b = R(lt);
      const apart = a.right <= b.left + 0.5 || a.left >= b.right - 0.5
                 || a.bottom <= b.top + 0.5 || a.top >= b.bottom - 0.5;
      T('列表视图：星标没有压到正文上', apart,
        `星标 [${f(a.left)},${f(a.top)}]–[${f(a.right)},${f(a.bottom)}]`
        + ` / 正文右沿 ${f(b.right)}（视口 ${window.innerWidth}）`);
    }
    const gridBtn = $('.seg button[data-view="grid"]');
    if (gridBtn) gridBtn.click();
  }

  /* ---------- 8. 详情弹窗的「来源」徽标：真的画出了颜色 ---------- */
  /* 用户的原话是「来源 icon 是不是可以有点颜色」。查下来根因不在配色，
     而在**徽标压根没上色**：source_app 存的是 localizedName
     （「Google Chrome」「微信」），而面板的映射表键写的是 Chrome / WeChat 这种短名，
     于是除了 Safari 全都落到灰底兜底。
     那条由 jsdom 的 T19 锁；这里补一条**真渲染**的判据——
     jsdom 读不出 `hsl(var(--badge-h) …)` 解析成什么颜色，WebKit 可以。 */
  const bgOf = el => getComputedStyle(el).backgroundColor;
  const chroma = s => {                      // 灰底的三个通道几乎相等，色差接近 0
    const [r, g, b] = (s.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
    if ([r, g, b].some(v => !Number.isFinite(v))) return NaN;
    return Math.max(r, g, b) - Math.min(r, g, b);
  };
  const openSheet = id => {
    const c = $('#grid .card[data-id="' + id + '"]');
    if (c) c.click();
    return $('#sheetBody .srcpair .badge');
  };
  const closeSheet = () => { const x = $('#sheetClose'); if (x) x.click(); };

  const b1 = openSheet('h1');
  if (!b1) {
    T('弹窗徽标：打开详情后能找到来源徽标', false, '找不到 #sheetBody .srcpair .badge');
  } else {
    const bg = bgOf(b1);
    T('弹窗徽标：Chrome 是彩色的（不是灰底）', chroma(bg) > 40,
      `背景 ${bg}，通道极差 ${f(chroma(bg))}`);
    T('弹窗徽标：认得出的应用走品牌色（data-brand 落在 DOM 上）',
      b1.getAttribute('data-brand') === 'chrome', `data-brand=${b1.getAttribute('data-brand')}`);
  }
  closeSheet();

  const b2 = openSheet('h4');
  if (!b2) {
    T('弹窗徽标：灵感卡片也能打开详情', false, '找不到徽标');
  } else {
    const bg = bgOf(b2);
    T('弹窗徽标：灵感是彩色的（走强调色，不是灰底）', chroma(bg) > 12,
      `背景 ${bg}，通道极差 ${f(chroma(bg))}`);
    // 灵感早先用 `[data-kind="idea"] .badge` 上色，而弹窗里没有 [data-kind] 祖先，
    // 那条规则在弹窗里静默失效——所以这里必须验**弹窗里**的颜色，不是卡片上的。
    T('弹窗徽标：灵感的标记挂在徽标自己身上（不靠祖先）',
      b2.getAttribute('data-brand') === 'idea', `data-brand=${b2.getAttribute('data-brand')}`);
  }
  closeSheet();

  return JSON.stringify({ checks: out, viewport: { w: window.innerWidth, h: window.innerHeight } });
})()
