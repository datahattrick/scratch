# derper built from the official github.com/tailscale/tailscale repository
# at a release tag. DERP protocol v2, the same as the coder/tailscale fork
# that Coder agents and clients use.
ARG GO_VERSION=1.27
FROM golang:${GO_VERSION} AS build
ARG TAILSCALE_VERSION=v1.106.1
RUN git clone --depth 1 --branch "${TAILSCALE_VERSION}" https://github.com/tailscale/tailscale /src
WORKDIR /src
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/derper ./cmd/derper

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/derper /usr/local/bin/derper
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/derper"]
