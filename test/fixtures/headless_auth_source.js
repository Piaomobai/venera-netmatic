// Local integration fixture. No real API keys, accounts or endpoint addresses.
class AuthFixture extends ComicSource {
    name = 'Auth Fixture';
    key = 'picacg';
    version = '1.0.0';
    minAppVersion = '1.0.0';
    url = 'http://127.0.0.1:PORT/source.js';
    settings = {base_url: {type: 'input', title: 'API', default: 'http://127.0.0.1:PORT'}};
    buildHeaders(method, path, token) {
        return {'Content-Type': 'application/json', authorization: token || '', http_client: 'dart:io'};
    }
    account = {
        login: async (username, password) => {
            if (username === 'captcha') await UI.showInputDialog('Fixture interaction');
            const response = await Network.post(`${this.loadSetting('base_url')}/auth/sign-in`,
                this.buildHeaders('POST', 'auth/sign-in'), JSON.stringify({email: username, password}));
            if (response.status !== 200) throw 'Login rejected with private response: ' + response.body;
            const body = JSON.parse(response.body);
            if (!body.data?.token) throw 'No token: ' + response.body;
            this.saveData('token', body.data.token);
        },
        reLogin: async () => {
            if (!this.isLogged) throw 'Not logged in';
            const account = this.loadData('account');
            await this.account.login(account[0], account[1]);
        },
        logout: async () => {
            await new Promise(resolve => setTimeout(resolve, 10));
            this.deleteData('token');
        }
    };
    search = {load: async (query, options, page) => {
        const response = await Network.post(`${this.loadSetting('base_url')}/comics/advanced-search?page=${page}`,
            this.buildHeaders('POST', 'comics/advanced-search', this.loadData('token')), JSON.stringify({keyword: query, sort: 'dd'}));
        if (response.status !== 200) throw 'Invalid status code: ' + response.status;
        const body = JSON.parse(response.body);
        return {comics: body.data.comics.docs, maxPage: 1};
    }};
    category = {title: 'Fixture categories', enableRankingPage: true, parts: [
        {name: 'Topics', type: 'fixed', categories: ['General'], itemType: 'category'}
    ]};
    categoryComics = {
        optionList: [{label: 'Sort', options: ['dd-Newest', 'ld-Most liked']}],
        load: async (category, param, options, page) => {
            const response = await Network.get(`${this.loadSetting('base_url')}/comics?page=${page}&${param || 'c'}=${encodeURIComponent(category)}&s=${options[0]}`,
                this.buildHeaders('GET', 'comics', this.loadData('token')));
            if (response.status !== 200) throw 'Invalid status code: ' + response.status;
            return {comics: JSON.parse(response.body).data.comics.docs, maxPage: 1};
        },
        ranking: {options: ['H24-Daily', 'D7-Weekly', 'D30-Monthly'], load: async option => {
            const response = await Network.get(`${this.loadSetting('base_url')}/comics/leaderboard?tt=${option}&ct=VC`,
                this.buildHeaders('GET', 'comics/leaderboard', this.loadData('token')));
            if (response.status !== 200) throw 'Invalid status code: ' + response.status;
            return {comics: JSON.parse(response.body).data.comics, maxPage: 1};
        }}
    };
    comic = {loadInfo: async id => {
        const load = async () => {
            const response = await Network.get(`${this.loadSetting('base_url')}/comics/${id}`,
                this.buildHeaders('GET', `comics/${id}`, this.loadData('token')));
            if (response.status !== 200) throw 'Invalid status code: ' + response.status;
            return JSON.parse(response.body).data;
        };
        // Mirrors the installed picacg 1.0.6 catch/rethrow bug. The runtime
        // transport must renew before this function observes an old 401.
        let result;
        try { result = await load(); }
        catch (error) {
            if (error === 'Invalid status code: 401') { await this.account.reLogin(); result = await load(); }
            throw error;
        }
        return {title: result.title, cover: '', description: '', tags: {}, chapters: {'1': 'One'}};
    }, onClickTag: (namespace, tag) => namespace === 'Categories'
        ? {action: 'category', keyword: tag, param: 'c'}
        : {action: 'search', keyword: tag}
    };
}
