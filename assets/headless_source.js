// Source-local transports keep credential refresh and cookie ownership inside
// the worker. No credentials are returned through the public command protocol.
const HeadlessSourceRuntime = {
    failure(error, status) {
        if (String(error).includes('interaction_required')) return new Error('interaction_required');
        if (status === 429) return new Error('auth_rate_limited');
        if (status >= 500 || String(error).includes('auth_network_error')) return new Error('auth_network_error');
        if (String(error).includes('auth_invalid_response') || status === 200 && !String(error).includes('authentication_failed')) return new Error('auth_invalid_response');
        return new Error('authentication_failed');
    },

    network(reference) {
        const network = Object.create(Network);
        const request = async (method, url, headers, data, extra, bytes) => {
            const source = reference.source;
            const response = await sendMessage({method: 'http', http_method: method,
                url, headers, data, extra, bytes, source_key: source?.key});
            if (response.error) throw new Error('auth_network_error');
            const api = source?.key === 'picacg' ? source.loadSetting('base_url') : null;
            const isPicaApi = api && url.startsWith(api.replace(/\/$/, '') + '/');
            if (isPicaApi && url.includes('/auth/sign-in')) {
                source.__headlessLoginStatus = response.status;
            }
            if (isPicaApi && response.status === 401 && !url.includes('/auth/sign-in') && !extra?.headless_no_renew) {
                if (!source.isLogged || source.loadData('__headlessAuth')?.state === 'expired') throw new Error('authentication_required');
                // Another request may already have renewed the token between
                // sending this request and receiving its old 401 response.
                if (headers?.authorization === source.loadData('token')) await source.account.reLogin();
                const retry = await sendMessage({method: 'http', http_method: method,
                    url, headers: {...headers, authorization: source.loadData('token')},
                    data, extra, bytes, source_key: source.key});
                if (retry.error) throw new Error('auth_network_error');
                if (retry.status === 401) {
                    source.saveData('__headlessAuth', {state: 'expired'});
                    throw new Error('authentication_required');
                }
                if (retry.status === 200) source.saveData('__headlessAuth', {state: 'authenticated', verifiedAt: new Date().toISOString()});
                return retry;
            }
            return response;
        };
        network.sendRequest = (method, url, headers, data, extra) => request(method, url, headers, data, extra, false);
        network.fetchBytes = (method, url, headers, data, extra) => request(method, url, headers, data, extra, true);
        // Explicit overrides preserve the documented extra argument on GET/DELETE.
        network.get = (url, headers, extra) => network.sendRequest('GET', url, headers, null, extra);
        network.delete = (url, headers, extra) => network.sendRequest('DELETE', url, headers, null, extra);
        network.setCookies = (url, cookies) => sendMessage({method: 'cookie', function: 'set', url, cookies, source_key: reference.source?.key});
        network.getCookies = url => sendMessage({method: 'cookie', function: 'get', url, source_key: reference.source?.key});
        network.deleteCookies = url => sendMessage({method: 'cookie', function: 'delete', url, source_key: reference.source?.key});
        return network;
    },

    install(source, network) {
        const account = source.account;
        if (account) {
            if (typeof account.login === 'function') {
                const login = account.login;
                account.login = async function (...args) {
                    source.__headlessLoginStatus = null;
                    try {
                        const result = await login.apply(this, args);
                        if (result === false) throw new Error('authentication_failed');
                        return result;
                    } catch (error) {
                        throw HeadlessSourceRuntime.failure(error, source.__headlessLoginStatus);
                    }
                };
            }
            if (typeof account.reLogin === 'function') {
                const renew = account.reLogin;
                let renewing = null;
                account.reLogin = function (...args) {
                    if (!renewing) {
                        renewing = (async () => {
                            try {
                                const value = await renew.apply(this, args);
                                source.saveData('__headlessAuth', {state: 'unverified'});
                                return value;
                            } catch (error) {
                                const failure = HeadlessSourceRuntime.failure(error, source.__headlessLoginStatus);
                                if (String(failure).includes('authentication_failed')) {
                                    source.saveData('__headlessAuth', {state: 'expired'});
                                    throw new Error('authentication_required');
                                }
                                throw failure;
                            } finally { renewing = null; }
                        })();
                    }
                    return renewing;
                };
            }
            if (source.key === 'picacg' && !account.validateSession && typeof source.buildHeaders === 'function') {
                account.validateSession = async () => {
                    if (!source.loadData('token')) return false;
                    const path = 'comics/random';
                    const response = await network.get(`${source.loadSetting('base_url')}/${path}`,
                        source.buildHeaders('GET', path, source.loadData('token')), {headless_no_renew: true});
                    if (response.status === 401) return false;
                    if (response.status !== 200) throw HeadlessSourceRuntime.failure(null, response.status);
                    // A proxy/login page returning HTTP 200 is not proof of a valid session.
                    let body;
                    try { body = JSON.parse(response.body); } catch (_) { throw new Error('auth_invalid_response'); }
                    if (!Array.isArray(body.data?.comics)) throw new Error('auth_invalid_response');
                    return true;
                };
            }
        }
        // A cancelled query can stop awaiting a JS Promise before that Promise
        // settles. Account replacement waits for those old source calls, so an
        // old automatic renewal cannot overwrite a new account later.
        const pending = new Set();
        const visited = new Set();
        const wrap = object => {
            if (!object || typeof object !== 'object' || visited.has(object)) return;
            visited.add(object);
            for (const name of Object.getOwnPropertyNames(object)) {
                const descriptor = Object.getOwnPropertyDescriptor(object, name);
                if (!descriptor || !('value' in descriptor) || !descriptor.writable) continue;
                const value = descriptor.value;
                if (typeof value === 'function') {
                    object[name] = function (...args) {
                        const result = value.apply(this, args);
                        if (result && typeof result.then === 'function') {
                            pending.add(result);
                            result.then(() => pending.delete(result), () => pending.delete(result));
                        }
                        return result;
                    };
                } else if (value && typeof value === 'object') { wrap(value); }
            }
        };
        wrap(source);
        // Class methods live on the prototype; do not alter shared base APIs.
        const prototype = Object.getPrototypeOf(source);
        for (const name of Object.getOwnPropertyNames(prototype)) {
            if (name === 'constructor') continue;
            const descriptor = Object.getOwnPropertyDescriptor(prototype, name);
            if (typeof descriptor?.value === 'function') {
                const holder = {[name]: descriptor.value};
                wrap(holder);
                source[name] = holder[name];
            }
        }
        source.__headlessWaitForIdle = async () => {
            while (pending.size) await Promise.allSettled([...pending]);
        };
    },
};
