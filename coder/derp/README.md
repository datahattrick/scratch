# Coder DERP relay

A standalone Tailscale `derper` (DERP relay and STUN server) for Coder workspaces on a network with no internet access.
[Networking basics](docs/networking-basics.md) (plain language) and [how it works](docs/how-it-works.md) (technical), with diagrams.
The chart also renders a DERP map ConfigMap for coderd's `CODER_DERP_CONFIG_PATH`.

- **Matched to Coder**: `derper` is built from `github.com/coder/tailscale` at the commit Coder 2.39.1 pins, plus [one patch](patches/0001-mesh-with-urls.patch) for meshing replicas. [Do we need it?](docs/how-it-works.md#do-we-need-the-patch)
- **Replicas**: a StatefulSet whose pods mesh with each other, so clients on different pods reach each other.
- **LoadBalancer or Ingress**: relay and STUN on one LoadBalancer Service, or the relay behind an Ingress with STUN on its own UDP Service.
- **STUN**: optional; `externalTrafficPolicy: Local`, so clients see their own address.
- **TLS**: in the pods from a `kubernetes.io/tls` Secret or cert-manager, at the ingress, or plain HTTP (`ForceHTTP` in the DERP map).
- **Access restriction**: `loadBalancerSourceRanges` and an optional NetworkPolicy.
- **DERP map**: region 900 with one node, written to a ConfigMap in Coder's namespace.

## Requirements

1. A registry the cluster can pull from, for the image built from `Dockerfile`.
2. One of:
   - a LoadBalancer that supports TCP and UDP on one Service (Kubernetes 1.26+), or `service.type=NodePort`;
   - an ingress controller that passes HTTP upgrades (Traefik does), plus a UDP LoadBalancer or NodePort for STUN.
3. A DNS name for the relay that resolves from coderd, workspace pods and Coder clients.
4. With TLS, a certificate for that name signed by a CA that workspace images and client machines trust.

## Deploy

```bash
podman build -t registry.example.internal/coder-derper:0fde3fc36b30 .
podman push registry.example.internal/coder-derper:0fde3fc36b30
```

LoadBalancer, TLS in the pods:

```bash
helm upgrade --install derp ./chart -n derp --create-namespace \
  --set hostname=derp.example.internal \
  --set tls.certManager.enabled=true --set tls.certManager.issuerRef.name=my-ca \
  --set derpMap.namespace=coder
```

Ingress, TLS at the ingress:

```bash
helm upgrade --install derp ./chart -n derp --create-namespace \
  --set hostname=derp.example.internal \
  --set tls.enabled=false \
  --set ingress.enabled=true --set ingress.className=traefik --set ingress.tls.secretName=derp-tls \
  --set derpMap.namespace=coder
```

Point the DNS name at the LoadBalancer or ingress address.
Behind an ingress, if the STUN Service gets a different address, set `derpMap.stunIPv4` to it.
For another Coder release, set `CODER_TAILSCALE_REF` to the commit in that release's `go.mod` (`replace tailscale.com => github.com/coder/tailscale ...`).

Then add to `deploy/coder-values.yaml` and upgrade Coder:

```yaml
coder:
  env:
    - {name: CODER_DERP_CONFIG_PATH, value: /etc/coder-derp/derpmap.json}
    - {name: CODER_DERP_SERVER_STUN_ADDRESSES, value: disable}   # Drop the default Google STUN servers
    # - {name: CODER_DERP_SERVER_ENABLE, value: "false"}        # Use only this relay
  volumes:
    - {name: derpmap, configMap: {name: coder-derpmap}}
  volumeMounts:
    - {name: derpmap, mountPath: /etc/coder-derp, readOnly: true}
```

coderd reads the DERP map once at startup.
Restart it after any change to the ConfigMap.

With `CODER_DERP_SERVER_ENABLE` left on, clients get both coderd's built-in relay (region 999) and this one, and use the one with lower latency.

## Workspaces limited to TCP 443

For workspaces whose only egress is TCP 443, run everything through the ingress, including coderd:

```bash
helm upgrade --install derp ./chart -n derp --create-namespace \
  --set hostname=derp.example.internal \
  --set tls.enabled=false --set stun.enabled=false \
  --set ingress.enabled=true --set ingress.className=traefik --set ingress.tls.secretName=derp-tls \
  --set derpMap.namespace=coder
```

```yaml
coder:
  env:
    - {name: CODER_DERP_CONFIG_PATH, value: /etc/coder-derp/derpmap.json}
    - {name: CODER_DERP_SERVER_ENABLE, value: "false"}   # All relay traffic through this chart
```

The DERP map has one node, `derp.example.internal:443`, with no STUN port.
Without UDP, workspaces cannot connect directly (p2p) to anyone, so every connection to a workspace is relayed.
Clients measure the region over HTTPS (`/derp/latency-check`) and pick it as their home relay.

Workspaces need DNS for `hostname`, or set `derpMap.ipv4` to the ingress address.

When the ingress controller runs in the same cluster as the workspaces, a workspace egress NetworkPolicy matches the ingress controller pod's port after NAT, not 443.
Allow that port too, or the workspace gets `connect: connection refused`:

```yaml
egress:
  - ports: [{port: 443, protocol: TCP}]
  - to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}},
          podSelector: {matchLabels: {app.kubernetes.io/name: traefik}}}]
    ports: [{port: 8443, protocol: TCP}]   # Traefik's websecure container port
```

Tested on k3s with 3 replicas behind Traefik: a workspace pod limited to TCP 443 (UDP and direct pod access blocked) picked region 900 and answered relayed pings from a coderd stand-in in the cluster and from a user machine on the LAN, over DERP and websockets.
The same layout with Coder 2.39.1 (built-in relay off): `coder ping` and `coder ssh` to the workspace went `proxied via DERP(Custom DERP)`, and coderd reached the agent. [Detail](docs/how-it-works.md#what-was-tested)

## Replicas

With `replicaCount` above 1, each pod connects to every pod (itself included) through the headless `<release>-coder-derper-mesh` Service, authenticated by a pre-shared key.
The chart creates the key Secret and keeps it across upgrades; `mesh.existingSecret` uses your own (64+ hex characters).

With TLS in the pods, mesh connections verify the certificate against `hostname`.
The pods trust `tls.ca.secretName`, the cert-manager Secret's `ca.crt`, or the image's system roots, in that order.
With `tls.enabled=false` (Ingress mode), mesh traffic between pods is plain HTTP.

## Access

Relayed traffic is WireGuard, encrypted end to end between the two Coder peers.
The relay sees peer public keys, source addresses and traffic volume.

The relay does not authenticate clients.
To keep others from using it, restrict who can reach it:

| Value | Restricts |
|---|---|
| `service.loadBalancerSourceRanges` | Source CIDRs through the LoadBalancer (relay and STUN) |
| `stunService.loadBalancerSourceRanges` | Source CIDRs to STUN, in Ingress mode |
| `networkPolicy.enabled`, `.derpFrom`, `.stunFrom` | NetworkPolicy peers allowed to the relay and STUN ports. Mesh traffic is always allowed |

Behind an ingress, `derpFrom` must allow the ingress controller's pods; restrict client addresses at the ingress.

## Values

| Value | Default | Purpose |
|---|---|---|
| `hostname` | none | Relay DNS name; required. Must match the pod certificate |
| `replicaCount` | `2` | Above 1 meshes the pods |
| `tls.enabled` | `true` | TLS in the pods. `false` for Ingress mode or plain HTTP |
| `tls.secretName` | none | Existing TLS Secret for `hostname` |
| `tls.certManager.enabled` | `false` | Create a cert-manager `Certificate` from `tls.certManager.issuerRef` |
| `service.type` | `LoadBalancer` | `NodePort` needs `service.nodePorts.derp` and `.stun` |
| `service.derpPort` / `stunPort` | `443` / `3478` | External ports |
| `ingress.enabled` | `false` | Relay through an Ingress; STUN through `stunService` |
| `ingress.tls.enabled` | `true` | `false` puts clients on plain HTTP port 80 |
| `stun.enabled` | `true` | `false`: no STUN listener or UDP Service; STUN port `-1` in the DERP map |
| `stunService.port` | `3478` | STUN port in Ingress mode |
| `derpMap.namespace` | release namespace | Coder's namespace |
| `derpMap.regionID` | `900` | Must not clash with 999 (built-in relay) or 1000+ (built-in STUN regions) |
| `derpMap.ipv4` | none | Relay node address, so clients skip DNS |
| `derpMap.stunIPv4` / `stunHostName` | none | STUN address when it differs from the relay's; adds STUN-only region `regionID + 1` |
| `derpMap.derpPort` / `stunPort` | derived | Override the ports written to the DERP map |
| `extraArgs` | `[]` | Extra `derper` flags |

## Checking it

```bash
curl https://derp.example.internal/derp/probe   # 200, empty body
coder netcheck | jq '.derp.netcheck | {UDP, GlobalV4, RegionLatency}'
coder ping <workspace>                          # "proxied via DERP(Custom DERP)" or "p2p via ..."
```

With STUN working, `UDP` is `true`, `GlobalV4` is the client's address as the relay saw it, and region `900` has a latency.
`UDP: false` means the STUN port is blocked between the client and the Service.
Generic STUN clients such as `stunclient` get no reply: `derper` answers only requests carrying Tailscale's `tailnode` software attribute.

Tested on k3s 1.36 with 3 replicas, in both modes: clients on different pods relay to each other over DERP and websockets, through the LoadBalancer, through Traefik, and pinned to each pod pair; two unmeshed relays fail the same test.

## Known issues

- **No client authentication.** `-verify-clients` needs a local `tailscaled` and does not work with Coder. Coder agents and the CLI can send a custom header (`CODER_AGENT_HEADER`, `--header`), but coderd's own connections to workspaces send none, so a header check would block the dashboard terminal and apps.
- **Certificate changes need a restart.** `derper` reads the certificate once at startup, including after cert-manager renews it.
- **TCP health checks with TLS.** `derper` refuses TLS handshakes whose server name is not `hostname`, and kubelet sends none, so the probes only check the port is open.
- **Node keys change on every restart.** They live in an `emptyDir`; meshed peers reconnect.
- **Untrusted certificates fail on the client.** A workspace image without the CA fails to connect to the relay with `x509: certificate signed by unknown authority` in the agent log. `derpMap.insecureForTests=true` skips verification for tests.

## Future

- Client admission by node key (upstream's `-verify-client-url`) backed by Coder
- Persist node keys in a Secret

## Documentation

| Doc | Contents |
|---|---|
| [docs/networking-basics.md](docs/networking-basics.md) | Plain-language guide: packets, TCP/UDP, firewalls, NAT, DERP, STUN, your network, whether to allow UDP, glossary |
| [docs/how-it-works.md](docs/how-it-works.md) | Coder networking, DERP, STUN, home relay choice, meshing, the production layout, whether the patch is needed, test results |
