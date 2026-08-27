#!/usr/bin/env bash
#
# Keeps the places a version is written from drifting apart, and checks the
# tag on a release build.
#
#   MARKETING_VERSION   project.pbxproj, once per build configuration --
#                       six of them, and nothing makes them agree
#   git tag             v<x.y.z> -- what the release is named
#
# Android learned this the expensive way: versionCode/versionName are
# hardcoded, and a tag disagreeing with them is caught by Play rejecting the
# upload rather than by anything in the repository. Here the equivalent
# failure is worse, because CFBundleShortVersionString is what App Store
# Connect files the build under and it cannot be corrected after the fact.
#
# Xcode edits one configuration at a time, so the six copies drift silently:
# bumping the app's Release and forgetting its Debug produces two builds
# claiming different versions from one commit.
#
# Usage: verify-version.sh [tag]
#   tag defaults to $GITHUB_REF_NAME when the ref is a tag, else no tag check.

set -euo pipefail

cd "$(dirname "$0")/.."

pbxproj=KyPost.xcodeproj/project.pbxproj
[ -f "$pbxproj" ] || { echo "no $pbxproj here" >&2; exit 1; }

# Every MARKETING_VERSION in the file, deduplicated. More than one distinct
# value is drift; none at all means the setting was renamed or removed and
# this check has quietly stopped checking anything.
# No mapfile/readarray here: macOS ships bash 3.2 as /bin/bash, and the
# GitHub macOS runners are no different. `mapfile: command not found` under
# `set -e` exits non-zero, so this would have "failed correctly" on a version
# mismatch while never having read a version at all.
versions=$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$pbxproj" | sort -u)
count=$(printf '%s' "$versions" | grep -c . || true)

if [ "$count" -eq 0 ]; then
  echo "no MARKETING_VERSION in $pbxproj -- this check is not checking anything" >&2
  exit 1
fi

if [ "$count" -gt 1 ]; then
  echo "version drift inside $pbxproj: MARKETING_VERSION is set to $count different values:" >&2
  printf '%s\n' "$versions" | sed 's/^/  /' >&2
  exit 1
fi

version="$versions"
echo "MARKETING_VERSION = ${version}"

tag="${1-}"
if [ -z "$tag" ] && [ "${GITHUB_REF_TYPE-}" = "tag" ]; then
  tag="${GITHUB_REF_NAME-}"
fi
[ -n "$tag" ] || exit 0

# Tags are `v0.4.0`; the build setting is bare. Compared with the prefix
# stripped so the two conventions can coexist.
if [ "${tag#v}" != "$version" ]; then
  echo "tag ${tag} does not match MARKETING_VERSION ${version}" >&2
  exit 1
fi
echo "tag ${tag} matches"
