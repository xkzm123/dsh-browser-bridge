window.__ModuleLoader__.load({
	id: "dsh-browser-bridge",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		let react = require("react");
		let react_jsx_runtime = require("react/jsx-runtime");

		//#region css
		// 一张卡片、三个按钮。样式只用 DSH 自己的 token，换主题时不用跟着改。
		const css = ".bbx_root{display:flex;flex-direction:column;gap:8px;max-width:560px}.bbx_label{font-size:13px;font-weight:500;line-height:20px;color:var(--dsw-alias-label-primary)}.bbx_modes{display:flex;flex-wrap:wrap;gap:8px}.bbx_mode{border:.5px solid var(--dsw-alias-border-l4);border-radius:var(--dsw-radius-md);background:var(--dsw-alias-bg-layer-2);color:var(--dsw-alias-label-primary);font:inherit;font-size:13px;line-height:20px;cursor:pointer;padding:7px 14px}.bbx_mode[data-active=true]{border-color:var(--dsw-alias-state-business-primary);background:color-mix(in srgb, var(--dsw-alias-state-business-primary) 12%, transparent);color:var(--dsw-alias-label-primary)}.bbx_mode:disabled{opacity:.55;cursor:default}@media (hover:hover){.bbx_mode:not(:disabled):not([data-active=true]):hover{background:var(--dsw-alias-interactive-bg-hover)}}.bbx_mode:focus-visible{outline:var(--dsw-focus-ring-width) solid var(--dsw-focus-ring-color,var(--dsw-alias-state-business-primary));outline-offset:2px}.bbx_hint{margin:0;font-size:12px;line-height:18px;color:var(--dsw-alias-label-secondary)}.bbx_note{margin:0;font-size:12px;line-height:18px;color:var(--dsw-alias-label-tertiary)}.bbx_error{margin:0;font-size:12px;line-height:18px;color:var(--dsw-alias-state-error-primary)}";
		const tagId = "dsh-browser-bridge/ModeCard.css";
		if (typeof document !== "undefined" && document.querySelector("style[data-plugin-css=" + JSON.stringify(tagId) + "]") === null) {
			const tag = document.createElement("style");
			tag.dataset.plugin = "dsh-browser-bridge";
			tag.dataset.pluginCss = tagId;
			tag.textContent = css;
			document.head.appendChild(tag);
		}
		const styles = {
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
			title: "目标浏览器",
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
			title: "Target browser",
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

		//#region ModeCard
		const OPTIONS = ["existing", "new", "auto"];
		const MODE_OF = { existing: "opt.existing", new: "opt.new", auto: "opt.auto" };

		/** Pick a translation function even when the owner injects no `t`. */
		function translator(props) {
			if (typeof props.t === "function") return props.t;
			return (key) => zh[key] ?? key;
		}

		/**
		 * The row's configuration card: three mutually exclusive modes over the
		 * plugin's `targetMode` field.
		 *
		 * The owner hands over `form` = { state, mutate }. `state` is the settings
		 * namespace snapshot (value + revision); `mutate` writes one path op and
		 * answers whether the host accepted it. There is no save button on purpose:
		 * one click is one write, and a rejected write rolls itself back.
		 *
		 * @param props - `view` ('summary' | 'page'), `form`, and the locale `t`.
		 */
		function ModeCard(props) {
			const t = translator(props);
			const form = props.form;
			const state = form?.state;
			const value = state?.value?.targetMode ?? "existing";
			// 钩子必须无条件调用：view 在挂载后不会变，但顺序一旦错开 React 会直接报错。
			const [pending, setPending] = react.useState("");
			const [error, setError] = react.useState("");

			if (props.view === "summary") {
				return t("summary").replace("{mode}", t(MODE_OF[value] ?? MODE_OF.existing));
			}
			if (!form || !state) {
				return (0, react_jsx_runtime.jsx)("p", { className: styles.note, children: t("unavailable") });
			}

			const disabled = pending !== "" || state.writable === false;
			const choose = (next) => {
				if (next === value || disabled) return;
				setPending(next);
				setError("");
				Promise.resolve(form.mutate([{ op: "set", path: ["targetMode"], value: next }], state.revision))
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
					state.writable === false
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

		//#region index
		/** Required services (cordis fiber inject). */
		const inject = ["slots", "locale"];

		/**
		 * Mount the settings card.
		 *
		 * The card sits on the plugin's own row under Settings -> Plugins, keyed by
		 * `<package name>#<row id>`. The row id is the loader entry id this package's
		 * cordis.patch.yml inserts, which is also the settings namespace the host
		 * serves for that entry.
		 *
		 * @param ctx - the browser plugin context.
		 */
		function apply(ctx) {
			ctx.effect(() => ctx.locale.register(NS, { zh, en }), "dsh-browser-bridge: dictionaries");
			ctx.effect(() => ctx.slots.inject("plugins.row.config", () => ctx.slots.register({
				name: "plugins.row.config",
				key: "dsh-browser-bridge#dsh-browser-bridge",
				locale: NS
			}, ModeCard)), "dsh-browser-bridge: settings card");
		}
		//#endregion

		exports.NS = NS;
		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});
