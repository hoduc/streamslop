// ==UserScript==
// @name         X to Discord
// @namespace    x-to-discord
// @version      1.1.0
// @description  Adds a Discord button to X posts that sends the link to your Discord channel.
// @match        https://x.com/*
// @match        https://twitter.com/*
// @grant        GM_xmlhttpRequest
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        GM_registerMenuCommand
// @connect      discord.com
// ==/UserScript==

// The webhook is NOT in this file. It's stored privately in the userscript manager.
const WEBHOOK = GM_getValue("webhook", "");

GM_registerMenuCommand("Set Discord webhook", () => {
  const input = prompt("Paste your Discord webhook URL:", WEBHOOK);
  if (input === null) return;
  if (!/^https:\/\/discord(app)?\.com\/api\/webhooks\//.test(input.trim())) {
    alert("That doesn't look like a Discord webhook URL.");
    return;
  }
  GM_setValue("webhook", input.trim());
  location.reload();
});

function send(content) {
  return new Promise((resolve) => {
    GM_xmlhttpRequest({
      method: "POST",
      url: WEBHOOK,
      headers: { "Content-Type": "application/json" },
      data: JSON.stringify({ content }),
      onload: (r) => resolve(r.status >= 200 && r.status < 300),
      onerror: () => resolve(false),
    });
  });
}

function addButtons() {
  if (!WEBHOOK) return;
  document
    .querySelectorAll('article[data-testid="tweet"]:not([data-d2d])')
    .forEach((article) => {
      article.dataset.d2d = "1";
      const link = article.querySelector('a[href*="/status/"] time')?.parentElement;
      const bar = article.querySelector('[role="group"]');
      if (!link || !bar) return;

      const btn = document.createElement("button");
      btn.textContent = "➡️ Discord";
      btn.style.cssText =
        "margin-left:6px;padding:2px 8px;border-radius:12px;border:1px solid #888;background:none;color:inherit;cursor:pointer;font-size:12px";
      btn.onclick = async (e) => {
        e.preventDefault();
        e.stopPropagation();
        btn.textContent = "…";
        // fixupx makes Discord show the full post embed
        const url = link.href.split("?")[0].replace(/https:\/\/(x|twitter)\.com/, "https://fixupx.com");
        btn.textContent = (await send(url)) ? "✅ Sent" : "❌ Failed";
      };
      bar.appendChild(btn);
    });
}

new MutationObserver(addButtons).observe(document.body, { childList: true, subtree: true });
addButtons();
