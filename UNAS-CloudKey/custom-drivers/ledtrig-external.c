// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 the CloudKey UNAS project authors

/*
 * ledtrig-external.c - Clean-room reimplementation of Ubiquiti's
 * proprietary "external" LED trigger pair, found on CloudKey-family
 * hardware as CONFIG_LEDS_TRIGGER_EXTERNAL in Ubiquiti's own build
 * (confirmed via /proc/config.gz extracted from a live stock unit --
 * this symbol name does not appear anywhere in Ubiquiti's public GPL
 * source drop for this kernel).
 *
 * This registers a small, Kconfig-tunable number of generic LED
 * triggers named "external0", "external1", ... "external<N-1>"
 * (N = CONFIG_LEDS_TRIGGER_EXTERNAL_MAX, matching the real device's
 * observed value of 2). Any LED class device can bind to one of these
 * via the standard sysfs interface:
 *
 *   echo external0 > /sys/class/leds/blue/trigger
 *
 * Once bound, ledtrig_external(idx, value) (exported for use by
 * leds-ulogo.c or any other in-tree caller) drives that trigger via
 * the completely standard led_trigger_event() mainline API -- there is
 * no proprietary hardware access anywhere in this file. The real
 * brightness_set() call that eventually reaches hardware (e.g. the
 * LP5562 driver behind "blue"/"white") is handled entirely by the
 * existing mainline LED trigger framework once a real LED has bound to
 * one of these triggers.
 *
 * Reconstructed from ARM64 disassembly of the stock kernel's own
 * compiled leds_ulogo/ledtrig-external code (recovered via kallsyms
 * reconstruction of the stock Image binary) -- see leds-ulogo.c for
 * full reverse-engineering notes. Contains no Ubiquiti source.
 *
 * License: GPL v2, matching the kernel tree this is built against.
 */

#include <linux/module.h>
#include <linux/leds.h>
#include <linux/slab.h>
#include <linux/errno.h>

#ifndef CONFIG_LEDS_TRIGGER_EXTERNAL_MAX
#define CONFIG_LEDS_TRIGGER_EXTERNAL_MAX 2
#endif

#define LEDTRIG_EXTERNAL_MAX CONFIG_LEDS_TRIGGER_EXTERNAL_MAX

static struct led_trigger *ext_trigger[LEDTRIG_EXTERNAL_MAX];
static char ext_trigger_name[LEDTRIG_EXTERNAL_MAX][16];

/*
 * ledtrig_external - drive external-trigger slot @idx to @value.
 *
 * @idx:   which "externalN" trigger to fire (0..LEDTRIG_EXTERNAL_MAX-1)
 * @value: any nonzero value is treated as full-on; this hardware path
 *         only supports binary on/off, matching the original's
 *         observed "level ? 255 : 0" behavior.
 *
 * Returns 0 on success, -EINVAL if idx is out of range.
 */
int ledtrig_external(unsigned int idx, enum led_brightness value)
{
	if (idx >= LEDTRIG_EXTERNAL_MAX)
		return -EINVAL;

	led_trigger_event(ext_trigger[idx], value ? LED_FULL : LED_OFF);
	return 0;
}
EXPORT_SYMBOL_GPL(ledtrig_external);

static int __init ledtrig_external_init(void)
{
	int i;

	/* led_trigger_register_simple() returns void in this kernel
	 * (3.18) -- later mainline versions changed it to return int
	 * for error reporting, but this tree predates that change, so
	 * there is nothing to check or unwind here.
	 */
	for (i = 0; i < LEDTRIG_EXTERNAL_MAX; i++) {
		snprintf(ext_trigger_name[i], sizeof(ext_trigger_name[i]),
			 "external%d", i);
		led_trigger_register_simple(ext_trigger_name[i],
					     &ext_trigger[i]);
	}
	return 0;
}

static void __exit ledtrig_external_exit(void)
{
	int i;

	for (i = 0; i < LEDTRIG_EXTERNAL_MAX; i++)
		led_trigger_unregister_simple(ext_trigger[i]);
}

module_init(ledtrig_external_init);
module_exit(ledtrig_external_exit);

MODULE_DESCRIPTION("Clean-room reimplementation of CONFIG_LEDS_TRIGGER_EXTERNAL (external0/external1 LED triggers, CloudKey-family)");
MODULE_LICENSE("GPL v2");
