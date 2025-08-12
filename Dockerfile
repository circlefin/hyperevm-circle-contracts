ARG FOUNDRY_VERSION=v0.3.0
# Use fixed foundry image
FROM ghcr.io/foundry-rs/foundry:${FOUNDRY_VERSION}

# Copy our source code into the container
WORKDIR /app
COPY . .

# Build the source code
EXPOSE 8545
RUN forge build
