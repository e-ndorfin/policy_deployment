# Yonsei Reverse-Tunnel PoC

This PoC exposes the policy server from a Yonsei SLURM GPU job through a
public VM:

```text
organizer -> wss://policy.example.com -> Caddy on VM
          -> VM 127.0.0.1:18000 -> reverse SSH tunnel
          -> SLURM GPU job 127.0.0.1:8000 -> policy server
```

The default PoC uses `examples.echo_policy:EchoPolicy`, so it proves the
network path before loading a real model.

## VM Setup

1. Create a small public VM with ports `80` and `443` open.
2. Create a restricted SSH user, for example `deploy`.
3. Add the Yonsei cluster public key to `~deploy/.ssh/authorized_keys`.
4. Install Caddy.
5. Copy `deploy/caddy.reverse-tunnel.Caddyfile.example` to the VM Caddyfile
   and replace `policy.example.com` with your domain.

The VM should not expose port `18000` publicly. Caddy connects to that port
on localhost after the SLURM job opens the reverse tunnel.

## Yonsei Setup

From this repository on a login node:

```bash
python -m venv .venv
.venv/bin/pip install -r requirements.txt

ssh-keygen -t ed25519 -f ~/.ssh/policy_tunnel -C policy-tunnel
cat ~/.ssh/policy_tunnel.pub
```

Add that public key to the VM's `deploy` user.

Create an untracked env file from the example:

```bash
cp deploy/yonsei.env.example .env
chmod 600 .env
vi .env
```

At minimum, set:

```bash
export POLICY_SERVER_API_KEYS="..."
export TUNNEL_SSH_TARGET="deploy@policy-vm.example.com"
export TUNNEL_SSH_KEY="${HOME}/.ssh/policy_tunnel"
```

Submit the GPU job:

```bash
mkdir -p logs
source .env
sbatch deploy/yonsei_policy_server.sbatch
```

Watch logs:

```bash
squeue -u "$USER"
tail -f logs/policy_server.<JOBID>.out
```

## Tests

From the VM, while the job is running:

```bash
curl -i http://127.0.0.1:18000/healthz
```

From your laptop or another internet host:

```bash
curl -i https://policy.example.com/healthz
```

From a machine with this repo installed:

```bash
PYTHONPATH=. python scripts/ping.py \
  --host wss://policy.example.com \
  --api-key "$POLICY_SERVER_API_KEYS"

PYTHONPATH=. python scripts/smoke_test.py \
  --host wss://policy.example.com \
  --api-key "$POLICY_SERVER_API_KEYS"
```

Do not pass `--port 443` unless you intentionally want the client URL to
include `:443`; the test client uses the scheme in `--host` directly when
it starts with `ws` or `wss`.

## Switching To A Real Policy

After the echo-policy PoC works, update `.env`:

```bash
export POLICY_SPEC="examples.my_policy:MyPolicy"
export POLICY_KWARGS="checkpoint_path=/lustre/${USER}/checkpoints/policy.pt device=cuda:0"
```

Keep `device=cuda:0`. SLURM sets `CUDA_VISIBLE_DEVICES`, so `cuda:0` maps
to the GPU allocated to the job.

## Security Notes

- Keep API keys out of git. `.env` is ignored by this repo.
- Use the policy server API key even though Caddy terminates TLS.
- Put organizer IP allowlists on the VM firewall or Caddy/nginx layer. With
  the reverse tunnel, the policy server itself usually sees local proxy or
  tunnel addresses rather than the original organizer IP.
- The endpoint is available only while the SLURM job is running.
