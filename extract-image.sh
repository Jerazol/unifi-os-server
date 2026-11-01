#!/usr/bin/env bash
# Extract the UniFi OS Server container image from Ubiquiti's official Linux installer,
# without running the installer.
#
# The installer is an ELF binary with a zip archive appended to it. The zip contains
# Ubiquiti's management tools (podman based) and image.tar, an OCI image archive with
# UniFi OS Server itself. This script unpacks the zip, verifies the image against its
# own sha256 digests and, optionally, pushes it to a container registry with skopeo.
#
# Usage: extract-image.sh [-o OUTDIR] [-v VERSION] [-p REGISTRY/REPOSITORY] INSTALLER
#
#   -o OUTDIR   where to put the extracted files (default: ./uos-<version>)
#   -v VERSION  UniFi OS Server version, if it can't be read from the installer file name
#   -p REPO     push the image to REPO:<version> with skopeo, e.g. registry.example.com/uosserver
#
# Requires: 7z or unzip, tar, sha256sum; skopeo for -p.
set -euo pipefail

usage() { sed -n '/^# Usage:/,/^# Requires:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "error: $*" >&2; exit 1; }

OUTDIR="" VERSION="" PUSH=""
while getopts "o:v:p:h" opt; do
  case $opt in
    o) OUTDIR=$OPTARG ;;
    v) VERSION=$OPTARG ;;
    p) PUSH=$OPTARG ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage
INSTALLER=$1
[ -f "$INSTALLER" ] || die "installer not found: $INSTALLER"

# Version from the download's file name, e.g. 1234-linux-x64-5.1.42-<uuid>.42-x64
if [ -z "$VERSION" ]; then
  VERSION=$(basename "$INSTALLER" | sed -nE 's/.*linux-(x64|arm64)-([0-9]+\.[0-9]+\.[0-9]+)-.*/\2/p')
  [ -n "$VERSION" ] || die "could not read the version from the file name, pass it with -v"
fi
[ -n "$OUTDIR" ] || OUTDIR="./uos-$VERSION"

# Unpack into a new, empty directory
[ -e "$OUTDIR" ] && die "$OUTDIR already exists"
mkdir -p "$OUTDIR"
echo "Extracting $INSTALLER -> $OUTDIR"
if command -v 7z >/dev/null; then
  7z x -o"$OUTDIR" "$INSTALLER" >/dev/null
elif command -v unzip >/dev/null; then
  # unzip warns about the ELF in front of the archive and exits 1; that is expected
  unzip -q -d "$OUTDIR" "$INSTALLER" || [ $? -eq 1 ] || die "unzip failed"
else
  die "need 7z or unzip"
fi
IMAGE="$OUTDIR/image.tar"
[ -f "$IMAGE" ] || die "no image.tar in the installer; the format may have changed"

# Verify every blob in the OCI archive against its sha256 name
echo "Verifying image blobs"
VERIFY="$OUTDIR/.verify"
mkdir "$VERIFY"
tar -xf "$IMAGE" -C "$VERIFY" index.json blobs
( cd "$VERIFY/blobs/sha256" && for f in *; do echo "$f  $f"; done | sha256sum --quiet -c - ) \
  || die "image blob checksum mismatch"
DIGEST=$(grep -oE '"digest":"sha256:[0-9a-f]{64}"' "$VERIFY/index.json" | head -1 | cut -d'"' -f4)
ARCH=$(grep -oE '"architecture":"[^"]+"' "$VERIFY/index.json" | head -1 | cut -d'"' -f4)
rm -rf "$VERIFY"
[ -n "$DIGEST" ] || die "could not read the manifest digest from index.json"

cat > "$OUTDIR/image-info.env" <<EOF
VERSION=$VERSION
ARCH=$ARCH
DIGEST=$DIGEST
EOF

echo
echo "UniFi OS Server $VERSION ($ARCH)"
echo "  image:        $IMAGE"
echo "  digest:       $DIGEST"
echo "  ports:        $OUTDIR/portmap.json"
echo "  volumes:      $OUTDIR/mounts.json"

if [ -n "$PUSH" ]; then
  command -v skopeo >/dev/null || die "skopeo is needed for -p"
  echo
  echo "Pushing to $PUSH:$VERSION"
  skopeo copy "oci-archive:$IMAGE" "docker://$PUSH:$VERSION"
  echo
  echo "Set this in kustomize/kustomization.yaml:"
  echo "  images:"
  echo "    - name: uosserver"
  echo "      newName: $PUSH"
  echo "      newTag: \"$VERSION\""
  echo "      digest: $DIGEST"
  echo "and APP_VERSION=$VERSION in kustomize/config.env"
else
  echo
  echo "Push it to your registry, for example:"
  echo "  skopeo copy oci-archive:$IMAGE docker://<registry>/uosserver:$VERSION"
fi
