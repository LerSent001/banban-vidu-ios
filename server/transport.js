import { ProxyAgent } from 'undici';
import { HttpsProxyAgent } from 'https-proxy-agent';

export function createUpstreamTransport(origin, env = process.env) {
  const url = new URL(origin);
  const hostname = url.hostname.toLowerCase();
  const noProxy = (env.no_proxy || env.NO_PROXY || '').split(',').map(x => x.trim().toLowerCase()).filter(Boolean);
  const bypass = ['localhost', '127.0.0.1', '[::1]'].includes(hostname) || noProxy.some(rule => {
    if (rule === '*') return true;
    const host = rule.replace(/^\*?\./, '').split(':')[0];
    return hostname === host || hostname.endsWith('.' + host);
  });
  const proxy = url.protocol === 'https:' ? (env.https_proxy || env.HTTPS_PROXY || env.http_proxy || env.HTTP_PROXY) : (env.http_proxy || env.HTTP_PROXY);
  if (bypass || !proxy) return { mode: 'direct', fetchOptions: {}, wsOptions: {}, close() {} };
  const dispatcher = new ProxyAgent(proxy);
  const agent = new HttpsProxyAgent(proxy);
  return { mode: 'proxy', fetchOptions: { dispatcher }, wsOptions: { agent }, close() { dispatcher.close().catch(() => {}); agent.destroy(); } };
}
