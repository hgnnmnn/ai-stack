# LiteLLM gateway exposed on LAN without firewall restriction

The LiteLLM gateway (port 4000) must be reachable by an external reverse proxy on another server, so it binds to the host's LAN-facing interface instead of `127.0.0.1` like most of the stack. We decided not to add a `firewalld` rule restricting inbound access to the reverse proxy's IP — security relies solely on LiteLLM's per-key API authentication. Revisit if the threat model changes or the reverse proxy's IP becomes stable enough to pin.
