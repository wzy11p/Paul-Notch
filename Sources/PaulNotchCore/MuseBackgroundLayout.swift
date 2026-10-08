import WebKit

extension WebsiteQuotaBrowser {
    /// WebKit suspends animation frames for detached views, even with the
    /// public inactive scheduling policy disabled. Muse uses frames to finish
    /// General's layout. Supply a bounded scheduler only for that owned route
    /// while a quota read is in progress; never fake visibility or input.
    static let museBackgroundLayoutScript = #"""
    (() => {
      const allowed = () => {
        const u = new URL(location.href), entries = [...u.searchParams.entries()];
        return u.protocol === 'https:' && u.hostname === 'muse.ai' && !u.port &&
          !u.username && !u.password && u.pathname === '/' &&
          (entries.length === 0 || entries.length === 1 && entries[0][0] === 'settings_tab' && entries[0][1] === 'general');
      };
      const initial = new URL(location.href);
      if (!allowed() || initial.searchParams.get('settings_tab') !== 'general') return;
      const nativeFrame = window.requestAnimationFrame.bind(window);
      const nativeCancel = window.cancelAnimationFrame.bind(window);
      const pending = new Map();
      let token = null, deadline = 0, tracking = true;
      const inRead = () => token !== null && performance.now() < deadline && allowed();
      const deliver = (record, time) => {
        if (record.cancelled || record.delivered) return;
        record.delivered = true;
        clearTimeout(record.timer);
        pending.delete(record.id);
        record.callback(time);
      };
      const schedule = record => {
        if (record.timer !== null || record.cancelled || record.delivered || !inRead() || !document.hidden) return;
        record.timer = setTimeout(() => {
          record.timer = null;
          if (!inRead() || !document.hidden || record.cancelled || record.delivered) return;
          nativeCancel(record.id);
          deliver(record, performance.now());
        }, 33);
      };
      window.requestAnimationFrame = callback => {
        if (typeof callback !== 'function' || !tracking || !allowed() || pending.size >= 128) return nativeFrame(callback);
        const record = {id: null, callback, timer: null, delivered: false, cancelled: false};
        record.id = nativeFrame(time => deliver(record, time));
        pending.set(record.id, record);
        schedule(record);
        return record.id;
      };
      window.cancelAnimationFrame = id => {
        const record = pending.get(id);
        if (record) {
          record.cancelled = true;
          clearTimeout(record.timer);
          pending.delete(id);
        }
        nativeCancel(id);
      };
      Object.defineProperty(window, '__PaulMuseBackgroundLayout', {value: Object.freeze({
        begin: readToken => {
          if (!allowed() || typeof readToken !== 'string' || readToken.length > 64) return false;
          if (token === readToken) return true;
          token = readToken;
          deadline = performance.now() + 15000;
          tracking = true;
          pending.forEach(schedule);
          return true;
        },
        end: readToken => {
          if (token !== readToken) return false;
          token = null;
          deadline = 0;
          tracking = false;
          pending.forEach(record => clearTimeout(record.timer));
          pending.clear();
          return true;
        }
      })});
    })();
    """#
}
