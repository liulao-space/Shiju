/* 详情弹窗「来源」徽标的配色样例。
 *
 * 为什么要专门造这份数据：panel.html 里那份 SEED 用的是短名
 * （'Safari' / 'WeChat' / 'Terminal' / 'Notes'），而**真实库里存的是
 * `NSRunningApplication.localizedName`**（见 Capture.swift）：
 * 「Google Chrome」「微信」「终端」「备忘录」「Xcode」。
 * 面板早先的映射表键写的是短名，于是除了 Safari 全都认不出来、
 * 徽标一律灰底 —— 而样例数据恰好全都能对上，截图上看不出任何问题。
 *
 * 所以这份数据刻意用**真名**，再加两条「认不出来的应用」。
 */
window.SRC = (() => {
  const now = Date.now();
  const rows = [
    { id:'s1', text:'从 Chrome 里复制的，徽标该是 Chrome 的青色。',
      app:'Google Chrome', title:'《浏览器来源》', kind:'page',
      capturedAt: now, ts:0, at:'刚刚', tags:['摘录'] },
    { id:'s2', text:'微信里摘的，徽标该是微信的绿。',
      app:'微信', title:'《群聊》', kind:'chat',
      capturedAt: now, ts:60e3, at:'1 分钟前', tags:['摘录'] },
    { id:'s3', text:'终端里复制的，徽标是深灰的 $_。',
      app:'终端', title:'', kind:'terminal',
      capturedAt: now, ts:120e3, at:'2 分钟前', tags:[] },
    { id:'s4', text:'脑子里蹦出来的一句，徽标走强调色的浅底。',
      app:'', title:'', kind:'idea',
      capturedAt: now, ts:180e3, at:'3 分钟前', tags:['灵感'] },
    { id:'s5', text:'没登记过的应用，徽标按名字散列出一个稳定色。',
      app:'Zed', title:'《编辑器》', kind:'page',
      capturedAt: now, ts:240e3, at:'4 分钟前', tags:[] },
  ];
  const open = id => {
    Shiju.hydrate(rows);
    const c = document.querySelector('#grid .card[data-id="' + id + '"]');
    if (c) c.click();
  };
  return { rows, open };
})();
