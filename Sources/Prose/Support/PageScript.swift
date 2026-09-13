//  The script prose puts in every page, so an agent can act on elements
//  instead of guessing selectors.
//
//  An agent reading a page gets `innerText` — prose, which carries no
//  selectors. Asked to click something, it had nothing to go on but a CSS
//  selector invented from that prose, and it invented them wrong: there is no
//  feedback when `document.querySelector` matches nothing, so a wrong guess and
//  a page that ignored the click are the same event.
//
//  So the page keeps a numbered list. `scan` walks the DOM for things a person
//  could interact with, hands back their roles and accessible names, and
//  remembers the elements themselves in an array. `act` addresses that array by
//  index. The agent never writes a selector.
//
//  **Staleness is loud.** The list lives in the page's own JavaScript context,
//  which a navigation destroys outright — so a ref from the previous page finds
//  no `window.__prose` at all and says so, rather than acting on whatever now
//  occupies index three. `generation` covers the softer case of a same-page
//  re-render, where the context survives but the elements do not.
//
//  # Every gap here sends an agent back to `browser_eval`
//
//  The list above was the first half of the job and left the second half
//  undone: a pilot that could click a link still could not choose from a
//  `<select>`, press Escape, scroll a pane that was not the window, or find
//  the one link it wanted among a thousand. Each of those is a thing a page
//  genuinely requires, and an agent that cannot do it through a ref does it
//  through a script — correctly, given what it had. So the fix for "the model
//  keeps writing DOM traversal" is mostly here, in what the refs *cannot yet
//  reach*, and only a little in the prompt telling it not to.
//
//  `settle` is the other half of the same argument. A ref-based click that
//  triggers no navigation leaves an agent with nothing to wait on, so it polls
//  — and polling is `browser_eval` in a loop, at a round trip and a script's
//  worth of context each. Waiting belongs in the page, where it costs nothing.

enum PageScript {
    /// Injected at document start, main frame only, on every navigation.
    static let source = #"""
    (() => {
      if (window.__prose) return;

      // Everything a person could plausibly act on. Deliberately generous:
      // a missing element is an agent that cannot do its job, while a spurious
      // one costs a line.
      const CANDIDATES = [
        'a[href]', 'button', 'input', 'textarea', 'select', 'summary',
        '[contenteditable=""]', '[contenteditable="true"]',
        '[onclick]', '[tabindex]', '[role]',
      ].join(', ');

      // Roles that mean "you can do something to this". An element matched
      // only by `[role]` has to be one of these, or every heading and region
      // on the page would be listed.
      const ACTIONABLE = new Set([
        'button', 'link', 'checkbox', 'radio', 'tab', 'switch', 'option',
        'menuitem', 'menuitemcheckbox', 'menuitemradio', 'combobox',
        'textbox', 'searchbox', 'slider', 'spinbutton',
      ]);

      const NATIVE = new Set(['A', 'BUTTON', 'INPUT', 'TEXTAREA', 'SELECT', 'SUMMARY']);

      // A hard stop on how many elements one scan will hold refs for. Not a
      // display limit — `scan` has its own, smaller one — but a guard against
      // a pathological page costing the main thread a visible pause.
      const CEILING = 4000;

      const state = { refs: [], generation: 0 };
      window.__prose = state;

      const trim = (value) => String(value == null ? '' : value)
        .replace(/\s+/g, ' ').trim().slice(0, 120);

      const visible = (el) => {
        const style = window.getComputedStyle(el);
        if (style.visibility === 'hidden' || style.display === 'none') return false;
        const box = el.getBoundingClientRect();
        return box.width > 0 && box.height > 0;
      };

      const roleOf = (el) => {
        const explicit = el.getAttribute('role');
        if (explicit) return explicit.toLowerCase();
        const tag = el.tagName;
        if (tag === 'A') return 'link';
        if (tag === 'BUTTON' || tag === 'SUMMARY') return 'button';
        if (tag === 'SELECT') return 'combobox';
        if (tag === 'TEXTAREA') return 'textbox';
        if (tag === 'INPUT') {
          const type = (el.type || 'text').toLowerCase();
          if (type === 'checkbox' || type === 'radio') return type;
          if (type === 'submit' || type === 'reset' || type === 'button') return 'button';
          if (type === 'search') return 'searchbox';
          return 'textbox';
        }
        if (el.isContentEditable) return 'textbox';
        return 'button';
      };

      // The order a screen reader would use, which is the order that produces
      // the label a person would actually read off the screen.
      const nameOf = (el) => {
        const label = el.getAttribute('aria-label');
        if (label) return trim(label);

        const by = el.getAttribute('aria-labelledby');
        if (by) {
          const parts = by.split(/\s+/)
            .map((id) => document.getElementById(id))
            .filter(Boolean)
            .map((node) => node.innerText || node.textContent);
          if (parts.length) return trim(parts.join(' '));
        }

        const text = trim(el.innerText || el.textContent);
        if (text) return text;
        if (el.placeholder) return trim(el.placeholder);
        if (el.title) return trim(el.title);
        if (el.alt) return trim(el.alt);

        const image = el.querySelector ? el.querySelector('img[alt]') : null;
        if (image && image.alt) return trim(image.alt);

        // A password's value is never a name, and never leaves the page.
        if (typeof el.value === 'string' && el.type !== 'password') return trim(el.value);
        if (el.name) return trim(el.name);
        return '';
      };

      const wanted = (el) => {
        if (NATIVE.has(el.tagName)) return true;
        if (el.isContentEditable) return true;
        if (el.hasAttribute('onclick')) return true;
        const explicit = el.getAttribute('role');
        if (explicit && ACTIONABLE.has(explicit.toLowerCase())) return true;
        const index = el.getAttribute('tabindex');
        return index !== null && Number(index) >= 0;
      };

      // Document order, descending into open shadow roots where their host
      // sits.
      //
      // `querySelectorAll` stops dead at a shadow boundary, so a page built
      // out of web components reported almost nothing actionable — which
      // looks to an agent exactly like a page with no links, and sends it to
      // `browser_eval`, where the same boundary is waiting for it. A *closed*
      // root is unreachable from any script, so there is nothing there this
      // could have found either way.
      const gather = (root, out) => {
        for (const el of root.children || []) {
          if (out.length >= CEILING) return;
          if (el.matches(CANDIDATES) && wanted(el) && visible(el)) out.push(el);
          if (el.shadowRoot) gather(el.shadowRoot, out);
          gather(el, out);
        }
      };

      const describe = (el) => {
        const entry = {
          ref: 'e' + (state.refs.push(el)),
          role: roleOf(el),
          name: nameOf(el),
        };
        // Only what is not the default, so a long list stays readable.
        if (el.disabled) entry.enabled = false;
        if (el.tagName === 'A') entry.href = trim(el.getAttribute('href'));
        if ((el.type === 'checkbox' || el.type === 'radio')) entry.checked = !!el.checked;
        if (typeof el.value === 'string' && el.type !== 'password' && el.value) {
          entry.value = trim(el.value);
        }
        return entry;
      };

      // **Every** actionable element gets a ref, even the ones no caller is
      // about to be shown. That is what lets `find` hand back `e743` on a page
      // whose list was cut off at two hundred: the number addresses the scan,
      // not the excerpt of it that was printed.
      const collect = () => {
        state.generation += 1;
        state.refs = [];
        const found = [];
        gather(document, found);
        return found.map(describe);
      };

      const where = () => ({
        generation: state.generation,
        url: location.href,
        title: document.title,
      });

      state.scan = (cap) => {
        const all = collect();
        const shown = all.slice(0, cap);
        return Object.assign(where(), {
          total: all.length,
          truncated: all.length > shown.length,
          elements: shown,
        });
      };

      // The answer to a long page, which is the common case and used to be the
      // most reliable way to push an agent into writing a script: ask for the
      // elements of an article with nine hundred links, get two hundred lines
      // of site chrome, and none of them is the one you wanted.
      state.find = (query, cap) => {
        const all = collect();
        const want = String(query == null ? '' : query).toLowerCase();
        const hit = (entry) =>
          entry.name.toLowerCase().includes(want)
          || String(entry.href || '').toLowerCase().includes(want);
        const matched = want ? all.filter(hit) : all;
        return Object.assign(where(), {
          total: all.length,
          matched: matched.length,
          truncated: matched.length > cap,
          elements: matched.slice(0, cap),
        });
      };

      const at = (ref) => {
        const index = parseInt(String(ref).replace(/^e/, ''), 10) - 1;
        const el = state.refs[index];
        // `isConnected` is the same-page case: the list was taken, the app
        // re-rendered, and this node is no longer in the document.
        return el && el.isConnected ? el : null;
      };

      const stale = (ref) => ({
        error: 'no element ' + ref + ' on this page — it has changed since the '
             + 'list was taken. Call browser_elements again.',
      });

      // Assigning `el.value` directly is invisible to React and Vue: they patch
      // the property on the instance, so the field shows the text and the
      // application never learns of it. That looks exactly like the model
      // having typed nothing, and it is the single most confusing failure
      // available on a modern page.
      const setValue = (el, value) => {
        const prototype = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
          : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype
          : HTMLInputElement.prototype;
        const descriptor = Object.getOwnPropertyDescriptor(prototype, 'value');
        if (descriptor && descriptor.set) descriptor.set.call(el, value);
        else el.value = value;
      };

      const fire = (el, ...names) => {
        for (const name of names) {
          el.dispatchEvent(new Event(name, { bubbles: true, composed: true }));
        }
      };

      state.click = (ref) => {
        const el = at(ref);
        if (!el) return stale(ref);
        if (el.disabled) return { error: nameOf(el) + ' is disabled' };
        el.scrollIntoView({ block: 'center', inline: 'nearest' });
        const options = { bubbles: true, cancelable: true, view: window, composed: true };
        // Read before the click, because the click is what invalidates it.
        const target = el.tagName === 'A' ? el.href : null;
        try {
          // The whole pointer sequence, not a bare `.click()`. Plenty of
          // components listen for `pointerdown` or `mousedown` and never see a
          // synthesised click at all, which looks from outside like the click
          // silently not working.
          if (window.PointerEvent) el.dispatchEvent(new PointerEvent('pointerdown', options));
          el.dispatchEvent(new MouseEvent('mousedown', options));
          if (el.focus) el.focus();
          if (window.PointerEvent) el.dispatchEvent(new PointerEvent('pointerup', options));
          el.dispatchEvent(new MouseEvent('mouseup', options));
          el.click();
        } catch (failure) {
          return { error: String(failure) };
        }
        const result = { ok: true, clicked: nameOf(el), url: location.href };
        // Whether to expect a load. A click returns before any navigation it
        // started, so `url` above is still the old page — an agent told only
        // "ok" cannot tell a link it just followed from a button that did
        // nothing, and goes looking for the difference with a script.
        if (target && target !== location.href) result.navigating = target;
        return result;
      };

      state.type = (ref, text, enter) => {
        const el = at(ref);
        if (!el) return stale(ref);
        if (el.disabled || el.readOnly) return { error: nameOf(el) + ' cannot be typed into' };
        el.scrollIntoView({ block: 'center', inline: 'nearest' });
        if (el.focus) el.focus();

        try {
          if (el.isContentEditable) {
            el.textContent = text;
            el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true }));
          } else {
            setValue(el, text);
            fire(el, 'input', 'change');
          }

          if (enter) {
            press(el, 'enter');
            // A form that listens for submit rather than for Enter still wants
            // submitting; `requestSubmit` runs validation as a real press would.
            if (el.form && typeof el.form.requestSubmit === 'function') el.form.requestSubmit();
          }
        } catch (failure) {
          return { error: String(failure) };
        }
        return { ok: true, value: typeof el.value === 'string' ? trim(el.value) : trim(el.textContent) };
      };

      // A dropdown is not a click target. Dispatching a pointer sequence at a
      // `<select>` opens nothing — the menu is drawn by the platform, outside
      // the page — so this was the clearest case of a control an agent could
      // see, name, and have no way at all to operate.
      state.select = (ref, option) => {
        const el = at(ref);
        if (!el) return stale(ref);
        if (el.disabled) return { error: nameOf(el) + ' is disabled' };
        const want = String(option == null ? '' : option).toLowerCase();

        if (el.tagName !== 'SELECT') {
          // The ARIA spelling of the same control: a listbox of `option`
          // elements somewhere else in the document, which *is* clickable.
          const owned = el.getAttribute('aria-controls');
          const box = (owned && document.getElementById(owned)) || el;
          const options = Array.from(box.querySelectorAll('[role="option"]'));
          const found = options.find((node) => trim(nameOf(node)).toLowerCase() === want)
            || options.find((node) => trim(nameOf(node)).toLowerCase().includes(want));
          if (!found) {
            return {
              error: 'no option matching ' + JSON.stringify(option) + ' — this is not a <select>, '
                   + 'and its listbox offers: '
                   + JSON.stringify(options.slice(0, 30).map(nameOf)),
            };
          }
          found.scrollIntoView({ block: 'center', inline: 'nearest' });
          found.click();
          return { ok: true, selected: nameOf(found) };
        }

        const options = Array.from(el.options);
        const label = (node) => trim(node.label || node.textContent).toLowerCase();
        const found = options.find((node) => label(node) === want)
          || options.find((node) => String(node.value).toLowerCase() === want)
          || options.find((node) => label(node).includes(want));
        if (!found) {
          return {
            error: 'no option matching ' + JSON.stringify(option) + ' — this select offers: '
                 + JSON.stringify(options.slice(0, 50).map((node) => trim(node.label || node.textContent))),
          };
        }
        setValue(el, found.value);
        fire(el, 'input', 'change');
        return { ok: true, selected: trim(found.label || found.textContent), value: found.value };
      };

      // Enter was the only key an agent could send, which left Escape, Tab and
      // the arrows — modals, autocompletes, and every listbox — reachable only
      // by script.
      const KEYS = {
        enter: { key: 'Enter', code: 'Enter', keyCode: 13 },
        escape: { key: 'Escape', code: 'Escape', keyCode: 27 },
        tab: { key: 'Tab', code: 'Tab', keyCode: 9 },
        backspace: { key: 'Backspace', code: 'Backspace', keyCode: 8 },
        delete: { key: 'Delete', code: 'Delete', keyCode: 46 },
        space: { key: ' ', code: 'Space', keyCode: 32 },
        arrowup: { key: 'ArrowUp', code: 'ArrowUp', keyCode: 38 },
        arrowdown: { key: 'ArrowDown', code: 'ArrowDown', keyCode: 40 },
        arrowleft: { key: 'ArrowLeft', code: 'ArrowLeft', keyCode: 37 },
        arrowright: { key: 'ArrowRight', code: 'ArrowRight', keyCode: 39 },
        home: { key: 'Home', code: 'Home', keyCode: 36 },
        end: { key: 'End', code: 'End', keyCode: 35 },
        pageup: { key: 'PageUp', code: 'PageUp', keyCode: 33 },
        pagedown: { key: 'PageDown', code: 'PageDown', keyCode: 34 },
      };

      const press = (el, name) => {
        const spec = KEYS[name];
        const init = Object.assign({}, spec, {
          which: spec.keyCode, bubbles: true, cancelable: true, composed: true,
        });
        el.dispatchEvent(new KeyboardEvent('keydown', init));
        el.dispatchEvent(new KeyboardEvent('keypress', init));
        el.dispatchEvent(new KeyboardEvent('keyup', init));
      };

      state.key = (ref, name) => {
        const key = String(name == null ? '' : name).toLowerCase();
        if (!KEYS[key]) {
          return { error: 'unknown key ' + JSON.stringify(name) + ' — known: ' + Object.keys(KEYS).join(', ') };
        }
        // No ref means "wherever the focus is", which is what a person pressing
        // Escape means.
        const el = ref ? at(ref) : (document.activeElement || document.body);
        if (ref && !el) return stale(ref);
        if (ref && el.focus) el.focus();
        try {
          press(el, key);
        } catch (failure) {
          return { error: String(failure) };
        }
        return { ok: true, key: KEYS[key].key, on: nameOf(el) || el.tagName.toLowerCase() };
      };

      const scrolls = (el) => {
        const style = window.getComputedStyle(el);
        const flow = style.overflowY;
        return (flow === 'auto' || flow === 'scroll' || flow === 'overlay')
          && el.scrollHeight > el.clientHeight + 1;
      };

      // What `to` and `by` move when no ref says otherwise. Usually the
      // document — but an application shell pins the document at viewport
      // height and scrolls a div inside it, and scrolling the document there
      // does nothing at all, silently.
      const primary = () => {
        const root = document.scrollingElement || document.documentElement;
        if (root.scrollHeight > root.clientHeight + 1) return root;
        let best = root;
        let area = 0;
        for (const el of document.querySelectorAll('div, main, section, ul, ol')) {
          if (!scrolls(el)) continue;
          const box = el.getBoundingClientRect();
          if (box.width * box.height > area) { area = box.width * box.height; best = el; }
        }
        return best;
      };

      // The scroller a ref actually lives in, so "scroll down in this list"
      // moves the list rather than the page behind it.
      const scrollerFor = (el) => {
        for (let node = el.parentElement; node; node = node.parentElement) {
          if (scrolls(node)) return node;
        }
        return primary();
      };

      const at_end = (el) => Math.ceil(el.scrollTop + el.clientHeight) >= el.scrollHeight - 1;

      state.scroll = (ref, to, by) => {
        const el = ref ? at(ref) : null;
        if (ref && !el) return stale(ref);

        // A ref with neither `to` nor `by` still means what it always meant:
        // put this element where I can see it.
        if (el && to == null && by == null) {
          el.scrollIntoView({ block: 'center', inline: 'nearest' });
          return { ok: true, at: nameOf(el) };
        }

        const box = el ? scrollerFor(el) : primary();
        const before = box.scrollTop;
        if (by != null) box.scrollTop = before + Number(by);
        else box.scrollTop = to === 'top' ? 0 : box.scrollHeight;

        // `moved` is the difference between "scrolled" and "already at the
        // bottom", which an agent paging through a long list has to be able to
        // tell or it pages forever.
        return {
          ok: true,
          top: Math.round(box.scrollTop),
          height: Math.round(box.scrollHeight),
          moved: Math.round(box.scrollTop - before),
          at_end: at_end(box),
        };
      };

      // The end of polling.
      //
      // A click that navigates is answered by the pane's load counter. A click
      // that opens a menu, filters a list or swaps a route is answered by
      // nothing, so an agent with no way to wait writes
      // `browser_eval("document.querySelector(...) !== null")` and calls it
      // every few hundred milliseconds — a round trip and a script's worth of
      // context per poll, to watch a page it is already standing in.
      //
      // Level-triggered, like every other wait in prose: if what you are
      // waiting for has already happened, this returns at once rather than
      // waiting for a change that is now in the past.
      state.settle = (timeoutMs, expect) => new Promise((resolve) => {
        const started = Date.now();
        const want = expect == null ? null : String(expect).toLowerCase();
        let observer = null;
        let quiet = null;
        let deadline = null;
        let done = false;

        const finish = (reason) => {
          if (done) return;
          done = true;
          if (observer) observer.disconnect();
          if (quiet) clearTimeout(quiet);
          if (deadline) clearTimeout(deadline);
          resolve({
            reason: reason,
            elapsed_ms: Date.now() - started,
            url: location.href,
            title: document.title,
          });
        };

        const there = () => {
          if (!want) return false;
          return String(document.body ? document.body.innerText : '').toLowerCase().includes(want);
        };

        if (there()) return finish('found');

        // Quiescence, not absence of work: pages mutate continuously, so what
        // is worth waiting for is a gap rather than a stop.
        //
        // **Only when nothing specific was asked for.** A caller waiting for
        // named text means it, and a page that is merely quiet has not
        // produced it — resolving on the gap would hand back the page as it
        // was before the thing arrived, which is the stale-read bug this
        // whole path exists to avoid, arriving by a new door. With an
        // `expect`, the only ways out are finding it and giving up.
        const restart = () => {
          if (want) return;
          if (quiet) clearTimeout(quiet);
          quiet = setTimeout(() => finish('quiet'), 250);
        };

        observer = new MutationObserver(() => {
          if (there()) return finish('found');
          restart();
        });
        observer.observe(document.documentElement, {
          childList: true, subtree: true, attributes: true, characterData: true,
        });
        deadline = setTimeout(() => finish('timeout'), Math.max(100, Number(timeoutMs) || 10000));
        restart();
      });
    })();
    """#

    /// Wraps a call so that a page without the script says why, rather than
    /// failing as an opaque JavaScript error.
    ///
    /// The script is injected at document start on every navigation, so its
    /// absence means something unusual — a frame it does not run in, or a page
    /// that threw before it finished — and an agent is better served by a
    /// sentence than by `null`.
    static func call(_ expression: String) -> String {
        """
        (window.__prose
            ? window.__prose.\(expression)
            : { error: "this page has no prose page script — it may still be loading" })
        """
    }

    /// The same guard for the async path, as the body of an `async` function.
    ///
    /// `settle` returns a promise, and `evaluateJavaScript` hands back a
    /// promise object rather than waiting for it — so the waiting calls go
    /// through `callAsyncJavaScript`, which needs statements rather than an
    /// expression.
    static let awaitingScan = """
        if (!window.__prose) {
            return { error: "this page has no prose page script — it may still be loading" };
        }
        const waited = await window.__prose.settle(timeout, expect);
        const listed = window.__prose.scan(cap);
        listed.waited = waited;
        return listed;
        """
}
