# Guest Firejail overlay for Aider. Install next to guest-profiles/code-agent.profile.
include aider.local
whitelist ${HOME}/.aider
whitelist ${HOME}/.config/aider
read-only ${HOME}/.aider
read-only ${HOME}/.config/aider
include code-agent.profile
