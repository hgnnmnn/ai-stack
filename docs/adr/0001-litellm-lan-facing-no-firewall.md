# LiteLLM gateway exposed on LAN without firewall restriction

The LiteLLM gateway (port 4000) must be reachable by an external reverse proxy on another server, so it binds to the host's LAN-facing interface instead of `127.0.0.1` like most of the stack. We decided not to add a `firewalld` rule restricting inbound access to the reverse proxy's IP — security relies solely on LiteLLM's per-key API authentication. Revisit if the threat model changes or the reverse proxy's IP becomes stable enough to pin.

## Update (2026-08-11): reverse proxy CIDR now pinned for MCP trust, not firewalling

The reverse proxy's network is stable at `10.0.0.0/24`. This is now used to fix a LiteLLM MCP-access-control gap (a request carrying an `X-Forwarded-For` header was otherwise ignored, so the proxy's peer IP — falling inside `mcp_internal_ip_ranges` — made every external caller look internal to MCP server access control): `litellm/config.yaml` sets `general_settings.use_x_forwarded_for: true` and `mcp_trusted_proxy_ranges: ["10.0.0.0/24"]`, so only XFF headers arriving from that subnet are trusted. This is narrower than a firewall rule (it only affects MCP-internal-IP evaluation, not the port-4000 exposure decision above) — the no-firewall decision itself is unchanged, since API-key auth still covers `/v1/*`.
