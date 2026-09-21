#!/usr/bin/env node
/**
 * 面板契约测试 —— 用 jsdom 把 Resources/panel.html 真跑起来，
 * 对面接一个「假原生」端，模拟 Store（SQLite）与 PanelWindow.pushCaptured，
 * 验证 Swift ↔ JS 之间的消息往返。
 *
 * 为什么需要它：面板的 bug 多半不是「报错」，而是「静默不一致」——
 * 卡片插两次、撤销之后下次打开又回来。这类问题靠静态读代码很难确信，
 * 而本机无头 Chrome 起不来（见 README「已知限制」），jsdom 是可行的替代。
 *
 * 跑法（推荐用包装脚本）：
 *   ./Scripts/test-panel.sh
 * 或直接：
 *   node Scripts/panel-contract-test.cjs
 *
 * 依赖：jsdom。按这个顺序找：
 *   1. 常规的 `require('jsdom')`（在项目里 npm install jsdom 就行）
 *   2. 环境变量 SHIJU_JSDOM=/path/to/node_modules/jsdom
 *   3. 本机那个隔离的 node 工作区（不污染项目，也不全局安装）
 * 三条都落空才会报错退出。
 *
 * 加 --selfcheck 会额外跑一遍「故意把双重插入的 bug 改回去」的版本，
 * 用来证明这些断言真的有牙齿（不是恒真）。
 */

const { readFileSync } = require('node:fs');
const { join, dirname } = require('node:path');

const HERE = __dirname;
const PANEL = join(HERE, '..', 'Resources', 'panel.html');

// ---------------------------------------------------------------- jsdom 加载

function loadJsdom() {
  const candidates = [
    'jsdom',
    process.env.SHIJU_JSDOM,
    // 本机把这个包装在隔离的 node 工作区里（不污染项目，也不全局安装）。
    // 这只是兜底的一条：clone 下来的人走上面第一条就够了。
    join(process.env.HOME || '', '.workbuddy-ai/binaries/node/workspace/node_modules/jsdom'),
  ].filter(Boolean);
  for (const c of candidates) {
    try { return require(c); } catch (_) { /* 换下一个 */ }
  }
  console.error('找不到 jsdom。任选一种：\n' +
    '  npm install jsdom                                        # 装在项目里\n' +
    '  SHIJU_JSDOM=/path/to/node_modules/jsdom node Scripts/panel-contract-test.cjs');
  process.exit(2);
}
const { JSDOM } = loadJsdom();

// ---------------------------------------------------------------- 断言记账

let passed = 0, failed = 0;
const lines = [];

function check(name, cond, detail) {
  if (cond) { passed++; lines.push(`  \x1b[32m✓\x1b[0m ${name}`); }
  else {
    failed++;
    lines.push(`  \x1b[31m✗\x1b[0m ${name}${detail ? `\n      \x1b[90m→ ${detail}\x1b[0m` : ''}`);
  }
}

// ---------------------------------------------------------------- 启动面板

/** 起一个面板实例。native=false 用来模拟「浏览器里单独调样式」的环境。 */
function boot(html, { native = true } = {}) {
  const sent = [];                       // 面板发往原生的消息
  const dom = new JSDOM(html, {
    runScripts: 'dangerously',
    pretendToBeVisual: true,             // 提供 requestAnimationFrame
    url: 'https://shiju.local/panel.html', // 给一个正常 origin，localStorage 才可用
    beforeParse(w) {
      // jsdom 不实现 Web Animations，而卡片入场动画会调 element.animate()
      w.Element.prototype.animate = () => ({ finished: Promise.resolve(), cancel() {}, finish() {} });
      try {
        Object.defineProperty(w.navigator, 'clipboard',
          { value: { writeText: () => Promise.resolve() }, configurable: true });
      } catch (_) { /* 没有就算了，copyText 会走同步兜底 */ }
      if (native) {
        w.webkit = { messageHandlers: { action: { postMessage: m => sent.push(m) } } };
      }
    },
  });
  const win = dom.window;
  return { dom, win, doc: win.document, sent };
}

// ---------------------------------------------------------------- 假原生端

const SEED_ROWS = [
  { id: 'r1', text: '人间送小温。', kind: 'page', at: '1 分钟前', starred: false, tags: ['句子'] },
  { id: 'r2', text: '死生亦大矣。', kind: 'note', at: '2 分钟前', starred: true, tags: [] },
  { id: 'r3', text: '被误解是表达者的宿命。', kind: 'page', at: '3 分钟前', starred: false, tags: [] },
];

/**
 * 模拟原生侧：一张 snippets 表 + PanelWindow 的消息分支。
 * pump() 把面板发来的消息按序消费掉，行为和 Swift 端一一对应。
 *
 * 去重必须一起模拟：Store.insert 命中 text_hash 时会返回 nil，
 * PanelWindow 就不再 pushCaptured —— 少了这一层，回环类 bug 会被放大成
 * 「插几十次」，看到的就不是真实行为了。这里用归一化后的字符串当 key
 * （Snippet.hash 只是把它压成 FNV-1a，做去重等价）。
 */
function nativeSide(win, sent) {
  const now = Date.now();
  const db = SEED_ROWS.map((r, i) => ({
    ...r, capturedAt: now - (i + 1) * 60000, deleted: false,
  }));
  const log = [];      // 收到过的消息类型，按序
  let seq = 0;

  const dedupeKey = t => String(t).split(/\s+/).filter(Boolean).join(' ').toLowerCase();
  // 软删除的行也算「已存在」，和 Store.existingID 一致
  const seen = new Set(db.map(r => dedupeKey(r.text)));
  const discarded = [];   // 记录被去重挡掉的文本，便于断言

  const payload = r => ({
    id: r.id, text: r.text, kind: r.kind, capturedAt: r.capturedAt,
    ts: Math.max(0, Date.now() - r.capturedAt), at: r.at,
    starred: !!r.starred, tags: r.tags || [],
  });

  /** 对应 PanelWindow.refresh() / hydrate() */
  function hydrate() {
    const rows = db.filter(r => !r.deleted).map(payload);
    win.eval(`window.Shiju.hydrate(${JSON.stringify(rows)});`);
  }

  /** 对应 PanelWindow.pushCaptured() */
  const pushCaptured = row => win.eval(`window.Shiju.capture(${JSON.stringify(payload(row))});`);

  function pump() {
    // 熔断：万一面板把消息回环（比如 Shiju.capture 里又 bridge 回去），
    // 这里必须能停下来，否则测试会挂死而不是报红。
    let budget = 64;
    while (sent.length) {
      if (--budget < 0) {
        log.push('<<熔断：消息回环>>');
        sent.length = 0;
        break;
      }
      const m = sent.shift();
      log.push(m.type);
      switch (m.type) {
        case 'capture': {          // Store.insert + pushCaptured
          const key = dedupeKey(m.text);
          if (seen.has(key)) { discarded.push(m.text); break; }   // 命中去重 → 返回 nil
          seen.add(key);
          const row = {
            id: 'db' + (++seq), text: m.text, kind: 'idea',
            capturedAt: Date.now(), at: '刚刚', starred: false, tags: [], deleted: false,
          };
          db.push(row);
          pushCaptured(row);
          break;
        }
        case 'discard': {          // Store.discard → 物理删除
          const i = db.findIndex(r => r.id === m.id);
          if (i >= 0) { seen.delete(dedupeKey(db[i].text)); db.splice(i, 1); }
          break;
        }
        case 'delete': {           // Store.softDelete
          const r = db.find(r => r.id === m.id);
          if (r) r.deleted = true;
          break;
        }
        case 'undo': {             // Store.restore
          const r = db.find(r => r.id === m.id);
          if (r) r.deleted = false;
          break;
        }
        default: break;            // star / edit / copy / setTheme 本测试不涉及
      }
    }
  }

  return { db, log, pump, hydrate, discarded, live: () => db.filter(r => !r.deleted) };
}

// ---------------------------------------------------------------- DOM 助手

const cards = doc => doc.querySelectorAll('#grid .card');
const cardById = (doc, id) => doc.querySelectorAll(`#grid .card[data-id="${id}"]`);
const delBtn = (doc, id) => doc.querySelector(`#grid .card[data-id="${id}"] .acts button[data-act="del"]`);
const press = (win, key) => win.document.dispatchEvent(
  new win.KeyboardEvent('keydown', { key, bubbles: true }));
function stateOf(win, expr) {
  try { return win.eval(expr); } catch (e) { return `<<${e.message}>>`; }
}

/** 点一个可能不存在的元素。
 *  自检时注入的 bug 会让卡片提前消失，测试脚本不该跟着崩——
 *  我们要的是「断言变红」，不是「脚本报错退出」。 */
const clickOn = el => { if (el) { el.click(); return true; } return false; };

/** <dialog> 开着没有。jsdom 不实现 showModal()，面板会退回 setAttribute('open')，
 *  所以两种判据都要认。 */
const dlgOpen = (doc, sel) => {
  const d = doc.querySelector(sel);
  return !!d && (d.hasAttribute('open') || d.open === true);
};

/** 「＋ 记录」→ 弹窗填表 → 点「记录」。
 *  取代以前的 window.prompt：手动记录现在和编辑共用一个弹窗，
 *  能填正文、标签、出处、链接。 */
function createSnippet(win, doc, text, extra = {}) {
  doc.querySelector('#addBtn').click();
  doc.querySelector('#edText').value = text;
  if (extra.title != null) doc.querySelector('#edTitle').value = extra.title;
  if (extra.url != null) doc.querySelector('#edUrl').value = extra.url;
  for (const t of (extra.tags || [])) {
    const inp = doc.querySelector('#edTagAdd');
    inp.value = t;
    inp.dispatchEvent(new win.KeyboardEvent('keydown',
      { key: 'Enter', bubbles: true, cancelable: true }));
  }
  doc.querySelector('#sheetFoot [data-d="create"]').click();
}

/** 点卡片上的「删除」并确认。删除现在必须先过确认弹窗。 */
function deleteCard(doc, id) {
  clickOn(delBtn(doc, id));
  clickOn(doc.querySelector('#confirmOk'));
}

/** 点开一张卡片的详情弹窗。 */
function openCard(doc, id) {
  cardById(doc, id)[0].dispatchEvent(
    new doc.defaultView.MouseEvent('click', { bubbles: true }));
}

// ---------------------------------------------------------------- 用例

function suite(html, label) {
  passed = 0; failed = 0; lines.length = 0;
  const doms = [];
  const open = opts => { const b = boot(html, opts); doms.push(b.dom); return b; };

  // ---- T1：「＋ 记录」只落库一次，且卡片用数据库真 id
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    nat.hydrate();
    const before = cards(doc).length;
    createSnippet(win, doc, '测试句子：只该收录一次');
    nat.pump();

    check('T1 只发出一条 capture 消息',
      nat.log.length === 1 && nat.log[0] === 'capture',
      `实际发出 ${JSON.stringify(nat.log)}（两条说明 JS 自己插了一次又让原生插了一次）`);
    check('T1 库里只有一行',
      nat.db.length === SEED_ROWS.length + 1,
      `实际 ${nat.db.length} 行，期望 ${SEED_ROWS.length + 1} 行`);
    check('T1 界面只多出一张卡片',
      cards(doc).length === before + 1,
      `${before} → ${cards(doc).length}`);

    const realId = nat.db[nat.db.length - 1].id;
    const head = stateOf(win, 'state.data[0].id');
    check('T1 新卡用的是数据库真 id（不是本地假 id）',
      head === realId && cardById(doc, realId).length === 1,
      `state.data[0].id = ${head}，数据库给的 id = ${realId}`);

    // 最锋利的一条：界面上的每张卡都必须能在库里找到。
    // 双重插入时会多出一张带本地假 id 的卡，只有这条能抓到它
    // （因为真 id 的那张也在，且库里的行数看起来「刚好」）。
    const dbIds = new Set(nat.db.map(r => r.id));
    const orphans = Array.from(cards(doc))
      .map(c => c.dataset.id)
      .filter(id => !dbIds.has(id));
    check('T1 界面上没有库里不存在的「孤儿卡片」',
      orphans.length === 0,
      `多出 ${orphans.length} 张假 id 卡片：${JSON.stringify(orphans)}`);
    win.close();
  }

  // ---- T2：「已收录 · 撤销」走 discard，且同一句话还能再收录
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    nat.hydrate();
    const before = cards(doc).length;
    const TEXT = '测试句子：撤销后还能再收';

    createSnippet(win, doc, TEXT);
    nat.pump();
    doc.querySelector('#toastAct').click();
    nat.pump();

    check('T2 撤销发的是 discard（不是 undo）',
      nat.log.join(',') === 'capture,discard',
      `实际 ${nat.log.join(',')}`);
    check('T2 撤销后库里那行真的没了',
      nat.db.length === SEED_ROWS.length,
      `实际 ${nat.db.length} 行，期望 ${SEED_ROWS.length} 行`);
    check('T2 撤销后卡片从界面移除',
      cards(doc).length === before,
      `${before} → ${cards(doc).length}`);

    // 关键回归点：软删会被去重逻辑永久挡住，硬删不会
    createSnippet(win, doc, TEXT);
    nat.pump();
    check('T2 同一句话能再次收录（软删方案会在这里静默失败）',
      nat.db.length === SEED_ROWS.length + 1,
      `实际 ${nat.db.length} 行，期望 ${SEED_ROWS.length + 1} 行`);
    check('T2 再次收录没有被去重挡掉',
      nat.discarded.length === 0,
      `被 Store.insert 去重拒绝 ${nat.discarded.length} 次：${JSON.stringify(nat.discarded)}`);
    win.close();
  }

  // ---- T3：删除 → 撤销 → 再按 z，不该重复插入
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    nat.hydrate();
    const TARGET = 'r1';
    const before = cards(doc).length;

    clickOn(delBtn(doc, TARGET));
    doc.querySelector('#confirmOk').click();
    nat.pump();
    check('T3 删除发出 delete', nat.log.join(',') === 'delete', nat.log.join(','));
    check('T3 删除后卡片消失', cardById(doc, TARGET).length === 0);

    doc.querySelector('#toastAct').click();   // 点 toast 上的「撤销」
    nat.pump();
    check('T3 toast 撤销发出 undo', nat.log.join(',') === 'delete,undo', nat.log.join(','));
    check('T3 toast 撤销后卡片回来且只有一张',
      cardById(doc, TARGET).length === 1, `实际 ${cardById(doc, TARGET).length} 张`);

    press(win, 'z');                          // 此时不该再有动作
    nat.pump();
    check('T3 撤销后再按 z 不会重复插入',
      cardById(doc, TARGET).length === 1, `实际 ${cardById(doc, TARGET).length} 张`);
    check('T3 撤销后再按 z 不再发消息',
      nat.log.join(',') === 'delete,undo', `实际 ${nat.log.join(',')}`);
    check('T3 总数没有变多', cards(doc).length === before, `${before} → ${cards(doc).length}`);
    win.close();
  }

  // ---- T4：删除后按 z 恢复，必须同步到数据库
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    nat.hydrate();
    const TARGET = 'r2';

    deleteCard(doc, TARGET);
    nat.pump();
    press(win, 'z');
    nat.pump();

    check('T4 z 恢复发出 undo（只改本地不改库是 bug）',
      nat.log.join(',') === 'delete,undo', `实际 ${nat.log.join(',')}`);
    const row = nat.db.find(r => r.id === TARGET);
    check('T4 z 恢复后库里不再是删除态', row && row.deleted === false,
      `库里该行 = ${JSON.stringify(row)}`);
    check('T4 z 恢复后卡片回到列表且只有一张',
      cardById(doc, TARGET).length === 1, `实际 ${cardById(doc, TARGET).length} 张`);
    win.close();
  }

  // ---- T5：没有原生壳时（浏览器里调样式）退化为纯本地插入
  {
    const { win, doc, sent } = open({ native: false });
    const before = cards(doc).length;
    createSnippet(win, doc, '浏览器预览里记一句');

    check('T5 无原生壳时不报错，本地插入一张',
      cards(doc).length === before + 1, `${before} → ${cards(doc).length}`);
    check('T5 无原生壳时没有消息外发', sent.length === 0, `实际 ${sent.length} 条`);
    win.close();
  }

  // ---- T6：顶栏拖动
  // WKWebView **不实现** `-webkit-app-region`（那是 Electron 的私有属性），
  // 所以拖动只能走原生桥。两条约束都要守住：
  //   1. 空白处按下 → 必须发 startDrag，否则窗口拖不动
  //   2. 控件上按下 → 必须不发，否则按钮点不动（等价于 Electron 的 no-drag）
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    nat.hydrate();

    const bar = doc.querySelector('.topbar');
    check('T6 顶栏存在', !!bar);

    const down = el => el.dispatchEvent(
      new win.MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0 }));
    const dragCount = () => sent.filter(m => m.type === 'startDrag').length;

    down(doc.querySelector('.topbar .spacer'));            // 中间那片空白
    check('T6 顶栏空白处按下发出 startDrag', dragCount() === 1,
      `实际 ${dragCount()} 条，收到：${JSON.stringify(sent)}`);

    sent.length = 0;
    down(bar);                                             // 标题栏那一条（顶栏的 padding）
    check('T6 标题栏留白处按下也能拖', dragCount() === 1, `实际 ${dragCount()} 条`);

    sent.length = 0;
    down(doc.querySelector('.brand'));                     // logo
    check('T6 logo 上按下也能拖', dragCount() === 1, `实际 ${dragCount()} 条`);

    sent.length = 0;
    down(doc.querySelector('#themeBtn'));
    down(doc.querySelector('#q'));
    down(doc.querySelector('.seg button'));
    check('T6 控件上按下不发 startDrag（否则按钮点不动）', dragCount() === 0,
      `实际 ${dragCount()} 条，收到：${JSON.stringify(sent)}`);

    win.close();
  }

  // ---- T7：删除必须先确认（以前点一下就直接永久删掉）
  // 三个出口都要守：取消不删、点遮罩不删、确认才删。
  // 「取消」这条最要紧——它是「手滑点了删除」唯一的退路。
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    nat.hydrate();
    const TARGET = 'r1';
    const before = cards(doc).length;
    // 直接看「已发出的消息」而不是 nativeSide 的 log：log 要 pump 之后才有内容，
    // pump 之前它恒为空，拿它当判据会得到一条永远为真的断言。
    const delCount = () => sent.filter(m => m.type === 'delete').length;

    clickOn(delBtn(doc, TARGET));
    check('T7 点删除先弹确认框', dlgOpen(doc, '#confirm'));
    check('T7 确认文案里带那句话本身（不然不知道在删哪条）',
      /人间送小温/.test(doc.querySelector('#confirmText').textContent),
      `实际文案：${doc.querySelector('#confirmText').textContent}`);
    check('T7 只弹框、不删：一条 delete 都没发', delCount() === 0,
      `实际发了 ${delCount()} 条，收到：${JSON.stringify(sent)}`);
    check('T7 只弹框、不删：卡片还在', cardById(doc, TARGET).length === 1);
    nat.pump();
    check('T7 只弹框、不删：库里那行还在',
      nat.live().length === SEED_ROWS.length, `库里 ${nat.live().length} 行`);

    doc.querySelector('#confirmCancel').click();
    check('T7 点取消后弹窗关掉', !dlgOpen(doc, '#confirm'));
    check('T7 点取消后依然没发 delete', delCount() === 0, `实际 ${delCount()} 条`);
    nat.pump();
    check('T7 点取消后卡片没少', cards(doc).length === before);

    // 取消要真的把「待删」清掉，否则下一次点删除会拿旧的 id 去删
    clickOn(delBtn(doc, TARGET));
    doc.querySelector('#confirm').dispatchEvent(
      new win.MouseEvent('click', { bubbles: true, cancelable: true }));
    check('T7 点遮罩关闭后也不删',
      delCount() === 0 && cardById(doc, TARGET).length === 1,
      `delete ${delCount()} 条，卡片 ${cardById(doc, TARGET).length} 张`);
    nat.pump();

    deleteCard(doc, TARGET);
    check('T7 确认后才真的发 delete',
      delCount() === 1 && sent[0] && sent[0].id === TARGET,
      `delete ${delCount()} 条，收到：${JSON.stringify(sent)}`);
    nat.pump();
    check('T7 确认后卡片才消失', cardById(doc, TARGET).length === 0);
    check('T7 确认后库里标记为删除态',
      nat.live().length === SEED_ROWS.length - 1, `库里剩 ${nat.live().length} 行`);
    win.close();
  }

  // ---- T8：手动记录要能把标签 / 出处 / 链接一起落库
  // 以前这条路走 window.prompt，只能收一行字；现在和编辑共用弹窗。
  // 契约的关键是这几个字段真的上了消息，而不是只留在界面里。
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    nat.hydrate();

    createSnippet(win, doc, '测试句子：带标签和出处', {
      tags: ['电影', '台词'], title: '《一一》', url: 'https://example.com/a',
    });
    const msg = sent[0] || {};
    check('T8 新建发出的是 capture', sent.length === 1 && sent[0].type === 'capture',
      JSON.stringify(sent));
    check('T8 正文跟着走', msg.text === '测试句子：带标签和出处', JSON.stringify(msg));
    check('T8 标签跟着走', Array.isArray(msg.tags) && msg.tags.join('|') === '电影|台词',
      JSON.stringify(msg.tags));
    check('T8 出处跟着走', msg.title === '《一一》', JSON.stringify(msg.title));
    check('T8 链接跟着走', msg.url === 'https://example.com/a', JSON.stringify(msg.url));

    nat.pump();
    check('T8 记录完弹窗关掉', !dlgOpen(doc, '#sheet'));
    check('T8 记录完多出一张卡', cards(doc).length === SEED_ROWS.length + 1,
      `${SEED_ROWS.length} → ${cards(doc).length}`);

    // 选填项留空时不该写进去（原生用 nilIfBlank 归一成 NULL），
    // 但消息里必须是「空串」而不是 undefined —— undefined 会在 Swift 侧变成 nil，
    // 那样也「恰好」是对的，所以这条只在防止 JS 漏传字段时才有意义。
    sent.length = 0;
    createSnippet(win, doc, '测试句子：什么都不填');
    const bare = sent[0] || {};
    check('T8 出处留空时传的是空串（不是漏字段）',
      typeof bare.title === 'string' && typeof bare.url === 'string',
      `title=${JSON.stringify(bare.title)} url=${JSON.stringify(bare.url)}`);
    nat.pump();
    win.close();
  }

  // ---- T9：详情弹窗的关闭按钮是画出来的叉，不是文字「×」
  // 文字 × 的垂直居中随字体而变，上一版就是歪的。改成 SVG 之后
  // 位置由几何决定，只要结构在就必然居中。
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    nat.hydrate();
    openCard(doc, 'r1');

    const btn = doc.querySelector('#sheetClose');
    check('T9 关闭按钮里有 svg', !!btn.querySelector('svg'));
    check('T9 关闭按钮没有文字（文字叉会歪）',
      btn.textContent.trim() === '', JSON.stringify(btn.textContent));
    const svg = btn.querySelector('svg');
    check('T9 叉的两笔都是圆头描边',
      svg && Array.from(svg.querySelectorAll('path'))
        .every(p => p.getAttribute('stroke-linecap') === 'round'),
      svg ? svg.innerHTML : '没有 svg');
    check('T9 关闭按钮有可读名字（读屏 / 悬浮提示）',
      !!btn.getAttribute('aria-label') && !!btn.getAttribute('title'));
    win.close();
  }

  // ---- T10：新建弹窗不啰嗦
  // 新建态只留输入框与按钮：文本框下面那行「N 字 · N 行 + ⌘↵ 保存 · Esc 取消」
  // 刚打开时报的是「0 字 · 1 行」，没有信息量。编辑态**要保留**——
  // 那里字数会变，是有效信息，别被「顺手一起删了」。
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    nat.hydrate();

    doc.querySelector('#addBtn').click();
    check('T10 新建弹窗打开了', dlgOpen(doc, '#sheet'));
    check('T10 新建态没有文本框下面那行辅助信息',
      !doc.querySelector('#sheetBody .edit__foot'), doc.querySelector('#sheetBody').innerHTML.slice(0, 120));
    check('T10 新建态没有字数统计节点', !doc.querySelector('#edCount'));
    check('T10 新建态底栏只有两个按钮',
      doc.querySelectorAll('#sheetFoot .btn').length === 2,
      `实际 ${doc.querySelectorAll('#sheetFoot .btn').length} 个：`
      + Array.from(doc.querySelectorAll('#sheetFoot .btn')).map(b => b.textContent).join('/'));
    check('T10 新建态底栏没有多余提示文案',
      !/不填出处|手动记录/.test(doc.querySelector('#sheetFoot').textContent),
      JSON.stringify(doc.querySelector('#sheetFoot').textContent));

    // 关键回归点：编辑态的字数统计不能被顺手删掉
    doc.querySelector('#sheetFoot [data-d="cancel"]').click();
    openCard(doc, 'r1');
    doc.querySelector('#sheetFoot [data-d="edit"]').click();
    check('T10 编辑态仍然有字数统计', !!doc.querySelector('#edCount'));
    check('T10 编辑态仍然有文本框下面那行',
      !!doc.querySelector('#sheetBody .edit__foot'));
    win.close();
  }

  // ---- T11：关闭按钮挂在卡片**外面**
  // 它必须相对 dialog 定位、而不是在 .sheet__panel 里面——
  // panel 为了长内容能滚动带 overflow-y:auto，按钮挂进去就会被一起裁掉，
  // 表现为「详情弹窗看不见关闭按钮」。这是纯结构约束，所以只能这么测。
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    nat.hydrate();
    openCard(doc, 'r1');

    const btn = doc.querySelector('#sheetClose');
    const panel = doc.querySelector('.sheet__panel');
    check('T11 有关闭按钮', !!btn);
    check('T11 卡片内层存在', !!panel);
    check('T11 关闭按钮不在卡片内层里（否则会被 overflow 裁掉）',
      !!panel && !panel.contains(btn),
      `panel.contains(btn) = ${panel ? panel.contains(btn) : 'panel 不存在'}`);
    check('T11 关闭按钮的父元素就是 dialog',
      btn.parentElement === doc.querySelector('#sheet'),
      `父元素是 <${btn.parentElement && btn.parentElement.tagName.toLowerCase()}>`);
    check('T11 卡片内层装着正文与底栏',
      !!panel && panel.contains(doc.querySelector('#sheetBody'))
             && panel.contains(doc.querySelector('#sheetFoot')));
    check('T11 dialog 自己不裁内容（overflow 不能是 hidden/auto/scroll）',
      !/hidden|auto|scroll/.test(stateOf(win, "getComputedStyle(document.querySelector('#sheet')).overflow")),
      `overflow = ${stateOf(win, "getComputedStyle(document.querySelector('#sheet')).overflow")}`);
    // 结构对还不够：按钮得真的悬到卡片上沿之外，否则「外置」只是个说法
    const top = parseFloat(stateOf(win, "getComputedStyle(document.querySelector('#sheetClose')).top"));
    check('T11 关闭按钮悬在卡片上沿之外（top 为负）',
      Number.isFinite(top) && top < 0,
      `top = ${stateOf(win, "getComputedStyle(document.querySelector('#sheetClose')).top")}`);
    win.close();
  }

  // ---- T12：一行放几列要跟着面板宽度走
  // 旧实现是两个坑叠在一起：硬编码断点（>=1080?4:…）+ .grid 的 max-width:1160px。
  // 结果拖到 1160 以上列数就再也不涨，看起来像「拖了没反应」。
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    nat.hydrate();
    const cols = w => stateOf(win, `colCount(${w})`);
    const WIDTHS = [320, 600, 900, 1200, 1500, 1800, 2200, 2600];

    check('T12 极窄面板只放 1 列', cols(320) === 1, `colCount(320) = ${cols(320)}`);
    check('T12 默认窗口宽约 3 列', cols(988) === 3, `colCount(988) = ${cols(988)}`);
    check('T12 拖到 1160 以上还会继续加列（旧实现在这里就封顶了）',
      cols(1160) < cols(1400), `1160→${cols(1160)} 列，1400→${cols(1400)} 列`);
    check('T12 列数随宽度单调不减',
      WIDTHS.every((w, i, a) => i === 0 || cols(w) >= cols(a[i - 1])),
      WIDTHS.map(w => `${w}:${cols(w)}`).join(' '));
    check('T12 有列数上限（超宽屏不至于变成十几列）',
      cols(6000) <= 6, `colCount(6000) = ${cols(6000)}`);
    check('T12 每列都不窄于下限',
      [400, 700, 1000, 1300, 1600, 2000].every(w => w / cols(w) >= 240),
      [400, 700, 1000, 1300, 1600, 2000].map(w => `${w}→${cols(w)}列`).join(' '));
    // 列数算得再对，只要 .grid 自己封了宽度就白算
    check('T12 网格没有宽度上限（有的话拖宽白拖）',
      stateOf(win, "getComputedStyle(document.querySelector('#grid')).maxWidth") === 'none',
      `max-width = ${stateOf(win, "getComputedStyle(document.querySelector('#grid')).maxWidth")}`);
    win.close();
  }

  // ---- T13：标签多了不能把底栏挤坏
  // 旧版：标签 flex-wrap:wrap 会换行，右侧「星标/复制/删除」被压得换行甚至挤出卡片。
  // 露几个标签跟着卡片宽度走，所以测试要自己造宽度——jsdom 不做布局，clientWidth 恒为 0。
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    const now = Date.now();
    win.eval(`window.Shiju.hydrate([{
      id:'t1', text:'一句话', kind:'page', capturedAt:${now}, ts:0, at:'刚刚',
      starred:false, tags:['一','二','三','四','五']
    }])`);

    const card = () => doc.querySelector('#grid .card[data-id="t1"]');
    const cardTags = () => card().querySelectorAll('.foot__tags .tag');
    const setGridWidth = w => {
      Object.defineProperty(doc.querySelector('#grid'), 'clientWidth',
        { value: w, configurable: true });
      win.eval('render()');
    };

    setGridWidth(1200);   // 4 列，卡片约 280px
    check('T13 窄卡片只露 1 个标签', cardTags().length === 1, `实际 ${cardTags().length} 个`);
    const more = card().querySelector('.tagmore');
    check('T13 其余折成「+4」', more && more.textContent === '+4', more ? more.textContent : '没有 +N');
    check('T13「+N」的 title 里能看到被藏起来的标签名',
      more && /五/.test(more.getAttribute('title') || ''), more ? more.getAttribute('title') : '');
    check('T13 每个标签都有 title（被截断后还能看全名）',
      Array.from(cardTags()).every(b => b.getAttribute('title')));
    check('T13 标签行不换行（换行会把按钮顶到第二行）',
      stateOf(win, "getComputedStyle(document.querySelector('#grid .foot__tags')).flexWrap") !== 'wrap',
      `flex-wrap = ${stateOf(win, "getComputedStyle(document.querySelector('#grid .foot__tags')).flexWrap")}`);
    check('T13 操作按钮不参与压缩',
      stateOf(win, "getComputedStyle(document.querySelector('#grid .acts')).flexShrink") === '0',
      `flex-shrink = ${stateOf(win, "getComputedStyle(document.querySelector('#grid .acts')).flexShrink")}`);
    check('T13 按钮文字不折行（「★ 星标」断成两行就是这么来的）',
      stateOf(win, "getComputedStyle(document.querySelector('#grid .acts button')).whiteSpace") === 'nowrap',
      `white-space = ${stateOf(win, "getComputedStyle(document.querySelector('#grid .acts button')).whiteSpace")}`);
    check('T13「+N」自己不被压缩掉（没了就以为只有这几个标签）',
      stateOf(win, "getComputedStyle(document.querySelector('#grid .tagmore')).flexShrink") === '0',
      `flex-shrink = ${stateOf(win, "getComputedStyle(document.querySelector('#grid .tagmore')).flexShrink")}`);

    // 同样的数据，卡片变宽就该多露几个——否则宽屏上一张卡只挂一个标签太浪费
    setGridWidth(900);    // 3 列
    check('T13 3 列时露 2 个', cardTags().length === 2, `实际 ${cardTags().length} 个`);
    setGridWidth(400);    // 1 列，卡片很宽
    check('T13 宽卡片露 3 个', cardTags().length === 3, `实际 ${cardTags().length} 个`);
    const moreWide = card().querySelector('.tagmore');
    check('T13 宽卡片上「+2」跟着变', moreWide && moreWide.textContent === '+2',
      moreWide ? moreWide.textContent : '没有 +N');

    // 列表视图一行读完，固定给 3 个（不受列数影响）
    doc.querySelector('.seg button[data-view="list"]').click();
    const rowTags = () => card().querySelectorAll('.card__meta .tag');
    check('T13 列表视图最多 3 个标签', rowTags().length === 3, `实际 ${rowTags().length} 个`);
    const rowMore = card().querySelector('.card__meta .tagmore');
    check('T13 列表视图折成「+2」', rowMore && rowMore.textContent === '+2',
      rowMore ? rowMore.textContent : '没有 +N');
    win.close();
  }

  // ---- T14：按标签筛选
  // 和卡片上点标签的区别：那个是全文搜索（正文里出现该词也会命中），
  // 这个是精确匹配——必须真带这个标签。
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    const now = Date.now();
    win.eval(`window.Shiju.hydrate([
      {id:'a', text:'甲', kind:'page', capturedAt:${now}, ts:0, at:'刚刚', starred:false, tags:['诗','夜']},
      {id:'b', text:'乙', kind:'page', capturedAt:${now - 1000}, ts:0, at:'刚刚', starred:false, tags:['诗']},
      {id:'c', text:'丙', kind:'page', capturedAt:${now - 2000}, ts:0, at:'刚刚', starred:false, tags:['夜']},
      {id:'d', text:'这句正文里有诗字但没打标签', kind:'page', capturedAt:${now - 3000}, ts:0, at:'刚刚', starred:false, tags:[]}
    ])`);

    const tagBtn = doc.querySelector('#tagBtn');
    const ids = () => Array.from(doc.querySelectorAll('#grid .card')).map(c => c.dataset.id);
    const rows = () => Array.from(doc.querySelectorAll('#tagList .tagrow'));

    check('T14 有标签时入口出现', !tagBtn.hidden);
    check('T14 入口上的数字是标签种类数', doc.querySelector('#tagBtnN').textContent === '2',
      doc.querySelector('#tagBtnN').textContent);

    tagBtn.click();
    check('T14 点开弹层', dlgOpen(doc, '#tagPop'));
    check('T14 列出全部标签', rows().length === 2, `实际 ${rows().length} 行`);
    check('T14 每个标签带出现次数',
      rows().map(r => (r.textContent.match(/\d+/) || [''])[0]).join(',') === '2,2',
      rows().map(r => r.textContent.trim()).join(' | '));
    check('T14 同次数的按拼音排（诗 shi 在 夜 ye 前）',
      rows()[0] && rows()[0].dataset.tag === '诗' && rows()[1] && rows()[1].dataset.tag === '夜',
      rows().map(r => r.dataset.tag).join(','));

    clickOn(rows()[0]);
    check('T14 选「诗」后只剩带该标签的两条', ids().join(',') === 'a,b', ids().join(','));
    check('T14 精确匹配：正文里有「诗」但没打标签的不算', !ids().includes('d'), ids().join(','));
    check('T14 选完弹层关闭', !dlgOpen(doc, '#tagPop'));
    check('T14 入口变成「标签名 + 命中条数」',
      doc.querySelector('#tagBtnLabel').textContent === '诗'
      && doc.querySelector('#tagBtnN').textContent === '2',
      `${doc.querySelector('#tagBtnLabel').textContent} / ${doc.querySelector('#tagBtnN').textContent}`);

    tagBtn.click();
    const clear = doc.querySelector('#tagList .tagrow--clear');
    check('T14 选中状态下才有「清除筛选」', !!clear);
    clickOn(clear);
    check('T14 清除后全部回来', ids().length === 4, `实际 ${ids().length} 条`);
    check('T14 清除后入口回到「标签 + 种类数」',
      doc.querySelector('#tagBtnLabel').textContent === '标签'
      && doc.querySelector('#tagBtnN').textContent === '2',
      `${doc.querySelector('#tagBtnLabel').textContent} / ${doc.querySelector('#tagBtnN').textContent}`);

    // 库里没标签时不该留一个点开是空的按钮。
    // 光看 hidden 属性不够：.chip 的 display 是作者样式，会盖掉 [hidden] 的 UA 样式。
    win.eval(`window.Shiju.hydrate([{id:'x', text:'没标签', kind:'page',
      capturedAt:${now}, ts:0, at:'刚刚', starred:false, tags:[]}])`);
    check('T14 一条标签都没有时入口整个藏起来', doc.querySelector('#tagBtn').hidden);
    // 这里**不能**用 computed style 断言：jsdom 把 [hidden] 的 UA 样式排在作者样式之前
    // （实测 display 恒为 none），而真实浏览器是反的——.chip 的 display:inline-flex
    // 会盖掉 [hidden]{display:none}。两者行为不一致，所以只能查源码里确实有那条规则。
    check('T14 源码里有 .chip[hidden] 规则（浏览器里 .chip 的 display 会盖掉 [hidden]）',
      /\.chip\[hidden\]\s*\{[^}]*display\s*:\s*none/.test(html),
      'panel.html 里缺 .chip[hidden]{display:none}：hidden 属性设了也没用，空入口会一直杵着');
    win.close();
  }

  // ---- T15：主题弹层贴在按钮下方
  // 位置不能写死 right：主题按钮右边还有「＋ 记录」，写死 right 会贴到窗口边上去。
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    nat.hydrate();

    check('T15 主题弹层没有底部说明文案', !doc.querySelector('#themePop .popover__foot'));

    const pos = (left, bottom, popW, viewW) =>
      win.eval(`popoverPos({left:${left},bottom:${bottom}}, ${popW}, ${viewW})`);
    check('T15 贴锚点左沿', pos(500, 80, 296, 1200).left === 500,
      `left = ${pos(500, 80, 296, 1200).left}`);
    check('T15 落在锚点下方 6px', pos(500, 80, 296, 1200).top === 86,
      `top = ${pos(500, 80, 296, 1200).top}`);
    check('T15 锚点太靠右时向左收，不越出窗口',
      pos(1000, 80, 296, 1200).left === 1200 - 296 - 12,
      `left = ${pos(1000, 80, 296, 1200).left}，期望 ${1200 - 296 - 12}`);
    check('T15 锚点太靠左时留出边距', pos(0, 80, 296, 1200).left === 12,
      `left = ${pos(0, 80, 296, 1200).left}`);

    const btn = doc.querySelector('#themeBtn');
    btn.click();
    const pop = doc.querySelector('#themePop');
    check('T15 点开后 aria-expanded 为 true', btn.getAttribute('aria-expanded') === 'true');
    check('T15 位置真的写进了样式（left/top 已设，right 归位 auto）',
      /px$/.test(pop.style.left) && /px$/.test(pop.style.top) && pop.style.right === 'auto',
      `left=${pop.style.left} top=${pop.style.top} right=${pop.style.right}`);
    btn.click();
    check('T15 再点一下关掉', !dlgOpen(doc, '#themePop')
      && btn.getAttribute('aria-expanded') === 'false');
    win.close();
  }

  // ---- T16：空状态文案要居中
  // 旧版是 `.empty{ padding:80px 0; text-align:center }`——水平靠 text-align 勉强算居中，
  // 垂直方向只是往下推 80px。而 .grid 是 flex 容器，不主动撑高就只有一行文字的高度。
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    nat.hydrate();
    win.eval('window.Shiju.hydrate([])');
    const grid = doc.querySelector('#grid');
    const cs = p => stateOf(win, `getComputedStyle(document.querySelector('#grid')).${p}`);

    check('T16 空状态给网格挂上 is-empty', grid.classList.contains('is-empty'));
    check('T16 两个方向都居中（flex + align + justify）',
      cs('display') === 'flex' && cs('alignItems') === 'center' && cs('justifyContent') === 'center',
      `display=${cs('display')} align=${cs('alignItems')} justify=${cs('justifyContent')}`);
    check('T16 空状态撑满内容区高度（不撑高就没法垂直居中）',
      cs('minHeight') === '100%', `min-height = ${cs('minHeight')}`);
    // 百分比是相对 .content 的内容盒算的，而它的上下内边距不对称（4 / 26），
    // 只给 100% 仍会偏上 11px，所以还要一条把下留白收平的规则。
    // 这条规则 jsdom 验不了效果（读不到布局），只能查源码里在不在；
    // 真实偏差由 Scripts/test-layout.sh 在 WebKit 里量——改回旧写法那条会红。
    check('T16 空状态时收平内容区下留白（否则百分比居中会偏上）',
      /\.content:has\(>\s*\.grid\.is-empty\)\s*\{[^}]*padding-bottom\s*:\s*4px/.test(html),
      'panel.html 里缺 .content:has(> .grid.is-empty){padding-bottom:4px}');
    check('T16 文案自身也居中',
      stateOf(win, "getComputedStyle(document.querySelector('#grid .empty')).textAlign") === 'center');

    // 反向：有内容时必须摘掉，否则卡片会被 flex 居中成竖排
    win.eval(`window.Shiju.hydrate([{id:'z', text:'有内容', kind:'page',
      capturedAt:${Date.now()}, ts:0, at:'刚刚', starred:false, tags:[]}])`);
    check('T16 有数据时摘掉 is-empty', !grid.classList.contains('is-empty'));
    win.close();
  }

  // ---- T17：快捷键设置的入口
  // 入口原先只挂在「右键菜单栏图标 → 快捷键设置…」里，用户反馈「没看到设置入口」——
  // 藏在一个要右键才出现、而且平时不会去点的地方。现在顶栏有个齿轮。
  // 这里锁的是「入口存在 + 点得动 + 发对了消息」，位置和观感交给 test-layout.sh。
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    nat.hydrate();

    const btn = doc.querySelector('#settingsBtn');
    check('T17 顶栏有快捷键设置入口', !!btn && !!btn.closest('.topbar'),
      btn ? '#settingsBtn 不在 .topbar 里' : '找不到 #settingsBtn');
    check('T17 入口是图标按钮（没有文字，不跟搜索框抢宽度）',
      !!btn && btn.classList.contains('btn--icon') && btn.textContent.trim() === '',
      btn ? `class="${btn.className}" text="${btn.textContent.trim()}"` : '');
    check('T17 入口有可读的名字（图标按钮没 title 就是个谜语）',
      !!btn && !!(btn.getAttribute('title') || btn.getAttribute('aria-label')),
      btn ? `title=${btn.getAttribute('title')} aria-label=${btn.getAttribute('aria-label')}` : '');
    check('T17 图标是 SVG 而不是文字字符（字号会跟着系统字体跑）',
      !!btn && !!btn.querySelector('svg'));
    // jsdom 读不到布局，所以这条查源码——跟 T16 处理 :has() 的做法一致。
    check('T17 图标按钮是方的（宽度对齐 .btn 的 28px 高）',
      /\.btn--icon\s*\{[^}]*width\s*:\s*28px/.test(html),
      'panel.html 里缺 .btn--icon{width:28px}：不写死宽度，一排按钮的基线会歪');

    const order = [...doc.querySelectorAll('.topbar > button')].map(b => b.id);
    check('T17 顶栏按钮顺序：设置 → 主题 → ＋记录（主操作留在最右）',
      order.join(',') === 'settingsBtn,themeBtn,addBtn', `实际 ${order.join(',')}`);

    const before = sent.length;
    btn.click();
    const out = sent.slice(before);
    check('T17 点一下给原生发 settings 消息', out.some(m => m.type === 'settings'),
      `实际发出 ${out.map(m => m.type).join(',') || '（一条都没有）'}`);
    check('T17 只发一条（点一下不该开两个窗口）',
      out.filter(m => m.type === 'settings').length === 1,
      `实际 ${out.filter(m => m.type === 'settings').length} 条`);
    win.close();
  }

  // ---- T18：元信息从卡片搬进详情弹窗
  // 用户原话：「每个卡片上的不需要显示来源和 icon 还有时间，这些都放在弹窗里面显示」。
  // 卡片是拿来扫读的——头上多一行元信息，正文就往后挪一行、一屏少一排卡片。
  // 但「这句哪儿来的」不能丢，只是挪进弹窗按需看。
  // 两条断言写法互补：查元素（精确）＋查卡片上的可见文字（换个类名重加回来也能抓到）。
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    nat.hydrate();
    const now = Date.now();
    win.eval(`window.Shiju.hydrate([
      {id:'m1', text:'卡片上只留正文和标签。', app:'Safari', title:'《测试标题》', kind:'page',
       capturedAt:${now}, ts:60000, at:'7 分钟前', starred:false, tags:['标签甲']},
      {id:'m2', text:'没出处、没星标，卡片上什么都不该多出来。', app:'Terminal', kind:'terminal',
       capturedAt:${now}, ts:0, at:'8 分钟前', starred:false, tags:[]},
      {id:'m3', text:'加了星标的。', app:'Safari', title:'《另一本》', kind:'page',
       capturedAt:${now}, ts:0, at:'9 分钟前', starred:true, tags:[]}
    ])`);

    const card = id => cardById(doc, id)[0];
    const textOf = id => (card(id) ? card(id).textContent : '');

    check('T18 卡片上读不到来源名', !!card('m1') && !textOf('m1').includes('Safari'),
      `卡片文字里出现了「Safari」：${textOf('m1')}`);
    check('T18 卡片上读不到时间', !!card('m1') && !textOf('m1').includes('7 分钟前'),
      `卡片文字里出现了「7 分钟前」：${textOf('m1')}`);
    check('T18 卡片上读不到来源徽标', doc.querySelectorAll('#grid .card .badge').length === 0,
      `还剩 ${doc.querySelectorAll('#grid .card .badge').length} 个 .badge`);
    check('T18 卡片上读不到来源名元素（.src）', doc.querySelectorAll('#grid .card .src').length === 0,
      `还剩 ${doc.querySelectorAll('#grid .card .src').length} 个 .src`);
    // 用户后来又改了口：「卡片上的出处先删除」。所以卡片上现在只剩正文和标签。
    check('T18 卡片上连出处也没有了', !!card('m1') && !textOf('m1').includes('《测试标题》'),
      `卡片文字：${textOf('m1')}`);
    // 要「整块撤掉」，不是「留个空容器」——容器自带的 padding-bottom
    // 会在正文上方留下一段没有来由的空白。
    check('T18 头部容器整个撤掉了（不是留个空容器）',
      !!card('m1') && !card('m1').querySelector('.card__head'),
      'm1 上还挂着 .card__head');
    check('T18 源码里已经没有 .card__head 了（别留死规则）',
      !/\.card__head\s*\{/.test(html), 'panel.html 里还有 .card__head 的样式');

    // 星标是用户自己按下的状态，藏起来等于丢了反馈，所以必须还在卡片上——
    // 但它不能占一行（占一行的话有星标的卡片正文会比旁边低 23px）。
    check('T18 星标还在卡片上（换成了右上角的角标）',
      !!card('m3') && !!card('m3').querySelector('.card__star'),
      card('m3') ? 'm3 上没有 .card__star' : '找不到 m3');
    check('T18 星标是卡片的直接子元素（不占布局，才不会把正文挤下去）',
      !!card('m3') && card('m3').querySelector('.card__star').parentElement === card('m3'),
      '星标被塞进了某个容器里，那就会占一行');
    check('T18 没星标的卡片没有角标',
      !!card('m1') && !card('m1').querySelector('.card__star'));
    // 正文两端对齐、会一直写到内容盒右沿，不让位就会和 ★ 叠在一起
    check('T18 有星标的卡片把右边留宽了',
      !!card('m3') && card('m3').getAttribute('data-star') === '1'
        && /\.card\[data-star="1"\]\s*\{[^}]*--star-w/.test(html),
      '缺 data-star="1" 或 --star-w 那条规则');

    // 列表视图的 meta 行同理：只剩「出处 + 字数 + 标签」
    doc.querySelector('.seg button[data-view="list"]').click();
    const meta = card('m1').querySelector('.card__meta');
    check('T18 列表视图的 meta 行还在（出处/字数/标签留着）', !!meta);
    check('T18 列表视图的 meta 行也没有来源与时间',
      !!meta && !meta.querySelector('.badge') && !meta.querySelector('.src')
        && !meta.querySelector('.when') && !meta.textContent.includes('7 分钟前'),
      meta ? `meta 文字：${meta.textContent}` : '');
    check('T18 列表视图的 meta 行仍带标签', !!meta && !!meta.querySelector('.tag'));
    // 「字数」前那个分隔点必须只在它前面真有东西时才画。撤掉来源徽标之后，
    // 「灵感」这类没有出处标题的卡片会以字数打头，固定加点就渲染出「· 12 字」。
    // jsdom 读不到 ::before 的内容（getComputedStyle 的伪元素参数被忽略），
    // 所以这条跟 T16 一样查源码。
    check('T18 字数前的分隔点改成条件渲染（否则会冒出没有前文的「·」）',
      /\.card__meta\s+\.count:not\(:first-child\)::before/.test(html),
      'panel.html 里缺 .card__meta .count:not(:first-child)::before');

    // 换回卡片视图，开详情弹窗——被撤掉的元信息必须在这里全部找得到
    doc.querySelector('.seg button[data-view="grid"]').click();
    openCard(doc, 'm1');
    const body = doc.querySelector('#sheetBody');
    const rows = {};
    if (body) body.querySelectorAll('dt').forEach(dt => { rows[dt.textContent.trim()] = dt.nextElementSibling; });
    check('T18 弹窗里有「来源」行，且带上了徽标',
      !!rows['来源'] && !!rows['来源'].querySelector('.badge') && !!rows['来源'].querySelector('.src'),
      rows['来源'] ? `来源行 HTML：${rows['来源'].innerHTML}` : '没有「来源」行');
    // 注意读的是 .src 的文本，不是整行的 textContent——徽标里那个「S」
    // 也是文本，整行拼起来是「SSafari」。
    check('T18 来源行的名字就是应用名',
      !!rows['来源'] && !!rows['来源'].querySelector('.src')
        && rows['来源'].querySelector('.src').textContent.trim() === 'Safari',
      rows['来源'] ? `来源行文字：${rows['来源'].textContent}` : '');
    check('T18 弹窗里有「时间」行，值还在',
      !!rows['时间'] && rows['时间'].textContent.includes('7 分钟前'),
      rows['时间'] ? rows['时间'].textContent : '没有「时间」行');
    check('T18 弹窗里还有「出处」和「链接」', !!rows['出处'] && !!rows['链接']);
    check('T18 弹窗里不再出现 id', !!body && !body.textContent.includes('m1'),
      `弹窗文字里出现了 id：${body ? body.textContent : ''}`);
    check('T18 字数那行还在（只是不再拖着 id）',
      !!rows['字数'] && /^\d+\s*字$/.test(rows['字数'].textContent.trim()),
      rows['字数'] ? `「字数」行是「${rows['字数'].textContent.trim()}」` : '没有「字数」行');
    win.close();
  }

  // ---- T19：来源识别与徽标配色
  // 用户的原话：「卡片详情的来源 icon 是不是可以有点颜色」。
  // 查下来不是「配色不够艳」，而是**徽标压根没上色**：
  // source_app 存的是 NSRunningApplication.localizedName（Capture.swift），
  // 实测是「Google Chrome」「微信」「终端」「备忘录」「Xcode」；
  // 而面板的映射表键写的是 Chrome / WeChat / Notes / Terminal / Code 这种短名，
  // 于是**除了 Safari 之外一个都对不上**，全部落到 var(--color-text-3) 的灰底兜底。
  // 真实库里 9 条 Chrome + 1 条微信，两条都是灰的。
  //
  // 所以这里锁两件事：① 按关键词认（不是按精确键认）；② 认不出来也要有颜色。
  {
    const { win, doc, sent } = open({});
    const nat = nativeSide(win, sent);
    nat.hydrate();

    // 直接调渲染函数：比开弹窗快，出错时也能直接指出是哪一条名字没认出来
    const srcOf = o => stateOf(win, `sourceOf(${JSON.stringify(o)}).html`);
    const brand = o => {
      const s = srcOf(o);
      if (/data-brand="([^"]+)"/.test(s)) return /data-brand="([^"]+)"/.exec(s)[1];
      return /--badge-h:/.test(s) ? '(散列色)' : '(无标记)';
    };
    const page = app => ({ app, kind: 'page' });

    check('T19 「Google Chrome」认得出是 Chrome（真实库里就是这么存的）',
      brand(page('Google Chrome')) === 'chrome', `实际 ${brand(page('Google Chrome'))}`);
    check('T19 「Chrome」也认得出（样例数据用的是短名）',
      brand(page('Chrome')) === 'chrome', `实际 ${brand(page('Chrome'))}`);
    check('T19 「微信」认得出', brand(page('微信')) === 'wechat', `实际 ${brand(page('微信'))}`);
    check('T19 「WeChat」也认得出（大小写不敏感）',
      brand(page('wechat')) === 'wechat', `实际 ${brand(page('wechat'))}`);
    check('T19 「终端」认得出', brand(page('终端')) === 'terminal', `实际 ${brand(page('终端'))}`);
    check('T19 「备忘录」认得出', brand(page('备忘录')) === 'notes', `实际 ${brand(page('备忘录'))}`);
    check('T19 「Xcode」认得出', brand(page('Xcode')) === 'code', `实际 ${brand(page('Xcode'))}`);
    check('T19 「Safari」认得出', brand(page('Safari')) === 'safari', `实际 ${brand(page('Safari'))}`);

    // 认不出来的应用：给一个稳定的散列色相，而不是灰底
    check('T19 认不出的应用也有颜色（走散列色相，不是灰底）',
      brand(page('Zed')) === '(散列色)', `实际 ${brand(page('Zed'))}`);
    const hue = a => stateOf(win, `hueOf(${JSON.stringify(a)})`);
    check('T19 同一个应用每次色相一样（所以认得出来）', hue('Zed') === hue('Zed'));
    check('T19 不同应用的色相不一样', hue('Zed') !== hue('Nova'), `${hue('Zed')} vs ${hue('Nova')}`);
    check('T19 色相落在 0–359', [hue('Zed'), hue('Nova'), hue('微信')]
      .every(h => Number.isInteger(h) && h >= 0 && h < 360),
      `${hue('Zed')} / ${hue('Nova')} / ${hue('微信')}`);
    check('T19 徽标底色不再是无条件的灰（源码里走 --badge-h）',
      /\.badge\s*\{[^}]*background:\s*hsl\(var\(--badge-h/.test(html),
      'panel.html 的 .badge 里缺 hsl(var(--badge-h …))：认不出的应用还是灰的');

    // 灵感不是「某个应用」，是你自己写下来的：走强调色浅底。
    // 关键在这条选择器挂在徽标**自己**身上——早先写的是 `[data-kind="idea"] .badge`，
    // 而详情弹窗里没有 [data-kind] 祖先，那种写法在弹窗里会静默退回灰底。
    check('T19 灵感走强调色标记',
      brand({ app: '', kind: 'idea' }) === 'idea', `实际 ${brand({ app: '', kind: 'idea' })}`);
    // 注意断言要带上 `\s*\{`：注释里为了说明「不要这么写」会把旧选择器原文抄一遍，
    // 只匹配选择器本身的话，注释也会被当成规则（这条一开始就是这么误报的）。
    check('T19 灵感的选择器挂在徽标自己身上（不靠 [data-kind] 祖先）',
      /\.badge\[data-brand="idea"\]\s*\{/.test(html)
        && !/\[data-kind="idea"\]\s+\.badge\s*\{/.test(html),
      'panel.html 里还有 [data-kind="idea"] .badge 规则 —— 弹窗里没有那个祖先，会静默退回灰底');

    // 集成：真开一次弹窗，看 DOM 里的徽标是不是带着标记
    win.eval(`window.Shiju.hydrate([{id:'c1', text:'从 Chrome 里复制的。',
      app:'Google Chrome', title:'《测试》', kind:'page',
      capturedAt:${Date.now()}, ts:0, at:'刚刚', starred:false, tags:[]}])`);
    openCard(doc, 'c1');
    const b = doc.querySelector('#sheetBody .srcpair .badge');
    check('T19 弹窗里的徽标带着品牌标记',
      !!b && b.getAttribute('data-brand') === 'chrome',
      b ? `data-brand=${b.getAttribute('data-brand')}` : '找不到 .srcpair .badge');
    check('T19 弹窗里的来源名是原始应用名（「Google Chrome」而不是「Chrome」）',
      (doc.querySelector('#sheetBody .srcpair .src') || {}).textContent === 'Google Chrome',
      (doc.querySelector('#sheetBody .srcpair .src') || {}).textContent);
    win.close();
  }

  doms.forEach(d => { try { d.window.close(); } catch (_) {} });
  return { passed, failed, lines: lines.slice() };
}

// ---------------------------------------------------------------- 主流程

const html = readFileSync(PANEL, 'utf8');

console.log(`\n\x1b[1m面板契约测试\x1b[0m  ${PANEL}\n`);
const main = suite(html, 'main');
console.log(`\x1b[1m主用例\x1b[0m`);
console.log(main.lines.join('\n'));
console.log(`\n  ${main.passed} 通过 / ${main.failed} 失败`);

let selfcheckOK = true;
if (process.argv.includes('--selfcheck')) {
  // 每个已修的 bug 都要能被断言抓住，所以这里把它们逐个改回去：
  //   (a) 「＋ 记录」落库后忘了 return，于是既回传原生、又自己本地插一次
  //       → 界面上多出一张带本地假 id 的孤儿卡片（T1 的两条断言会红）
  //   (b) 卡片上的「删除」绕过确认框直接删
  //       → 手滑点一下就永久没了（T7 的「只弹框不删」三条会红）
  //   (c) 顶栏拖动不区分「空白处」和「控件上」
  //       少了这道闸，点顶栏上的按钮也会变成拖窗口（T6 会红）
  //   (d) 新建态又把「N 字 · N 行 + ⌘↵ 保存 · Esc 取消」加回去
  //       → 打开弹窗先看到「0 字 · 1 行」（T10 三条会红）
  //   (e) 关闭按钮挪回卡片内右上角
  //       → 「悬在卡片上沿之外」这条会红
  //   (f) dialog 自己又去裁内容（overflow 从 visible 改回 auto）
  //       → 外置的关闭按钮会被裁掉，「dialog 不裁内容」这条会红
  //   (g) 网格又封上宽度上限
  //       → 拖宽时列数算得再对也用不上（T12 的 max-width 断言会红）
  //   (h) 标签不再限数
  //       → 标签一多就把底栏的按钮挤到第二行（T13 三条会红）
  //   (i) visible() 不再按标签过滤
  //       → 选了标签但列表没变（T14 三条会红）
  //   (j) 弹层定位不再做右侧夹取
  //       → 窄面板时按钮靠右，弹层会被推出窗口（T15 一条会红）
  //   (k) 去掉 .chip[hidden] 这条规则
  //       → hidden 设了也没用（.chip 的 display 会盖掉 UA 样式），空入口一直杵着
  //   (l) 空状态撑高改回旧写法（视口高减常数）
  //       → 那个常数得同时盯着筛选栏高度和内边距，实测偏上 18px（T16 一条会红）
  //   (m) 去掉空状态下收平下留白那条规则
  //       → 内容盒上下不对称，百分比居中仍会偏上 11px（T16 一条会红）
  //   (n) 顶栏齿轮不再发 settings 消息
  //       → 点了没反应，快捷键设置又变成找不到（T17 两条会红）
  //   (o) 卡片头部又整个长回来（出处 + 来源徽标 + 来源名 + 时间）
  //       → 用户特意要求撤掉的那几样又占着卡片头部（T18 前六条会红）
  //   (p) 有星标的卡片不再给角标让位
  //       → 正文两端对齐会一直写到右沿，和 ★ 叠在一起（T18 一条会红）
  //   (q) 字数前面又无条件加点
  //       → 「灵感」这类没有出处标题的卡片会以「· 12 字」开头（T18 一条会红）
  //   (r) 详情弹窗的「来源」行又退回纯文本（徽标丢了）
  //       → 用户说 icon 也放弹窗里，丢了就等于哪儿都看不到（T18 一条会红）
  //   (s) 详情弹窗底部又把 id 挂回字数后面
  //       → 用户特意要求去掉的那串东西（T18 两条会红）
  //   (t) 来源识别退回「精确键」而不是「关键词」
  //       → source_app 存的是 localizedName（「Google Chrome」），
  //         精确键认不出来，真实库里 9/10 条的徽标会变回灰色（T19 一条会红）
  //   (u) 徽标底色退回无条件的灰
  //       → 认不出来的应用（以及所有匹配不上的）全灰，就是用户抱怨的那件事（T19 一条会红）
  //   (v) 灵感的选择器退回依赖 [data-kind] 祖先
  //       → 详情弹窗里没有那个祖先，灵感徽标静默退回灰底（T19 一条会红）
  const mutations = [
    ['  if (bridge(\'capture\', { text, tags, title, url })) return;\n',
      '  bridge(\'capture\', { text, tags, title, url });\n'],
    ['    if (act.dataset.act === \'del\') remove(x.id);\n',
      '    if (act.dataset.act === \'del\'){ pendingDelete = x.id; commitDelete(); }\n'],
    ['    if (e.target.closest(\'button, input, label, a\')) return;   // 控件自己处理\n', ''],
    ['    ${foot}\n',
      '    <div class="edit__foot"><span id="edCount"></span>'
      + '<span class="tip"><code>⌘↵</code> 保存 · <code>Esc</code> 取消</span></div>\n'],
    ['  position:absolute; top:-34px; right:0;\n',
      '  position:absolute; top:11px; right:11px;\n'],
    ['  overflow:visible;\n', '  overflow:auto;\n'],
    ['  margin: 0 auto;\n  display:flex; gap: var(--gap-grid); align-items:flex-start;\n',
      '  max-width: 1160px;\n  margin: 0 auto;\n  display:flex; gap: var(--gap-grid); align-items:flex-start;\n'],
    ['  const maxTags = isList ? 3 : (lastCols >= 4 ? 1 : lastCols >= 3 ? 2 : 3);\n',
      '  const maxTags = 99;\n'],
    ['    // 标签筛选是精确匹配（必须真带这个标签），和下面 q 的全文模糊匹配是两件事\n'
      + '    if (state.tagFilter && !(x.tags||[]).includes(state.tagFilter)) return false;\n', ''],
    ['    left: Math.max(margin, Math.min(anchor.left, viewW - popW - margin)),\n',
      '    left: Math.max(margin, anchor.left),\n'],
    // (k) 去掉 .chip[hidden] 这条：hidden 属性设了，但 .chip 的 display 会盖掉它
    ['\n.chip[hidden]{ display:none; }', ''],
    // (l) 空状态撑高改回旧写法（用视口高减常数）：那个常数得同时盯着筛选栏高度
    //     和 .content 的上下内边距，改一处忘一处就会偏——实测偏上 18px
    ['  min-height: 100%;\n',
      '  min-height: calc(100vh - var(--h-topbar-total) - 76px);\n'],
    // (m) 去掉「空状态时收平下留白」：内容盒上下不再对称，百分比居中仍会偏上 11px
    ['\n.content:has(> .grid.is-empty){ padding-bottom: 4px; }', ''],
    // (n) 齿轮不再发消息：入口还在、还看得见，但点了没反应——最难查的一种坏法
    ["$('#settingsBtn').onclick = () => bridge('settings');\n", ''],
    // (o) 卡片头部整个长回来（出处 + 徽标 + 来源名 + 时间）
    ['${starMark}${inner}\n',
      '${starMark}    <div class="card__head">\n'
      + '      <div class="head__row"><span class="badge" data-brand="chrome">C</span>'
      + '<span class="src">Chrome</span><span class="when">刚刚</span></div>\n'
      + '      ${t0 ? `<div class="head__row"><span class="card__title">${hl(t0)}</span></div>` : \'\'}\n'
      + '    </div>\n${inner}\n'],
    // (p) 有星标也不给角标让位：正文会和 ★ 叠在一起
    ["${x.starred ? ' data-star=\"1\"' : ''}", ''],
    // (q) 字数前无条件加点
    ['.grid.list .card__meta .count:not(:first-child)::before{',
      '.grid.list .card__meta .count::before{'],
    // (r) 弹窗「来源」行退回纯文本
    ['<dt>来源</dt><dd><span class="srcpair">${sourceOf(x).html}</span></dd>',
      '<dt>来源</dt><dd>${esc(sourceOf(x).name)}</dd>'],
    // (s) 弹窗底部又把 id 挂回去
    ['    <dt>字数</dt><dd>${(x.text||\'\').length} 字</dd>`;',
      '    <dt>字数</dt><dd>${(x.text||\'\').length} 字 · id ${esc(x.id)}</dd>`;'],
    // (t) 来源识别退回精确键（真实库里存的是 localizedName，认不出来）
    ['  const hit = raw ? SOURCES.find(s => s.names.some(n => lower.includes(n))) : null;\n',
      '  const hit = raw ? SOURCES.find(s => s.names.includes(lower)) : null;\n'],
    // (u) 徽标底色退回无条件的灰
    ['  background: hsl(var(--badge-h, 220) 42% 46%);\n',
      '  background: var(--color-text-3);\n'],
    // (v) 灵感选择器退回依赖祖先
    ['.badge[data-brand="idea"]{', '[data-kind="idea"] .badge{'],
  ];
  let buggy = html, applied = 0;
  for (const [from, to] of mutations) {
    if (buggy.includes(from)) { buggy = buggy.replace(from, to); applied++; }
  }

  if (applied !== mutations.length) {
    console.log(`\n\x1b[33m! 自检只注入了 ${applied}/${mutations.length} 处 bug（锚点没找到），跳过\x1b[0m`);
    selfcheckOK = false;
  } else {
    const sc = suite(buggy, 'selfcheck');
    console.log(`\n\x1b[1m自检：把已修的 bug 改回去（${applied} 处）\x1b[0m`);
    console.log(sc.lines.join('\n'));
    console.log(`\n  ${sc.passed} 通过 / ${sc.failed} 失败`);
    selfcheckOK = sc.failed > 0;
    console.log(selfcheckOK
      ? '\n  \x1b[32m✓ 断言有牙齿：改回 bug 后确实变红\x1b[0m'
      : '\n  \x1b[31m✗ 断言没有牙齿：bug 改回去也照样全绿\x1b[0m');
  }
}

console.log('');
process.exit(main.failed === 0 && selfcheckOK ? 0 : 1);
