window.__ModuleLoader__.load({
	id: "dsh-browser-bridge",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		let react = require("react");
		let react_jsx_runtime = require("react/jsx-runtime");

		//#region css
		// 一份样式两处用：设置页的独立入口（settings.section）和插件行上的配置卡片
		// （plugins.row.config）。只用 DSH 自己的 token，换主题不用跟着改。
		const css = ".bbx_page{display:flex;flex-direction:column;gap:12px;max-width:560px;padding-top:4px}.bbx_h2{margin:0;font-size:18px;font-weight:600;line-height:26px;color:var(--dsw-alias-label-primary)}.bbx_lead{margin:0;font-size:13px;line-height:20px;color:var(--dsw-alias-label-tertiary)}.bbx_root{display:flex;flex-direction:column;gap:8px;max-width:560px}.bbx_label{font-size:13px;font-weight:500;line-height:20px;color:var(--dsw-alias-label-primary)}.bbx_modes{display:flex;flex-wrap:wrap;gap:8px}.bbx_mode{border:.5px solid var(--dsw-alias-border-l4);border-radius:var(--dsw-radius-md);background:var(--dsw-alias-bg-layer-2);color:var(--dsw-alias-label-primary);font:inherit;font-size:13px;line-height:20px;cursor:pointer;padding:7px 14px}.bbx_mode[data-active=true]{border-color:var(--dsw-alias-state-business-primary);background:color-mix(in srgb, var(--dsw-alias-state-business-primary) 12%, transparent);color:var(--dsw-alias-label-primary)}.bbx_mode:disabled{opacity:.55;cursor:default}@media (hover:hover){.bbx_mode:not(:disabled):not([data-active=true]):hover{background:var(--dsw-alias-interactive-bg-hover)}}.bbx_mode:focus-visible{outline:var(--dsw-focus-ring-width) solid var(--dsw-focus-ring-color,var(--dsw-alias-state-business-primary));outline-offset:2px}.bbx_hint{margin:0;font-size:12px;line-height:18px;color:var(--dsw-alias-label-secondary)}.bbx_note{margin:0;font-size:12px;line-height:18px;color:var(--dsw-alias-label-tertiary)}.bbx_error{margin:0;font-size:12px;line-height:18px;color:var(--dsw-alias-state-error-primary)}";
		const tagId = "dsh-browser-bridge/ModeCard.css";
		if (typeof document !== "undefined" && document.querySelector("style[data-plugin-css=" + JSON.stringify(tagId) + "]") === null) {
			const tag = document.createElement("style");
			tag.dataset.plugin = "dsh-browser-bridge";
			tag.dataset.pluginCss = tagId;
			tag.textContent = css;
			document.head.appendChild(tag);
		}
		const styles = {
			page: "bbx_page",
			h2: "bbx_h2",
			lead: "bbx_lead",
			root: "bbx_root",
			label: "bbx_label",
			modes: "bbx_modes",
			mode: "bbx_mode",
			hint: "bbx_hint",
			note: "bbx_note",
			error: "bbx_error"
		};
		//#endregion

		//#region locales
		const NS = "settings.browserBridge";
		const zh = {
			nav: "浏览器桥",
			title: "目标浏览器",
			pageTitle: "浏览器桥",
			pageLead: "决定 browser_* 工具操作哪个浏览器窗口。改动写入 profile 的 cordis.patch.yml，插件随即热重载。",
			summary: "目标浏览器：{mode}",
			"opt.existing": "仅已打开的浏览器",
			"opt.new": "仅新浏览器",
			"opt.auto": "自动（优先新浏览器）",
			"hint.existing": "只驱动你自己打开的窗口，插件绝不启动浏览器。默认值，行为与旧版本一致。",
			"hint.new": "只驱动插件自己启动的那个实例（独立配置目录，不碰你的登录态）。没有就启动一个；启动失败就报错，不会退回去操作你的窗口。",
			"hint.auto": "优先用插件启动的实例；启动不了才退回你已打开的窗口。",
			liveNote: "点一下立即生效：写回 profile 的 cordis.patch.yml 并热重载插件，不用重启 DSH。切换会重挂插件，正在跑的浏览器调用会被打断。",
			readOnly: "这个部署的配置是只读的，改了也不会生效。",
			unavailable: "这个部署没有开放该插件的配置，请在 profile 的 cordis.patch.yml 里改 targetMode。",
			saveFailed: "宿主没有接受这次写入，值已回滚。"
		};
		const en = {
			nav: "Browser bridge",
			title: "Target browser",
			pageTitle: "Browser bridge",
			pageLead: "Picks which browser window the browser_* tools act on. A change is written to the profile's cordis.patch.yml and the plugin remounts.",
			summary: "Target browser: {mode}",
			"opt.existing": "Only the browser you opened",
			"opt.new": "Only a new browser",
			"opt.auto": "Automatic (prefer a new browser)",
			"hint.existing": "Drives only the window you opened; the plugin never launches a browser. This is the default and matches the previous behaviour.",
			"hint.new": "Drives only the instance the plugin launches (its own profile directory, your logins untouched). It launches one when none is running, and reports the failure instead of falling back to your window.",
			"hint.auto": "Prefers the instance the plugin launches and falls back to the window you opened when launching is not possible.",
			liveNote: "A click applies immediately: the value is written to the profile's cordis.patch.yml and the plugin remounts, no DSH restart. Remounting interrupts browser calls that are in flight.",
			readOnly: "This deployment stores configuration read-only; a change would not take effect.",
			unavailable: "This deployment does not expose the plugin's configuration. Set targetMode in the profile's cordis.patch.yml instead.",
			saveFailed: "The host rejected the write, so the value was rolled back."
		};
		//#endregion

		//#region ModeControl
		const OPTIONS = ["existing", "new", "auto"];
		const MODE_OF = { existing: "opt.existing", new: "opt.new", auto: "opt.auto" };

		/**
		 * Resolve a translation function for either surface.
		 *
		 * The section gets `t` through its inject face, the row card through the
		 * slot's locale option; a deployment that injects neither still renders
		 * readable Chinese instead of raw keys.
		 */
		function translator(props) {
			const bound = typeof props.t === "function" ? props.t : null;
			return (key) => {
				const value = bound ? bound(key) : void 0;
				return typeof value === "string" && value !== "" ? value : zh[key] ?? key;
			};
		}

		/** Read the saved mode out of a settings namespace snapshot. */
		function modeOf(state) {
			const value = state?.value?.targetMode;
			return OPTIONS.includes(value) ? value : "existing";
		}

		/**
		 * The three-way switch itself.
		 *
		 * One click is one write: `mutate` sends a single path op with the revision
		 * the snapshot was read at, so a concurrent edit is rejected by the host
		 * instead of being silently overwritten. A rejected write rolls itself back.
		 *
		 * @param props - `t`, the namespace snapshot, its mutate, and disabled state.
		 */
		function ModeControl(props) {
			const t = props.t;
			const state = props.state;
			const value = modeOf(state);
			const [pending, setPending] = react.useState("");
			const [error, setError] = react.useState("");
			const disabled = props.disabled === true || pending !== "";

			const choose = (next) => {
				if (next === value || disabled || !props.mutate) return;
				setPending(next);
				setError("");
				Promise.resolve(props.mutate([{ op: "set", path: ["targetMode"], value: next }], state?.revision))
					.then((accepted) => {
						if (accepted === false) setError(t("saveFailed"));
					})
					.catch(() => setError(t("saveFailed")))
					.then(() => setPending(""));
			};

			return (0, react_jsx_runtime.jsxs)("div", {
				className: styles.root,
				children: [
					(0, react_jsx_runtime.jsx)("div", { className: styles.label, children: t("title") }),
					(0, react_jsx_runtime.jsx)("div", {
						className: styles.modes,
						role: "radiogroup",
						"aria-label": t("title"),
						children: OPTIONS.map((option) => (0, react_jsx_runtime.jsx)("button", {
							type: "button",
							role: "radio",
							className: styles.mode,
							"aria-checked": option === value,
							"data-active": option === value ? "true" : void 0,
							disabled,
							onClick: () => choose(option),
							children: t(MODE_OF[option])
						}, option))
					}),
					(0, react_jsx_runtime.jsx)("p", { className: styles.hint, children: t("hint." + value) }),
					state?.writable === false
						? (0, react_jsx_runtime.jsx)("p", { className: styles.error, children: t("readOnly") })
						: null,
					error !== ""
						? (0, react_jsx_runtime.jsx)("p", { className: styles.error, children: error })
						: null,
					(0, react_jsx_runtime.jsx)("p", { className: styles.note, children: t("liveNote") })
				]
			});
		}
		//#endregion

		//#region RowCard
		/**
		 * The plugin row's configuration card (Settings -> Plugins -> configure).
		 *
		 * The owner hands over `form` = { state, mutate }. There is no save button on
		 * purpose: one click is one write.
		 *
		 * @param props - `view` ('summary' | 'page'), `form`, and the locale `t`.
		 */
		function RowCard(props) {
			const t = translator(props);
			const form = props.form;
			const state = form?.state;

			if (props.view === "summary") {
				return t("summary").replace("{mode}", t(MODE_OF[modeOf(state)]));
			}
			if (!form) {
				return (0, react_jsx_runtime.jsx)("p", { className: styles.note, children: t("unavailable") });
			}

			return (0, react_jsx_runtime.jsx)(ModeControl, {
				t,
				state,
				mutate: form.mutate,
				disabled: state?.writable === false
			});
		}
		//#endregion

		//#region Section
		/**
		 * The standalone settings page (Settings -> Browser bridge).
		 *
		 * The shell passes only `close`; the form arrives through this entry's inject
		 * face as the `browserBridgeForm` store, which the slot turns into the
		 * `useBrowserBridgeForm` hook.
		 *
		 * @param props - the injected `t`, the namespace store hook, and `close`.
		 */
		function Section(props) {
			const t = translator(props);
			const state = props.useBrowserBridgeForm((snapshot) => snapshot);
			return (0, react_jsx_runtime.jsxs)("div", {
				className: styles.page,
				children: [
					(0, react_jsx_runtime.jsx)("h2", { className: styles.h2, children: t("pageTitle") }),
					(0, react_jsx_runtime.jsx)("p", { className: styles.lead, children: t("pageLead") }),
					(0, react_jsx_runtime.jsx)(ModeControl, {
						t,
						state,
						mutate: props.browserBridgeMutate,
						disabled: state?.writable === false
					})
				]
			});
		}

		/** Navigation glyph: a browser window with its tab strip. */
		function BrowserIcon(props) {
			const size = props && props.size ? props.size : 16;
			return (0, react_jsx_runtime.jsxs)("svg", {
				width: size,
				height: size,
				viewBox: "0 0 16 16",
				fill: "none",
				"aria-hidden": "true",
				children: [
					(0, react_jsx_runtime.jsx)("rect", {
						x: 1.6,
						y: 2.6,
						width: 12.8,
						height: 10.8,
						rx: 2,
						stroke: "currentColor",
						strokeWidth: 1.2
					}),
					(0, react_jsx_runtime.jsx)("path", {
						d: "M1.6 5.7h12.8",
						stroke: "currentColor",
						strokeWidth: 1.2
					}),
					(0, react_jsx_runtime.jsx)("circle", { cx: 3.7, cy: 4.15, r: 0.55, fill: "currentColor" }),
					(0, react_jsx_runtime.jsx)("circle", { cx: 5.5, cy: 4.15, r: 0.55, fill: "currentColor" })
				]
			});
		}
		//#endregion

		//#region index
		/** Settings namespace = the loader entry id this package's patch inserts. */
		const NAMESPACE = "dsh-browser-bridge";

		/** Section id in the settings navigation. */
		const SECTION_ID = "browser-bridge";

		/** Required services (cordis fiber inject). */
		const inject = ["slots", "locale", "configForms"];

		/**
		 * Mount both configuration surfaces.
		 *
		 * 1. `settings.section` + `settings.section.icon`: a page of its own in the
		 *    settings navigation, next to the shipped ones.
		 * 2. `plugins.row.config`: the same switch on the plugin's row under
		 *    Settings -> Plugins, keyed by `<package>#<row id>`.
		 *
		 * Both write the same namespace field, so the two surfaces can never drift.
		 * Neither is registered until the Host serves the namespace, which keeps a
		 * deployment without this plugin's host half free of empty pages.
		 *
		 * @param ctx - the browser plugin context.
		 */
		function apply(ctx) {
			const t = ctx.locale.bind(NS);
			ctx.effect(() => ctx.locale.register(NS, { zh, en }), "dsh-browser-bridge: dictionaries");

			const form = ctx.configForms.get(NAMESPACE);
			ctx.effect(() => () => {
				try { form.dispose(); } catch { /* already gone */ }
			}, "dsh-browser-bridge: configuration form");

			ctx.effect(() => ctx.configForms.whileServed([NAMESPACE], () => {
				const face = () => ({
					t,
					browserBridgeMutate: (ops, revision) => form.mutate(ops, revision),
					hooks: { browserBridgeForm: form }
				});
				const offSection = ctx.slots.inject("settings.section", () => ctx.slots.register({
					name: "settings.section",
					id: SECTION_ID,
					order: 25,
					label: () => t("nav"),
					locale: NS,
					inject: face
				}, Section));
				const offIcon = ctx.slots.inject("settings.section.icon", () => ctx.slots.register({
					name: "settings.section.icon",
					id: SECTION_ID
				}, BrowserIcon));
				const offRow = ctx.slots.inject("plugins.row.config", () => ctx.slots.register({
					name: "plugins.row.config",
					key: "dsh-browser-bridge#dsh-browser-bridge",
					locale: NS
				}, RowCard));
				return () => {
					offRow();
					offIcon();
					offSection();
				};
			}), "dsh-browser-bridge: settings surfaces");
		}
		//#endregion

		exports.NS = NS;
		exports.NAMESPACE = NAMESPACE;
		exports.SECTION_ID = SECTION_ID;
		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});
