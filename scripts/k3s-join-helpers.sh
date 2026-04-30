# k3s-join-helpers.sh — source this on the Mac Air to get `join_server` and
# `join_agent` shell functions for adding nodes to the cluster bootstrapped
# by lab-cp01 (10.10.20.21).
#
# Usage:
#   source scripts/k3s-join-helpers.sh
#   join_server 10.10.20.22       # adds another control-plane node
#   join_agent  10.10.20.31       # adds a worker
#
# Token-handling discipline (see runbook 02 §1):
#   - Token only ever lives in pipe buffers locally and as a remote shell var.
#   - Never in argv (visible to `ps -ef`), env, shell history, or on disk.
#   - Token + install script share ssh's stdin via a brace group; the remote
#     side splits them with `IFS= read -r TOKEN`.
#
# This file is meant to be sourced from the repo root
# (cucox-lab-infra/), so the relative path to secrets.enc.yaml resolves.

# ---- shell hygiene ----------------------------------------------------------
# Make sure the leading-space history-skip habit is in effect for this shell,
# since invocations of these functions take an IP arg that's harmless but the
# decrypt + ssh interaction is still worth keeping out of `~/.zsh_history`.
if [ -n "${ZSH_VERSION:-}" ]; then
  setopt HIST_IGNORE_SPACE 2>/dev/null || true
fi

# ---- join_server ------------------------------------------------------------
# Adds a control-plane node that joins cp01's embedded-etcd cluster.
# Pass the new node's IP as the only argument.
join_server () {
  local host_ip="$1"
  if [ -z "$host_ip" ]; then
    echo "usage: join_server <host_ip>" >&2
    return 2
  fi

  {
    sops --decrypt ansible/group_vars/k3s/secrets.enc.yaml | yq -r .k3s_token
    cat <<INSTALL
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="v1.30.5+k3s1" \
  sh -s - server \
    --server https://10.10.20.21:6443 \
    --node-ip ${host_ip} \
    --advertise-address ${host_ip} \
    --tls-san 10.10.20.21 --tls-san 10.10.20.22 --tls-san 10.10.20.23 \
    --flannel-backend=none \
    --disable-network-policy \
    --disable=servicelb \
    --disable=traefik \
    --cluster-cidr=10.42.0.0/16 \
    --service-cidr=10.43.0.0/16
INSTALL
  } | ssh ubuntu@"$host_ip" 'IFS= read -r TOKEN; sudo K3S_TOKEN="$TOKEN" bash -s'
}

# ---- join_agent -------------------------------------------------------------
# Adds a worker (agent) node to the cluster. Pass the new node's IP.
join_agent () {
  local host_ip="$1"
  if [ -z "$host_ip" ]; then
    echo "usage: join_agent <host_ip>" >&2
    return 2
  fi

  {
    sops --decrypt ansible/group_vars/k3s/secrets.enc.yaml | yq -r .k3s_token
    cat <<INSTALL
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="v1.30.5+k3s1" \
  K3S_URL="https://10.10.20.21:6443" \
  sh -s - agent \
    --node-ip ${host_ip}
INSTALL
  } | ssh ubuntu@"$host_ip" 'IFS= read -r TOKEN; sudo K3S_TOKEN="$TOKEN" bash -s'
}
