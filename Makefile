# qa-apps build entry point. Everything runs in Docker (builder image from the rollups-node tag).
#   make foreclose-app NETWORK=devnet|sepolia|base-sepolia   one snapshot, prints its template hash
#   make foreclose-apps                                       all networks
#   make fixtures                                             node terminal-state fixtures
#   make all                                                  everything
#   make reproducible                                         rebuild everything and require identical hashes
#   make verify                                               compare out/*.hash with hashes.txt
#   make dist                                                 out/ -> dist/*.tar.gz + SHA256SUMS + template-hashes.txt
NETWORKS := devnet sepolia base-sepolia
NETWORK ?=

.PHONY: all foreclose-app foreclose-apps fixtures reproducible verify dist clean

all: foreclose-apps fixtures

foreclose-app:
	@test -n "$(NETWORK)" || { echo "usage: make foreclose-app NETWORK=<$(NETWORKS)>"; exit 2; }
	@./foreclose-app/build.sh $(NETWORK)

foreclose-apps:
	@set -e; for n in $(NETWORKS); do ./foreclose-app/build.sh $$n; done

fixtures:
	@./fixtures/build.sh

reproducible:
	@./build/reproducible.sh

verify:
	@./build/verify.sh

dist:
	@./build/dist.sh

clean:
	rm -rf out dist
