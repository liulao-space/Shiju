/* 用压测数据渲染面板，并强制显示操作按钮——给 Scripts/snapshot-panel.sh 用。
   数据在 Tests/snapshot-fixtures.js 里（探针也用同一份）。 */
window.SNAP.reset();
window.SNAP.forceHover();
Shiju.hydrate(window.SNAP.tagsRows);
'ok';
