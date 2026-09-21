/* 截图与布局探针共用的样例数据 / 小工具。
   用 --js-file 传，可以在它后面再接一个 --js-file（会按顺序拼接）。 */
window.SNAP = (() => {
  /* localStorage 在 file:// 下可能被上一次运行留下改动（applyEdits 会读它），
     清掉才能保证每次截图/探针看到的是同一份数据。 */
  const reset = () => { try { localStorage.clear(); } catch (_) {} };

  /* 操作按钮平时 opacity:0（hover 才出）。截图里看不到就等于没验证，
     所以提供一个「扮演 hover」的开关——只改可见性，不动布局。
     探针不需要它：opacity:0 的元素照样有几何。 */
  const forceHover = () => {
    const s = document.createElement('style');
    s.id = '__force_hover';
    s.textContent = '.card .acts, .card .card__foot{ opacity:1 !important; }';
    document.head.appendChild(s);
  };

  /* 标签底栏的压测数据：真实 SEED 里每条最多 2 个标签，而且「灵感」会被过滤掉，
     所以 `+N` 那个分支从来没被画出来过——「标签多了会不会挤坏按钮」也就无从验证。
     这里造几条极端数据：5 标签 / 1 个超长标签 / 2 标签 / 0 标签 / 7 标签 / 正文很长。 */
  const tagsRows = [
    { id:'t1', text:'五个标签，看看底栏怎么收。', app:'Safari', title:'《测试》', kind:'page',
      at:'刚刚', ts:0,
      tags:['王小波','沉默的大多数','读后感','2026 读书计划','杂文'] },

    { id:'t2', text:'只有一个标签，但那标签特别长，长到必须打省略号。', app:'Notes', kind:'note',
      at:'5 分钟前', ts:5*60e3,
      tags:['这是一个非常非常长的标签名字用来测试省略号'] },

    { id:'t3', text:'两个短标签。', app:'WeChat', kind:'chat', at:'10 分钟前', ts:10*60e3,
      tags:['短','也短'] },

    { id:'t4', text:'没有标签，底栏只剩时间。', app:'Terminal', kind:'terminal',
      at:'20 分钟前', ts:20*60e3 },

    { id:'t5', text:'标签多到数不过来，用来确认 +N 里的数字是对的。', app:'Safari',
      title:'《再多一点》', kind:'page', at:'30 分钟前', ts:30*60e3,
      tags:['甲','乙','丙','丁','戊','己','庚'] },

    { id:'t6', text:'正文很长很长，用来把卡片撑高，看看高度不同时底栏是不是都稳。生活不能等待别人来安排，要自己去争取和奋斗；不论其结果是喜是悲，但可以慰藉的是，你总不枉在这世界上活了一场。',
      app:'WeChat', title:'《平凡的世界》', kind:'chat', at:'1 小时前', ts:3600e3,
      tags:['路遥','长篇','摘抄'] },
  ];

  return { reset, forceHover, tagsRows };
})();
