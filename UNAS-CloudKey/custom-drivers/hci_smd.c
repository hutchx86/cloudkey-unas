/*
 * Modified 2026-09 for the CloudKey UNAS project (ported to linux-qcom-
 * apq8053-3.18.44-ui-qcom: include path + HCI/SMD API changes, listed below).
 *
 * NOTE (port for the UBNT CloudKey G2 Plus / APQ8053, linux-qcom-apq8053-
 * 3.18.44-ui-qcom): Ubiquiti's GPL tarball ships a broken symlink for this
 * file pointing at Ubiquiti's internal vendoring of a generic Qualcomm/
 * CodeAurora msm-3.18.x kernel tree
 * (/home/inaro/src/github.com/ubiquiti/debbox/target/kernel/files/
 * linux-msm-3.18.x/./drivers/bluetooth/hci_smd.c), with no real source in
 * the release itself. This file is NOT Ubiquiti-proprietary code -- it is
 * genuine Qualcomm/CodeAurora Forum GPLv2 source (see copyright header
 * below), sourced from a public MSM8953-era Android kernel tree (same SoC
 * family and same 3.18 kernel version as this device). Function-name
 * fingerprinting against the actual stock kernel's own compiled binary
 * (including the distinctively-misspelled "hcismd_set_enable", lacking
 * the underscore every other hci_smd_* function in this file has)
 * confirms this is the same source Ubiquiti's own build used.
 *
 * Only one change was required to build against this tree: the include
 * path below. mach/msm_smd.h (the older, pre-devicetree SMD header path)
 * does not exist in this tree -- it was relocated to soc/qcom/smd.h.
 * Every SMD API this file calls (smd_named_open_on_edge, smd_read,
 * smd_read_avail, smd_write, smd_write_avail, smd_close,
 * smd_disable_read_intr) was verified present with matching signatures
 * in this tree's actual soc/qcom/smd.h, and this file already uses the
 * modern smd_named_open_on_edge() API (rather than an older bare
 * smd_open()), so no call-site changes were needed beyond the include.
 *
 * The following Bluetooth HCI core API differences WERE confirmed against
 * this tree's actual headers and are fixed in this file (not left as
 * open questions):
 *   - hci_recv_frame() takes (hdev, skb) in this tree, not just (skb).
 *     Both call sites below pass hdev now.
 *   - hdev->destruct does not exist in this tree's struct hci_dev.
 *     hci_smd_destruct() was a no-op in practice anyway -- it only ever
 *     freed hdev->driver_data, which this driver sets to NULL
 *     immediately after allocation and never assigns anything to
 *     afterward -- so both the dead function and its wiring were
 *     removed rather than inventing a replacement mechanism for
 *     something that never did anything.
 *   - hcismd_set_enable()'s kernel_param argument needed to become
 *     `const struct kernel_param *kp` to match this tree's
 *     moduleparam.h (int (*set)(const char *val, const struct
 *     kernel_param *kp)).
 *   - HCI_SMD is already defined in this tree's own
 *     include/net/bluetooth/hci.h (#define HCI_SMD 7, right alongside
 *     HCI_VIRTUAL/HCI_USB/etc.) -- an earlier check of this got a false
 *     negative from a truncated `grep | head -20` that cut off just
 *     before reaching it. No local definition or header patch needed
 *     at all; hdev->bus = HCI_SMD below resolves correctly as-is.
 *   - hdev->driver_data and hdev->owner also do not exist in this
 *     tree's struct hci_dev (found via an actual failed build, not
 *     preemptive checking -- these two were missed in the initial
 *     header review). Confirmed against two real, already-compiling
 *     drivers (hci_ldisc.c, btusb.c): neither sets an owner field at
 *     all, and hci_alloc_dev()'s own implementation in
 *     net/bluetooth/hci_core.c doesn't touch module ownership
 *     internally either -- it's simply not the caller's job to set
 *     this anymore. driver_data's modern replacement is
 *     hci_set_drvdata(), but since nothing in this file ever reads
 *     driver_data back, both lines were deleted outright rather than
 *     introducing a new, unverified API call for a value nothing
 *     consumes.
 *   - hci_unregister_dev() returns void in this tree (confirmed
 *     against include/net/bluetooth/hci_core.h), not int -- another
 *     build-time discovery, same class of mismatch as
 *     led_trigger_register_simple() in the leds-ulogo driver
 *     elsewhere in this build. The original's error-logging wrapper
 *     around its return value was dropped since there's nothing left
 *     to check.
 *   - hdev->send's real signature is int (*)(struct hci_dev *hdev,
 *     struct sk_buff *skb), not the older int (*)(struct sk_buff *skb)
 *     this file originally used. This one is worth calling out
 *     specifically: it did NOT cause a build failure. Assigning a
 *     function of the wrong pointer type to a struct field only
 *     triggers -Wincompatible-pointer-types (a warning) in C, not a
 *     hard error, so the kernel built "successfully" while this was
 *     silently broken -- at runtime the kernel passed hdev in the
 *     first argument slot and skb in the second, so the single-
 *     parameter version was reading a struct hci_dev * as if it were
 *     a struct sk_buff *, corrupting bt_cb(skb)->pkt_type into
 *     garbage. This produced a real, reproducible symptom during
 *     testing: "Uknown packet type" / "hci0 sending frame failed
 *     (-19)" in dmesg, and hciconfig hci0 up timing out because the
 *     HCI Reset command byte sequence was never actually sent
 *     correctly. Fixed by adding the hdev parameter to match; the
 *     function body needed no other changes since it already sourced
 *     channel state from the global `hs` struct rather than hdev.
 *     Worth remembering for any future porting work in this codebase:
 *     a clean build is not proof a callback's signature is correct --
 *     check function-pointer assignments specifically, since their
 *     mismatches compile silently.
 *
 * License note: this file is GPLv2 (see header below), which explicitly
 * permits redistribution and modification, including republishing this
 * adapted version -- the only real obligation is keeping the original
 * copyright/license notice intact and licensing any derivative under
 * GPLv2 too (which is non-optional under GPLv2's copyleft terms anyway).
 */

/*
 *  HCI_SMD (HCI Shared Memory Driver) is Qualcomm's Shared memory driver
 *  for the BT HCI protocol.
 *
 *  Copyright (c) 2000-2001, 2011-2012 Code Aurora Forum. All rights reserved.
 *  Copyright (C) 2002-2003  Maxim Krasnyansky <maxk@qualcomm.com>
 *  Copyright (C) 2004-2006  Marcel Holtmann <marcel@holtmann.org>
 *
 *  This file is based on drivers/bluetooth/hci_vhci.c
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License version 2
 *  as published by the Free Software Foundation
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/errno.h>
#include <linux/semaphore.h>
#include <linux/string.h>
#include <linux/skbuff.h>
#include <linux/wakelock.h>
#include <linux/workqueue.h>
#include <linux/uaccess.h>
#include <linux/netdevice.h>
#include <net/net_namespace.h>
#include <net/bluetooth/bluetooth.h>
#include <net/bluetooth/hci_core.h>
#include <net/bluetooth/hci.h>
#include <soc/qcom/smd.h>	/* was <mach/msm_smd.h> -- see port note above */

/* HCI_SMD is already defined in this tree's own hci.h (=7) -- confirmed
 * directly, no local definition needed. See port note above. */

#define EVENT_CHANNEL		"APPS_RIVA_BT_CMD"
#define DATA_CHANNEL		"APPS_RIVA_BT_ACL"
/* release wakelock in 500ms, not immediately, because higher layers
 * don't always take wakelocks when they should
 * This is derived from the implementation for UART transport
 */

#define RX_Q_MONITOR		(500)	/* 500 milli second */


static int hcismd_set;
static DEFINE_SEMAPHORE(hci_smd_enable);

static int restart_in_progress;

static int hcismd_set_enable(const char *val, const struct kernel_param *kp);
module_param_call(hcismd_set, hcismd_set_enable, NULL, &hcismd_set, 0644);

static void hci_dev_smd_open(struct work_struct *worker);
static void hci_dev_restart(struct work_struct *worker);

struct hci_smd_data {
	struct hci_dev *hdev;

	struct smd_channel *event_channel;
	struct smd_channel *data_channel;
	struct wake_lock wake_lock_tx;
	struct wake_lock wake_lock_rx;
	struct timer_list rx_q_timer;
	struct tasklet_struct rx_task;
};
static struct hci_smd_data hs;

/* Rx queue monitor timer function */
static int is_rx_q_empty(unsigned long arg)
{
	struct hci_dev *hdev = (struct hci_dev *) arg;
	struct sk_buff_head *list_ = &hdev->rx_q;
	struct sk_buff *list = ((struct sk_buff *)list_)->next;
	BT_DBG("%s Rx timer triggered", hdev->name);

	if (list == (struct sk_buff *)list_) {
		BT_DBG("%s RX queue empty", hdev->name);
		return 1;
	} else{
		BT_DBG("%s RX queue not empty", hdev->name);
		return 0;
	}
}

static void release_lock(void)
{
	struct hci_smd_data *hsmd = &hs;
	BT_DBG("Releasing Rx Lock");
	if (is_rx_q_empty((unsigned long)hsmd->hdev) &&
		wake_lock_active(&hs.wake_lock_rx))
			wake_unlock(&hs.wake_lock_rx);
}

/* Rx timer callback function */
static void schedule_timer(unsigned long arg)
{
	struct hci_dev *hdev = (struct hci_dev *) arg;
	struct hci_smd_data *hsmd = &hs;
	BT_DBG("%s Schedule Rx timer", hdev->name);

	if (is_rx_q_empty(arg) && wake_lock_active(&hs.wake_lock_rx)) {
		BT_DBG("%s RX queue empty", hdev->name);
		/*
		 * Since the queue is empty, its ideal
		 * to release the wake lock on Rx
		 */
		wake_unlock(&hs.wake_lock_rx);
	} else{
		BT_DBG("%s RX queue not empty", hdev->name);
		/*
		 * Restart the timer to monitor whether the Rx queue is
		 * empty for releasing the Rx wake lock
		 */
		mod_timer(&hsmd->rx_q_timer,
			jiffies + msecs_to_jiffies(RX_Q_MONITOR));
	}
}

static int hci_smd_open(struct hci_dev *hdev)
{
	set_bit(HCI_RUNNING, &hdev->flags);
	return 0;
}


static int hci_smd_close(struct hci_dev *hdev)
{
	if (!test_and_clear_bit(HCI_RUNNING, &hdev->flags))
		return 0;
	else
		return -EPERM;
}


static void hci_smd_recv_data(void)
{
	int len = 0;
	int rc = 0;
	struct sk_buff *skb = NULL;
	struct hci_smd_data *hsmd = &hs;
	wake_lock(&hs.wake_lock_rx);

	len = smd_read_avail(hsmd->data_channel);
	if (len > HCI_MAX_FRAME_SIZE) {
		BT_ERR("Frame larger than the allowed size, flushing frame");
		smd_read(hsmd->data_channel, NULL, len);
		goto out_data;
	}

	if (len <= 0)
		goto out_data;

	skb = bt_skb_alloc(len, GFP_ATOMIC);
	if (!skb) {
		BT_ERR("Error in allocating socket buffer");
		smd_read(hsmd->data_channel, NULL, len);
		goto out_data;
	}

	rc = smd_read(hsmd->data_channel, skb_put(skb, len), len);
	if (rc < len) {
		BT_ERR("Error in reading from the channel");
		goto out_data;
	}

	skb->dev = (void *)hsmd->hdev;
	bt_cb(skb)->pkt_type = HCI_ACLDATA_PKT;
	skb_orphan(skb);

	rc = hci_recv_frame(hsmd->hdev, skb);	/* was hci_recv_frame(skb) --
						 * this tree's hci_recv_frame()
						 * takes an explicit hdev */
	if (rc < 0) {
		BT_ERR("Error in passing the packet to HCI Layer");
		/*
		 * skb is getting freed in hci_recv_frame, making it
		 * to null to avoid multiple access
		 */
		skb = NULL;
		goto out_data;
	}

	/*
	 * Start the timer to monitor whether the Rx queue is
	 * empty for releasing the Rx wake lock
	 */
	BT_DBG("Rx Timer is starting");
	mod_timer(&hsmd->rx_q_timer,
			jiffies + msecs_to_jiffies(RX_Q_MONITOR));

out_data:
	release_lock();
	if (rc)
		kfree_skb(skb);
}

static void hci_smd_recv_event(void)
{
	int len = 0;
	int rc = 0;
	struct sk_buff *skb = NULL;
	struct hci_smd_data *hsmd = &hs;
	wake_lock(&hs.wake_lock_rx);

	len = smd_read_avail(hsmd->event_channel);
	if (len > HCI_MAX_FRAME_SIZE) {
		BT_ERR("Frame larger than the allowed size, flushing frame");
		rc = smd_read(hsmd->event_channel, NULL, len);
		goto out_event;
	}

	while (len > 0) {
		skb = bt_skb_alloc(len, GFP_ATOMIC);
		if (!skb) {
			BT_ERR("Error in allocating socket buffer");
			smd_read(hsmd->event_channel, NULL, len);
			goto out_event;
		}

		rc = smd_read(hsmd->event_channel, skb_put(skb, len), len);
		if (rc < len) {
			BT_ERR("Error in reading from the event channel");
			goto out_event;
		}

		skb->dev = (void *)hsmd->hdev;
		bt_cb(skb)->pkt_type = HCI_EVENT_PKT;

		skb_orphan(skb);

		rc = hci_recv_frame(hsmd->hdev, skb);	/* was hci_recv_frame(skb) */
		if (rc < 0) {
			BT_ERR("Error in passing the packet to HCI Layer");
			/*
			 * skb is getting freed in hci_recv_frame, making it
			 *  to null to avoid multiple access
			 */
			skb = NULL;
			goto out_event;
		}

		len = smd_read_avail(hsmd->event_channel);
		/*
		 * Start the timer to monitor whether the Rx queue is
		 * empty for releasing the Rx wake lock
		 */
		BT_DBG("Rx Timer is starting");
		mod_timer(&hsmd->rx_q_timer,
				jiffies + msecs_to_jiffies(RX_Q_MONITOR));
	}
out_event:
	release_lock();
	if (rc)
		kfree_skb(skb);
}

/* hdev->send's real signature in this tree is
 * int (*send)(struct hci_dev *hdev, struct sk_buff *skb) -- confirmed
 * against include/net/bluetooth/hci_core.h. The original (and this
 * file's first port pass) used the older one-argument
 * int (*send)(struct sk_buff *skb) form. That mismatch did NOT produce
 * a hard build error -- assigning a function of the wrong pointer type
 * to hdev->send below only triggers -Wincompatible-pointer-types, a
 * warning, not -Werror here -- so this built "successfully" while
 * being silently wrong: at runtime, the kernel passed hdev in the
 * first argument slot and skb in the second, meaning the single-
 * parameter version below was reading a struct hci_dev * memory layout
 * as if it were a struct sk_buff *. This is what produced the
 * "Uknown packet type" / "hci0 sending frame failed (-19)" dmesg loop
 * during testing -- bt_cb(skb)->pkt_type was reading garbage.
 */
static int hci_smd_send_frame(struct hci_dev *hdev, struct sk_buff *skb)
{
	int len;
	int avail;
	int ret = 0;
	wake_lock(&hs.wake_lock_tx);

	switch (bt_cb(skb)->pkt_type) {
	case HCI_COMMAND_PKT:
		avail = smd_write_avail(hs.event_channel);
		if (!avail) {
			BT_ERR("No space available for smd frame");
			ret =  -ENOSPC;
		}
		len = smd_write(hs.event_channel, skb->data, skb->len);
		if (len < skb->len) {
			BT_ERR("Failed to write Command %d", len);
			ret = -ENODEV;
		}
		break;
	case HCI_ACLDATA_PKT:
	case HCI_SCODATA_PKT:
		avail = smd_write_avail(hs.data_channel);
		if (!avail) {
			BT_ERR("No space available for smd frame");
			ret = -ENOSPC;
		}
		len = smd_write(hs.data_channel, skb->data, skb->len);
		if (len < skb->len) {
			BT_ERR("Failed to write Data %d", len);
			ret = -ENODEV;
		}
		break;
	default:
		BT_ERR("Uknown packet type");
		ret = -ENODEV;
		break;
	}

	kfree_skb(skb);
	wake_unlock(&hs.wake_lock_tx);
	return ret;
}

static void hci_smd_rx(unsigned long arg)
{
	struct hci_smd_data *hsmd = &hs;

	while ((smd_read_avail(hsmd->event_channel) > 0) ||
				(smd_read_avail(hsmd->data_channel) > 0)) {
		hci_smd_recv_event();
		hci_smd_recv_data();
	}
}

static void hci_smd_notify_event(void *data, unsigned int event)
{
	struct hci_dev *hdev = hs.hdev;
	struct hci_smd_data *hsmd = &hs;
	struct work_struct *reset_worker;
	struct work_struct *open_worker;

	int len = 0;

	if (!hdev) {
		BT_ERR("Frame for unknown HCI device (hdev=NULL)");
		return;
	}

	switch (event) {
	case SMD_EVENT_DATA:
		len = smd_read_avail(hsmd->event_channel);
		if (len > 0)
			tasklet_hi_schedule(&hs.rx_task);
		else if (len < 0)
			BT_ERR("Failed to read event from smd %d", len);

		break;
	case SMD_EVENT_OPEN:
		BT_INFO("opening HCI-SMD channel :%s", EVENT_CHANNEL);
		hci_smd_open(hdev);
		open_worker = kzalloc(sizeof(*open_worker), GFP_ATOMIC);
		if (!open_worker) {
			BT_ERR("Out of memory");
			break;
		}
		INIT_WORK(open_worker, hci_dev_smd_open);
		schedule_work(open_worker);
		break;
	case SMD_EVENT_CLOSE:
		BT_INFO("Closing HCI-SMD channel :%s", EVENT_CHANNEL);
		hci_smd_close(hdev);
		reset_worker = kzalloc(sizeof(*reset_worker), GFP_ATOMIC);
		if (!reset_worker) {
			BT_ERR("Out of memory");
			break;
		}
		INIT_WORK(reset_worker, hci_dev_restart);
		schedule_work(reset_worker);
		break;
	default:
		break;
	}
}

static void hci_smd_notify_data(void *data, unsigned int event)
{
	struct hci_dev *hdev = hs.hdev;
	struct hci_smd_data *hsmd = &hs;
	int len = 0;

	if (!hdev) {
		BT_ERR("Frame for unknown HCI device (hdev=NULL)");
		return;
	}

	switch (event) {
	case SMD_EVENT_DATA:
		len = smd_read_avail(hsmd->data_channel);
		if (len > 0)
			tasklet_hi_schedule(&hs.rx_task);
		else if (len < 0)
			BT_ERR("Failed to read data from smd %d", len);
		break;
	case SMD_EVENT_OPEN:
		BT_INFO("opening HCI-SMD channel :%s", DATA_CHANNEL);
		hci_smd_open(hdev);
		break;
	case SMD_EVENT_CLOSE:
		BT_INFO("Closing HCI-SMD channel :%s", DATA_CHANNEL);
		hci_smd_close(hdev);
		break;
	default:
		break;
	}

}

static int hci_smd_hci_register_dev(struct hci_smd_data *hsmd)
{
	struct hci_dev *hdev;

	hdev = hsmd->hdev;

	if (hci_register_dev(hdev) < 0) {
		BT_ERR("Can't register HCI device");
		hci_free_dev(hdev);
		hsmd->hdev = NULL;
		return -ENODEV;
	}
	return 0;
}

/*
 * hdev->setup callback. Missing from the public Qualcomm/CodeAurora port --
 * a Ubiquiti addition recovered by disassembling stock kernel.img. Sends two
 * vendor "write NV item" commands under opcode 0xFC0B: the BD address derived
 * from the eth0 MAC with the locally-administered bit set, then an
 * unidentified 12-byte NV item (0x24) sent verbatim. An earlier version had an
 * offset bug (objdump prints unprefixed immediates in decimal, not hex).
 */
static int hci_smd_send_vendor_nv_cmd(const u8 *header, size_t header_len,
				       const u8 *data, size_t data_len,
				       const char *what)
{
	u8 cmd[18];
	int avail;
	int written;
	size_t total = header_len + data_len;

	if (total > sizeof(cmd)) {
		BT_ERR("hci_smd_setup: %s command too large (%zu)", what, total);
		return -EINVAL;
	}

	memcpy(cmd, header, header_len);
	memcpy(cmd + header_len, data, data_len);

	avail = smd_write_avail(hs.event_channel);
	BT_INFO("hci_smd_setup: %s: smd_write_avail=%d, need=%zu",
		what, avail, total);
	if (avail < total) {
		BT_ERR("hci_smd_setup: %s: no space available for smd frame", what);
		return -ENOSPC;
	}

	written = smd_write(hs.event_channel, cmd, total);
	BT_INFO("hci_smd_setup: %s: smd_write returned %d (wanted %zu)",
		what, written, total);
	if (written < total) {
		BT_ERR("hci_smd_setup: %s: failed to write vendor command", what);
		return -EIO;
	}

	return 0;
}

static int hci_smd_setup(struct hci_dev *hdev)
{
	struct net_device *netdev;
	bdaddr_t bda;
	/* Command 1: opcode 0xFC0B, plen=9 (3 fixed param bytes + 6-byte
	 * bdaddr), sub-op 0x01 (write), item_id 0x02 (BD address), item_len 6.
	 */
	static const u8 bdaddr_header[] = { 0x0b, 0xfc, 0x09, 0x01, 0x02, 0x06 };
	/* Command 2: opcode 0xFC0B, plen=15 (3 fixed param bytes + 12-byte
	 * item), sub-op 0x01 (write), item_id 0x24, item_len 12. Fixed,
	 * unconditional, no per-board substitution -- see port note above.
	 */
	static const u8 fixed_cmd2[] = {
		0x0b, 0xfc, 0x0f, 0x01, 0x24, 0x0c,
		0xff, 0x03, 0x07, 0x09, 0x09, 0x09,
		0x00, 0x00, 0x09, 0x09, 0x04, 0x00,
	};

	BT_INFO("hci_smd_setup: called");

	netdev = dev_get_by_name(&init_net, "eth0");
	if (!netdev) {
		BT_ERR("hci_smd_setup: eth0 not found, cannot derive BD address");
		return 0;	/* non-fatal, matches stock's tolerant behavior */
	}

	baswap(&bda, (bdaddr_t *)netdev->dev_addr);
	dev_put(netdev);

	bda.b[5] |= 0x02;	/* locally-administered bit, first displayed octet */

	BT_INFO("hci_smd_setup: derived BD address %02x:%02x:%02x:%02x:%02x:%02x from eth0",
		bda.b[5], bda.b[4], bda.b[3], bda.b[2], bda.b[1], bda.b[0]);

	hci_smd_send_vendor_nv_cmd(bdaddr_header, sizeof(bdaddr_header),
				    bda.b, 6, "bdaddr");

	hci_smd_send_vendor_nv_cmd(fixed_cmd2, sizeof(fixed_cmd2), fixed_cmd2, 0,
				    "nv-item-0x24");

	return 0;
}

static int hci_smd_register_smd(struct hci_smd_data *hsmd)
{
	struct hci_dev *hdev;
	int rc;

	/* Initialize and register HCI device */
	hdev = hci_alloc_dev();
	if (!hdev) {
		BT_ERR("Can't allocate HCI device");
		return -ENOMEM;
	}

	hsmd->hdev = hdev;
	hdev->bus = HCI_SMD;
	/* hdev->driver_data = NULL; -- field removed in this tree's struct
	 * hci_dev (replaced by hci_set_drvdata() in modern kernels, per
	 * drivers/bluetooth/hci_ldisc.c). Deleted outright rather than
	 * calling the replacement API: nothing in this file ever reads
	 * driver_data back (the only consumer, hci_smd_destruct(), was
	 * already removed as dead code -- see note below), so there is
	 * nothing to set in the first place. */
	hdev->open  = hci_smd_open;
	hdev->close = hci_smd_close;
	hdev->send  = hci_smd_send_frame;
	hdev->setup = hci_smd_setup;
	/* hdev->destruct = hci_smd_destruct; -- field removed in this tree's
	 * struct hci_dev; was a no-op anyway (driver_data is always NULL
	 * here). See port note at top of file. */
	/* hdev->owner = THIS_MODULE; -- field removed in this tree's struct
	 * hci_dev. Confirmed via net/bluetooth/hci_core.c's own
	 * hci_alloc_dev() implementation and two real, compiling drivers
	 * (hci_ldisc.c, btusb.c) that neither sets this field nor needs
	 * to -- module ownership/refcounting is handled elsewhere now, not
	 * the caller's responsibility. */


	tasklet_init(&hsmd->rx_task,
			hci_smd_rx, (unsigned long) hsmd);
	/*
	 * Setup the timer to monitor whether the Rx queue is empty,
	 * to control the wake lock release
	 */
	setup_timer(&hsmd->rx_q_timer, schedule_timer,
			(unsigned long) hsmd->hdev);

	/* Open the SMD Channel and device and register the callback function */
	rc = smd_named_open_on_edge(EVENT_CHANNEL, SMD_APPS_WCNSS,
			&hsmd->event_channel, hdev, hci_smd_notify_event);
	if (rc < 0) {
		BT_ERR("Cannot open the command channel");
		hci_free_dev(hdev);
		hsmd->hdev = NULL;
		return -ENODEV;
	}

	rc = smd_named_open_on_edge(DATA_CHANNEL, SMD_APPS_WCNSS,
			&hsmd->data_channel, hdev, hci_smd_notify_data);
	if (rc < 0) {
		BT_ERR("Failed to open the Data channel");
		hci_free_dev(hdev);
		hsmd->hdev = NULL;
		return -ENODEV;
	}

	/* Disable the read interrupts on the channel */
	smd_disable_read_intr(hsmd->event_channel);
	smd_disable_read_intr(hsmd->data_channel);
	return 0;
}

static void hci_smd_deregister_dev(struct hci_smd_data *hsmd)
{
	tasklet_kill(&hs.rx_task);

	if (hsmd->hdev) {
		/* hci_unregister_dev() returns void in this tree (confirmed
		 * against include/net/bluetooth/hci_core.h), not int -- the
		 * original's error-logging wrapper around it is dropped
		 * since there's no return value left to check. */
		hci_unregister_dev(hsmd->hdev);

		hci_free_dev(hsmd->hdev);
		hsmd->hdev = NULL;
	}

	smd_close(hs.event_channel);
	smd_close(hs.data_channel);

	if (wake_lock_active(&hs.wake_lock_rx))
		wake_unlock(&hs.wake_lock_rx);
	if (wake_lock_active(&hs.wake_lock_tx))
		wake_unlock(&hs.wake_lock_tx);

	/*Destroy the timer used to monitor the Rx queue for emptiness */
	if (hs.rx_q_timer.function) {
		del_timer_sync(&hs.rx_q_timer);
		hs.rx_q_timer.function = NULL;
		hs.rx_q_timer.data = 0;
	}
}

static void hci_dev_restart(struct work_struct *worker)
{
	down(&hci_smd_enable);
	restart_in_progress = 1;
	hci_smd_deregister_dev(&hs);
	hci_smd_register_smd(&hs);
	up(&hci_smd_enable);
	kfree(worker);
}

static void hci_dev_smd_open(struct work_struct *worker)
{
	down(&hci_smd_enable);
	if (restart_in_progress == 1) {
		/* Allow wcnss to initialize */
		restart_in_progress = 0;
		msleep(10000);
	}
	hci_smd_hci_register_dev(&hs);
	up(&hci_smd_enable);
	kfree(worker);
}

static int hcismd_set_enable(const char *val, const struct kernel_param *kp)
{
	int ret = 0;

	pr_err("hcismd_set_enable %d", hcismd_set);

	down(&hci_smd_enable);

	ret = param_set_int(val, kp);

	if (ret)
		goto done;

	switch (hcismd_set) {

	case 1:
		if (hs.hdev == NULL)
			hci_smd_register_smd(&hs);
	break;
	case 0:
		hci_smd_deregister_dev(&hs);
	break;
	default:
		ret = -EFAULT;
	}

done:
	up(&hci_smd_enable);
	return ret;
}
static int  __init hci_smd_init(void)
{
	wake_lock_init(&hs.wake_lock_rx, WAKE_LOCK_SUSPEND,
			 "msm_smd_Rx");
	wake_lock_init(&hs.wake_lock_tx, WAKE_LOCK_SUSPEND,
			 "msm_smd_Tx");
	restart_in_progress = 0;
	hs.hdev = NULL;
	return 0;
}
module_init(hci_smd_init);

static void __exit hci_smd_exit(void)
{
	wake_lock_destroy(&hs.wake_lock_rx);
	wake_lock_destroy(&hs.wake_lock_tx);
}
module_exit(hci_smd_exit);

MODULE_AUTHOR("Ankur Nandwani <ankurn@codeaurora.org>");
MODULE_DESCRIPTION("Bluetooth SMD driver");
MODULE_LICENSE("GPL v2");
