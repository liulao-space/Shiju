/* README「主题」那张拼图用的样例数据。
 *
 * 为什么不复用 Tests/snapshot-fixtures.js 里那份 SEED：那是 14 条、按面板真实
 * 数据量造的，在这个尺寸（520pt 宽 → 1 列）下会排成很长一列，四张拼起来太高，
 * 放进 README 会把页面撑开一大截。这里只留 4 条。
 *
 * 4 条刻意**每种来源各来一条**（浏览器 / 终端 / 灵感 / 微信）。原因是：
 * 主题之间最容易被忽略的差异不是底色，而是**徽标和强调色**——
 * 只放一堆「网页」的话，四种主题看上去会差不多。
 */
window.THEME_DEMO = (() => {
  const rows = [
    { id:'th1', text:'我们最终拥有的，只有我们记住的。', app:'Safari',
      title:'《永恒之间》', kind:'page', at:'刚刚', ts:0, tags:['书'] },

    { id:'th2', text:'git log --author="me" --since=1.week',
      app:'终端', kind:'terminal', at:'1 小时前', ts:3600e3, tags:['命令'] },

    { id:'th3', text:'脑子里蹦出来的一句，也得有地方放。', app:'',
      kind:'idea', at:'3 小时前', ts:3*3600e3, tags:['灵感'] },

    { id:'th4', text:'人间送小温。', app:'Google Chrome',
      title:'《受戒》· 汪曾祺', kind:'page', at:'昨天', ts:26*3600e3,
      starred:true, tags:['句子'] },
  ];

  /* 切主题。
   *
   * 两件不能省的事：
   *   1. 先 reset()。localStorage 里会留着上一次运行选的主题（applyTheme 会写它），
   *      不清的话第二次跑出来的图和第一次不一样。
   *   2. **第二个参数必须显式传 false**。applyTheme 的签名是
   *      `(key, notify)`，里面写的是 `if (notify !== false) bridge('setTheme', …)`
   *      —— 不传就是 undefined，undefined !== false 成立，于是它会去调 bridge。
   *      而截图工具里**没有注册那个 messageHandler**，这一步会抛异常，
   *      整个注入脚本失败，出来的是一张「数据没进去」的空图。
   */
  const apply = key => {
    window.SNAP.reset();
    Shiju.hydrate(rows);
    applyTheme(key, false);
  };

  return { rows, apply };
})();
