FROM ghcr.io/celestiaorg/celestia-app:v6.0.5-mocha

USER root

RUN apk add lz4

USER celestia