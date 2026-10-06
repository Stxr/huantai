import Foundation

extension WebAssets {
    /// Pure metadata transforms shared by the page and synthetic-data JavaScriptCore tests.
    static let modelJavascript = #"""
        'use strict';
        var HuantaiViewModel = (() => {
          function dateValue(value) { if (!value) return null; const stamp = Date.parse(value); return Number.isFinite(stamp) ? stamp : null; }
          function metadataValue(session, key) { return String(session[key] || (key === 'machine' ? '未知设备' : '未知来源')); }
          function replyOrder(left, right) {
            const a = dateValue(left.lastAIReplyAt), b = dateValue(right.lastAIReplyAt);
            if (a !== null && b !== null && a !== b) return b - a;
            if (a !== null && b === null) return -1;
            if (a === null && b !== null) return 1;
            return String(left.id) < String(right.id) ? -1 : String(left.id) > String(right.id) ? 1 : 0;
          }
          function filterSessions(sessions, options = {}) {
            const query = String(options.query || '').trim().toLocaleLowerCase();
            const status = options.status || 'pending';
            return sessions.filter(session => (status === 'all' || (status === 'completed' ? Boolean(session.isCompleted) : !session.isCompleted)) && (!options.favoritesOnly || session.isFavorite) &&
              (!options.source || metadataValue(session,'source') === options.source) &&
              (!options.machine || metadataValue(session,'machine') === options.machine) && (!query ||
              String(session.title || '').toLocaleLowerCase().includes(query) || String(session.cwd || '').toLocaleLowerCase().includes(query)))
              .slice().sort((a,b) => options.sort === 'favorite' && Boolean(a.isFavorite) !== Boolean(b.isFavorite) ? Number(Boolean(b.isFavorite)) - Number(Boolean(a.isFavorite)) : replyOrder(a,b));
          }
          function availableValues(sessions, key) {
            return [...new Set(sessions.map(session => metadataValue(session,key)))].sort((a,b) => a.localeCompare(b,'zh-CN'));
          }
          function fullTimestamp(value) {
            const stamp = dateValue(value); if (stamp === null) return '暂无数据';
            const date = new Date(stamp); return `${date.toLocaleString('zh-CN',{hour12:false})} · ${date.toISOString()}`;
          }
          function resetCountdown(resetsAt, now = Date.now()) {
            const stamp = dateValue(resetsAt);
            if (stamp === null || !Number.isFinite(now)) return '重置时间未连接';
            const interval = stamp - now;
            if (interval <= 0) return '等待额度刷新';
            const seconds = Math.ceil(interval / 1000), days = Math.floor(seconds / 86400);
            const clock = [Math.floor(seconds % 86400 / 3600),Math.floor(seconds % 3600 / 60),seconds % 60].map(value => String(value).padStart(2,'0')).join(':');
            return `重置 ${days > 0 ? `${days}天 ` : ''}${clock}`;
          }
          function resetDate(resetsAt) {
            const stamp = dateValue(resetsAt);
            if (stamp === null) return '重置时间未连接';
            const date = new Date(stamp), weekday = ['周日','周一','周二','周三','周四','周五','周六'][date.getDay()];
            return `${date.getMonth()+1}-${date.getDate()}(${weekday})重置`;
          }
          function resetCreditRows(usage = {}) {
            const count = Number.isSafeInteger(usage.resetCount) && usage.resetCount >= 0 ? usage.resetCount : null;
            const rows = [];
            if (count === null) return ['重置卡未连接'];
            rows.push(`重置卡 ${count} 张`);
            if (count === 0) return rows;
            if (!Array.isArray(usage.resetCredits)) return [...rows,'有效期暂未返回'];
            const credits = usage.resetCredits.slice(0,count);
            credits.forEach((credit,index) => {
              const stamp = dateValue(credit.expiresAt);
              let expiry = '有效期未知';
              if (credit.expirationKnown === true && credit.expiresAt == null) expiry = '不过期';
              else if (credit.expirationKnown === true && stamp !== null) {
                const date = new Date(stamp), pad = value => String(value).padStart(2,'0');
                expiry = `${date.getFullYear()}-${pad(date.getMonth()+1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}到期`;
              }
              rows.push(`第${index+1}张 · ${expiry}`);
            });
            if (credits.length < count) rows.push(`另有 ${count - credits.length} 张，明细暂未返回`);
            return rows;
          }
          function validatedOpenURL(value) {
            if (typeof value !== 'string' || value.length > 4096 || /[\u0000-\u001f\u007f]/.test(value)) return null;
            try {
              const url = new URL(value);
              if (url.username || url.password || url.port || url.hash) return null;
              if (url.protocol === 'codex:' && url.hostname === 'threads' && !url.search && /^\/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(url.pathname)) return url.href;
              const entries = [...url.searchParams.entries()];
              if (!['https:','lark:','x-feishu:'].includes(url.protocol) || url.hostname !== 'applink.feishu.cn') return null;
              const validChatID = value => value.length <= 128 && /^oc_[A-Za-z0-9]+$/.test(value);
              if (url.pathname === '/client/chat/open' && entries.length === 1 && entries[0][0] === 'openChatId' && validChatID(entries[0][1])) return `lark://applink.feishu.cn/client/chat/open?openChatId=${encodeURIComponent(entries[0][1])}`;
              const names = ['open_chat_id','open_thread_id','openchatid','openthreadid','thread_position'];
              if (url.pathname !== '/client/thread/open' || entries.length !== names.length || new Set(entries.map(entry => entry[0])).size !== names.length || entries.some(entry => !names.includes(entry[0]))) return null;
              const values = Object.fromEntries(entries), chat = values.open_chat_id, thread = values.open_thread_id;
              if (!validChatID(chat) || thread.length > 128 || !/^omt_[A-Za-z0-9_-]+$/.test(thread) || chat !== values.openchatid || thread !== values.openthreadid || values.thread_position !== '-1') return null;
              return `lark://applink.feishu.cn/client/thread/open?open_chat_id=${encodeURIComponent(chat)}&open_thread_id=${encodeURIComponent(thread)}&openchatid=${encodeURIComponent(chat)}&openthreadid=${encodeURIComponent(thread)}&thread_position=-1`;
            } catch { return null; }
          }
          function usageConnectionRows(usage = {}) {
            const weekly = usage.weekly;
            const connected = weekly && Number.isFinite(weekly.usedPercent);
            const resetCount = Number.isInteger(usage.resetCount) && usage.resetCount >= 0;
            const duration = weekly && Number.isInteger(weekly.windowDurationMins) && weekly.windowDurationMins > 0 ? weekly.windowDurationMins : null;
            const live = usage.source === 'codex-app-server';
            return [
              ['账户接口',live ? 'Codex app-server（现有授权，只读）' : '未连接'],
              ['周用量来源',connected ? (usage.status || '离线快照') : '未连接周用量来源'],
              [live ? '额度读取时间' : '快照导入时间',dateValue(usage.observedAt) === null ? '尚无读取记录' : `${fullTimestamp(usage.observedAt)}${live ? '（定时读取）' : '（非实时）'}`],
              ['窗口长度',duration === null ? '未连接' : `${duration} 分钟${duration === 10080 ? '（7 天）' : ''}`],
              ['窗口重置点',connected ? fullTimestamp(weekly.resetsAt) : '未连接'],
              ['可用重置次数',resetCount ? `${usage.resetCount} 次（${live ? '账户接口' : '已导入快照'}）` : '未连接'],
              ['重置卡有效期',Array.isArray(usage.resetCredits) ? '账户接口提供的可用卡明细；可能不完整' : '明细未提供'],
              ['参考预算','用户自定参考节奏，非官方日限额'],
            ];
          }
          return {metadataValue,filterSessions,availableValues,fullTimestamp,usageConnectionRows,resetCountdown,resetDate,resetCreditRows,validatedOpenURL};
        })();
        """#
}
