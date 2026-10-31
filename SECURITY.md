# Security

scope runs with the **Accessibility** permission, which lets it read every window's title and control keyboard focus, and it intercepts ⌘Tab with an event tap. A flaw in it could expose what is on screen or what is typed, so reports are welcome.

## Reporting a vulnerability

Report it privately through GitHub: [**Report a vulnerability**](https://github.com/np25071984/Scope/security/advisories/new). Please do not open a public issue.

Include the scope version (`scope version`), the macOS version, and the steps to reproduce. You should get an answer within a week.

## Supported versions

Only the latest release gets fixes.

## What scope touches

- **Reads:** window titles and positions (Accessibility), the on-screen window list, `~/.config/scope/scope.conf`.
- **Writes:** its launchd file in `~/Library/LaunchAgents`, `~/Library/Logs/scope.log`, and a control socket in the per-user temporary directory, readable by your user only.
- **Network:** none.
- **Keys:** the event tap sees every key press, but only acts on the switcher's own keys and keeps nothing.
