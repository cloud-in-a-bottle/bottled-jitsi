# Cloud in a Bottle builds this file. The expensive Jitsi assembly is built
# from Dockerfile.prebuilt on every merge to main and published by
# .github/workflows/image.yml, so installs pull it instead of rebuilding.
FROM ghcr.io/cloud-in-a-bottle/bottled-jitsi:latest
