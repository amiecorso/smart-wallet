FOUNDRY_VERSION := 1.5.1

.PHONY: deploy check-foundry

check-foundry:
	@forge --version | grep -q "$(FOUNDRY_VERSION)" || { \
	  echo "forge $(FOUNDRY_VERSION) required (found: $$(forge --version | head -1))"; \
	  echo "run: foundryup --install $(FOUNDRY_VERSION) && foundryup --use $(FOUNDRY_VERSION)"; \
	  exit 1; }

deploy: check-foundry
	source .env && export FOUNDRY_PROFILE=deploy && forge script script/DeployFactory.s.sol --rpc-url $${RPC_URL} --account $${ACCOUNT} --broadcast --verify
