/*
 * Copyright (c) 2026 The runtt authors
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Template application.
 *
 * Deliberately boring: it logs and it feeds the liveness watchdog. Everything
 * that makes it deployable as a container -- the SMP server, the two channels,
 * the describe command -- comes from the `runtt` snippet, so this is what
 * a customer's existing firmware looks like after adopting the platform.
 */
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <app_version.h>

#ifdef CONFIG_RUNTT_HEALTH
#include <runtt/health.h>
#endif

LOG_MODULE_REGISTER(app, LOG_LEVEL_INF);

int main(void)
{
	uint32_t tick = 0;

	/* Goes to the log channel, which the runtime pipes to container stdio,
	 * which is what `docker logs` shows. This line is the whole feature.
	 */
	LOG_INF("runtt template app %s starting on %s", APP_VERSION_STRING,
		CONFIG_BOARD_TARGET);

	while (1) {
#ifdef CONFIG_RUNTT_HEALTH
		runtt_health_feed();
#endif
		LOG_INF("alive, tick %u", tick++);
		k_sleep(K_SECONDS(2));
	}

	return 0;
}
