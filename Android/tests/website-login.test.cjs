// Synthetic DOM only: never connects to an account or a live website.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('Android/assets/website/login.js', 'utf8');
let checks = 0;
function page(options = {}) {
  let clicks = 0, writes = 0;
  const timers = [];
  class Input {
    constructor(type, placeholder) { Object.assign(this, {type, placeholder, children: [], isConnected: true}); }
    getClientRects() { return [1]; }
    dispatchEvent() {}
    closest(selector) { return selector === 'form' ? {action: options.form || 'https://www.ixuecheng.cn/login'} : document; }
  }
  Object.defineProperty(Input.prototype, 'value', {set(value) { writes++; this.text = value; }});
  const username = new Input('text', '账号');
  const password = new Input('password', '密码');
  const checkbox = new Input('checkbox', ''); checkbox.checked = false;
  const submit = {textContent: '登录', children: [], isConnected: true, classList: {contains: () => !options.agreement}, getClientRects: () => [1], click() {clicks++;}};
  const inputs = options.ready ? [] : [username, password];
  if (options.captcha) inputs.push(new Input('text', '验证码'));
  const document = {
    querySelectorAll(selector) {
      if (selector === 'input') return inputs;
      if (selector.includes('captcha')) return [];
      if (selector === 'input[type=checkbox]') return options.checkbox ? [checkbox] : [];
      return options.ready ? [] : [submit];
    },
    querySelector() { return options.agreement ? {} : null; }
  };
  const location = new URL(options.url || 'https://www.ixuecheng.cn/detail?id=42');
  const window = {name: 'synthetic'};
  const context = vm.createContext({document, location, window, HTMLInputElement: Input, URL,
    getComputedStyle: () => ({visibility: 'visible'}), Event: class {}, setTimeout: fn => timers.push(fn)});
  vm.runInContext(source, context);
  const status = context.studyWebsiteLogin(['www.ixuecheng.cn'], 'xuecheng', options.noCredentials ? null : {username: 'SYNTHETIC_USER', password: 'SYNTHETIC_PASSWORD'});
  if (options.navigate) location.hostname = 'other.example';
  timers.forEach(fn => fn());
  return {status, clicks, writes, window};
}
for (const options of [{url:'https://www.ixuecheng.cn.evil.example/login'}, {url:'http://www.ixuecheng.cn/login'}, {url:'https://www.ixuecheng.cn:444/login'}, {form:'https://other.example/login'}, {captcha:true}, {checkbox:true}]) {
  const result = page(options); assert.equal(result.status, 'verification'); assert.equal(result.clicks,0); assert.equal(result.writes,0); checks++;
}
assert.equal(page({noCredentials:true}).status,'login-required'); checks++;
assert.equal(page({ready:true}).status,'ready'); checks++;
const login = page(); assert.equal(login.status,'submitted'); assert.equal(login.clicks,1); assert.equal(login.writes,2); checks++;
const agreement = page({agreement:true}); assert.equal(agreement.clicks,0); assert.equal(agreement.window.__studyLoginState,'verification'); checks++;
assert.equal(page({navigate:true}).clicks,0); checks++;
console.log(`Website login guards: ${checks} checks passed`);
