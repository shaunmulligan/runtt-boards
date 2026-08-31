/*
 * Copyright (c) 2026 The runtt authors
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Flash inspector for RP2040 bring-up.
 *
 * Answers "is the image actually where we think we put it?" without a SWD probe
 * or picotool. It links at the start of flash, like any no-bootloader image, so
 * flashing it leaves the MCUboot slots untouched -- it can therefore report on
 * an image that a bootloader has just refused to boot.
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>

/* RP2040 executes in place from a fixed window, so flash offsets are directly
 * addressable and we can just read them.
 */
#define XIP_BASE 0x10000000U

/* From dts/vendor/raspberrypi/partitions_2M_sysbuild.dtsi. */
struct region {
	const char *name;
	uint32_t offset;
	uint32_t size;
};

static const struct region regions[] = {
	{ "boot2",   0x000000, 0x000100 },
	{ "mcuboot", 0x000100, 0x00fe00 },
	{ "slot0",   0x010000, 0x0d0000 },
	{ "slot1",   0x0e0000, 0x0d0000 },
};

#define MCUBOOT_IMAGE_MAGIC 0x96f3b83dU

static void dump(const char *label, uint32_t addr, size_t len)
{
	const uint8_t *p = (const uint8_t *)addr;

	printk("  %-8s @ %08x:", label, addr);
	for (size_t i = 0; i < len; i++) {
		printk(" %02x", p[i]);
	}
	printk("\n");
}

int main(void)
{
	printk("\n=== runtt flash inspector ===\n");

	for (size_t i = 0; i < ARRAY_SIZE(regions); i++) {
		const struct region *r = &regions[i];
		uint32_t addr = XIP_BASE + r->offset;
		const uint8_t *p = (const uint8_t *)addr;

		/* How much of the region is not erased. Sampled rather than
		 * exhaustive: 832 KB of byte reads per slot is needlessly slow
		 * and the first few KB answer the question.
		 */
		size_t sample = MIN(r->size, 0x4000);
		size_t used = 0;

		for (size_t j = 0; j < sample; j++) {
			if (p[j] != 0xff) {
				used++;
			}
		}

		uint32_t magic = *(const uint32_t *)addr;
		const char *note = (magic == MCUBOOT_IMAGE_MAGIC) ? "  <- MCUboot image header"
								 : "";

		printk("%-8s %08x  %6u/%u bytes used in first %uKB%s\n",
		       r->name, addr, (unsigned)used, (unsigned)sample,
		       (unsigned)(sample / 1024), note);
		dump("first16", addr, 16);
	}

	/* The trailer lives at the very end of a slot and is what tells MCUboot
	 * whether an image is pending, confirmed, or nothing at all.
	 */
	printk("trailers:\n");
	dump("slot0", XIP_BASE + 0x010000 + 0x0d0000 - 32, 32);
	dump("slot1", XIP_BASE + 0x0e0000 + 0x0d0000 - 32, 32);

	printk("=== end ===\n");

	while (1) {
		k_sleep(K_SECONDS(10));
	}
	return 0;
}
