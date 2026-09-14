// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 the CloudKey UNAS project authors

/*
 * leds-ulogo.c - Clean-room reimplementation of Ubiquiti's proprietary
 * "leds-ulogo" driver for the CloudKey G2 Plus (and likely sibling
 * CloudKey-family devices).
 *
 * Ubiquiti's original binary was never present in their public GPL
 * source drop (confirmed by exhaustive search of the released tarball,
 * including its own pre-built vmlinux/.o artifacts) despite being
 * compiled into every shipped stock kernel. This file reconstructs its
 * externally observable behavior from ARM64 disassembly of the actual
 * stock kernel image (recovered via kallsyms table reconstruction), not
 * from any Ubiquiti source. It contains no Ubiquiti code.
 *
 * NOTE ON STRUCTURE: this was originally written as a single combined
 * file handling both the ulogo platform driver AND the external0/
 * external1 triggers. That turned out to not match reality -- pulling
 * /proc/config.gz from a live stock unit (verified-running.config)
 * showed Ubiquiti's real build uses TWO separate Kconfig symbols,
 * CONFIG_LEDS_ULOGO and CONFIG_LEDS_TRIGGER_EXTERNAL (with its own
 * CONFIG_LEDS_TRIGGER_EXTERNAL_MAX=2), meaning the trigger provider is
 * architected as its own standalone driver -- consistent with every
 * other ledtrig-*.c file already living in drivers/leds/trigger/ in
 * this tree. This file now only implements the CONFIG_LEDS_ULOGO half;
 * see ledtrig-external.c for the CONFIG_LEDS_TRIGGER_EXTERNAL half,
 * whose exported ledtrig_external() this file calls.
 *
 * Reverse-engineered behavior summary:
 *
 *   - This is a platform driver matching compatible = "leds-ulogo".
 *   - The DT node contains one or more child nodes ("group0", "group1",
 *     ...), each with:
 *       label          - string, becomes the LED class device name
 *       led_idx         - u32 array, indices into ledtrig-external's
 *                         "externalN" triggers (observed max index 1,
 *                         i.e. 2 triggers total: "external0"/"external1")
 *       default_pattern - optional string, "LEVEL:MS LEVEL:MS ...",
 *                         a boot-time blink program
 *   - Each group's LED classdev's brightness_set callback
 *     (ctrl_led_set_brightness in the original) does no hardware access
 *     itself: it simply calls ledtrig_external() for every index in
 *     that group's led_idx list, converting any nonzero brightness to
 *     full-on (this hardware only supports binary on/off dimming via
 *     this path, not analog levels).
 *   - The pattern engine (led_pattern_timer_function /
 *     ulogo_pattern_set_timer in the original) is an ordinary kernel
 *     timer_list, not the LP5562's onboard autonomous pattern engine.
 *     It parses "LEVEL:MS" tokens, and on each timer tick tests bit N
 *     of LEVEL for each configured led_idx N, driving that trigger
 *     on/off accordingly, then reschedules itself via mod_timer() for
 *     the token's duration. Step count is capped at
 *     CONFIG_LEDS_ULOGO_PATTERN_MAX (observed as 16 on the real device
 *     via verified-running.config), not an arbitrary value.
 *
 * This reimplementation intentionally omits the original's "binary" and
 * "constant" sysfs attributes (alternate runtime pattern-programming
 * formats) since they are not required to restore the DT-driven boot
 * pattern or normal LED operation. A "pattern" sysfs attribute
 * equivalent to the original is included for parity and runtime
 * control. The original's per-trigger activate()/deactivate() hooks
 * (cosmetic state tracking only, not required for led_trigger_event()
 * to function) are also omitted for simplicity; led_trigger_register()
 * with full custom ops can be added later if that bookkeeping turns
 * out to matter in practice.
 *
 * License: GPL v2, matching the kernel tree this is built against.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/of_device.h>
#include <linux/leds.h>
#include <linux/slab.h>
#include <linux/timer.h>
#include <linux/jiffies.h>
#include <linux/ctype.h>
#include <linux/string.h>
#include <linux/device.h>
#include <linux/list.h>
#include <linux/kernel.h>
#include <linux/printk.h>

#ifndef CONFIG_LEDS_ULOGO_PATTERN_MAX
#define CONFIG_LEDS_ULOGO_PATTERN_MAX 16
#endif

#define ULOGO_MAX_STEPS       CONFIG_LEDS_ULOGO_PATTERN_MAX
#define ULOGO_MAX_PATTERN_LEN 256

/* Provided by ledtrig-external.c (CONFIG_LEDS_TRIGGER_EXTERNAL) */
extern int ledtrig_external(unsigned int idx, enum led_brightness value);

/* One step of a blink pattern: LEVEL is a bitmask over led_idx values,
 * MS is how long to hold that state before advancing to the next step.
 */
struct ulogo_step {
	u32 level;
	u32 ms;
};

struct ulogo_led {
	struct led_classdev cdev;
	struct platform_device *pdev;
	struct timer_list timer;
	struct list_head list;

	u32 *led_idx;
	int num_idx;

	char pattern_raw[ULOGO_MAX_PATTERN_LEN];
	struct ulogo_step steps[ULOGO_MAX_STEPS];
	int num_steps;
	int cur_step;

	/* Raw captures of whatever uled-ctrl actually writes, kept purely
	 * for diagnostics (dev_info + hex dump on every write) until the
	 * real payload format for these two is confirmed from a live
	 * device and this can be replaced with a proper decoder. See the
	 * comment above ulogo_capture_and_apply() below.
	 */
	char constant_raw[64];
	size_t constant_len;
	char binary_raw[64];
	size_t binary_len;
};

static void ctrl_led_set_brightness(struct led_classdev *cdev,
				     enum led_brightness value)
{
	struct ulogo_led *ule = container_of(cdev, struct ulogo_led, cdev);
	int i;

	for (i = 0; i < ule->num_idx; i++)
		ledtrig_external(ule->led_idx[i], value);
}

/* Parse "LEVEL:MS LEVEL:MS ..." into ule->steps[]. Returns steps parsed,
 * or 0 on empty/unparseable input (caller treats 0 as "stop blinking").
 */
static int ulogo_parse_pattern(struct ulogo_led *ule, const char *buf)
{
	const char *p = buf;
	int n = 0;
	unsigned int level, ms;

	while (n < ULOGO_MAX_STEPS) {
		while (*p == ' ' || *p == '\t')
			p++;
		if (*p == '\0' || *p == '\n')
			break;
		if (sscanf(p, "%u:%u", &level, &ms) != 2)
			break;
		ule->steps[n].level = level;
		ule->steps[n].ms = ms;
		n++;
		while (*p && *p != ' ' && *p != '\t' && *p != '\n')
			p++;
	}
	return n;
}

/* Old-era (pre-4.15) kernels pass an unsigned long, not a timer_list *.
 * setup_timer()/init_timer() below matches that ABI for this 3.18 tree;
 * adjust the callback signature if backporting to a timer_setup()-era
 * kernel.
 */
static void ulogo_pattern_timer_function_compat(unsigned long data)
{
	struct ulogo_led *ule = (struct ulogo_led *)data;
	struct ulogo_step *step;
	int i;

	if (ule->num_steps <= 0)
		return;

	step = &ule->steps[ule->cur_step];

	for (i = 0; i < ule->num_idx; i++) {
		u32 idx = ule->led_idx[i];
		int bit = (step->level >> idx) & 1;

		ledtrig_external(idx, bit ? LED_FULL : LED_OFF);
	}

	mod_timer(&ule->timer, jiffies + msecs_to_jiffies(step->ms));

	ule->cur_step++;
	if (ule->cur_step >= ule->num_steps)
		ule->cur_step = 0;
}

static void ulogo_start_pattern(struct ulogo_led *ule, const char *buf)
{
	del_timer_sync(&ule->timer);

	strlcpy(ule->pattern_raw, buf, sizeof(ule->pattern_raw));
	ule->num_steps = ulogo_parse_pattern(ule, ule->pattern_raw);
	ule->cur_step = 0;

	if (ule->num_steps > 0)
		mod_timer(&ule->timer, jiffies + 1);
}

static ssize_t pattern_show(struct device *dev,
			     struct device_attribute *attr, char *buf)
{
	struct led_classdev *cdev = dev_get_drvdata(dev);
	struct ulogo_led *ule = container_of(cdev, struct ulogo_led, cdev);

	return scnprintf(buf, PAGE_SIZE, "%s\n", ule->pattern_raw);
}

static ssize_t pattern_store(struct device *dev,
			      struct device_attribute *attr,
			      const char *buf, size_t count)
{
	struct led_classdev *cdev = dev_get_drvdata(dev);
	struct ulogo_led *ule = container_of(cdev, struct ulogo_led, cdev);

	if (count >= sizeof(ule->pattern_raw))
		return -E2BIG;

	ulogo_start_pattern(ule, buf);
	return count;
}
static DEVICE_ATTR_RW(pattern);

/*
 * constant / binary - the attributes uled-ctrl (the real UniFi-side LED
 * control binary, /usr/bin/uled-ctrl) actually writes to. Confirmed via
 * strace against the stock uled-ctrl binary: it targets
 * ".../ulogo_ctrl/constant" for "off" and "fw <status>" commands (the
 * only ones this white/blue 2-channel hardware supports -- color/hsb/
 * blink/breath are all rejected inside uled-ctrl's own argument
 * validation before ever reaching sysfs, since those are for
 * RGB-capable CloudKey-family variants this device isn't).
 *
 * UPDATE: the payload format is now confirmed live, not guessed. Real
 * device testing captured this exact sequence in dmesg across many
 * uled-ctrl invocations (both "off" and normal fw-status transitions
 * triggered by the actual UniFi app):
 *
 *   leds ulogo_ctrl: constant: received 1 bytes (boot pattern stopped)
 *   ulogo raw: 00000000: 30                                     0
 *   leds ulogo_ctrl: constant: parsed as integer 0x0, applied as bitmask
 *
 * i.e. uled-ctrl really does send a single plain ASCII digit ("0" or
 * "1"), applied as a bitmask over led_idx exactly as implemented below
 * -- this has been exercised on real hardware with the physical LED
 * changing state correctly in response, not just parsed successfully.
 * The three-step approach below (stop timer / log raw bytes / best-
 * effort ASCII-integer parse) was originally written defensively before
 * this confirmation existed; it's kept as-is since it's already
 * confirmed correct for every payload actually observed, and the raw
 * hex-dump logging remains harmless and useful if this hardware or a
 * future uled-ctrl version ever sends something outside this format.
 */
static ssize_t ulogo_capture_and_apply(struct device *dev, const char *buf,
					size_t count, char *raw_out,
					size_t raw_out_sz, size_t *raw_len_out,
					const char *attr_name)
{
	struct led_classdev *cdev = dev_get_drvdata(dev);
	struct ulogo_led *ule = container_of(cdev, struct ulogo_led, cdev);
	size_t copy_len = min(count, raw_out_sz - 1);
	unsigned long val;
	int i;

	del_timer_sync(&ule->timer);
	ule->num_steps = 0;

	memcpy(raw_out, buf, copy_len);
	raw_out[copy_len] = '\0';
	*raw_len_out = copy_len;

	dev_info(dev, "%s: received %zu bytes (boot pattern stopped)\n",
		 attr_name, count);
	print_hex_dump(KERN_INFO, "ulogo raw: ", DUMP_PREFIX_OFFSET,
			16, 1, buf, min(count, (size_t)64), true);

	if (!kstrtoul(raw_out, 0, &val)) {
		for (i = 0; i < ule->num_idx; i++) {
			u32 idx = ule->led_idx[i];
			int bit = (val >> idx) & 1;

			ledtrig_external(idx, bit ? LED_FULL : LED_OFF);
		}
		dev_info(dev, "%s: parsed as integer 0x%lx, applied as bitmask\n",
			 attr_name, val);
	} else {
		dev_info(dev, "%s: not a plain integer -- accepted but not applied; "
			 "see hex dump above for the real payload format\n",
			 attr_name);
	}

	return count;
}

static ssize_t constant_show(struct device *dev,
			      struct device_attribute *attr, char *buf)
{
	struct led_classdev *cdev = dev_get_drvdata(dev);
	struct ulogo_led *ule = container_of(cdev, struct ulogo_led, cdev);

	return scnprintf(buf, PAGE_SIZE, "%.*s\n", (int)ule->constant_len,
			  ule->constant_raw);
}

static ssize_t constant_store(struct device *dev,
			       struct device_attribute *attr,
			       const char *buf, size_t count)
{
	struct led_classdev *cdev = dev_get_drvdata(dev);
	struct ulogo_led *ule = container_of(cdev, struct ulogo_led, cdev);

	if (count >= sizeof(ule->constant_raw))
		return -E2BIG;

	return ulogo_capture_and_apply(dev, buf, count, ule->constant_raw,
					sizeof(ule->constant_raw),
					&ule->constant_len, "constant");
}
static DEVICE_ATTR_RW(constant);

static ssize_t binary_show(struct device *dev,
			    struct device_attribute *attr, char *buf)
{
	struct led_classdev *cdev = dev_get_drvdata(dev);
	struct ulogo_led *ule = container_of(cdev, struct ulogo_led, cdev);

	return scnprintf(buf, PAGE_SIZE, "%.*s\n", (int)ule->binary_len,
			  ule->binary_raw);
}

static ssize_t binary_store(struct device *dev,
			     struct device_attribute *attr,
			     const char *buf, size_t count)
{
	struct led_classdev *cdev = dev_get_drvdata(dev);
	struct ulogo_led *ule = container_of(cdev, struct ulogo_led, cdev);

	if (count >= sizeof(ule->binary_raw))
		return -E2BIG;

	return ulogo_capture_and_apply(dev, buf, count, ule->binary_raw,
					sizeof(ule->binary_raw),
					&ule->binary_len, "binary");
}
static DEVICE_ATTR_RW(binary);

static struct attribute *ulogo_led_attrs[] = {
	&dev_attr_pattern.attr,
	&dev_attr_constant.attr,
	&dev_attr_binary.attr,
	NULL,
};
ATTRIBUTE_GROUPS(ulogo_led);

static int ulogo_probe_group(struct platform_device *pdev,
			      struct device_node *group_node,
			      struct list_head *led_list)
{
	struct ulogo_led *ule;
	const char *label = NULL;
	const char *default_pattern = NULL;
	int count, ret;

	ule = devm_kzalloc(&pdev->dev, sizeof(*ule), GFP_KERNEL);
	if (!ule)
		return -ENOMEM;

	ule->pdev = pdev;
	INIT_LIST_HEAD(&ule->list);

	of_property_read_string(group_node, "label", &label);
	if (!label)
		label = group_node->name;

	count = of_property_count_elems_of_size(group_node, "led_idx",
						 sizeof(u32));
	if (count <= 0) {
		dev_err(&pdev->dev, "%pOF: missing/empty led_idx\n",
			group_node);
		return -EINVAL;
	}

	ule->led_idx = devm_kcalloc(&pdev->dev, count, sizeof(u32),
				    GFP_KERNEL);
	if (!ule->led_idx)
		return -ENOMEM;

	ret = of_property_read_u32_array(group_node, "led_idx",
					  ule->led_idx, count);
	if (ret)
		return ret;
	ule->num_idx = count;

	ule->cdev.name = label;
	ule->cdev.brightness_set = ctrl_led_set_brightness;
	ule->cdev.max_brightness = LED_FULL;
	ule->cdev.groups = ulogo_led_groups;

	/* This 3.18 tree predates devm_led_classdev_register() (a later
	 * mainline addition) -- only the plain, non-devm registration
	 * function exists here, so teardown is handled explicitly in
	 * leds_ulogo_remove() below via the led_list this group gets
	 * added to.
	 */
	ret = led_classdev_register(&pdev->dev, &ule->cdev);
	if (ret)
		return ret;

	setup_timer(&ule->timer, ulogo_pattern_timer_function_compat,
		    (unsigned long)ule);

	of_property_read_string(group_node, "default_pattern",
				 &default_pattern);
	if (default_pattern)
		ulogo_start_pattern(ule, default_pattern);

	list_add_tail(&ule->list, led_list);

	dev_info(&pdev->dev, "registered '%s' (%d led_idx entries)%s\n",
		 label, count, default_pattern ? ", pattern active" : "");

	return 0;
}

static int leds_ulogo_probe(struct platform_device *pdev)
{
	struct device_node *np = pdev->dev.of_node;
	struct device_node *child;
	struct list_head *led_list;
	int registered = 0;
	int ret;

	if (!np)
		return -ENODEV;

	led_list = devm_kzalloc(&pdev->dev, sizeof(*led_list), GFP_KERNEL);
	if (!led_list)
		return -ENOMEM;
	INIT_LIST_HEAD(led_list);
	platform_set_drvdata(pdev, led_list);

	for_each_available_child_of_node(np, child) {
		ret = ulogo_probe_group(pdev, child, led_list);
		if (ret) {
			dev_err(&pdev->dev, "%pOF: probe failed (%d)\n",
				child, ret);
			of_node_put(child);
			goto unwind;
		}
		registered++;
	}

	if (registered == 0) {
		dev_err(&pdev->dev, "no valid groups found\n");
		ret = -ENODEV;
		goto unwind;
	}

	return 0;

unwind:
	{
		struct ulogo_led *ule, *tmp;

		list_for_each_entry_safe(ule, tmp, led_list, list) {
			del_timer_sync(&ule->timer);
			led_classdev_unregister(&ule->cdev);
			list_del(&ule->list);
		}
	}
	return ret;
}

static int leds_ulogo_remove(struct platform_device *pdev)
{
	struct list_head *led_list = platform_get_drvdata(pdev);
	struct ulogo_led *ule, *tmp;

	list_for_each_entry_safe(ule, tmp, led_list, list) {
		del_timer_sync(&ule->timer);
		led_classdev_unregister(&ule->cdev);
		list_del(&ule->list);
	}

	return 0;
}

static const struct of_device_id ulogo_of_match[] = {
	{ .compatible = "leds-ulogo", },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, ulogo_of_match);

static struct platform_driver leds_ulogo_driver = {
	.probe = leds_ulogo_probe,
	.remove = leds_ulogo_remove,
	.driver = {
		.name = "leds-ulogo",
		.of_match_table = ulogo_of_match,
	},
};

module_platform_driver(leds_ulogo_driver);

MODULE_DESCRIPTION("Clean-room reimplementation of the leds-ulogo platform driver (CloudKey G2 Plus U-logo LED control). Requires CONFIG_LEDS_TRIGGER_EXTERNAL.");
MODULE_LICENSE("GPL v2");
