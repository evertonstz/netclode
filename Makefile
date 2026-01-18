CONTEXT ?= netclode
NAMESPACE ?= netclode

.PHONY: rollout rollout-control-plane rollout-web rollout-all deploy test-ios

rollout: ## Rollout a deployment: make rollout target=control-plane
ifndef target
	$(error target is required. Usage: make rollout target=control-plane)
endif
	kubectl --context $(CONTEXT) -n $(NAMESPACE) rollout restart deployment/$(target)

rollout-control-plane: ## Rollout control-plane
	kubectl --context $(CONTEXT) -n $(NAMESPACE) rollout restart deployment/control-plane

rollout-web: ## Rollout web
	kubectl --context $(CONTEXT) -n $(NAMESPACE) rollout restart deployment/web

rollout-all: rollout-control-plane rollout-web ## Rollout all deployments

drain-warmpool: ## Drain warm pool to pick up new agent image
	@echo "Scaling warm pool to 0..."
	kubectl --context $(CONTEXT) -n $(NAMESPACE) patch sandboxwarmpool netclode-agent-pool -p '{"spec":{"replicas":0}}' --type=merge
	@echo "Waiting for warm pods to terminate..."
	@sleep 5
	@echo "Scaling warm pool back to 1..."
	kubectl --context $(CONTEXT) -n $(NAMESPACE) patch sandboxwarmpool netclode-agent-pool -p '{"spec":{"replicas":1}}' --type=merge
	@echo "Warm pool refreshed"

deploy: ## Wait for CI then rollout all
	gh run watch $$(gh run list --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status
	$(MAKE) rollout-all

test-ios: ## Run iOS unit tests
	cd clients/ios && xcodebuild test -scheme NetclodeTests -destination 'platform=macOS' -quiet

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
