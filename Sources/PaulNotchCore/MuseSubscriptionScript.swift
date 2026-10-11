import Foundation

extension MuseSubscriptionReader {
    /// The read-only action/discovery protocol follows CodexBar's MIT Muse AI
    /// adapter (see THIRD_PARTY_NOTICES). Only bounded quota fields leave JS.
    static let script = #"""
    const origin = 'https://muse.ai';
    if (location.origin !== origin) return JSON.stringify({state:'format'});
    const controller = new AbortController(), timeout = setTimeout(() => controller.abort(),12000);
    let discoveryBytes = 0;
    const fail = state => { throw {quotaState:state}; };
    const request = async (path, options, limit, discovery=false) => {
      if (!(path === '/' || /^\/_next\/static\/chunks\/[\w~.-]+\.js$/.test(path))) fail('format');
      const r = await fetch(origin+path,{...options,credentials:'same-origin',redirect:'error',signal:controller.signal});
      if (r.status === 401) fail('authentication');
      if (r.status === 403 || r.status === 429 || r.status >= 500) fail('unavailable');
      const length = Number(r.headers.get('content-length'));
      if (length > limit) fail('format');
      const reader = r.body?.getReader();
      if (!reader) fail('format');
      const decoder = new TextDecoder(); let size=0, body='';
      try {
        while (true) {
          const part = await reader.read(); if (part.done) break;
          size += part.value.byteLength;
          if (discovery) discoveryBytes += part.value.byteLength;
          if (size > limit || discoveryBytes > 8*1024*1024) { await reader.cancel(); fail('format'); }
          body += decoder.decode(part.value,{stream:true});
        }
        body += decoder.decode();
      } finally { reader.releaseLock(); }
      return {status:r.status,body};
    };
    const chunkPaths = text => [...new Set((text.match(/static\/chunks\/[\w~.-]+\.js/g)||[]).map(p=>'/_next/'+p))];
    const chunks = paths => Promise.all(paths.map(async path => {
      const r = await request(path,{headers:{Accept:'*/*'},cache:'force-cache'},2*1024*1024,true);
      return r.status === 200 ? r.body : '';
    }));
    const discover = async () => {
      const page = await request('/',{headers:{Accept:'text/html'},cache:'no-store'},1024*1024,true);
      if (page.status !== 200) fail('unavailable');
      const paths = chunkPaths(page.body).slice(0,96); let scripts='';
      for (let i=0;i<paths.length;i+=8) {
        scripts += '\n'+(await chunks(paths.slice(i,i+8))).join('\n');
        const module = /\.A\((\d+)\)\.then\(\(\{[^}]*Settings/.exec(scripts)?.[1];
        const loader = module && new RegExp('[,{\\[]'+module+',\\w+=>\\{\\w+\\.v\\(\\w+=>Promise\\.all\\(\\[([^\\]]*)').exec(scripts);
        if (!loader) continue;
        const settings = chunkPaths(loader[1]).slice(0,32);
        for (let j=0;j<settings.length;j+=8) {
          for (const body of await chunks(settings.slice(j,j+8))) {
            const id = /"([0-9a-f]{40,80})",[^"]{0,200}"fetchSubscriptionAction"/.exec(body)?.[1];
            if (id) return id;
          }
        }
        break;
      }
      fail('format');
    };
    const post = id => request('/',{method:'POST',cache:'no-store',
      headers:{Accept:'text/x-component','Next-Action':id},body:'[{"includeAgreement":true}]'},262144);
    const stale = r => r.status === 404 && /server action not found/i.test(r.body);
    try {
      let id = /^[0-9a-f]{40,80}$/.test(cachedActionID) ? cachedActionID : null;
      let r = id ? await post(id) : null;
      if (!r || stale(r)) { id = await discover(); r = await post(id); }
      if (r.status !== 200) fail(stale(r) ? 'format' : 'unavailable');
      let sub;
      for (const line of r.body.split('\n')) {
        const match = /^[0-9a-f]+:(\{.*\})\s*$/.exec(line); if (!match) continue;
        try { const row = JSON.parse(match[1]); if (row?.success === true && row.subscription) {
          if (sub) fail('format'); sub = row.subscription;
        }} catch (error) { if (error?.quotaState) throw error; }
      }
      const used = sub?.usage?.percentUsed;
      if (typeof used !== 'number' || !Number.isFinite(used) || used < 0 || used > 100) fail('format');
      const seconds = v => v == null ? null : (typeof v === 'number' && Number.isFinite(v) && v >= 1577836800 && v <= 4102444800 ? v : fail('format'));
      const text = v => typeof v === 'string' && v.length <= 80 ? v : null;
      let extra = null;
      if (typeof sub.topupTotal === 'number' && sub.topupTotal > 0 &&
          typeof sub.topupBalance === 'number' && Number.isFinite(sub.topupBalance) && sub.topupBalance >= 0) {
        // Server balances are micro-dollars, never a count of tokens.
        extra = text(sub.topupRowValueLabel) ?? ('$'+(sub.topupBalance/1e6).toFixed(2)+' 余额');
      }
      return JSON.stringify({state:'ok',actionID:id,used,resetsAt:seconds(sub.usage.resetsAt),
        renewsAt:seconds(sub.agreement?.currentPeriodEndTime),plan:text(sub.tier?.name),extra});
    } catch (error) {
      return JSON.stringify({state:error?.quotaState || 'unavailable'});
    } finally { clearTimeout(timeout); controller.abort(); }
    """#
}
