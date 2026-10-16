#!/bin/bash -Eeu

# Appends one test framework to the test_frameworks list the base image
# wrote in /versions.json, keeping any entry an earlier image added. Stops
# the build if the list is not found, rather than record nothing. Short grep
# flags because busybox grep has no long ones.
add_test_framework()
{
  local -r name="${1}"
  local -r version="${2}"
  local -r entry="{\"name\": \"${name}\", \"version\": \"${version}\"}"
  if grep -q '"test_frameworks": \[\]' /versions.json; then
    sed -i "s|\"test_frameworks\": \[\]|\"test_frameworks\": [${entry}]|" /versions.json
  else
    sed -i "/\"test_frameworks\": \[/s|}\]|}, ${entry}]|" /versions.json
  fi
  if ! grep -q -F "${entry}" /versions.json; then
    echo "Could not add ${name} to /versions.json" >&2
    cat /versions.json >&2
    exit 1
  fi
}

mkdir cdl && cd cdl

go mod init cdl-go-ginkgo

# The newest ginkgo and gomega releases, resolved once here at build time.
# Every later module in this build requires exactly these, so the image holds
# one version of each. A kata runs with no network, so the start-point's
# go.mod and go.sum must name these same versions; the end of this build
# writes them to /start_point_sync/.
go get github.com/onsi/ginkgo/v2@latest github.com/onsi/gomega@latest
readonly GINKGO_VERSION=$(go list -m -f '{{.Version}}' github.com/onsi/ginkgo/v2)
readonly GOMEGA_VERSION=$(go list -m -f '{{.Version}}' github.com/onsi/gomega)

# Requires exactly the resolved versions in the module in the current dir. go
# mod tidy then keeps them, and resolves every indirect dependency from them,
# so the whole module graph is fixed by these two versions. Do not drop a call
# to this before a go mod tidy: tidy alone could take a newer release.
require_pinned_versions()
{
  go get "github.com/onsi/ginkgo/v2@${GINKGO_VERSION}" "github.com/onsi/gomega@${GOMEGA_VERSION}"
}

cat > dummy.go << 'EOF'
package cdl
import (
    _ "github.com/onsi/ginkgo/v2"
    _ "github.com/onsi/gomega"
)
EOF

# Download ginkgo, gomega and all their deps, update go.mod with versions and
# go.sum with hashes
require_pinned_versions
go mod tidy

# Pre-compile them into a shared build cache accessible by all users
mkdir /go/build-cache
GOCACHE=/go/build-cache go build ./...

# Building the library is not what a kata does. A kata's test run calls
# [go test], which additionally compiles the test variant of each package and
# links a test binary, and neither of those is produced by the build above.
# Without them the first run in a fresh container rebuilt them every time,
# which was most of the wait; a kata runs in a container thrown away
# afterwards, so every run was a first run.
#
# The warm-up below is shaped like a real kata: a package, the suite file that
# hands the specs to go test, and a spec asserting against the package through
# gomega. A warm-up that only imported ginkgo would leave none of the entries
# that running specs reaches for.
mkdir warmup && cd warmup

go mod init cdl-go-ginkgo-warmup

cat > hiker.go << 'EOF'
package hiker

func answer() int {
    return 42
}
EOF

# ginkgo does not find specs by itself. RunSpecs is what hands them to go
# test, so a suite without this file compiles and runs no specs at all.
cat > hiker_suite_test.go << 'EOF'
package hiker

import (
    "testing"
    . "github.com/onsi/ginkgo/v2"
    . "github.com/onsi/gomega"
)

func TestHiker(t *testing.T) {
    RegisterFailHandler(Fail)
    RunSpecs(t, "Hiker Suite")
}
EOF

cat > hiker_test.go << 'EOF'
package hiker

import (
    . "github.com/onsi/ginkgo/v2"
    . "github.com/onsi/gomega"
)

var _ = Describe("answer", func() {
    It("is life the universe and everything", func() {
        Expect(answer()).To(Equal(42))
    })
})
EOF

require_pinned_versions
go mod tidy
GOCACHE=/go/build-cache go test

# A cache is keyed on the toolchain and the flags that filled it. If those ever
# drift from what cyber-dojo.sh runs, go silently rebuilds and the run is
# merely as slow as it was before. This compares a run against the warmed cache
# with one against an empty one, and insists the warm run be several times
# quicker.
#
# The comparison is against a cold run rather than a fixed number of seconds
# because this same script runs under QEMU when the arm64 half of the image is
# built on an amd64 machine. Emulated, a warm run takes seconds where it takes a
# fraction of one natively, so any threshold that fits one fails the other. A
# ratio holds either way: both runs are slowed by the same emulation.
go_test_seconds()
{
  local -r cache_dir="${1}"
  { TIMEFORMAT='%3R'; time GOCACHE="${cache_dir}" go test > /dev/null 2>&1; } 2>&1
}

readonly COLD_SECONDS=$(go_test_seconds /tmp/cold-cache)
readonly WARM_SECONDS=$(go_test_seconds /go/build-cache)
echo "[go test] cold ${COLD_SECONDS}s, warm ${WARM_SECONDS}s"
rm -rf /tmp/cold-cache

if [ "$(echo "${COLD_SECONDS} > ${WARM_SECONDS} * 3" | bc -l)" != '1' ]; then
  >&2 echo "Expected a warmed cache to be several times quicker than an empty one."
  >&2 echo "The cache is not being hit, so a kata's first run will rebuild."
  exit 42
fi

add_test_framework ginkgo "${GINKGO_VERSION#v}"
add_test_framework gomega "${GOMEGA_VERSION#v}"
cat /versions.json

# The start-point's go.mod and go.sum must require exactly what this image
# holds. They are written to /start_point_sync/, which the propagation bot
# copies into the start-point whenever this image's versions change. The
# module line is the start-point's own; the go line is this image's Go.
mkdir -p /start_point_sync
{
  printf 'module cyber-dojo-go-ginkgo\n\ngo %s\n\n' "$(go env GOVERSION | sed 's/^go//')"
  sed -n '/^require/,$p' go.mod
} > /start_point_sync/go.mod
cp go.sum /start_point_sync/go.sum

cd ..
rm -rf warmup
chmod -R 777 /go/build-cache

rm dummy.go
# Note: do NOT run go mod tidy again as it would remove ginkgo from go.mod
