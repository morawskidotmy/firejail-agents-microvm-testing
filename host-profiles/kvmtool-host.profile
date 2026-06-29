# Host Firejail policy for kvmtool/lkvm.

include kvmtool-host.local

whitelist ${HOME}/.local/bin/lkvm
whitelist ${HOME}/.local/bin/kvmtool
read-only ${HOME}/.local/bin/lkvm
read-only ${HOME}/.local/bin/kvmtool

blacklist ${HOME}/.ssh
blacklist ${HOME}/.gnupg
blacklist ${HOME}/.password-store
blacklist ${HOME}/.aws
blacklist ${HOME}/.azure
blacklist ${HOME}/.kube
blacklist ${HOME}/.config/gh
blacklist ${HOME}/.config/gcloud
blacklist ${HOME}/.docker/config.json
blacklist ${HOME}/.config/containers/auth.json
blacklist ${HOME}/.mozilla
blacklist ${HOME}/.config/google-chrome
blacklist ${HOME}/.config/chromium
blacklist ${HOME}/.config/BraveSoftware
blacklist ${HOME}/.local/share/keyrings
blacklist ${HOME}/.local/share/gnome-keyring
blacklist ${HOME}/.npmrc
blacklist ${HOME}/.pypirc
blacklist ${HOME}/.netrc
blacklist ${HOME}/.git-credentials
blacklist /run/user/*/bus
blacklist /run/user/*/wayland-*
blacklist /run/user/*/pipewire-*
blacklist /run/user/*/podman
blacklist /var/run/docker.sock
blacklist /run/docker.sock
blacklist /tmp/.X11-unix
blacklist /tmp/.ICE-unix
blacklist /dev/sd*
blacklist /dev/nvme*
blacklist /dev/vd*
blacklist /dev/mapper
blacklist /dev/dm-*
blacklist /dev/loop*
blacklist /dev/md*

caps.drop all
nonewprivs
noroot
seccomp add_key,request_key,keyctl,bpf,perf_event_open,userfaultfd,io_uring_setup,io_uring_enter,io_uring_register,ptrace,process_vm_readv,process_vm_writev,process_madvise,kcmp,pidfd_getfd,setns,unshare,mount,umount2,pivot_root,chroot,open_tree,move_mount,fsopen,fsconfig,fsmount,fspick,name_to_handle_at,open_by_handle_at,init_module,finit_module,delete_module,kexec_load,kexec_file_load,iopl,ioperm,swapon,swapoff,reboot,acct,syslog,personality,modify_ldt
seccomp.block-secondary
restrict-namespaces
protocol unix,inet,inet6,netlink
nosound
novideo
no3d
notv
nodvd
nou2f
noinput
nodbus
rmenv DISPLAY
rmenv WAYLAND_DISPLAY
rmenv XAUTHORITY
rmenv XDG_SESSION_TYPE
disable-mnt
machine-id
private-tmp
private-etc alternatives,ca-certificates,resolv.conf,hosts,host.conf,hostname,nsswitch.conf,localtime,timezone,ssl,pki,protocols,services,passwd,group,shells,terminfo
