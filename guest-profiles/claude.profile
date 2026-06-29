# Guest Firejail overlay for Claude Code. Install next to guest-profiles/code-agent.profile.
include claude.local
whitelist ${HOME}/.claude
whitelist ${HOME}/.config/claude
read-only ${HOME}/.claude
read-only ${HOME}/.config/claude
include code-agent.profile
