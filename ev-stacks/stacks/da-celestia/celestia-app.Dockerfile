FROM ghcr.io/celestiaorg/celestia-app-standalone:v5.0.1-mocha

USER root

RUN apk add lz4

USER celestia