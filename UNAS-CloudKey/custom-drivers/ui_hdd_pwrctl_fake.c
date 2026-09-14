// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 the CloudKey UNAS project authors

/*
 * ui_hdd_pwrctl_fake.c -- dummy stand-in for Ubiquiti's ui-hdd-pwrctl
 *
 * Written for the UCK-G2-Plus custom-btrfs-kernel project.
 *
 * The real ui-hdd-pwrctl.ko (present only under
 * /lib/modules/5.10.216-alpine-unas/extra/ -- built for the modern
 * Annapurna Alpine kernel real UNAS Pro/UNAS4 hardware ships with, not
 * this device's 3.18 Qualcomm APQ8053 tree, and not buildable against
 * it) exposes bay occupancy to userspace as
 * /sys/devices/platform/ui-hdd-pwrctl/slot-<N>/{present,fault,force_power}.
 * uhwd reads that tree directly (confirmed via strace) to decide which
 * bays are occupied; on this device the path doesn't exist at all, so
 * uhwd always treats every slot as empty regardless of what disks are
 * actually attached.
 *
 * This is a from-scratch stub, not a port of the real driver -- it
 * creates the same sysfs shape by hand, backed by plain in-kernel state
 * instead of real backplane I2C/GPIO (which this board doesn't have
 * wired the way real UNAS hardware does). All three attributes are
 * read/write here (real hardware only makes "present" and "fault"
 * read-only) specifically so slot state can be poked live from
 * userspace without a reboot, e.g.:
 *   echo 0 > /sys/devices/platform/ui-hdd-pwrctl/slot-2/present
 *
 * num_slots and the initial present_mask are both module_param'd (read
 * via /sys/module/ui_hdd_pwrctl_fake/parameters/ even though this is
 * built into the kernel image rather than insmod'd -- see ubnthal.c's
 * header comment for why this project bakes stubs like this in as =y).
 * Defaults: 4 slots, all present -- matches the UNAS-Pro-4/UNAS-4
 * identity this project currently spoofs via /opt/ubnthal + ubnt-tools.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/slab.h>
#include <linux/err.h>

#define DRV_NAME "ui-hdd-pwrctl"
#define MAX_SLOTS 8

static int num_slots = 4;
module_param(num_slots, int, 0444);
MODULE_PARM_DESC(num_slots, "Number of HDD bay slots to expose (default 4)");

static unsigned int present_mask = 0xFF; /* bit N-1 set => slot-N present */
module_param(present_mask, uint, 0444);
MODULE_PARM_DESC(present_mask, "Bitmask of which slots start out present (bit0=slot-1)");

struct fake_slot {
	struct kobject kobj;
	int index; /* 1-based */
	int present;
	int fault;
	int force_power;
};

static struct platform_device *pdev;
static struct fake_slot *slots[MAX_SLOTS];
static int slots_created; /* how many of slots[] are valid, for unwind */

static ssize_t present_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	struct fake_slot *s = container_of(kobj, struct fake_slot, kobj);
	return sprintf(buf, "%d\n", s->present);
}

static ssize_t present_store(struct kobject *kobj, struct kobj_attribute *attr,
			      const char *buf, size_t count)
{
	struct fake_slot *s = container_of(kobj, struct fake_slot, kobj);
	int val;

	if (kstrtoint(buf, 0, &val))
		return -EINVAL;
	s->present = !!val;
	return count;
}

static ssize_t fault_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	struct fake_slot *s = container_of(kobj, struct fake_slot, kobj);
	return sprintf(buf, "%d\n", s->fault);
}

static ssize_t fault_store(struct kobject *kobj, struct kobj_attribute *attr,
			    const char *buf, size_t count)
{
	struct fake_slot *s = container_of(kobj, struct fake_slot, kobj);
	int val;

	if (kstrtoint(buf, 0, &val))
		return -EINVAL;
	s->fault = !!val;
	return count;
}

static ssize_t force_power_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	struct fake_slot *s = container_of(kobj, struct fake_slot, kobj);
	return sprintf(buf, "%d\n", s->force_power);
}

static ssize_t force_power_store(struct kobject *kobj, struct kobj_attribute *attr,
				  const char *buf, size_t count)
{
	struct fake_slot *s = container_of(kobj, struct fake_slot, kobj);
	int val;

	if (kstrtoint(buf, 0, &val))
		return -EINVAL;
	s->force_power = !!val;
	return count;
}

static struct kobj_attribute present_attr = __ATTR(present, 0644, present_show, present_store);
static struct kobj_attribute fault_attr = __ATTR(fault, 0644, fault_show, fault_store);
static struct kobj_attribute force_power_attr =
	__ATTR(force_power, 0644, force_power_show, force_power_store);

/*
 * kernel 3.18 struct kobj_type uses "default_attrs" (a plain
 * attribute** array). "default_groups" doesn't exist on this tree --
 * that's a much later kobject-core addition. Do not "modernize" this.
 */
static struct attribute *slot_attrs[] = {
	&present_attr.attr,
	&fault_attr.attr,
	&force_power_attr.attr,
	NULL,
};

static void slot_release(struct kobject *kobj)
{
	struct fake_slot *s = container_of(kobj, struct fake_slot, kobj);
	kfree(s);
}

static struct kobj_type slot_ktype = {
	.sysfs_ops = &kobj_sysfs_ops,
	.release = slot_release,
	.default_attrs = slot_attrs,
};

static int __init ui_hdd_pwrctl_fake_init(void)
{
	int i, ret;

	if (num_slots < 1 || num_slots > MAX_SLOTS) {
		pr_err(DRV_NAME ": num_slots=%d out of range (1-%d)\n", num_slots, MAX_SLOTS);
		return -EINVAL;
	}

	pdev = platform_device_register_simple(DRV_NAME, -1, NULL, 0);
	if (IS_ERR(pdev)) {
		pr_err(DRV_NAME ": failed to register platform device\n");
		return PTR_ERR(pdev);
	}

	for (i = 0; i < num_slots; i++) {
		struct fake_slot *s = kzalloc(sizeof(*s), GFP_KERNEL);
		char name[16];

		if (!s) {
			ret = -ENOMEM;
			goto fail;
		}

		s->index = i + 1;
		s->present = (present_mask >> i) & 1;
		s->fault = 0;
		s->force_power = 1;

		snprintf(name, sizeof(name), "slot-%d", s->index);

		ret = kobject_init_and_add(&s->kobj, &slot_ktype, &pdev->dev.kobj, "%s", name);
		if (ret) {
			kobject_put(&s->kobj);
			goto fail;
		}

		slots[i] = s;
		slots_created = i + 1;
		pr_info(DRV_NAME ": %s present=%d\n", name, s->present);
	}

	pr_info(DRV_NAME ": registered with %d slot(s)\n", num_slots);
	return 0;

fail:
	while (--i >= 0) {
		kobject_put(&slots[i]->kobj);
		slots[i] = NULL;
	}
	slots_created = 0;
	platform_device_unregister(pdev);
	return ret;
}

static void __exit ui_hdd_pwrctl_fake_exit(void)
{
	int i;

	for (i = 0; i < slots_created; i++)
		if (slots[i])
			kobject_put(&slots[i]->kobj);

	platform_device_unregister(pdev);
	pr_info(DRV_NAME ": unloaded\n");
}

module_init(ui_hdd_pwrctl_fake_init);
module_exit(ui_hdd_pwrctl_fake_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Dummy ui-hdd-pwrctl sysfs shim for non-UNAS hardware");
MODULE_AUTHOR("hutchx86");
