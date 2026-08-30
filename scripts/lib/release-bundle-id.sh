#!/usr/bin/env bash
# Prints the CFBundleIdentifier scripts/release/build.sh should stamp.
#
# macOS keys Accessibility, Automation and notification grants to the
# bundle identifier. A locally built bundle carrying the shipped one
# competes with the installed app for the same TCC record: System
# Settings keeps showing the permission as granted while the installed
# app is quietly denied, and the only cure is resetting it by hand.
#
# CI builds the artifact that ships, so there the identifier has to be
# the real one. Everywhere else the build is a development artifact and
# gets the dev identifier, unless the caller says otherwise with
# CLYDE_RELEASE_BUNDLE=1 — building a release by hand for signing.
set -euo pipefail

if [ -n "${CLYDE_RELEASE_BUNDLE:-}" ] || [ -n "${CI:-}" ]; then
    echo "io.github.kl0sin.clyde"
else
    echo "io.github.kl0sin.clyde.dev"
fi
