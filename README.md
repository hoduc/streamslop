# Utilities

- dell-input.ps1 : Switch to different input of a monitor if it supports
- X to Discord: Share link to Discord server for collecting/archiving purpose


## X to Discord

Firefox userscript that adds a **➡️ Discord** button to posts on X. Click it and the
post link is sent to your Discord channel through a webhook.

### Setup
1. In your Discord server: Channel settings > Integrations > Webhooks > New Webhook > Copy Webhook URL.
   (Webhooks work in server channels, not in group DMs.)
2. Install [Violentmonkey](https://addons.mozilla.org/firefox/addon/violentmonkey/) from addons.mozilla.org.
3. Violentmonkey icon > + > New script, paste the contents of `x-to-discord.user.js`, save.
4. On x.com, click the Violentmonkey icon > **Set Discord webhook** and paste the URL.

The webhook is stored only in your browser, never in this repo.

### Security notes
- Never commit the webhook URL. If it ever leaks or is committed, delete it in Discord and create a new one.
- Enable secret scanning + push protection in the repo's Security settings, and 2FA on GitHub.
- The script only runs on x.com / twitter.com and can only connect to discord.com.

### Ideas for later
- Categories (one webhook per channel), manual or AI-based.
