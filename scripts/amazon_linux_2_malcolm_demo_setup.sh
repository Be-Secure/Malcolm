#!/usr/bin/env bash

###################################################################################
# script for setting up a Malcolm demo instance on an Amazon Linux 2 instance
# from scratch.

###################################################################################
# initialize

if [ -z "$BASH_VERSION" ]; then
  echo "Wrong interpreter, please run \"$0\" with bash" >&2
  exit 1
fi

if ! type amazon-linux-extras >/dev/null 2>&1; then
  echo "This command only targets Amazon Linux 2" >&2
  exit 1
fi


REALPATH=realpath
DIRNAME=dirname
if ! (type "$REALPATH" && type "$DIRNAME") > /dev/null; then
  echo "$(basename "${BASH_SOURCE[0]}") requires $REALPATH and $DIRNAME" >&2
  exit 1
fi
SCRIPT_PATH="$($DIRNAME $($REALPATH -e "${BASH_SOURCE[0]}"))"
SCRIPT_NAME="$(basename $($REALPATH -e "${BASH_SOURCE[0]}"))"

LOCAL_DATA_PATH=${XDG_DATA_HOME:-$HOME/.local/share}
LOCAL_BIN_PATH=$HOME/.local/bin
LOCAL_CONFIG_PATH=${XDG_CONFIG_HOME:-$HOME/.config}

###################################################################################
# variables for env development environments and tools

ENV_LIST=(
  age
  fd
  jq
  yq
  ripgrep
  watchexec
)

DOCKER_COMPOSE_INSTALL_VERSION=( 1.29.2 )

if [[ $EUID -eq 0 ]]; then
  SCRIPT_USER="root"
  SUDO_CMD=""
else
  SCRIPT_USER="$(whoami)"
  SUDO_CMD="sudo"
fi

###################################################################################
# convenience function for installing curl/git/jq/moreutils for cloning/downloading
function InstallEssentialPackages {
  if curl -V >/dev/null 2>&1 && \
     git --version >/dev/null 2>&1 && \
     jq --version >/dev/null 2>&1; then
    echo "\"curl\", \"git\" and \"jq\" are already installed!" >&2
  else
    echo "Installing curl, git, and jq..." >&2
    $SUDO_CMD yum update -y >/dev/null 2>&1 && \
      $SUDO_CMD yum install -y curl git jq
  fi
}

###################################################################################
function _GitClone {
  git clone --depth=1 --single-branch --recurse-submodules --shallow-submodules --no-tags "$@"
}

###################################################################################
function _GitLatestRelease {
  if [ "$1" ]; then
    (set -o pipefail && curl -sL -f "https://api.github.com/repos/$1/releases/latest" | jq '.tag_name' | sed -e 's/^"//' -e 's/"$//' ) || \
      (set -o pipefail && curl -sL -f "https://api.github.com/repos/$1/releases" | jq '.[0].tag_name' | sed -e 's/^"//' -e 's/"$//' ) || \
      echo unknown
  else
    echo "unknown">&2
  fi
}

###################################################################################
# function to set up paths and init things after env installations
function _EnvSetup {
  if [ -d "${ASDF_DIR:-$HOME/.asdf}" ]; then
    . "${ASDF_DIR:-$HOME/.asdf}"/asdf.sh
    if [ -n $ASDF_DIR ]; then
      . "${ASDF_DIR:-$HOME/.asdf}"/completions/asdf.bash
      for i in ${ENV_LIST[@]}; do
        asdf reshim "$i" >/dev/null 2>&1 || true
      done
    fi
  fi
}

################################################################################
# envs (via asdf)
function InstallEnvs {
  declare -A ENVS_INSTALLED
  for i in ${ENV_LIST[@]}; do
    ENVS_INSTALLED[$i]=false
  done

  if ([[ -n $ASDF_DIR ]] && [[ ! -d "$ASDF_DIR" ]]) || ([[ -z $ASDF_DIR ]] && [[ ! -d "$HOME"/.asdf ]]) ; then
    ASDF_DIR="${ASDF_DIR:-$HOME/.asdf}"
    unset CONFIRMATION
    read -p "\"asdf\" is not installed, attempt to install it [Y/n]? " CONFIRMATION
    CONFIRMATION=${CONFIRMATION:-Y}
    if [[ $CONFIRMATION =~ ^[Yy] ]]; then
      InstallEssentialPackages
      git clone --recurse-submodules --shallow-submodules https://github.com/asdf-vm/asdf.git "$ASDF_DIR"
      pushd "$ASDF_DIR" >/dev/null 2>&1
      git checkout "$(git describe --abbrev=0 --tags)"
      popd >/dev/null 2>&1
    fi
  fi

  if [ -d "${ASDF_DIR:-$HOME/.asdf}" ]; then
    _EnvSetup
    if [ -n $ASDF_DIR ]; then
      asdf update
      for i in ${ENV_LIST[@]}; do
        if ! ( asdf plugin list | grep -q "$i" ) >/dev/null 2>&1 ; then
          unset CONFIRMATION
          read -p "\"$i\" is not installed, attempt to install it [y/N]? " CONFIRMATION
          CONFIRMATION=${CONFIRMATION:-N}
          if [[ $CONFIRMATION =~ ^[Yy] ]]; then
            asdf plugin add "$i" && ENVS_INSTALLED[$i]=true
          fi
        else
          unset CONFIRMATION
          read -p "\"$i\" is already installed, attempt to update it [y/N]? " CONFIRMATION
          CONFIRMATION=${CONFIRMATION:-N}
          if [[ $CONFIRMATION =~ ^[Yy] ]]; then
            ENVS_INSTALLED[$i]=true
          fi
        fi
      done
    fi
    _EnvSetup
  fi # .asdf check

  # install versions of the tools and plugins
  for i in ${ENV_LIST[@]}; do
    if [[ ${ENVS_INSTALLED[$i]} = 'true' ]]; then
      asdf plugin update $i
      asdf install $i latest
      asdf global $i latest
      asdf reshim $i
    fi
  done
  _EnvSetup
}

################################################################################
# InstallEnvPackages
function InstallEnvPackages {
  unset CONFIRMATION
  read -p "Install common pip, etc. packages [Y/n]? " CONFIRMATION
  CONFIRMATION=${CONFIRMATION:-Y}
  if [[ $CONFIRMATION =~ ^[Yy] ]]; then
    _EnvSetup

    if python3 -m pip -V >/dev/null 2>&1; then
      python3 -m pip install --user -U \
        dateparser \
        mmguero \
        requests
    fi
  fi

  _EnvSetup
}

################################################################################
function InstallDocker {

  # install docker-ce, if needed
  if ! $SUDO_CMD docker info >/dev/null 2>&1 ; then
    unset CONFIRMATION
    read -p "\"docker info\" failed, attempt to install docker [Y/n]? " CONFIRMATION
    CONFIRMATION=${CONFIRMATION:-Y}
    if [[ $CONFIRMATION =~ ^[Yy] ]]; then

      InstallEssentialPackages

      $SUDO_CMD yum update -y >/dev/null 2>&1 && \
        $SUDO_CMD amazon-linux-extras install -y docker

      $SUDO_CMD systemctl enable docker
      $SUDO_CMD systemctl start docker

      if [[ "$SCRIPT_USER" != "root" ]]; then
        echo "Adding \"$SCRIPT_USER\" to group \"docker\"..." >&2
        $SUDO_CMD usermod -a -G docker "$SCRIPT_USER"
        echo "You will need to log out and log back in for this to take effect" >&2
      fi
    fi # docker install confirmation check

  else
    echo "\"docker\" is already installed!" >&2
  fi # docker install check

  # install docker-compose, if needed
  if ! docker-compose version >/dev/null 2>&1 ; then
    unset CONFIRMATION
    read -p "\"docker-compose version\" failed, attempt to install docker-compose [Y/n]? " CONFIRMATION
    CONFIRMATION=${CONFIRMATION:-Y}
    if [[ $CONFIRMATION =~ ^[Yy] ]]; then
      echo "Installing Docker Compose via curl to /usr/local/bin..." >&2
      InstallEssentialPackages
      $SUDO_CMD curl -L "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_INSTALL_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
      $SUDO_CMD chmod +x /usr/local/bin/docker-compose
      if ! /usr/local/bin/docker-compose version >/dev/null 2>&1 ; then
        echo "Installing docker-compose failed" >&2
        exit 1
      fi
    fi # docker-compose install confirmation check
  else
    echo "\"docker-compose\" is already installed!" >&2
  fi # docker-compose install check
}

################################################################################
function InstallCommonPackages {

  unset CONFIRMATION
  read -p "Install common packages [Y/n]? " CONFIRMATION
  CONFIRMATION=${CONFIRMATION:-Y}
  if [[ $CONFIRMATION =~ ^[Yy] ]]; then

    $SUDO_CMD yum update -y >/dev/null 2>&1
    $SUDO_CMD amazon-linux-extras install -y epel
    $SUDO_CMD yum update -y >/dev/null 2>&1

    PACKAGE_LIST=(
      python3.8
    )
    # install the packages from amazon-linux-extras
    for i in ${PACKAGE_LIST[@]}; do
      if [[ ! $i =~ ^firmware ]] || [[ -z $WINDOWS ]]; then
        $SUDO_CMD amazon-linux-extras install -y "$i"
      fi
    done
    $SUDO_CMD ln -s -r -f /usr/bin/python3.8 /usr/bin/python3
    $SUDO_CMD ln -s -r -f /usr/bin/pip3.8 /usr/bin/pip3


    PACKAGE_LIST=(
      httpd-tools
      make
      openssl
      tmux
      wireshark
    )
    # install the packages from yum
    for i in ${PACKAGE_LIST[@]}; do
      if [[ ! $i =~ ^firmware ]] || [[ -z $WINDOWS ]]; then
        $SUDO_CMD yum install -y "$i"
      fi
    done

  fi # install common packages confirmation
}

################################################################################
function CreateCommonLinuxConfig {

  unset CONFIRMATION
  read -p "Create missing common local config in home [Y/n]? " CONFIRMATION
  CONFIRMATION=${CONFIRMATION:-Y}
  if [[ $CONFIRMATION =~ ^[Yy] ]]; then

    touch ~/.hushlogin

    mkdir -p "$HOME/tmp" \
             "$HOME/devel" \
             "$LOCAL_BIN_PATH" \
             "$LOCAL_DATA_PATH"/bash-completion/completions

    [ ! -f ~/.vimrc ] && echo "set nocompatible" > ~/.vimrc

    if [ ! -d ~/.ssh ]; then
      mkdir ~/.ssh
      chmod 700 ~/.ssh
    fi
  fi
}

################################################################################
function InstallUserLocalBinaries {
  unset CONFIRMATION
  read -p "Install user-local binaries/packages [Y/n]? " CONFIRMATION
  CONFIRMATION=${CONFIRMATION:-Y}
  if [[ $CONFIRMATION =~ ^[Yy] ]]; then
    mkdir -p "$LOCAL_BIN_PATH" "$LOCAL_DATA_PATH"/bash-completion/completions

    CROC_RELEASE="$(_GitLatestRelease schollz/croc | sed 's/^v//')"
    TMP_CLONE_DIR="$(mktemp -d)"
    curl -L "https://github.com/schollz/croc/releases/download/v${CROC_RELEASE}/croc_${CROC_RELEASE}_Linux-64bit.tar.gz" | tar xvzf - -C "${TMP_CLONE_DIR}"
    cp -f "${TMP_CLONE_DIR}"/croc "$LOCAL_BIN_PATH"/croc
    cp -f "${TMP_CLONE_DIR}"/bash_autocomplete "$LOCAL_DATA_PATH"/bash-completion/completions/croc.bash
    chmod 755 "$LOCAL_BIN_PATH"/croc
    rm -rf "$TMP_CLONE_DIR"

    GRON_RELEASE="$(_GitLatestRelease tomnomnom/gron | sed 's/^v//')"
    TMP_CLONE_DIR="$(mktemp -d)"
    curl -L "https://github.com/tomnomnom/gron/releases/download/v${GRON_RELEASE}/gron-linux-amd64-${GRON_RELEASE}.tgz" | tar xvzf - -C "${TMP_CLONE_DIR}"
    cp -f "${TMP_CLONE_DIR}"/gron "$LOCAL_BIN_PATH"/gron
    chmod 755 "$LOCAL_BIN_PATH"/gron
    rm -rf "$TMP_CLONE_DIR"

    SQ_RELEASE="$(_GitLatestRelease neilotoole/sq | sed 's/^v//')"
    TMP_CLONE_DIR="$(mktemp -d)"
    curl -L "https://github.com/neilotoole/sq/releases/download/v${SQ_RELEASE}/sq-linux-amd64.tar.gz" | tar xvzf - -C "${TMP_CLONE_DIR}"
    cp -f "${TMP_CLONE_DIR}"/sq "$LOCAL_BIN_PATH"/sq
    chmod 755 "$LOCAL_BIN_PATH"/sq
    rm -rf "$TMP_CLONE_DIR"

    TMP_CLONE_DIR="$(mktemp -d)"
    curl -o "${TMP_CLONE_DIR}"/ngrok.zip -L "https://bin.equinox.io/c/4VmDzA7iaHb/ngrok-stable-linux-amd64.zip"
    pushd "$TMP_CLONE_DIR" >/dev/null 2>&1
    unzip ./ngrok.zip
    chmod 755 ./ngrok
    cp -f ./ngrok "$LOCAL_BIN_PATH"/ngrok
    popd >/dev/null 2>&1
    rm -rf "$TMP_CLONE_DIR"

    BAT_RELEASE="$(_GitLatestRelease sharkdp/bat)"
    TMP_CLONE_DIR="$(mktemp -d)"
    curl -L "https://github.com/sharkdp/bat/releases/download/${BAT_RELEASE}/bat-${BAT_RELEASE}-x86_64-unknown-linux-musl.tar.gz" | tar xvzf - -C "${TMP_CLONE_DIR}" --strip-components 1
    cp -f "${TMP_CLONE_DIR}"/bat "$LOCAL_BIN_PATH"/bat
    chmod 755 "$LOCAL_BIN_PATH"/bat
    rm -rf "$TMP_CLONE_DIR"

    DRA_RELEASE="$(_GitLatestRelease devmatteini/dra)"
    TMP_CLONE_DIR="$(mktemp -d)"
    curl -L "https://github.com/devmatteini/dra/releases/download/${DRA_RELEASE}/dra-${DRA_RELEASE}.tar.gz" | tar xvzf - -C "${TMP_CLONE_DIR}" --strip-components 1
    cp -f "${TMP_CLONE_DIR}"/dra "$LOCAL_BIN_PATH"/dra
    chmod 755 "$LOCAL_BIN_PATH"/dra
    rm -rf "$TMP_CLONE_DIR"
  fi
}

################################################################################
function SystemConfig {

  if [[ -r /etc/sysctl.conf ]] && ! grep -q swappiness /etc/sysctl.conf; then
    unset CONFIRMATION
    read -p "Tweak sysctl.conf (swap, NIC buffers, handles, etc.) [Y/n]? " CONFIRMATION
    CONFIRMATION=${CONFIRMATION:-Y}
    if [[ $CONFIRMATION =~ ^[Yy] ]]; then
      $SUDO_CMD tee -a /etc/sysctl.conf > /dev/null <<'EOT'

# allow dmg reading
kernel.dmesg_restrict=0

# the maximum number of open file handles
fs.file-max=65536

# the maximum number of user inotify watches
fs.inotify.max_user_watches=131072

# the maximum number of memory map areas a process may have
vm.max_map_count=262144

# the maximum number of incoming connections
net.core.somaxconn=65535

# decrease "swappiness" (swapping out runtime memory vs. dropping pages)
vm.swappiness=1

# the % of system memory fillable with "dirty" pages before flushing
vm.dirty_background_ratio=40

# maximum % of dirty system memory before committing everything
vm.dirty_ratio=80
EOT
    fi # sysctl confirmation
  fi # sysctl check

  if [[ ! -f /etc/security/limits.d/limits.conf ]]; then
    unset CONFIRMATION
    read -p "Increase limits for file handles and memlock [Y/n]? " CONFIRMATION
    CONFIRMATION=${CONFIRMATION:-Y}
    if [[ $CONFIRMATION =~ ^[Yy] ]]; then
      $SUDO_CMD mkdir -p /etc/security/limits.d/
      $SUDO_CMD tee /etc/security/limits.d/limits.conf > /dev/null <<'EOT'
* soft nofile 65535
* hard nofile 65535
* soft memlock unlimited
* hard memlock unlimited
EOT
    fi # limits.conf confirmation
  fi # limits.conf check

  if [[ -f /etc/default/grub ]] && ! grep -q cgroup /etc/default/grub; then
    unset CONFIRMATION
    read -p "Tweak kernel parameters in grub (cgroup, etc.) [Y/n]? " CONFIRMATION
    CONFIRMATION=${CONFIRMATION:-Y}
    if [[ $CONFIRMATION =~ ^[Yy] ]]; then
      $SUDO_CMD sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*/& random.trust_cpu=on cgroup_enable=memory swapaccount=1 cgroup.memory=nokmem/' /etc/default/grub
      $SUDO_CMD grub2-mkconfig -o /boot/grub2/grub.cfg
    fi # grub confirmation
  fi # grub check
}

################################################################################
function SGroverDotfiles {
  unset CONFIRMATION
  read -p "Clone and setup symlinks for Seth Grover's dotfiles [Y/n]? " CONFIRMATION
  CONFIRMATION=${CONFIRMATION:-Y}
  if [[ $CONFIRMATION =~ ^[Yy] ]]; then

    mkdir -p "$LOCAL_BIN_PATH" "$LOCAL_CONFIG_PATH"

    SGROVER_GITHUB_PATH="$LOCAL_CONFIG_PATH"/sgrover.dotfiles
    _GitClone https://github.com/mmguero/dotfiles "$SGROVER_GITHUB_PATH"

    [[ -r "$SGROVER_GITHUB_PATH"/bash/"$SCRIPT_NAME" ]] && rm -vf "$LOCAL_BIN_PATH"/"$SCRIPT_NAME" && \
      ln -vrs "$SGROVER_GITHUB_PATH"/bash/"$SCRIPT_NAME" "$LOCAL_BIN_PATH"/"$SCRIPT_NAME"

    [[ -r "$SGROVER_GITHUB_PATH"/bash/rc ]] && rm -vf ~/.bashrc && \
      ln -vrs "$SGROVER_GITHUB_PATH"/bash/rc ~/.bashrc

    [[ -r "$SGROVER_GITHUB_PATH"/bash/aliases ]] && rm -vf ~/.bash_aliases && \
      ln -vrs "$SGROVER_GITHUB_PATH"/bash/aliases ~/.bash_aliases

    [[ -r "$SGROVER_GITHUB_PATH"/bash/functions ]] && rm -vf ~/.bash_functions && \
      ln -vrs "$SGROVER_GITHUB_PATH"/bash/functions ~/.bash_functions

    [[ -d "$SGROVER_GITHUB_PATH"/bash/rc.d ]] && rm -vf ~/.bashrc.d && \
      ln -vrs "$SGROVER_GITHUB_PATH"/bash/rc.d ~/.bashrc.d

    [[ -r "$SGROVER_GITHUB_PATH"/git/gitconfig ]] && rm -vf ~/.gitconfig && \
      ln -vrs "$SGROVER_GITHUB_PATH"/git/gitconfig ~/.gitconfig

    [[ -r "$SGROVER_GITHUB_PATH"/git/gitignore_global ]] && rm -vf ~/.gitignore_global && \
      ln -vrs "$SGROVER_GITHUB_PATH"/git/gitignore_global ~/.gitignore_global

    [[ -r "$SGROVER_GITHUB_PATH"/git/git_clone_all.sh ]] && rm -vf "$LOCAL_BIN_PATH"/git_clone_all.sh && \
      ln -vrs "$SGROVER_GITHUB_PATH"/git/git_clone_all.sh "$LOCAL_BIN_PATH"/git_clone_all.sh

    [[ -r "$SGROVER_GITHUB_PATH"/linux/tmux/tmux.conf ]] && rm -vf ~/.tmux.conf && \
      ln -vrs "$SGROVER_GITHUB_PATH"/linux/tmux/tmux.conf ~/.tmux.conf

    LINKED_SCRIPTS=(
      self_signed_key_gen.sh
    )
    for i in ${LINKED_SCRIPTS[@]}; do
      rm -vf "$LOCAL_BIN_PATH"/"$i" && ln -vrs "$SGROVER_GITHUB_PATH"/scripts/"$i" "$LOCAL_BIN_PATH"/
    done

    [[ -r "$SGROVER_GITHUB_PATH"/bash/context-color/context-color ]] && rm -vf "$LOCAL_BIN_PATH"/context-color && \
      ln -vrs "$SGROVER_GITHUB_PATH"/bash/context-color/context-color "$LOCAL_BIN_PATH"/context-color

  fi # dotfiles setup confirmation
}


################################################################################
function InstallMalcolm {

  MALCOLM_PATH="$HOME"/Malcolm
  ARTIFACTS_PATH="$HOME"/artifacts

  unset CONFIRMATION
  read -p "Clone and setup Malcolm [Y/n]? " CONFIRMATION
  CONFIRMATION=${CONFIRMATION:-Y}
  if [[ $CONFIRMATION =~ ^[Yy] ]]; then
    if _GitClone https://github.com/idaholab/Malcolm "$MALCOLM_PATH"; then
      pushd "$MALCOLM_PATH" >/dev/null 2>&1
      python3 ./scripts/install.py -c -d -r
      CONFIG_PAIRS=(
        "CAPA_MAX_REQUESTS:2"
        "CLAMD_MAX_REQUESTS:4"
        "EXTRACTED_FILE_ENABLE_CAPA:'true'"
        "EXTRACTED_FILE_ENABLE_CLAMAV:'true'"
        "EXTRACTED_FILE_ENABLE_YARA:'true'"
        "EXTRACTED_FILE_HTTP_SERVER_ENABLE:'true'"
        "EXTRACTED_FILE_HTTP_SERVER_ENCRYPT:'false'"
        "EXTRACTED_FILE_IGNORE_EXISTING:'true'"
        "EXTRACTED_FILE_PRESERVATION:'all'"
        "FREQ_LOOKUP:'true'"
        "LOGSTASH_OUI_LOOKUP:'true'"
        "LOGSTASH_REVERSE_DNS:'true'"
        "LOGSTASH_SEVERITY_SCORING:'true'"
        "PCAP_PIPELINE_IGNORE_PREEXISTING:'true'"
        "YARA_MAX_REQUESTS:4"
        "ZEEK_AUTO_ANALYZE_PCAP_FILES:'true'"
        "ZEEK_DISABLE_BEST_GUESS_ICS:''"
        "ZEEK_EXTRACTOR_MODE:'all'"
      )
      for i in ${CONFIG_PAIRS[@]}; do
        KEY="$(echo "$i" | cut -d':' -f1)"
        VALUE="$(echo "$i" | cut -d':' -f2)"
        sed -i "s/\(^[[:space:]]*$KEY[[:space:]]*:[[:space:]]*\).*/\1$VALUE/g" docker-compose.yml
      done
      touch auth.env
      docker-compose pull
      echo "Please run $MALCOLM_PATH/scripts/auth_setup to complete configuration" >&2
      popd >/dev/null 2>&1
    fi

    pushd "$LOCAL_BIN_PATH" >/dev/null 2>&1
    curl -sSL -J -O https://raw.githubusercontent.com/mmguero-dev/Malcolm/development/scripts/reset_and_auto_populate.sh
    curl -sSL -J -O https://raw.githubusercontent.com/mmguero-dev/Malcolm-PCAP/main/tools/pcap_time_shift.py
    chmod 755 reset_and_auto_populate.sh pcap_time_shift.py
    popd >/dev/null 2>&1
  fi

  unset CONFIRMATION
  read -p "Download a sample PCAP (SANS Cyberville ICS CTF) [Y/n]? " CONFIRMATION
  CONFIRMATION=${CONFIRMATION:-Y}
  if [[ $CONFIRMATION =~ ^[Yy] ]]; then
    pushd "$ARTIFACTS_PATH" >/dev/null 2>&1
    curl -sSL -J -O https://malcolm.fyi/examples/Cyberville.pcap
    curl -sSL -J -O https://malcolm.fyi/examples/net-map.json
    cp -f ./net-map.json "$MALCOLM_PATH"/
    popd >/dev/null 2>&1
  fi
}


################################################################################
# "main"

# in case we've already got some envs set up to use
_EnvSetup

# get a list of all the "public" functions (not starting with _)
FUNCTIONS=($(declare -F | awk '{print $NF}' | sort | egrep -v "^_"))

# present the menu to our customer and get their selection
printf "%s\t%s\n" "0" "ALL"
for i in "${!FUNCTIONS[@]}"; do
  ((IPLUS=i+1))
  printf "%s\t%s\n" "$IPLUS" "${FUNCTIONS[$i]}"
done
echo -n "Operation:"
read USER_FUNCTION_IDX

if (( $USER_FUNCTION_IDX == 0 )); then
  # ALL: do everything, in order
  InstallEnvs
  InstallEnvPackages
  InstallEssentialPackages
  InstallCommonPackages
  InstallDocker
  SystemConfig
  InstallUserLocalBinaries
  CreateCommonLinuxConfig
  SGroverDotfiles
  InstallMalcolm

elif (( $USER_FUNCTION_IDX > 0 )) && (( $USER_FUNCTION_IDX <= "${#FUNCTIONS[@]}" )); then
  # execute one function, à la carte
  USER_FUNCTION="${FUNCTIONS[((USER_FUNCTION_IDX-1))]}"
  echo $USER_FUNCTION
  $USER_FUNCTION

else
  # some people just want to watch the world burn
  echo "Invalid operation selected" >&2
  exit 1;
fi
