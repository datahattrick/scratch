# derper built from github.com/coder/tailscale at the commit Coder pins,
# so the relay speaks the same DERP version as Coder agents and clients,
# with patches/ applied (mesh-with URLs, for meshing replicas).
# Find the commit for another Coder release with:
#   curl -s https://raw.githubusercontent.com/coder/coder/v<version>/go.mod | grep coder/tailscale
ARG GO_VERSION=1.25
FROM golang:${GO_VERSION} AS build
ARG CODER_TAILSCALE_REF=0fde3fc36b30
RUN git clone --filter=blob:none https://github.com/coder/tailscale /src \
 && git -C /src checkout "${CODER_TAILSCALE_REF}"
WORKDIR /src
COPY patches/ /patches/
RUN git apply /patches/*.patch
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/derper ./cmd/derper

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/derper /usr/local/bin/derper
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/derper"]
