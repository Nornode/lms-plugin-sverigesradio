HA_HOST  ?= homeassistant.local
HA_SLUG  ?= local_lms
PLUGIN   := SverigesRadio

.PHONY: deploy restart logs deploy-restart

deploy:
	rsync -avz --delete ./$(PLUGIN)/ \
	  root@$(HA_HOST):/addon_configs/$(HA_SLUG)/lms/plugins/$(PLUGIN)/
	ssh root@$(HA_HOST) \
	  "chown -R squeezeboxserver /addon_configs/$(HA_SLUG)/lms/plugins/$(PLUGIN)/"
	@echo "Deployed $(PLUGIN) to $(HA_HOST)"

restart:
	@echo "restartserver" | nc $(HA_HOST) 9090
	@echo "LMS server restart requested"

logs:
	ssh root@$(HA_HOST) \
	  "tail -100f /addon_configs/$(HA_SLUG)/lms/logs/server.log"

deploy-restart: deploy restart
	@echo "Deployed and restarted"
