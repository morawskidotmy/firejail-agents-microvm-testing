# Guest Firejail overlay for OpenCode. Install next to guest-profiles/code-agent.profile.
include opencode.local
whitelist ${HOME}/.opencode
whitelist ${HOME}/.config/opencode
whitelist ${HOME}/.local/share/opencode
read-only ${HOME}/.opencode
read-only ${HOME}/.config/opencode
include code-agent.profile
