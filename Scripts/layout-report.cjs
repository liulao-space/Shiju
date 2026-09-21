#!/usr/bin/env node
/* 把布局探针（Tests/layout-probe.js）返回的 JSON 汇总成可读报告。
 * 从 stdin 读一行 JSON，按 --width 标注是哪一档宽度。
 * 有失败项时以非零码退出，好让 Scripts/test-layout.sh 能判定。 */
'use strict';

const width = (() => {
  const i = process.argv.indexOf('--width');
  return i >= 0 ? process.argv[i + 1] : '?';
})();

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => { raw += c; });
process.stdin.on('end', () => {
  let data;
  try {
    data = JSON.parse(raw.trim());
  } catch (e) {
    console.error(`  ✗ 探针没有返回可解析的 JSON：${raw.slice(0, 300)}`);
    process.exit(1);
  }

  let failed = 0;
  for (const c of data.checks || []) {
    if (c.ok) {
      console.log(`  ✓ ${c.n}`);
    } else {
      failed++;
      console.log(`  ✗ ${c.n}`);
      if (c.d) console.log(`      → ${c.d}`);
    }
  }

  const total = (data.checks || []).length;
  console.log(`  ${total - failed} 通过 / ${failed} 失败` + (failed ? '' : `   （视口 ${data.viewport.w}×${data.viewport.h}）`));
  process.exit(failed ? 1 : 0);
});
