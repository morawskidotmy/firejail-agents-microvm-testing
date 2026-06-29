# Guest Firejail overlay for Codex CLI. Install next to guest-profiles/code-agent.profile.
include codex.local
whitelist ${HOME}/.codex
whitelist ${HOME}/.config/codex
read-only ${HOME}/.codex
read-only ${HOME}/.config/codex
include code-agent.profile
