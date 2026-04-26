# Security

`cucox-lab-infra` is a personal homelab project. If you've found something
that looks like a credential leak, an accidentally committed secret, or
another security issue in this repository, please report it privately.

## Reporting

**Email:** [raziel.arias1991@gmail.com](mailto:raziel.arias1991@gmail.com)

Please do **not** open a public GitHub issue for vulnerabilities.

This is a one-person, best-effort project. Expect a response within a few
days, not within hours. There is no bug bounty.

## What's in scope

- Plaintext credentials, tokens, private keys, or other secrets
  accidentally committed to this repo. SOPS-encrypted payloads are
  expected and not a finding.
- Misconfiguration in IaC (Terraform, Ansible, Helm values) that would
  expose the lab in unintended ways if applied.

## What's not in scope

- The lab's network topology. All in-cluster networks (`10.10.x.x`) are
  RFC1918 private; the perimeter is enforced by a Cloudflare Tunnel and
  the firewall, not by obscurity.
- Vulnerabilities in upstream open-source projects used by the lab
  (Proxmox, k3s, Cilium, MetalLB, Cloudflared, SOPS, age, etc.). Please
  report those upstream.
