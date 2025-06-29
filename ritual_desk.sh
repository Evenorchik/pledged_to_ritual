#!/usr/bin/env bash
###############################################################################
# Ritual Infernet Node Manager · June-2025
###############################################################################
set -euo pipefail
IFS=$'\n\t'

# ───────────── Colors ────────────────────────────────────────────────────────
RED='\e[0;31m'; GREEN='\e[0;32m'; YELLOW='\e[0;33m'; BLUE='\e[0;34m'
CYAN='\e[0;36m'; WHITE='\e[1;37m'; BOLD='\e[1m'; NC='\e[0m'
DGREEN='\e[32m';

trap 'echo -e "${RED}❌ Error on line ${BASH_LINENO[0]}${NC}"' ERR

# ───────────── Versions / paths ──────────────────────────────────────────────
NODE_TAG="1.4.0"        # ritualnetwork/infernet-node
HELLO_TAG="1.0.0"       # ritualnetwork/hello-world-infernet
REPO_DIR="$HOME/infernet-container-starter"
COMPOSE_BIN="/usr/local/bin/docker-compose"

# ───────────── Helpers ───────────────────────────────────────────────────────
print_logo() {
  curl -sL \
    https://raw.githubusercontent.com/Evenorchik/pledged_to_ritual/refs/heads/main/ritual_logo.sh \
    | bash
}

ask_nonempty() {
  local __var=$1 prompt=$2 val
  while :; do
    read -e -p "$(echo -e "${BOLD}${YELLOW}${prompt}${NC}")" val
    [[ -n "${val// }" ]] && { printf -v "$__var" '%s' "$val"; break; }
    echo -e "${RED}Value cannot be empty.${NC}"
  done
}

normalize_key() {
  local pk=$1
  [[ $pk =~ ^0x?[0-9a-fA-F]{64}$ ]] || return 1
  [[ $pk =~ ^0x ]] && echo "$pk" || echo "0x$pk"
}

# ───────────── 1. Install dependencies ───────────────────────────────────────
install_deps() {
  echo -e "${BLUE}${BOLD}\nInstalling system packages…${NC}"
  sudo apt update && sudo apt -y upgrade
  sudo apt -qy install curl git jq lz4 build-essential screen docker.io

  echo -e "${BLUE}Installing docker-compose…${NC}"
  sudo curl -L \
    "https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-$(uname -s)-$(uname -m)" \
    -o "$COMPOSE_BIN"
  sudo chmod +x "$COMPOSE_BIN"

  DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
  mkdir -p "$DOCKER_CONFIG/cli-plugins"
  curl -SL \
    https://github.com/docker/compose/releases/download/v2.20.2/docker-compose-linux-x86_64 \
    -o "$DOCKER_CONFIG/cli-plugins/docker-compose"
  chmod +x "$DOCKER_CONFIG/cli-plugins/docker-compose"

  docker compose version && echo -e "${GREEN}docker compose installed${NC}"

  sudo usermod -aG docker "$USER"

  echo -e "\n${YELLOW}${BOLD}Docker group applied. Reboot required.${NC}"
  read -rp "$(echo -e "${YELLOW}Reboot now? [y/N]: ${NC}")" ans
  if [[ ${ans,,} == y ]]; then
    echo -e "${GREEN}Rebooting…${NC}"
    sudo reboot
  else
    echo -e "${YELLOW}Please reboot manually before continuing.${NC}"
  fi
}

# ───────────── 2. Install node ───────────────────────────────────────────────
install_node() {
  echo -e "${BLUE}${BOLD}\nCloning starter repo…${NC}"
  git clone https://github.com/ritual-net/infernet-container-starter "$REPO_DIR" 2>/dev/null || true
  cd "$REPO_DIR"

  echo -e "${BLUE}Launching containers in screen session ‘ritual’…${NC}"
  screen -S ritual -dm bash -c \
    "docker pull ritualnetwork/hello-world-infernet:latest && project=hello-world make deploy-container && exec bash"

  sleep 30

  echo -e "${GREEN}Containers up. Current list:${NC}"
  docker container ls
  sleep 15
}

# ───────────── 3. Configure node ─────────────────────────────────────────────
configure_node() {
  local rpc_url pk_raw pk reg

  echo -e "${GREEN}Press Enter to use default https://mainnet.base.org/, Alchemy instead recommended${NC}"
  read -e -p "$(echo -e "${BOLD}${YELLOW}Enter RPC URL or press Enter to use default: ${NC}")" rpc_url
  rpc_url=${rpc_url:-https://mainnet.base.org/}
  echo -e "${GREEN}Using RPC URL: $rpc_url ${NC}"

  while :; do
    ask_nonempty pk_raw "Enter private key (with 0x): "
    if pk=$(normalize_key "$pk_raw"); then break; fi
    echo -e "${RED}Invalid key format.${NC}"
  done

  echo -e "${GREEN}Press Enter to use default 0x3B1554f346DFe5c482Bb4BA31b880c1C18412170, this address is reliable on June 2025, ask for newer in Discord.${NC}"
  read -e -p "$(echo -e "${BOLD}${GREEN}Enter registry address or press Enter to use default: ${NC}")" reg
  reg=${reg:-0x3B1554f346DFe5c482Bb4BA31b880c1C18412170}

  for cfg in "$REPO_DIR/deploy/config.json" \
             "$REPO_DIR/projects/hello-world/container/config.json"; do
    [[ -f $cfg ]] || continue
    tmp=$(mktemp)
    jq --arg rpc "$rpc_url" --arg pk "$pk" --arg reg "$reg" '
      .chain.rpc_url        = $rpc |
      .chain.wallet.private_key = $pk |
      .chain.registry_address   = $reg |
      .chain.trail_head_blocks  = 3 |
      .chain.snapshot_sync.sleep          = 3 |
      .chain.snapshot_sync.starting_sub_id = 245000 |
      .chain.snapshot_sync.batch_size     = 500 |
      .chain.snapshot_sync.sync_period    = 30' "$cfg" >"$tmp"
    mv "$tmp" "$cfg"
  done

  sed -i -E "s|^(sender := ).*|\1$pk|" \
        "$REPO_DIR/projects/hello-world/contracts/Makefile"
  sed -i -E "s|^(RPC_URL := ).*|\1$rpc_url|" \
        "$REPO_DIR/projects/hello-world/contracts/Makefile"
  sed -i "0,/0x[0-9a-fA-F]\{40\}/{s//${reg}/}" \
        "$REPO_DIR/projects/hello-world/contracts/script/Deploy.s.sol"
  sed -i "s|ritualnetwork/infernet-node:.*|ritualnetwork/infernet-node:${NODE_TAG}|" \
        "$REPO_DIR/deploy/docker-compose.yaml"

  echo -e "${BLUE}Restarting containers one by one…${NC}"
  for c in infernet-anvil hello-world infernet-node infernet-fluentbit infernet-redis; do
    docker restart "$c"
    sleep 3
  done
  echo -e "${GREEN}✅ Configuration applied.${NC}"
}

# ───────────── 4. Deploy & call contract ─────────────────────────────────────
deploy_and_call() {
  echo -e "${BLUE}${BOLD}\nInstalling Foundry…${NC}"
  curl -L https://foundry.paradigm.xyz | bash

  set +u
  source "$HOME/.bashrc" 2>/dev/null || true
  set -u

  foundryup

  cd "$REPO_DIR/projects/hello-world/contracts"
  rm -rf lib
  forge install --no-commit foundry-rs/forge-std
  forge install --no-commit ritual-net/infernet-sdk
  foundryup

  echo -e "${BLUE}Deploying sample contracts…${NC}"
  cd "$REPO_DIR"
  project=hello-world make deploy-contracts

  echo -e "${BLUE}Enter deployed SaysGM address:${NC}"
  read -e says
  sed -E -i "s|(SaysGM saysGm = SaysGM\().*?\)|\1${says})|" \
        "$REPO_DIR/projects/hello-world/contracts/script/CallContract.s.sol"

  project=hello-world make call-contract
}

# ───────────── 5. Check health ───────────────────────────────────────────────
check_health() {
  curl -s localhost:4000/health | jq . || echo -e "${RED}Health endpoint not ready${NC}"
}

# ───────────── 6. Restart node ───────────────────────────────────────────────
restart_node() {
  echo -e "${BLUE}Restarting containers…${NC}"
  for c in infernet-anvil hello-world infernet-node infernet-fluentbit infernet-redis; do
    docker restart "$c"
    sleep 3
  done
  echo -e "${GREEN}Containers restarted.${NC}"
}

# ───────────── 7. Uninstall node ─────────────────────────────────────────────
uninstall_node() {
  docker compose -f "$REPO_DIR/deploy/docker-compose.yaml" down || true
  docker image ls -a | grep infernet | awk '{print $3}' | xargs -r docker rmi -f
  rm -rf "$REPO_DIR" "$HOME/foundry" "$HOME/.foundry"
  echo -e "${GREEN}Infernet node removed.${NC}"
}

# ───────────── Menu ──────────────────────────────────────────────────────────
menu() {
  clear
  print_logo
  printf "\n${BOLD}${WHITE}╭━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╮${NC}\n"
  printf "${BOLD}${WHITE}│   ${DGREEN}🔥${NC}  AUTOMATED BOOK OF RITUAL  ${DGREEN}🔥${NC}   │${NC}\n"
  printf "${BOLD}${WHITE}╰━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╯${NC}\n\n"

  printf "${WHITE}[${CYAN}1${WHITE}] ${GREEN}➜${NC} 🛠️  ${GREEN}Install dependencies${NC}\n"
  printf "${WHITE}[${CYAN}2${WHITE}] ${GREEN}➜${NC} 🐳  ${GREEN}Install node${NC}\n"
  printf "${WHITE}[${CYAN}3${WHITE}] ${GREEN}➜${NC} 🔧  ${GREEN}Configure node${NC}\n"
  printf "${WHITE}[${CYAN}4${WHITE}] ${GREEN}➜${NC} 📜  ${GREEN}Deploy & call contract${NC}\n"
  printf "${WHITE}[${CYAN}5${WHITE}] ${GREEN}➜${NC} 🩺  ${GREEN}Check node health${NC}\n"
  printf "${WHITE}[${CYAN}6${WHITE}] ${GREEN}➜${NC} 🔄  ${GREEN}Restart node${NC}\n"
  printf "${WHITE}[${CYAN}7${WHITE}] ${GREEN}➜${NC} 🧹  ${GREEN}Uninstall node${NC}\n"
  printf "${WHITE}[${CYAN}8${WHITE}] ${GREEN}➜${RED} 🚪  ${RED}Exit${NC}\n"
}

# ───────────── Main loop ─────────────────────────────────────────────────────
while true; do
  menu
  read -p "$(echo -e "${BOLD}${BLUE}Select action [1-8]: ${NC}")" choice
  case $choice in
    1) install_deps ;;
    2) install_node ;;
    3) configure_node ;;
    4) deploy_and_call ;;
    5) check_health ;;
    6) restart_node ;;
    7) uninstall_node ;;
    8) echo -e "${GREEN}👋 Bye!${NC}"; exit 0 ;;
    *) echo -e "${RED}Invalid choice${NC}" ;;
  esac
  sleep 2   # маленькая пауза, затем меню появится снова
done
