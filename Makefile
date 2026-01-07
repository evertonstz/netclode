CONTEXT ?= netclode
NAMESPACE ?= netclode

.PHONY: rollout rollout-control-plane rollout-web rollout-all deploy

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

deploy: ## Wait for CI then rollout all
	gh run watch $$(gh run list --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status
	$(MAKE) rollout-all

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
