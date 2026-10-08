import Foundation

/// Only bounded, nonsecret quota fields leave the owned official document.
struct MuseQuotaRead: Decodable {
    let used: Double
    let reset: String?
    let extraDisplay: String?
    let extraNeverExpires: Bool

    func snapshot(at date: Date) throws -> WebsiteQuotaSnapshot {
        try WebsiteQuotaParser.muse(used: used, reset: reset, extraBalance: nil,
            extraDisplay: extraDisplay, extraNeverExpires: extraNeverExpires, at: date)
    }
}

extension WebsiteQuotaBrowser {
    /// The official mobile sheet uses a labeled span for General; desktop
    /// uses a heading. Both must identify one settings dialog, never the chat
    /// behind it. Only bounded labels/semantics are examined here.
    private static let museGeneralScopeScript = #"""
      const query = new URLSearchParams(location.search);
      const quotaRoot = location.protocol === 'https:' && location.hostname === 'muse.ai' && !location.port &&
        location.pathname === '/' && ([...query].length === 0 ||
        [...query].length === 1 && query.get('settings_tab') === 'general');
      const hidden = e => !e || e.closest('[aria-hidden="true"],[inert],[hidden]');
      const visible = e => !hidden(e) && e.getBoundingClientRect().width > 0 && e.getBoundingClientRect().height > 0;
      const label = e => (e.textContent || '').trim().replace(/\s+/g,' ');
      const generalLabel = text => /^(General|通用)$/.test(text);
      const dialogs = quotaRoot ? [...document.querySelectorAll('[role="dialog"]')].slice(0,16).filter(visible) : [];
      const generalDialogs = dialogs.filter(dialog => {
        if (generalLabel(dialog.getAttribute('aria-label') || '')) return true;
        const ids = (dialog.getAttribute('aria-labelledby') || '').trim().split(/\s+/).slice(0,4);
        if (ids.some(id => {
          const title = document.getElementById(id);
          return title && dialog.contains(title) && visible(title) && title.textContent.length <= 80 && generalLabel(label(title));
        })) return true;
        return [...dialog.querySelectorAll('h1,h2,[role="heading"]')].slice(0,64).some(e =>
          visible(e) && e.textContent.length <= 80 && generalLabel(label(e)));
      });
      const general = generalDialogs.length === 1 ? generalDialogs[0] : null;
    """#

    static let museGeneralRenderedScript = "(() => {\n" + museGeneralScopeScript + "\nreturn general !== null; })()"

    static let museLoginRequiredScript = #"""
    (() => {
      if (location.protocol !== 'https:' || location.hostname !== 'muse.ai' || location.pathname !== '/') return false;
      if ([...document.querySelectorAll('h1,h2,[role="heading"]')].slice(0,64).some(e =>
          /^(General|通用)$/.test((e.textContent || '').trim()))) return false;
      const username = document.querySelector('input[autocomplete="username"],input[type="email"],input[placeholder="手机号或邮箱"]');
      if (!username || username.closest('[aria-hidden="true"],[inert],[hidden]')) return false;
      return [...document.querySelectorAll('button,a')].slice(0,80).some(e => {
        const label = (e.innerText || '').trim(), rect = e.getBoundingClientRect();
        return /^(Log in|Sign in|登录)$/i.test(label) && rect.width > 0 && rect.height > 0 &&
               !e.closest('[aria-hidden="true"],[inert],[hidden]');
      });
    })()
    """#

    /// General's public semantic UsageBar markup, not the native app bridge.
    /// No whole-page text, chat, input, credentials, storage or paid requests.
    static let museReadScript = "(() => {\n" + museGeneralScopeScript + #"""
      if (!general) return null;
      const headings = [...general.querySelectorAll('h1,h2,[role="heading"]')].slice(0,64);
      const usage = headings.filter(e => visible(e) && /^(Usage|使用情况)$/.test(label(e)));
      if (usage.length !== 1) return null;
      // The official General page uses a fragment: the Usage heading and its
      // SettingsCard are siblings. Ascending to their parent includes other
      // preferences (real Appearance radio inputs), not just personal quota.
      const adjacentCard = usage[0].nextElementSibling;
      let scope = null, bars = [];
      if (adjacentCard && general.contains(adjacentCard) && visible(adjacentCard) &&
          adjacentCard.querySelectorAll('[data-slot="settings-card-item"]').length === 1) {
        scope = adjacentCard;
        bars = [...scope.querySelectorAll('[role="progressbar"]')].filter(visible);
      } else {
        scope = usage[0].parentElement;
        for (let depth = 0; scope && depth < 4; depth++, scope = scope.parentElement) {
          if (!general.contains(scope) || scope === general || hidden(scope)) return null;
          bars = [...scope.querySelectorAll('[role="progressbar"]')].filter(visible);
          if (bars.length) break;
        }
      }
      if (!scope || ![1,2].includes(bars.length) || scope.closest('[aria-busy="true"]') ||
          scope.querySelector('input,textarea,[contenteditable="true"],[aria-busy="true"]')) return null;
      const readBar = bar => {
        const raw = bar.getAttribute('aria-valuenow');
        if (raw === null || !/^\d+(?:\.\d+)?$/.test(raw) ||
            bar.getAttribute('aria-valuemin') !== '0' || bar.getAttribute('aria-valuemax') !== '100') return null;
        const used = Number(raw), row = bar.parentElement;
        if (!Number.isFinite(used) || used < 0 || used > 100 || !row || !scope.contains(row) ||
            row.querySelectorAll('[role="progressbar"]').length !== 1 ||
            row.querySelector('input,textarea,[contenteditable="true"]')) return null;
        const text = (row.innerText || '').trim().replace(/\s+/g,' ');
        if (text.length > 400) return null;
        const caption = text.match(/已使用\s*(\d+(?:\.\d+)?)%/) || text.match(/(\d+(?:\.\d+)?)%\s+used/i);
        if (!caption || Number(caption[1]) !== used) return null;
        return {used,text};
      };
      const primary = readBar(bars[0]);
      if (!primary) return null;
      const reset = primary.text.match(/每周限额将在\s*[^%]{1,70}?重置/) ||
                    primary.text.match(/Weekly limit resets\s+[^%]{1,70}?(?=\s+\d+(?:\.\d+)?%\s+used|$)/i);
      if (!reset) return null;
      let extraDisplay = null, extraNeverExpires = false;
      if (bars.length === 2) {
        const extra = readBar(bars[1]);
        if (!extra || !/额外的使用额度|Additional usage/i.test(extra.text)) return null;
        const balance = extra.text.match(/剩余\s+[\d.,]+\s*(?:[万亿]?个?)?词元/) ||
                        extra.text.match(/[\d.,]+\s*(?:[KMB]\s*)?tokens?\s+remaining/i);
        if (!balance || balance[0].length > 80) return null;
        extraDisplay = balance[0];
        extraNeverExpires = /从不过期|Never expires/i.test(extra.text);
      }
      return JSON.stringify({used:primary.used, reset:reset[0], extraDisplay, extraNeverExpires});
    })()
    """#
}
