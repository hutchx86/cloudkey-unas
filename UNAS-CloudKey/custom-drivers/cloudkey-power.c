// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 the CloudKey UNAS project authors

/*
 * cloudkey-power.c - Clean-room reimplementation of Ubiquiti's proprietary
 * CloudKey power-source detection driver.
 *
 * In Ubiquiti's internal tree this lives at
 * drivers/misc/ubnt/cloudkey-power.c -- confirmed by that exact path
 * being referenced (as a dangling symlink) in the public GPL tarball's
 * own build plumbing: drivers/misc/ubnt/Kconfig sources it and
 * drivers/misc/Makefile has a conditional obj-y line for the ubnt/
 * directory, but the .c file itself, its sibling cloudkey-rackmount.c,
 * and their shared Kconfig/Makefile are all broken symlinks pointing at
 * Ubiquiti's internal build host, with no real source anywhere in the
 * release.
 *
 * Reconstructed from ARM64 disassembly of the actual stock kernel image
 * (same methodology as leds-ulogo.c / ledtrig-external.c -- kallsyms
 * table recovered via vmlinux-to-elf from a genuine device boot image,
 * not from any Ubiquiti source). Every kernel API this file calls
 * (__devm_gpiod_get, __devm_gpiod_get_optional,
 * devm_regulator_get_optional, devm_request_any_context_irq,
 * power_supply_register/_unregister/_changed) was directly confirmed
 * present by seeing the original compiled binary call it -- higher
 * confidence than a from-scratch guess against general kernel API
 * knowledge, though still worth a signature sanity-check against this
 * tree's actual headers before building (see notes below).
 *
 * Registers a power_supply of type POWER_SUPPLY_TYPE_MAINS matching the
 * "mains" DT node (compatible = "ubnt,ck-powersource"), reporting only
 * POWER_SUPPLY_PROP_ONLINE, derived from three GPIOs:
 *
 *   poe-gpios       (required)  -- PoE power present
 *   usb-plug-gpios  (required)  -- USB-C cable inserted
 *   qc-gpios        (optional)  -- Quick Charge negotiated
 *
 * Online logic (matches disassembled powersource_is_online() exactly):
 *   1. If poe-gpios reads asserted             -> online.
 *   2. Else if usb-plug-gpios reads deasserted  -> offline (no cable
 *      and no PoE: definitely no external power).
 *   3. Else if qc-gpios isn't wired up (optional, absent/error)
 *      -> online (a cable is present; no QC negotiation required).
 *   4. Else -> follow qc-gpios' actual asserted/deasserted state.
 *
 * Two further optional regulators, "usbc-ext" and "usbc-ext-current",
 * are read only for informational voltage/current-limit reporting (the
 * original exposed these via debugfs; this reimplementation logs the
 * same information via dev_info instead, since debugfs's diagnostic
 * value here is marginal against the added code surface -- can be
 * added later if that granularity turns out to matter in practice).
 *
 * The "mains" DT node also carries a "charger-supply" phandle that this
 * reimplementation deliberately does NOT claim: no matching
 * devm_regulator_get*() call for it was found anywhere in the
 * disassembled probe function, so its real consumer is unidentified.
 * Claiming an unclaimed regulator we don't understand risks starving
 * whatever the actual intended consumer is (if any). Revisit only if a
 * concrete need for it surfaces.
 *
 * NOTE ON API ERA: this kernel (3.18) predates the power_supply_desc/
 * power_supply_config split introduced in Linux 4.1. The disassembled
 * get_property() recovers its private struct via a fixed-offset
 * subtraction from the power_supply pointer it's handed -- i.e. the
 * original embeds `struct power_supply` directly inside its own
 * struct and calls the plain (non-devm) power_supply_register() on it,
 * exactly as this reimplementation does. There is no
 * power_supply_get_drvdata() in this API era; container_of() is used
 * instead, matching what the disassembly actually showed.
 *
 * License: GPL v2, matching the kernel tree this is built against.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/gpio/consumer.h>
#include <linux/interrupt.h>
#include <linux/workqueue.h>
#include <linux/power_supply.h>
#include <linux/regulator/consumer.h>
#include <linux/err.h>
#include <linux/device.h>

struct ck_powersource {
	struct power_supply psy;
	struct device *dev;

	struct gpio_desc *poe_gpio;
	struct gpio_desc *usb_plug_gpio;
	struct gpio_desc *qc_gpio;		/* optional, may be NULL */

	struct regulator *usbc_ext_reg;	/* optional, informational only */
	struct regulator *usbc_ext_current_reg;/* optional, informational only */

	int poe_irq;
	int usb_plug_irq;
	int qc_irq;				/* 0 if qc_gpio absent */

	struct delayed_work work;
};

static int ck_powersource_is_online(struct ck_powersource *cps)
{
	if (gpiod_get_value(cps->poe_gpio))
		return 1;

	if (!gpiod_get_value(cps->usb_plug_gpio))
		return 0;

	if (!cps->qc_gpio)
		return 1;

	return gpiod_get_value(cps->qc_gpio) ? 1 : 0;
}

static enum power_supply_property ck_powersource_props[] = {
	POWER_SUPPLY_PROP_ONLINE,
};

static int ck_powersource_get_property(struct power_supply *psy,
					enum power_supply_property psp,
					union power_supply_propval *val)
{
	struct ck_powersource *cps = container_of(psy, struct ck_powersource,
						   psy);

	switch (psp) {
	case POWER_SUPPLY_PROP_ONLINE:
		val->intval = ck_powersource_is_online(cps);
		return 0;
	default:
		return -EINVAL;
	}
}

static void ck_powersource_log_regulators(struct ck_powersource *cps)
{
	int mv, ma;

	if (cps->usbc_ext_reg && !IS_ERR(cps->usbc_ext_reg)) {
		mv = regulator_get_voltage(cps->usbc_ext_reg);
		if (mv >= 0)
			dev_info(cps->dev, "usbc-ext: %d.%03dV\n",
				 mv / 1000000, (mv / 1000) % 1000);
	}

	if (cps->usbc_ext_current_reg && !IS_ERR(cps->usbc_ext_current_reg)) {
		ma = regulator_get_current_limit(cps->usbc_ext_current_reg);
		if (ma >= 0)
			dev_info(cps->dev, "usbc-ext max current: %d.%03dA\n",
				 ma / 1000000, (ma / 1000) % 1000);
	}
}

/* Debounce work: GPIO-based cable/PoE detect lines can bounce briefly
 * on insertion/removal. The original's IRQ handler notified immediately
 * (power_supply_changed()) and separately queued further work on the
 * same work item used elsewhere (symbol powersource_usbc_work, not
 * disassembled -- likely a QC-negotiation settle/recheck). This
 * reimplementation simplifies to a single short debounce before
 * notifying, which is sufficient for correct online/offline reporting
 * even if it doesn't replicate whatever extra QC-specific bookkeeping
 * the original's secondary work item did.
 */
static void ck_powersource_work_fn(struct work_struct *w)
{
	struct ck_powersource *cps = container_of(w, struct ck_powersource,
						   work.work);

	power_supply_changed(&cps->psy);
	ck_powersource_log_regulators(cps);
}

static irqreturn_t ck_powersource_irq(int irq, void *data)
{
	struct ck_powersource *cps = data;

	schedule_delayed_work(&cps->work, msecs_to_jiffies(50));
	return IRQ_HANDLED;
}

static int ck_powersource_request_irq(struct ck_powersource *cps,
				       struct gpio_desc *gpio,
				       const char *name)
{
	int irq;

	if (!gpio)
		return 0;

	irq = gpiod_to_irq(gpio);
	if (irq < 0) {
		dev_warn(cps->dev, "%s: no irq available (%d)\n", name, irq);
		return 0; /* non-fatal -- online state is still readable by
			   * polling gpiod_get_value(); we just won't get
			   * async notification on change for this line.
			   */
	}

	/* Each of poe/usb-plug/qc is its own distinct physical GPIO with
	 * its own dedicated IRQ line -- there's no other device on this
	 * board known to share any of these three lines, and nothing in
	 * this reconstruction was ever confirmed against disassembly to
	 * need IRQF_SHARED (it was an earlier unexamined addition, not a
	 * deliberate choice). Genuinely sharing a line would also require
	 * this handler to distinguish "was this interrupt actually mine"
	 * before returning IRQ_HANDLED unconditionally, which it doesn't
	 * do -- on a real shared line that could silently swallow another
	 * device's interrupt. Omitted rather than left in unjustified.
	 */
	return devm_request_any_context_irq(cps->dev, irq, ck_powersource_irq,
					     IRQF_TRIGGER_RISING |
					     IRQF_TRIGGER_FALLING,
					     name, cps);
}

static int ck_powersource_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct ck_powersource *cps;
	int ret;

	cps = devm_kzalloc(dev, sizeof(*cps), GFP_KERNEL);
	if (!cps)
		return -ENOMEM;
	cps->dev = dev;

	cps->poe_gpio = devm_gpiod_get(dev, "poe", GPIOD_ASIS);
	if (IS_ERR(cps->poe_gpio)) {
		dev_err(dev, "Could not acquire poe-gpio: %ld\n",
			PTR_ERR(cps->poe_gpio));
		return PTR_ERR(cps->poe_gpio);
	}

	cps->usb_plug_gpio = devm_gpiod_get(dev, "usb-plug", GPIOD_ASIS);
	if (IS_ERR(cps->usb_plug_gpio)) {
		dev_err(dev, "Could not acquire usb-plug-gpio: %ld\n",
			PTR_ERR(cps->usb_plug_gpio));
		return PTR_ERR(cps->usb_plug_gpio);
	}

	cps->qc_gpio = devm_gpiod_get_optional(dev, "qc", GPIOD_ASIS);
	if (IS_ERR(cps->qc_gpio)) {
		dev_err(dev, "Could not acquire qc-gpio: %ld\n",
			PTR_ERR(cps->qc_gpio));
		return PTR_ERR(cps->qc_gpio);
	}

	/* Both purely informational -- absence/failure is not fatal. */
	cps->usbc_ext_reg = devm_regulator_get_optional(dev, "usbc-ext");
	cps->usbc_ext_current_reg =
		devm_regulator_get_optional(dev, "usbc-ext-current");

	INIT_DELAYED_WORK(&cps->work, ck_powersource_work_fn);

	cps->psy.name = "mains";
	cps->psy.type = POWER_SUPPLY_TYPE_MAINS;
	cps->psy.properties = ck_powersource_props;
	cps->psy.num_properties = ARRAY_SIZE(ck_powersource_props);
	cps->psy.get_property = ck_powersource_get_property;

	ret = power_supply_register(dev, &cps->psy);
	if (ret) {
		dev_err(dev, "Failed registering power supply\n");
		return ret;
	}

	ret = ck_powersource_request_irq(cps, cps->poe_gpio, "poe");
	if (ret)
		goto err_unregister;

	ret = ck_powersource_request_irq(cps, cps->usb_plug_gpio, "usb-plug");
	if (ret)
		goto err_unregister;

	ret = ck_powersource_request_irq(cps, cps->qc_gpio, "qc");
	if (ret)
		goto err_unregister;

	platform_set_drvdata(pdev, cps);

	dev_info(dev, "registered 'mains' power supply (online=%d)\n",
		 ck_powersource_is_online(cps));
	ck_powersource_log_regulators(cps);

	return 0;

err_unregister:
	power_supply_unregister(&cps->psy);
	return ret;
}

static int ck_powersource_remove(struct platform_device *pdev)
{
	struct ck_powersource *cps = platform_get_drvdata(pdev);

	cancel_delayed_work_sync(&cps->work);
	power_supply_unregister(&cps->psy);

	return 0;
}

static const struct of_device_id ck_powersource_of_match[] = {
	{ .compatible = "ubnt,ck-powersource", },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, ck_powersource_of_match);

static struct platform_driver ck_powersource_driver = {
	.probe = ck_powersource_probe,
	.remove = ck_powersource_remove,
	.driver = {
		.name = "cloudkey-power",
		.of_match_table = ck_powersource_of_match,
	},
};

module_platform_driver(ck_powersource_driver);

MODULE_DESCRIPTION("Clean-room reimplementation of the CloudKey power-source (mains/PoE/USB-C) detection driver. compatible=\"ubnt,ck-powersource\"");
MODULE_LICENSE("GPL v2");
