# Cloud in a Bottle builds this file. The expensive Jitsi assembly is built
# from Dockerfile.prebuilt on every push to main by the image job in
# .github/workflows/ci.yml and published, signed, to the app image registry,
# so installs pull it instead of rebuilding.
FROM registry.cloudinabottle.org/bottled-jitsi:main
