/*
 * Copyright (c) 2026 balena
 * SPDX-License-Identifier: Apache-2.0
 *
 * balena-mcu-idle: the application that ships in slot 0 at provisioning time.
 *
 * It does nothing, on purpose. What matters is what it makes possible: a board
 * carrying it enumerates, answers `describe`, and accepts an image upload.
 *
 * The alternative is worse than it sounds. MCUboot with an empty primary slot
 * halts, and having no USB of its own it does so completely silently -- no
 * enumeration, no device node, nothing. Such a board is indistinguishable from
 * one that is unplugged, unpowered or dead, and diagnosing it needs a wire to a
 * UART. With this image present the same board shows up as a service reporting
 * a clear error, which is the difference between a five-minute diagnosis and an
 * afternoon.
 *
 * Everything that makes it manageable comes from the balena-mcu module. There is
 * deliberately nothing here.
 */
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(idle, LOG_LEVEL_INF);

int main(void)
{
	LOG_INF("balena-mcu-idle on %s: provisioned, awaiting first firmware",
		CONFIG_BOARD_TARGET);

	/* Sleep forever. The SMP server runs on its own thread, so the runtime
	 * can talk to this board and replace it whenever it likes.
	 */
	while (1) {
		k_sleep(K_FOREVER);
	}

	return 0;
}
