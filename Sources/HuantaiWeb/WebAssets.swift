import Foundation

enum WebAssets {
    static let html = #"""
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <meta name="huantai-csrf" content="__CSRF_TOKEN__">
          <title>换台 · 会话详情</title>
          <link rel="stylesheet" href="/assets/app.css">
          <script defer src="/assets/model.js"></script>
          <script defer src="/assets/app.js"></script>
        </head>
        <body>
          <svg class="symbols" aria-hidden="true" xmlns="http://www.w3.org/2000/svg">
            <symbol id="search-icon" viewBox="0 0 24 24"><circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 4.5 4.5"/></symbol>
            <symbol id="star-icon" viewBox="0 0 24 24"><path d="m12 3 2.8 5.7 6.3.9-4.6 4.5 1.1 6.3-5.6-3-5.6 3 1.1-6.3L2.9 9.6l6.3-.9Z"/></symbol>
            <symbol id="refresh-icon" viewBox="0 0 24 24"><path d="M20 7v5h-5M4 17v-5h5M19 12a7 7 0 0 0-12-5L4 10M5 12a7 7 0 0 0 12 5l3-3"/></symbol>
          </svg>
          <main class="app">
            <header class="toolbar">
              <div class="brand"><span class="brand-mark" aria-hidden="true">↔</span><h1>换台</h1><span class="local-badge">本机详情</span></div>
              <div class="tools">
                <button class="icon-button" id="search-toggle" aria-label="展开搜索" aria-expanded="false" title="搜索会话"><svg><use href="#search-icon"/></svg></button>
                <button class="icon-button selected" id="favorites-toggle" aria-label="只看收藏" aria-pressed="true" title="只看收藏"><svg><use href="#star-icon"/></svg></button>
                <button class="icon-button" id="refresh" aria-label="刷新索引" title="刷新索引"><svg><use href="#refresh-icon"/></svg></button>
                <select id="theme" aria-label="外观主题"><option value="system">跟随系统</option><option value="light">浅色</option><option value="dark">深色</option></select>
              </div>
            </header>
            <section class="usage" aria-label="周额度">
              <div class="usage-heading"><span>周额度</span><div class="quota-values"><strong id="usage-value">未连接</strong><span id="today-reference" class="muted">今日参考未连接</span></div><span id="usage-source" class="muted"></span></div>
              <div id="usage-bar" class="progress unavailable" role="progressbar" aria-label="周剩余百分比" aria-valuemin="0" aria-valuemax="100">
                <span id="green-segment" class="segment green"></span><span id="red-segment" class="segment red"></span>
                <span id="budget-mark" class="marker budget" hidden></span>
              </div>
              <div class="usage-notes"><span id="usage-note" class="muted">等待真实用量来源</span><span id="reset-count">重置时间未连接</span></div>
              <div id="reset-credits" class="reset-credits" aria-label="额度重置卡"></div>
            </section>
            <div id="search-area" class="search-area" hidden><input id="query" type="search" autocomplete="off" placeholder="搜索标题或工作目录" aria-label="搜索标题或工作目录"><button id="clear-search" class="text-button">清除</button></div>
            <details class="web-settings"><summary>筛选与排序设置 <span id="filter-summary" class="muted">全部来源 · 全部设备</span></summary>
              <div class="settings-grid">
                <label>来源<select id="source-filter" aria-label="筛选会话来源"><option value="">全部来源</option></select></label>
                <label>设备<select id="machine-filter" aria-label="筛选设备"><option value="">全部设备</option></select></label>
                <label>任务状态<select id="status-filter" aria-label="筛选任务状态"><option value="pending">未完成</option><option value="completed">已完成</option><option value="all">全部状态</option></select></label>
                <label>排序<select id="sort" aria-label="会话排序"><option value="recent">最近 AI 回复</option><option value="favorite">收藏优先</option></select></label>
              </div>
              <div class="settings-note"><span>排序偏好保存在当前浏览器，App 与 CLI 使用各自入口的排序。</span><button id="clear-filters" class="text-button">清除来源与设备筛选</button></div>
            </details>
            <div class="list-summary"><span id="count" class="muted">正在读取索引…</span><span id="updated" class="muted"></span></div>
            <div id="error" class="error" role="alert" hidden></div>
            <section id="sessions" class="sessions" aria-label="会话列表" aria-live="polite"></section>
            <div id="empty" class="empty" hidden><span class="empty-symbol" aria-hidden="true">⌘</span><strong id="empty-title"></strong><p id="empty-message"></p></div>
            <details class="source-details"><summary>来源与账户连接状态</summary>
              <div class="connection-grid"><section><h2>会话来源</h2><div id="source-status"></div></section><section><h2>账户与用量</h2><dl id="usage-details" class="metadata"></dl></section></div>
              <p class="privacy-note">仅本机访问。页面使用会话标题、工作目录和回复时间，不展示消息正文。</p>
            </details>
            <footer><span id="ordering-note">全部设备 · 按 AI 最后回复时间排序</span><code>ht</code></footer>
          </main>
        </body>
        </html>
        """#

    static let css = #"""
        :root { color-scheme: light dark; --bg:#f4f5f8; --panel:#fff; --text:#222631; --muted:#79808e; --line:#e9ebf0; --hover:#f5f6f9; --chip:#f0f2f5; --accent:#edab38; --green:#37ac79; --red:#e86160; --shadow:0 12px 50px #2832470c; }
        @media(prefers-color-scheme:dark) { :root:not([data-theme="light"]) { --bg:#111319; --panel:#1c1f27; --text:#edf0f5; --muted:#8e96a6; --line:#2e333f; --hover:#242833; --chip:#2a2f3b; --green:#45ba87; --red:#f07470; --shadow:0 12px 50px #0003; } }
        :root[data-theme="dark"] { color-scheme:dark; --bg:#111319; --panel:#1c1f27; --text:#edf0f5; --muted:#8e96a6; --line:#2e333f; --hover:#242833; --chip:#2a2f3b; --green:#45ba87; --red:#f07470; --shadow:0 12px 50px #0003; }
        :root[data-theme="light"] { color-scheme:light; }
        * { box-sizing:border-box; }
        body { margin:0; background:var(--bg); color:var(--text); font:14px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC",sans-serif; }
        button,input,select { font:inherit; }
        button,select { cursor:pointer; }
        button { color:var(--text); }
        button:focus-visible,a:focus-visible,input:focus-visible,select:focus-visible,summary:focus-visible { outline:2px solid var(--accent); outline-offset:3px; }
        [hidden],.symbols { display:none !important; }
        .app { max-width:1000px; margin:32px auto; padding:20px 28px 12px; background:var(--panel); border:1px solid var(--line); border-radius:18px; box-shadow:var(--shadow); }
        .toolbar { display:flex; align-items:center; gap:16px; justify-content:space-between; min-height:32px; margin-bottom:18px; }
        .brand,.tools { display:flex; gap:8px; align-items:center; }
        .brand { flex-shrink:0; }
        h1 { font-size:16px; font-weight:650; margin:0; letter-spacing:.06em; }
        .brand-mark { color:var(--accent); font-size:21px; font-weight:600; }
        .local-badge { font-size:11px; color:var(--muted); margin-left:5px; }
        .icon-button { width:30px; height:30px; border:0; border-radius:7px; background:transparent; display:inline-grid; place-items:center; flex-shrink:0; padding:6px; }
        .icon-button:hover { background:var(--hover); }
        .icon-button svg { width:18px; height:18px; fill:none; stroke:currentColor; stroke-width:1.7; stroke-linecap:round; stroke-linejoin:round; }
        .icon-button.selected { color:var(--accent); background:var(--hover); }
        .icon-button.selected svg { fill:var(--accent); stroke:var(--accent); }
        .icon-button:disabled { opacity:.4; cursor:wait; }
        select { max-width:128px; border:0; border-left:1px solid var(--line); border-radius:0; background:var(--panel); color:var(--muted); font-size:12px; padding:3px 5px; }
        .usage { padding-bottom:15px; border-bottom:1px solid var(--line); }
        .usage-heading { display:flex; align-items:baseline; gap:9px; margin-bottom:8px; font-size:12px; }
        .usage-heading strong { font-weight:650; font-variant-numeric:tabular-nums; }
        .quota-values { display:flex; flex-direction:column; gap:2px; align-items:flex-end; }
        #today-reference { font-size:11px; font-variant-numeric:tabular-nums; }
        #today-reference.available { color:var(--green); }
        #today-reference.over { color:var(--red); }
        #usage-source { margin-left:auto; font-size:11px; }
        .progress { height:8px; position:relative; background:var(--chip); border-radius:5px; }
        .segment { position:absolute; height:100%; top:0; max-width:100%; }
        .green { background:var(--green); border-radius:5px; }
        .red { background:var(--red); border-radius:5px; }
        .marker { position:absolute; top:-4px; height:16px; width:0; border-left:2px dashed var(--text); opacity:.75; }
        .reset-credits { display:grid; gap:4px; margin-top:12px; font-size:12px; color:var(--muted); }
        .usage-notes { margin-top:7px; display:flex; gap:16px; align-items:start; justify-content:space-between; font-size:11px; }
        #reset-count { white-space:nowrap; font-variant-numeric:tabular-nums; }
        .muted { color:var(--muted); }
        .search-area { margin-top:16px; display:flex; gap:8px; }
        input { flex:1; min-width:0; border:1px solid var(--line); background:var(--hover); color:var(--text); border-radius:9px; padding:9px 12px; }
        .text-button { border:0; padding:6px; background:transparent; color:var(--muted); }
        .web-settings { margin-top:12px; padding:10px 12px; background:var(--hover); border:1px solid var(--line); border-radius:9px; font-size:12px; }
        .web-settings summary { cursor:pointer; }
        #filter-summary { font-size:11px; margin-left:10px; }
        .settings-grid { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:14px; margin-top:14px; }
        .settings-grid label { display:flex; flex-direction:column; gap:5px; color:var(--muted); font-size:11px; }
        .settings-grid select { width:100%; max-width:none; border:1px solid var(--line); border-radius:6px; padding:6px 8px; color:var(--text); }
        .settings-note { display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:8px; font-size:10px; color:var(--muted); padding-top:10px; }
        .settings-note button { font-size:11px; }
        .list-summary { display:flex; justify-content:space-between; gap:12px; font-size:11px; padding:15px 1px 7px; }
        .sessions { min-height:320px; }
        .session { display:flex; gap:12px; align-items:flex-start; padding:15px 2px; border-bottom:1px solid var(--line); }
        .session:last-child { border-bottom:0; }
        .session-main { flex:1; min-width:0; }
        .session-title { display:block; width:fit-content; max-width:100%; font-size:15px; line-height:1.55; color:var(--text); font-weight:580; text-decoration:none; overflow-wrap:anywhere; }
        a.session-title:hover { color:var(--green); }
        .session-title.unavailable { cursor:help; color:var(--text); }
        .session-meta { display:flex; align-items:center; gap:6px; margin-top:7px; font-size:11px; color:var(--muted); }
        .chip { background:var(--chip); border-radius:4px; padding:1px 6px; max-width:180px; white-space:nowrap; text-overflow:ellipsis; overflow:hidden; }
        .cwd { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; margin-left:3px; }
        .session-right { flex-shrink:0; display:flex; align-items:center; gap:8px; }
        .reply-time { color:var(--muted); font-size:11px; margin-top:7px; white-space:nowrap; }
        .session .icon-button { width:28px; height:28px; }
        .session-details { margin-top:9px; color:var(--muted); font-size:11px; }
        .session-details summary { width:fit-content; cursor:pointer; }
        .metadata { display:grid; grid-template-columns:max-content minmax(0,1fr); gap:6px 12px; margin:10px 0 0; font-size:11px; }
        .metadata dt { color:var(--muted); }
        .metadata dd { margin:0; color:var(--text); overflow-wrap:anywhere; white-space:pre-wrap; }
        .metadata code { font:10px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace; }
        .empty { min-height:320px; display:flex; align-items:center; justify-content:center; flex-direction:column; text-align:center; color:var(--muted); padding:28px; }
        .empty-symbol { font-size:34px; color:var(--accent); margin-bottom:12px; }
        .empty strong { font-size:15px; color:var(--text); font-weight:500; }
        .empty p { max-width:440px; margin:8px 0; font-size:12px; }
        .error { border:1px solid var(--red); border-radius:8px; color:var(--red); padding:10px; margin:8px 0; font-size:12px; }
        .source-details { border-top:1px solid var(--line); margin-top:14px; padding-top:12px; color:var(--muted); font-size:11px; }
        .source-details summary { cursor:pointer; width:fit-content; }
        .connection-grid { display:grid; grid-template-columns:1fr 1.4fr; gap:24px; margin-top:12px; }
        .connection-grid h2 { font-size:12px; font-weight:550; color:var(--text); margin:0 0 9px; }
        .source-line { margin-top:7px; display:flex; gap:12px; align-items:baseline; }
        .source-name { min-width:90px; color:var(--text); }
        .source-state { overflow-wrap:anywhere; }
        .privacy-note { margin:10px 0 0; }
        footer { display:flex; justify-content:space-between; padding-top:12px; font-size:10px; color:var(--muted); }
        footer code { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; }
        @media(max-width:720px) { .app { margin:0; min-height:100vh; border-radius:0; border:0; padding:16px; } .toolbar { gap:8px; flex-wrap:wrap; } .tools { margin-left:auto; gap:4px; } .local-badge { display:none; } select { max-width:108px; font-size:11px; } .session-right { gap:3px; } .reply-time { font-size:10px; } .cwd { display:none; } #updated { display:none; } .usage-notes { gap:8px; } .connection-grid { grid-template-columns:1fr; gap:18px; } .settings-grid { gap:8px; } #filter-summary { display:block; margin:4px 0 0 14px; } }
        """#

    static let javascript = #"""
        'use strict';
        const $ = id => document.getElementById(id);
        let snapshot = null;
        let projection = null;
        let favoritesOnly = true;
        let loading = false;
        const pendingFavorites = new Set();
        const expandedSessions = new Set();
        const csrf = document.querySelector('meta[name="huantai-csrf"]').content;
        const clamp = value => Math.min(100, Math.max(0, Number.isFinite(value) ? value : 0));
        const percent = value => Number.isFinite(value) ? `${Math.round(value * 10) / 10}%` : '未连接';
        const create = (tag, className, text) => { const node = document.createElement(tag); if (className) node.className = className; if (text !== undefined) node.textContent = text; return node; };
        function setError(message) { $('error').textContent = message; $('error').hidden = !message; }
        function dateValue(value) { if (!value) return null; const number = Date.parse(value); return Number.isFinite(number) ? number : null; }
        function visibleSessions() {
          return HuantaiViewModel.filterSessions(snapshot?.sessions || [], {
            query: $('query').value, favoritesOnly, source: $('source-filter').value,
            machine: $('machine-filter').value, sort: $('sort').value, status: $('status-filter').value
          });
        }
        function renderFilters() {
          [['source-filter','source','全部来源'],['machine-filter','machine','全部设备']].forEach(([id,key,label]) => {
            const select = $(id), selected = select.value;
            const options = [create('option', null, label)]; options[0].value = '';
            HuantaiViewModel.availableValues(snapshot?.sessions || [], key).forEach(value => { const option = create('option', null, value); option.value = value; options.push(option); });
            select.replaceChildren(...options);
            select.value = options.some(option => option.value === selected) ? selected : '';
          });
        }
        function addMetadata(list, label, value, code = false) {
          list.appendChild(create('dt', null, label)); const cell = create('dd');
          cell.appendChild(create(code ? 'code' : 'span', null, value)); list.appendChild(cell);
        }
        function sessionDetails(session, openURL) {
          const details = create('details', 'session-details'); details.open = expandedSessions.has(session.id);
          details.appendChild(create('summary', null, '会话详情'));
          const list = create('dl', 'metadata');
          addMetadata(list, '会话 ID', session.id, true);
          addMetadata(list, '工作目录', session.cwd || '未提供', true);
          addMetadata(list, '来源', HuantaiViewModel.metadataValue(session, 'source'));
          addMetadata(list, '设备', HuantaiViewModel.metadataValue(session, 'machine'));
          addMetadata(list, '任务状态', session.isCompleted ? '已完成' : '未完成');
          addMetadata(list, '最后 AI 回复', HuantaiViewModel.fullTimestamp(session.lastAIReplyAt));
          addMetadata(list, '打开映射', openURL ? '已配置，可点击标题打开' : session.openUnavailableReason || '未配置已核验的打开链接');
          if (openURL) addMetadata(list, '映射地址', openURL, true);
          details.appendChild(list);
          details.addEventListener('toggle', () => { if (details.open) expandedSessions.add(session.id); else expandedSessions.delete(session.id); });
          return details;
        }
        function relativeTime(value) {
          const stamp = dateValue(value); if (stamp === null) return '暂无 AI 回复';
          const minutes = Math.floor((Date.now() - stamp) / 60000);
          if (minutes < 0) return 'AI 回复时间在未来';
          if (minutes < 1) return '刚刚';
          if (minutes < 60) return `${minutes} 分钟前`;
          if (minutes < 1440) return `${Math.floor(minutes / 60)} 小时前`;
          if (minutes < 10080) return `${Math.floor(minutes / 1440)} 天前`;
          return new Date(stamp).toLocaleDateString('zh-CN');
        }
        function validatedOpenURL(value) {
          return HuantaiViewModel.validatedOpenURL(value);
        }
        function starButton(session) {
          const button = create('button', `icon-button${session.isFavorite ? ' selected' : ''}`);
          button.type = 'button'; button.setAttribute('aria-label', session.isFavorite ? '取消收藏' : '收藏会话');
          button.setAttribute('aria-pressed', String(Boolean(session.isFavorite)));
          button.title = session.isFavorite ? '取消收藏' : '收藏会话';
          const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
          const use = document.createElementNS('http://www.w3.org/2000/svg', 'use'); use.setAttribute('href', '#star-icon');
          svg.appendChild(use); button.appendChild(svg); button.disabled = pendingFavorites.has(session.id);
          button.addEventListener('click', () => toggleFavorite(session)); return button;
        }
        function renderSessions() {
          if (!snapshot) return;
          const sessions = visibleSessions(); $('sessions').replaceChildren();
          const fragment = document.createDocumentFragment();
          sessions.forEach(session => {
            const row = create('article', 'session'); const main = create('div', 'session-main');
            const openURL = validatedOpenURL(session.openURL);
            const title = create(openURL ? 'a' : 'span', `session-title${openURL ? '' : ' unavailable'}`, session.title || '未命名会话');
            if (openURL) { title.href = openURL; title.rel = 'noopener noreferrer'; title.addEventListener('click', event => { event.preventDefault(); openSession(session); }); }
            else { title.title = session.openUnavailableReason || '未配置已核验的打开链接'; title.tabIndex = 0; title.setAttribute('aria-description', title.title); }
            main.appendChild(title);
            const meta = create('div', 'session-meta');
            meta.appendChild(create('span', 'chip', HuantaiViewModel.metadataValue(session,'source')));
            meta.appendChild(create('span', 'chip', HuantaiViewModel.metadataValue(session,'machine')));
            meta.appendChild(create('span', 'chip', session.isCompleted ? '已完成' : '未完成'));
            const cwd = create('span', 'cwd', session.cwd || ''); cwd.title = session.cwd || ''; meta.appendChild(cwd); main.appendChild(meta);
            main.appendChild(sessionDetails(session, openURL));
            const right = create('div', 'session-right'); const time = create('time', 'reply-time', relativeTime(session.lastAIReplyAt));
            if (session.lastAIReplyAt) { time.dateTime = session.lastAIReplyAt; const stamp = dateValue(session.lastAIReplyAt); if (stamp !== null) time.title = `AI 最后回复：${new Date(stamp).toLocaleString('zh-CN')}`; }
            const completion = create('button', 'text-button', session.isCompleted ? '恢复' : '完成');
            completion.type = 'button'; completion.disabled = pendingFavorites.has(session.id);
            completion.setAttribute('aria-label', session.isCompleted ? '恢复为未完成' : '标记已完成');
            completion.addEventListener('click', () => toggleCompletion(session));
            right.appendChild(time); right.appendChild(starButton(session)); right.appendChild(completion); row.appendChild(main); row.appendChild(right); fragment.appendChild(row);
          });
          $('sessions').appendChild(fragment); $('sessions').hidden = !sessions.length; $('empty').hidden = Boolean(sessions.length);
          const filtered = Boolean($('query').value.trim() || $('source-filter').value || $('machine-filter').value);
          const statusLabel = $('status-filter').value === 'completed' ? '已完成' : $('status-filter').value === 'all' ? '全部状态' : '未完成';
          $('count').textContent = `${statusLabel} · ${favoritesOnly ? '收藏 ' : ''}${sessions.length} 个会话${filtered ? ' · 筛选结果' : ''}`;
          $('filter-summary').textContent = `${$('source-filter').value || '全部来源'} · ${$('machine-filter').value || '全部设备'} · ${$('status-filter').value === 'completed' ? '已完成' : $('status-filter').value === 'all' ? '全部状态' : '未完成'}`;
          $('ordering-note').textContent = `${$('machine-filter').value || '全部设备'} · ${$('sort').value === 'favorite' ? '收藏优先，同组按 AI 最新回复排序' : '按 AI 最后回复时间排序'}`;
          if (!sessions.length) {
            $('empty-title').textContent = filtered ? '没有匹配的会话' : `没有${statusLabel === '全部状态' ? '' : statusLabel}的${favoritesOnly ? '收藏' : ''}会话`;
            $('empty-message').textContent = filtered ? '试试其他关键词，或清除来源与设备筛选。' : '可切换任务状态查看已完成记录，或关闭星标筛选查看其他会话。';
          }
        }
        function renderUsage() {
          const usage = snapshot?.usage || {}; const weekly = usage.weekly;
          const connected = weekly && Number.isFinite(weekly.usedPercent);
          const remaining = connected ? 100 - clamp(weekly.usedPercent) : 0;
          $('usage-value').textContent = connected ? `剩余 ${percent(remaining)}` : '未连接';
          $('usage-source').textContent = usage.status || '未连接用量来源';
          $('usage-bar').classList.toggle('unavailable', !connected);
          if (connected) $('usage-bar').setAttribute('aria-valuenow', String(remaining));
          else $('usage-bar').removeAttribute('aria-valuenow');
          const today = connected ? projection?.todayReferenceRemainingPercent : null;
          const todayKnown = Number.isFinite(today);
          const belowReference = todayKnown && today < 0;
          const dailyValue = todayKnown ? (Math.abs(today) > 0 && Math.abs(today) < 0.1 ? '<0.1%' : `${Math.abs(today).toFixed(1)}%`) : null;
          $('today-reference').textContent = todayKnown ? `${belowReference ? '今日超出' : '今日参考剩余'} ${dailyValue}` : connected ? '今日参考待更新' : '今日参考未连接';
          $('today-reference').classList.toggle('available', todayKnown && !belowReference);
          $('today-reference').classList.toggle('over', belowReference);
          $('today-reference').title = todayKnown ? `前几天未用的参考额度累计到今天，百分比以全周额度为100%。今日参考截止：${HuantaiViewModel.fullTimestamp(projection.todayReferenceEndsAt)}（${projection.todayReferenceTimeZone || '本机时区'}）` : '需要有效的当前周窗口';
          const green = belowReference ? 0 : remaining;
          const red = belowReference ? remaining : 0;
          $('green-segment').style.width = `${green}%`;
          $('red-segment').style.left = '0%'; $('red-segment').style.width = `${red}%`;
          const budget = projection?.referenceBudgetPercent;
          $('budget-mark').hidden = !connected || !Number.isFinite(budget);
          if (Number.isFinite(budget)) { $('budget-mark').style.left = `${100 - clamp(budget)}%`; $('budget-mark').title = `用户自定参考剩余 ${percent(100 - clamp(budget))}，非官方日限额`; }
          const notes = [];
          if (connected && Number.isFinite(budget)) notes.push(`参考剩余 ${percent(100 - clamp(budget))}（自定节奏）`);
          if (connected && !notes.length) notes.push(projection?.status || '预算参考暂无数据');
          if (!connected) notes.push('等待真实周用量来源');
          $('usage-note').textContent = notes.join(' · ');
          renderResetDate();
          $('reset-credits').replaceChildren(...HuantaiViewModel.resetCreditRows(usage).map(text => create('div',null,text)));
          const observed = dateValue(usage.observedAt);
          $('usage-source').title = observed === null ? '' : `${usage.source === 'codex-app-server' ? '额度读取于' : '快照导入于'} ${new Date(observed).toLocaleString('zh-CN')}${usage.source === 'codex-app-server' ? '' : '，非实时账户读取'}`;
          $('usage-details').replaceChildren();
          HuantaiViewModel.usageConnectionRows(usage).forEach(([label,value]) => addMetadata($('usage-details'),label,value));
        }
        function renderResetDate() {
          $('reset-count').textContent = HuantaiViewModel.resetDate(snapshot?.usage?.weekly?.resetsAt);
          $('reset-count').setAttribute('aria-label', '周额度重置日期');
        }
        function renderSources() {
          const fragment = document.createDocumentFragment();
          (snapshot?.sources || []).forEach(source => { const row = create('div', 'source-line'); row.appendChild(create('span', 'source-name', source.name)); row.appendChild(create('span', 'source-state', source.status)); fragment.appendChild(row); });
          if (!(snapshot?.sources || []).length) fragment.appendChild(create('p', null, '暂无已连接来源'));
          $('source-status').replaceChildren(fragment);
          const stamp = dateValue(snapshot?.updatedAt);
          $('updated').textContent = stamp === null ? '' : `最近扫描 ${new Date(stamp).toLocaleTimeString('zh-CN', {hour:'2-digit',minute:'2-digit',second:'2-digit'})}`;
        }
        async function loadSnapshot() {
          if (loading || pendingFavorites.size) return;
          loading = true; $('refresh').disabled = true;
          try {
            const response = await fetch('/api/snapshot', {cache:'no-store', credentials:'same-origin'});
            if (!response.ok) throw new Error('无法读取本机索引。请检查换台 App 是否正在运行。');
            const value = await response.json();
            if (!value.snapshot || !Array.isArray(value.snapshot.sessions)) throw new Error('索引格式无效，请重新启动换台。');
            snapshot = value.snapshot; projection = value.usageProjection; renderFilters(); renderUsage(); renderSessions(); renderSources(); setError('');
          } catch (error) { setError(error.message || '本机服务暂时不可用。'); }
          finally { loading = false; $('refresh').disabled = false; }
        }
        async function openSession(session) {
          try {
            const response = await fetch('/api/open', {method:'POST', credentials:'same-origin', headers:{'Content-Type':'application/json','X-Huantai-CSRF':csrf}, body:JSON.stringify({id:session.id})});
            if (!response.ok) throw new Error('来源应用未能打开该会话，请检查 App 中的来源状态。');
            setError('');
          } catch (error) { setError(error.message || '来源应用暂时不可用。'); }
        }
        async function toggleFavorite(session) {
          if (pendingFavorites.has(session.id)) return;
          pendingFavorites.add(session.id); renderSessions();
          try {
            const response = await fetch('/api/favorite', {method:'POST', credentials:'same-origin', headers:{'Content-Type':'application/json','X-Huantai-CSRF':csrf}, body:JSON.stringify({id:session.id,value:!session.isFavorite})});
            if (!response.ok) throw new Error('收藏更新失败，请刷新后重试。');
            session.isFavorite = !session.isFavorite; setError('');
          } catch (error) { setError(error.message || '收藏更新失败。'); }
          finally { pendingFavorites.delete(session.id); renderSessions(); }
        }
        async function toggleCompletion(session) {
          if (pendingFavorites.has(session.id)) return;
          pendingFavorites.add(session.id); renderSessions();
          try {
            const response = await fetch('/api/completion', {method:'POST', credentials:'same-origin', headers:{'Content-Type':'application/json','X-Huantai-CSRF':csrf}, body:JSON.stringify({id:session.id,value:!session.isCompleted})});
            if (!response.ok) throw new Error('完成状态保存失败，请刷新后重试。');
            session.isCompleted = !session.isCompleted; setError('');
          } catch (error) { setError(error.message || '完成状态保存失败。'); }
          finally { pendingFavorites.delete(session.id); renderSessions(); }
        }
        $('search-toggle').addEventListener('click', () => {
          const expanded = $('search-area').hidden; $('search-area').hidden = !expanded;
          $('search-toggle').setAttribute('aria-expanded', String(expanded)); $('search-toggle').setAttribute('aria-label', expanded ? '收起搜索' : '展开搜索');
          if (expanded) $('query').focus(); else { $('query').value = ''; renderSessions(); }
        });
        $('favorites-toggle').addEventListener('click', () => { favoritesOnly = !favoritesOnly; $('favorites-toggle').classList.toggle('selected', favoritesOnly); $('favorites-toggle').setAttribute('aria-pressed', String(favoritesOnly)); $('favorites-toggle').setAttribute('aria-label', favoritesOnly ? '只看收藏' : '查看全部会话'); $('favorites-toggle').title = favoritesOnly ? '只看收藏（点击查看全部）' : '查看全部（点击只看收藏）'; renderSessions(); });
        $('query').addEventListener('input', renderSessions);
        $('clear-search').addEventListener('click', () => { $('query').value = ''; $('query').focus(); renderSessions(); });
        ['source-filter','machine-filter','status-filter'].forEach(id => $(id).addEventListener('change',renderSessions));
        $('clear-filters').addEventListener('click', () => { $('source-filter').value = ''; $('machine-filter').value = ''; renderSessions(); });
        try { const value = localStorage.getItem('huantai-sort'); if (['recent','favorite'].includes(value)) $('sort').value = value; } catch {}
        $('sort').addEventListener('change', () => { try { localStorage.setItem('huantai-sort',$('sort').value); } catch {} renderSessions(); });
        $('refresh').addEventListener('click', loadSnapshot);
        function applyTheme(value) { if (value === 'system') delete document.documentElement.dataset.theme; else document.documentElement.dataset.theme = value; }
        try { const value = localStorage.getItem('huantai-theme'); if (['light','dark','system'].includes(value)) $('theme').value = value; } catch {}
        applyTheme($('theme').value);
        $('theme').addEventListener('change', () => { applyTheme($('theme').value); try { localStorage.setItem('huantai-theme', $('theme').value); } catch {} });
        document.addEventListener('keydown', event => { if (event.key === 'Escape' && !$('search-area').hidden) $('search-toggle').click(); });
        document.addEventListener('visibilitychange', () => { if (!document.hidden) loadSnapshot(); });
        loadSnapshot(); setInterval(() => { if (!document.hidden) loadSnapshot(); }, 5000);
        """#
}
