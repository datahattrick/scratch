# Coder DERP relay

A standalone Tailscale `derper` (DERP relay and STUN server) for Coder workspaces on a network with no internet access.
[Networking basics](docs/networking-basics.md) (plain language) and [how it works](docs/how-it-works.md) (technical), with diagrams.
The chart also renders a DERP map ConfigMap for coderd's `CODER_DERP_CONFIG_PATH`.

- **Upstream derper**: built from `github.com/tailscale/tailscale` at a release tag, unpatched. [Coder compatibility](docs/how-it-works.md#upstream-derper-and-coder)
- **One server per node**: each entry in `nodes` gets its own pod, hostname, Service and Ingress.
- **Client-side balancing**: by default each node is its own DERP map region, and clients spread across them by latency. A single region with meshed failover nodes is also available. [Detail](docs/how-it-works.md#nodes-regions-and-meshing)
- **LoadBalancer or Ingress**: relay and STUN on one LoadBalancer Service per node, or the relay behind an Ingress per node with STUN on a shared UDP Service.
- **STUN**: optional; `externalTrafficPolicy: Local`, so clients see their own address.
- **TLS**: in the pods from `kubernetes.io/tls` Secrets you provide or from cert-manager, at the ingress, or plain HTTP (`ForceHTTP` in the DERP map). No ACME or Let's Encrypt.
- **Access restriction**: `loadBalancerSourceRanges` and an optional NetworkPolicy.
- **DERP map**: written to a ConfigMap in Coder's namespace, with regions from other clusters merged in. [Other clusters](#other-clusters)

## Requirements

1. A registry the cluster can pull from, for the image built from `Dockerfile`.
2. One of:
   - a LoadBalancer that supports TCP and UDP on one Service (Kubernetes 1.26+), or `service.type=NodePort`;
   - an ingress controller that passes HTTP upgrades (Traefik does), plus a UDP LoadBalancer or NodePort for STUN.
3. A DNS name per node that resolves from coderd, workspace pods and Coder clients.
4. With TLS, a certificate per node name (or one with every name as a SAN, or a wildcard), signed by a CA that workspace images and client machines trust.

## Deploy

```bash
podman build -t registry.example.internal/coder-derper:v1.106.1 .
podman push registry.example.internal/coder-derper:v1.106.1
```

Nodes go in a values file:

```yaml
nodes:
  - {name: a, hostname: derp-a.example.internal}
  - {name: b, hostname: derp-b.example.internal}
```

LoadBalancer, TLS in the pods from crt/key Secrets:

```bash
kubectl create secret tls -n derp derp-a-tls --cert=derp-a.crt --key=derp-a.key
kubectl create secret tls -n derp derp-b-tls --cert=derp-b.crt --key=derp-b.key
helm upgrade --install derp ./chart -n derp -f nodes.yaml \
  --set nodes[0].tlsSecretName=derp-a-tls --set nodes[1].tlsSecretName=derp-b-tls \
  --set derpMap.namespace=coder
```

One Secret valid for every name goes in `tls.secretName` instead.
For cert-manager, set `tls.certManager.enabled=true` and `tls.certManager.issuerRef.name`; the chart makes one Certificate per node.

Ingress, TLS at the ingress:

```bash
helm upgrade --install derp ./chart -n derp -f nodes.yaml \
  --set tls.enabled=false \
  --set ingress.enabled=true --set ingress.className=traefik --set ingress.tls.secretName=derp-tls \
  --set derpMap.namespace=coder
```

Point each DNS name at its node's LoadBalancer address, or at the ingress.
Behind an ingress, if the STUN Service gets a different address, set `derpMap.stunIPv4` to it.
For another `derper` release, set `TAILSCALE_VERSION` in the build.

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
helm upgrade --install derp ./chart -n derp -f nodes.yaml \
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

The DERP map has one region per node, each on port 443 with no STUN port.
Without UDP, workspaces cannot connect directly (p2p) to anyone, so every connection to a workspace is relayed.
Clients measure each region over HTTPS (`/derp/latency-check`) and pick the fastest as their home relay.

Workspaces need DNS for each node name, or set `nodes[].ipv4` to the ingress address.

When the ingress controller runs in the same cluster as the workspaces, a workspace egress NetworkPolicy matches the ingress controller pod's port after NAT, not 443.
Allow that port too, or the workspace gets `connect: connection refused`:

```yaml
egress:
  - ports: [{port: 443, protocol: TCP}]
  - to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}},
          podSelector: {matchLabels: {app.kubernetes.io/name: traefik}}}]
    ports: [{port: 8443, protocol: TCP}]   # Traefik's websecure container port
```

Tested earlier with the `coder/tailscale` build and 3 replicas behind one hostname on Traefik: a workspace pod limited to TCP 443 (UDP and direct pod access blocked) picked region 900 and answered relayed pings from a coderd stand-in in the cluster and from a user machine on the LAN, over DERP and websockets.
The same layout with Coder 2.39.1 (built-in relay off): `coder ping` and `coder ssh` to the workspace went `proxied via DERP(Custom DERP)`, and coderd reached the agent. [Detail](docs/how-it-works.md#what-was-tested)

## Nodes and regions

With `derpMap.layout=region-per-node` (default), node `i` is region `derpMap.regionID + i`.
Keep the list order stable: clients and coderd key on region IDs.

With `derpMap.layout=single-region`, all nodes share one region and clients use the first that answers, so the rest are failover.
The nodes mesh over HTTPS, authenticated by a pre-shared key, so they need TLS in the pods or at the ingress.
The chart creates the key Secret and keeps it across upgrades; `mesh.existingSecret` uses your own (64 lowercase hex characters).
The pods trust `tls.ca.secretName`, the cert-manager Secret's `ca.crt`, or the image's system roots, in that order.
Behind an ingress, mesh connections go through it: set `mesh.ingressDialHost` (e.g. `traefik.kube-system.svc.cluster.local`) when the node names do not resolve from pods.

## Other clusters

Install the chart in each cluster with its own `derpMap.regionID` range, then merge the other clusters' regions into the map coderd reads.
coderd reads one DERP map.

```bash
# In the other cluster: regions 920 and up
helm upgrade --install derp ./chart -n derp -f syd-nodes.yaml \
  --set derpMap.regionID=920 --set derpMap.regionCode=syd --set derpMap.regionName=Sydney ...

# Its regions, as a values file (JSON is YAML)
kubectl --context syd get cm -n derp coder-derpmap -o jsonpath='{.data.derpmap\.json}' \
  | jq '{derpMap: {extraRegions: .Regions}}' > syd-regions.yaml

# In Coder's cluster
helm upgrade derp ./chart -n derp --reuse-values -f syd-regions.yaml
```

Restart coderd after the ConfigMap changes.
Clients home on the region with the lowest latency, so each geography's clients use their own cluster.
A client sends to a peer through the peer's home region, so every client must reach every cluster's relays (and STUN, if used) that its peers might home on.
The chart refuses region IDs that clash with its own, or that reach 999.

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
`derper` takes the client address from the TCP connection, so behind an ingress it sees only the controller.

### HAProxy ingress

With the [HAProxy Technologies ingress controller](https://github.com/haproxytech/kubernetes-ingress), restrict sources and rate per source with Ingress annotations:

```yaml
ingress:
  enabled: true
  className: haproxy
  tls: {secretName: derp-tls}
  annotations:
    haproxy.org/allow-list: "10.10.0.0/16, 10.20.0.0/16"      # Coder users, workspace nodes, coderd
    haproxy.org/rate-limit-period: "1m"
    haproxy.org/rate-limit-requests: "300"                     # Per source address
    haproxy.org/rate-limit-status-code: "429"
    haproxy.org/rate-limit-whitelist: "10.20.0.0/16"           # Workspace nodes
```

Other sources get `403`; a source over the limit gets `429` on new requests, and its open relay connections stay up.

- **Real client addresses.** The controller must see them: `externalTrafficPolicy: Local` on its Service, or the `proxy-protocol` ConfigMap key when a load balancer in front sends PROXY protocol. Otherwise every client has the same address and the allowlist matches all or nothing.
- **Workspaces share addresses.** Workspace pods usually leave the cluster as their node's IP, so every workspace on a node counts as one source. Exempt the workspace node subnets from the rate limit.
- **STUN does not go through HAProxy.** Restrict it with `stunService.loadBalancerSourceRanges` or a firewall.

Tested with controller 3.4.1 on k3s: DERP and websocket clients connect from an allowed address, `/derp/latency-check` returns `403` from any other, and requests past a limit of 20 a minute return `429`.
The 300 per minute above is not measured against Coder traffic.

## Values

| Value | Default | Purpose |
|---|---|---|
| `nodes` | none | `name` and `hostname` per node; required. Optional `ipv4`, `loadBalancerIP`, `tlsSecretName`, `nodePorts`, `serviceAnnotations`, `nodeSelector`, `affinity` |
| `derpMap.layout` | `region-per-node` | Or `single-region` (failover, meshed) |
| `tls.enabled` | `true` | TLS in the pods. `false` for Ingress mode or plain HTTP |
| `tls.secretName` | none | Existing TLS Secret valid for every node name; `nodes[].tlsSecretName` overrides it |
| `tls.certManager.enabled` | `false` | One cert-manager `Certificate` per node from `tls.certManager.issuerRef` |
| `tls.ca.secretName` | none | CA the pods trust for mesh connections |
| `mesh.ingressDialHost` | none | Address pods dial for mesh connections behind an ingress |
| `service.type` | `LoadBalancer` | `NodePort` needs `nodes[].nodePorts.derp` and `.stun` |
| `service.derpPort` / `stunPort` | `443` / `3478` | External ports |
| `ingress.enabled` | `false` | Relay through an Ingress; STUN through `stunService` |
| `ingress.tls.enabled` | `true` | `false` puts clients on plain HTTP port 80 |
| `stun.enabled` | `true` | `false`: no STUN listener or UDP Service; STUN port `-1` in the DERP map |
| `stunService.port` | `3478` | STUN port in Ingress mode |
| `derpMap.namespace` | release namespace | Coder's namespace |
| `derpMap.regionID` | `900` | First region. Every region must stay below 999 (built-in relay) |
| `derpMap.extraRegions` | `{}` | Regions from other clusters, keyed by region ID, merged into the map |
| `derpMap.stunIPv4` / `stunHostName` | none | STUN address when it differs from the relay's; adds a STUN-only region after the node regions |
| `derpMap.derpPort` / `stunPort` | derived | Override the ports written to the DERP map |
| `extraArgs` | `[]` | Extra `derper` flags |

## Checking it

```bash
curl https://derp-a.example.internal/derp/probe # 200, empty body
coder netcheck | jq '.derp.netcheck | {UDP, GlobalV4, RegionLatency}'
coder ping <workspace>                          # "proxied via DERP(Custom DERP)" or "p2p via ..."
```

With STUN working, `UDP` is `true`, `GlobalV4` is the client's address as the relay saw it, and each node's region has a latency.
`UDP: false` means the STUN port is blocked between the client and the Service.
Generic STUN clients such as `stunclient` get no reply: `derper` answers only requests carrying Tailscale's `tailnode` software attribute.

Tested on k3s 1.36 with two nodes: clients built from Coder's `coder/tailscale` relay through upstream `derper` over DERP and websockets, behind Traefik and with TLS in the pods from crt/key Secrets. [Detail](docs/how-it-works.md#what-was-tested)

## Known issues

- **No client authentication.** `-verify-clients` needs a local `tailscaled` and does not work with Coder. Coder agents and the CLI can send a custom header (`CODER_AGENT_HEADER`, `--header`), but coderd's own connections to workspaces send none, so a header check would block the dashboard terminal and apps.
- **Certificate changes need a restart.** `derper` reads the certificate once at startup, including after cert-manager renews it.
- **TCP health checks with TLS.** `derper` refuses TLS handshakes whose server name is not `hostname`, and kubelet sends none, so the probes only check the port is open.
- **Node keys change on every restart.** They live in an `emptyDir`; clients and meshed nodes reconnect.
- **Coder end to end not rerun on upstream `derper`.** The Coder 2.39.1 tests above ran against the `coder/tailscale` build; upstream was tested with the fork's DERP client.
- **Untrusted certificates fail on the client.** A workspace image without the CA fails to connect to the relay with `x509: certificate signed by unknown authority` in the agent log. `derpMap.insecureForTests=true` skips verification for tests.

## Future

- Client admission by node key (upstream's `-verify-client-url`) backed by Coder
- Persist node keys in a Secret

## Documentation

| Doc | Contents |
|---|---|
| [docs/networking-basics.md](docs/networking-basics.md) | Plain-language guide: packets, TCP/UDP, firewalls, NAT, DERP, STUN, your network, whether to allow UDP, glossary |
| [docs/how-it-works.md](docs/how-it-works.md) | Coder networking, DERP, STUN, home relay choice, meshing, the production layout, whether the patch is needed, test results |
