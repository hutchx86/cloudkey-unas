// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 the CloudKey UNAS project authors

/*
 * ubnthal.c -- minimal /proc/ubnthal emulation, backed by real files
 *
 * Reconstructed for the UCK-G2-Plus custom-btrfs-kernel project.
 *
 * Ubiquiti's real UBNTHAL exposes hardware identity to userspace via
 * /proc/ubnthal/{system.info,board}. Several UniFi OS services --
 * notably unifi-drive's storageService -- read these files directly.
 * On this device those procfs entries don't exist at all, which is
 * what storageService's "failed to read system info file: open
 * /proc/ubnthal/system.info: no such file or directory" warning was
 * reporting.
 *
 * This version creates /proc/ubnthal/{system.info,board} as thin
 * pass-throughs to real files on disk (UBNTHAL_BACKING_DIR below),
 * matching the original project's /opt/ubnthal approach, rather than
 * compiling fixed identity data into the module. Edit the identity by
 * editing the backing files -- no kernel rebuild required.
 *
 * Crash-safety: the backing files are read lazily, from inside each
 * proc entry's show() callback, triggered only when something opens
 * /proc/ubnthal/system.info or /proc/ubnthal/board. This is built
 * into the kernel image (=y), so module_init() runs very early in
 * boot -- potentially before the filesystem holding
 * UBNTHAL_BACKING_DIR is even mounted. Doing the file access there
 * would race that mount. Deferring it to show() avoids the race
 * entirely: by the time anything can open a /proc/ubnthal/* file,
 * userspace is running and the real filesystem is guaranteed mounted.
 * If the backing directory or file is genuinely still missing at read
 * time, filp_open() returns an error pointer, which is checked
 * (IS_ERR()) and handled by returning an empty read -- never a fault.
 * /proc/ubnthal/{system.info,board} always exist as soon as the
 * kernel boots; whether they have content just depends on whether the
 * backing files exist yet at read time.
 */

#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/slab.h>
#include <linux/err.h>

#define UBNTHAL_DIR_NAME     "ubnthal"
#define UBNTHAL_BACKING_DIR  "/opt/ubnthal"
#define UBNTHAL_READ_BUFSIZE 4096

static struct proc_dir_entry *ubnthal_dir;
static struct proc_dir_entry *ubnthal_system_info_entry;
static struct proc_dir_entry *ubnthal_board_entry;

/*
 * Read a backing file's full contents into *m. Never faults on a
 * missing file or directory -- IS_ERR() is checked at every step, and
 * any failure just results in nothing being written to *m, which
 * userspace sees as an empty (but present) proc file.
 *
 * kernel_read()'s (struct file *, loff_t, char *, unsigned long)
 * signature is the pre-4.14 form, correct for this 3.18 tree -- do
 * not "modernize" this to the newer void*-based signature.
 */
static void ubnthal_emit_file(struct seq_file *m, const char *path)
{
	struct file *filp;
	char *buf;
	ssize_t n;

	filp = filp_open(path, O_RDONLY, 0);
	if (IS_ERR(filp)) {
		pr_warn("ubnthal: %s not available (%ld) -- serving empty read\n",
			path, PTR_ERR(filp));
		return;
	}

	buf = kmalloc(UBNTHAL_READ_BUFSIZE, GFP_KERNEL);
	if (!buf) {
		pr_err("ubnthal: kmalloc failed reading %s\n", path);
		filp_close(filp, NULL);
		return;
	}

	n = kernel_read(filp, 0, buf, UBNTHAL_READ_BUFSIZE - 1);
	if (n > 0)
		seq_write(m, buf, n);
	else if (n < 0)
		pr_warn("ubnthal: read of %s failed (%zd) -- serving empty read\n",
			path, n);

	kfree(buf);
	filp_close(filp, NULL);
}

static int ubnthal_system_info_show(struct seq_file *m, void *v)
{
	ubnthal_emit_file(m, UBNTHAL_BACKING_DIR "/system.info");
	return 0;
}

static int ubnthal_board_show(struct seq_file *m, void *v)
{
	ubnthal_emit_file(m, UBNTHAL_BACKING_DIR "/board");
	return 0;
}

static int ubnthal_system_info_open(struct inode *inode, struct file *file)
{
	return single_open(file, ubnthal_system_info_show, NULL);
}

static int ubnthal_board_open(struct inode *inode, struct file *file)
{
	return single_open(file, ubnthal_board_show, NULL);
}

/*
 * kernel 3.18 procfs API: proc_create() takes a "struct file_operations"
 * pointer directly. (The "struct proc_ops" split doesn't exist until
 * 5.6+ -- do not "modernize" this to proc_ops on this kernel tree.)
 */
static const struct file_operations ubnthal_system_info_fops = {
	.owner   = THIS_MODULE,
	.open    = ubnthal_system_info_open,
	.read    = seq_read,
	.llseek  = seq_lseek,
	.release = single_release,
};

static const struct file_operations ubnthal_board_fops = {
	.owner   = THIS_MODULE,
	.open    = ubnthal_board_open,
	.read    = seq_read,
	.llseek  = seq_lseek,
	.release = single_release,
};

/*
 * module_init only ever touches procfs itself (proc_mkdir/proc_create),
 * never UBNTHAL_BACKING_DIR -- see the file header comment for why
 * that split matters. proc_mkdir/proc_create failing here is a normal,
 * checked error path (e.g. procfs itself unavailable), unrelated to
 * whether the backing files on disk exist.
 */
static int __init procubnthal_init(void)
{
	ubnthal_dir = proc_mkdir(UBNTHAL_DIR_NAME, NULL);
	if (!ubnthal_dir) {
		pr_err("ubnthal: failed to create /proc/%s\n", UBNTHAL_DIR_NAME);
		return -ENOMEM;
	}

	ubnthal_system_info_entry = proc_create("system.info", 0444,
						 ubnthal_dir,
						 &ubnthal_system_info_fops);
	if (!ubnthal_system_info_entry) {
		pr_err("ubnthal: failed to create system.info entry\n");
		goto err_remove_dir;
	}

	ubnthal_board_entry = proc_create("board", 0444, ubnthal_dir,
					   &ubnthal_board_fops);
	if (!ubnthal_board_entry) {
		pr_err("ubnthal: failed to create board entry\n");
		goto err_remove_system_info;
	}

	pr_info("ubnthal: /proc/%s/{system.info,board} ready, backed by %s\n",
		UBNTHAL_DIR_NAME, UBNTHAL_BACKING_DIR);
	return 0;

err_remove_system_info:
	remove_proc_entry("system.info", ubnthal_dir);
err_remove_dir:
	remove_proc_entry(UBNTHAL_DIR_NAME, NULL);
	return -ENOMEM;
}

static void __exit procubnthal_exit(void)
{
	remove_proc_entry("board", ubnthal_dir);
	remove_proc_entry("system.info", ubnthal_dir);
	remove_proc_entry(UBNTHAL_DIR_NAME, NULL);
}

module_init(procubnthal_init);
module_exit(procubnthal_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Minimal /proc/ubnthal emulation backed by /opt/ubnthal files");
MODULE_AUTHOR("hutchx86");
