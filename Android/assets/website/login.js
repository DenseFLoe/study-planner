function studyWebsiteLogin(hosts, site, credentials) { return (() => {
          const allowedHosts = hosts;
          if (location.protocol !== 'https:' || !allowedHosts.includes(location.hostname) || (location.port && location.port !== '443')) return 'verification';
          const expectedOwner = null;
          if (expectedOwner !== null && window.name !== expectedOwner) return 'verification';
          if (window.__studyLoginState === 'verification') return 'verification';
          const visible = e => e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
          const inputs = [...document.querySelectorAll('input')].filter(visible);
          const passwords = inputs.filter(e => e.type === 'password');
          const controls = [...document.querySelectorAll('button, [role=button], a, span, div')].filter(e => visible(e) && e.children.length === 0);
          const text = e => e.textContent.trim();
          if (!passwords.length) {
            const switcher = controls.find(e => /^(密码登录|账号密码登录|帐号密码登录|账号登录)$/.test(text(e)));
            if (switcher) { switcher.click(); return 'switching'; }
            if (inputs.some(e => /验证码|手机号|手机号码/.test(e.placeholder || '')) || /\/(login|signin)(\/|$)/i.test(location.pathname)) return 'login-required';
            const login = controls.find(e => /^(登录|立即登录|去登录|登录后查看)$/.test(text(e)));
            if (login) { login.click(); return 'switching'; }
            return 'ready';
          }
          if (passwords.length !== 1) return 'verification';
          if (inputs.some(e => /验证码|captcha|one-time-code/i.test([e.placeholder,e.name,e.autocomplete].join(' '))) ||
              [...document.querySelectorAll('[class*=captcha], [id*=captcha], .tac, .geetest_panel')].some(visible)) return 'verification';
          const credential = credentials;
          if (!credential) return 'login-required';
          const password = passwords[0], form = password.closest('form');
          if (form?.action && new URL(form.action, location.href).origin !== location.origin) return 'verification';
          const scope = password.closest('.login-sub-wrapper, [role=dialog], .ant-modal, .el-dialog') || document;
          const usernames = [...scope.querySelectorAll('input')].filter(e => visible(e) && ['text','tel','email'].includes(e.type) &&
            /账号|帐号|手机|电话|邮箱|username|account|phone|mobile|email/i.test([e.placeholder,e.name,e.id,e.autocomplete].join(' ')));
          if (usernames.length !== 1 || [...scope.querySelectorAll('input[type=checkbox]')].some(e => visible(e) && !e.checked)) return 'verification';
          const submit = [...scope.querySelectorAll('button, [role=button], input[type=submit]')].filter(visible)
            .find(e => /^(开启我的上岸之旅|登\s*录|立即登录)$/.test((e.textContent || e.value || '').trim()) && !e.disabled);
          if (!submit) return 'verification';
          const set = (element, value) => {
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(element, value);
            element.dispatchEvent(new Event('input', {bubbles:true}));
            element.dispatchEvent(new Event('change', {bubbles:true}));
          };
          set(usernames[0], credential.username); set(password, credential.password);
          const origin = location.origin, owner = window.name;
          setTimeout(() => {
            if (location.origin !== origin || window.name !== owner || !submit.isConnected || !password.isConnected) return;
            // 学丞 uses an image for its agreement control. The enabled button class is set only after agreement.
            if (site === 'xuecheng' && scope.querySelector('.agreement-line .check-img') && !submit.classList.contains('loginBtn-check')) {
              window.__studyLoginState = 'verification'; return;
            }
            submit.click();
          }, 250);
          return 'submitted';
        })(); }
