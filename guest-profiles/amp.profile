# Guest Firejail overlay for Amp. Install next to guest-profiles/code-agent.profile.
include amp.local
whitelist ${HOME}/.amp
whitelist ${HOME}/.config/amp
read-only ${HOME}/.amp/bin
include code-agent.profile
