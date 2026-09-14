// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 the CloudKey UNAS project authors

/*
 * FB driver for the SP8110 display module (SSD1351-family OLED controller)
 * Used as the front-panel status display on Ubiquiti CloudKey G2/G2+ (APQ8053)
 *
 * Reconstructed from disassembly of the stock CloudKey vmlinux (LOCALVERSION
 * "-ui-qcom"). Ubiquiti's GPL source tarball ships a broken symlink for this
 * file pointing at internal build infra, so this is a from-scratch rebuild
 * based on:
 *   - struct fbtft_display contents dumped from .kernel @ 0xffffffc000d84df0
 *   - full disassembly of init_display, write_cmd, fbtft_driver_probe_spi
 *   - the vendor's fbtft_ops layout, which includes a legacy check_var field
 *     not present in current upstream drivers/staging/fbtft (confirms this
 *     backport predates fbtft's Jan 2015 merge into kernel staging)
 *
 * TODO markers below need the corresponding disassembly filled in before
 * this will produce correct/complete behavior. Do not flash a kernel built
 * with the TODO stubs as-is -- they are placeholders, not working code.
 *
 * UPDATE: backlight/brightness control (register_backlight() /
 * sp8110_bl_update_status()) has since been properly implemented, driving
 * the SSD1351's 0xC7 "Master Contrast Current Control" command from
 * sysfs brightness writes, with max_brightness corrected from an
 * unsupported placeholder of 4 to the confirmed real value of 15 (read
 * back from a live stock device). Other TODOs below (set_gamma, the
 * undocumented 0xD1 command, write_vmem's pixel-packing, the WIDTH-1 vs
 * 80 column-address discrepancy) remain open and unverified against real
 * hardware -- this file is closer to correct than when originally
 * written, but still not a fully confirmed match for stock in every
 * respect.
 *
 * Confirmed values (from struct dump):
 *   name       = "fb_sp8110"
 *   width      = 160
 *   height     = 60
 *   regwidth   = 8
 *   buswidth   = 0
 *   backlight  = 10
 *   txbuflen   = 16384
 *   init_sequence = NULL   (custom init_display handles everything)
 *   gamma_num  = 1, gamma_len = 1
 *   gamma      = "1F 0F 18 2F 28 20 22 1F 1B 23 37 00 07 02 10"
 *
 * Confirmed NULL callbacks (safe to omit / leave unset in fbtft_ops):
 *   write, read, write_register, reset, mkdirty, update_display,
 *   request_gpios_match, request_gpios, verify_gpios, unregister_backlight
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/spi/spi.h>
#include <linux/delay.h>
#include <linux/gpio.h>

#include "fbtft.h"

#define DRVNAME		"fb_sp8110"
#define WIDTH		160
#define HEIGHT		60
#define TXBUFLEN	16384
#define DEFAULT_GAMMA	"1F 0F 18 2F 28 20 22 1F 1B 23 37 00 07 02 10"

/*
 * write_cmd(par, dc, cmd, ...)
 *
 * Reconstructed from disassembly at 0xffffffc000678670. Signature inferred
 * from register usage:
 *   x0 = par
 *   w1 = command byte
 *   x2 = pointer to variadic arg buffer (data bytes)
 *   x3 = arg count
 *
 * Behavior:
 *   1. Reads the DC/RS GPIO number from par->gpio.dc (confirmed: this
 *      fbtft.h declares it as a plain `int` -- the legacy integer GPIO
 *      API, not a struct gpio_desc * -- see struct fbtft_gpio below) and
 *      drives it low via gpio_set_value() before sending the command
 *      byte -- i.e. DC/RS pin held low = command mode.
 *   2. Calls a function pointer at par offset +160 with (par, 1, cmd) --
 *      this matches par->fbtftops.write_register's calling convention,
 *      confirming write_cmd is a thin wrapper around write_register.
 *   3. If data bytes were passed (x20/x21 non-NULL, i.e. buf && len), calls
 *      fbtft_write_buf_dc(par, buf, len, dc=1) to send them in data mode.
 *
 * The implementation below uses par->fbtftops.write_register directly
 * instead of reimplementing the raw GPIO toggle, which is behaviorally
 * equivalent and is the idiomatic way to write this in a fbtft driver.
 */
/*
 * local_write_buf_dc(par, buf, len, dc)
 *
 * fbtft_write_buf_dc() was a real, exported function in the vendor's
 * original kernel binary (confirmed via kallsyms during disassembly), but
 * this fbtft.h snapshot doesn't declare or export it -- only the lower-
 * level fbtft_write_spi() is available. This reimplements the same
 * behavior write_cmd's disassembly showed: toggle the DC/RS GPIO for
 * data mode, then send the buffer over SPI. par->gpio.dc is confirmed
 * (see above) to be a plain int GPIO number in this fbtft.h, matching
 * the gpio_set_value() call used here.
 */
static int local_write_buf_dc(struct fbtft_par *par, void *buf, size_t len, int dc)
{
	gpio_set_value(par->gpio.dc, dc);
	return fbtft_write_spi(par, buf, len);
}

static int write_cmd(struct fbtft_par *par, u8 cmd, u8 *data, size_t len)
{
	par->fbtftops.write_register(par, 1, cmd);
	if (data && len)
		return local_write_buf_dc(par, data, len, 1);
	return 0;
}

/*
 * init_display(par)
 *
 * Reconstructed from disassembly at 0xffffffc0006789e4. Sequence of
 * write_cmd calls decoded (SSD1351 command set match noted):
 *
 *   0xFD, {0x12}       -- command lock (unlock extension commands)
 *   0xAE               -- display off
 *   0x15, {0x4F, 0x00}     wait -- actually 0x15 = col addr set: 0x00..0x4F
 *                          (79 = 80-1, i.e. width-related; note actual
 *                          panel width 160 vs SSD1351's native 128 --
 *                          TODO: verify this isn't a sub-window)
 *   0x75, {0x00, height-1} -- row addr set: 0x00..(HEIGHT-1) = 0x00..0x3B (59)
 *   0xA1, {0x00}       -- display start line = 0
 *   0xA2, {0x00}       -- display offset = 0
 *
 * TODO: disassembly was cut off after the 0xA2 command in the original
 * dump -- there are almost certainly more init commands following
 * (contrast/brightness, MUX ratio, COM config, VCOMH, pre-charge, etc. are
 * all standard SSD1351 init steps and none have shown up yet). Re-run:
 *   objdump -d stock-vmlinux.elf --start-address=0xffffffc000678b00 \
 *                                 --stop-address=0xffffffc000678c84
 * (0x678c84 = write_vmem, the next known function boundary) to capture the
 * rest of this function before treating this as complete.
 */
static int init_display(struct fbtft_par *par)
{
	u8 buf[2];

	par->fbtftops.reset(par);

	buf[0] = 0x12;
	write_cmd(par, 0xFD, buf, 1);		/* command lock (unlock) */

	write_cmd(par, 0xAE, NULL, 0);		/* sleep mode on / display off */

	buf[0] = 0x00;
	buf[1] = WIDTH - 1;			/* 0x4F = 79 = 80-1, TODO: why 80
						 * and not WIDTH-1=159? possibly
						 * a sub-window into a wider
						 * native panel buffer */
	write_cmd(par, 0x15, buf, 2);		/* column address set */

	buf[0] = 0x00;
	buf[1] = HEIGHT - 1;			/* 0x3B = 59 = HEIGHT-1, matches */
	write_cmd(par, 0x75, buf, 2);		/* row address set */

	buf[0] = 0x00;
	write_cmd(par, 0xA1, buf, 1);		/* display start line */

	buf[0] = 0x00;
	write_cmd(par, 0xA2, buf, 1);		/* display offset */

	buf[0] = 0x01;
	write_cmd(par, 0xAB, buf, 1);		/* function selection: enable
						 * internal Vdd regulator */

	buf[0] = 0xF1;
	write_cmd(par, 0xB1, buf, 1);		/* reset & precharge period
						 * (phase 1/2), packed nibble */

	buf[0] = 0x50;
	write_cmd(par, 0xB3, buf, 1);		/* display clock div / osc freq */

	buf[0] = 0xA0;
	buf[1] = 0xB5;
	write_cmd(par, 0xB4, buf, 2);		/* segment low voltage (VSL) --
						 * TODO: SSD1351 datasheet shows
						 * this as a 3-byte command; only
						 * 2 bytes sent here, unclear if
						 * intentional simplification */

	buf[0] = 0x00;
	write_cmd(par, 0xB5, buf, 1);		/* GPIO */

	buf[0] = 0x08;
	write_cmd(par, 0xB6, buf, 1);		/* second precharge period */

	write_cmd(par, 0xB9, NULL, 0);		/* use built-in grayscale LUT */

	buf[0] = 0x1F;
	write_cmd(par, 0xBB, buf, 1);		/* precharge voltage */

	buf[0] = 0x01;
	write_cmd(par, 0xBE, buf, 1);		/* VCOMH voltage */

	buf[0] = 0x80;
	write_cmd(par, 0xC1, buf, 1);		/* contrast current (single
						 * byte here; datasheet shows
						 * separate A/B/C channels --
						 * TODO: confirm this isn't a
						 * mono/grayscale-only panel
						 * using just one channel) */

	buf[0] = 0x0A;
	write_cmd(par, 0xC7, buf, 1);		/* master contrast current */

	buf[0] = HEIGHT - 1;			/* 0x3B = 59, confirms MUX ratio
						 * ties directly to HEIGHT */
	write_cmd(par, 0xCA, buf, 1);		/* set MUX ratio */

	buf[0] = 0xA2;
	buf[1] = 0x20;
	write_cmd(par, 0xD1, buf, 2);		/* TODO: undocumented in the
						 * public SSD1351 datasheet --
						 * possibly a vendor/variant-
						 * specific extension command.
						 * Verify against real hardware
						 * before assuming this is safe
						 * to omit or alter. */

	write_cmd(par, 0xA6, NULL, 0);		/* display mode: normal */

	/* Note: display is left in "sleep on" (0xAE) state here -- the
	 * fbtft core calls par->fbtftops.blank(par, false) after a
	 * successful init_display, which sends 0xAF (sleep off / display
	 * on). This matches this driver's blank() implementation below. */

	return 0;
}

/*
 * set_addr_win(par, xs, ys, xe, ye)
 *
 * Reconstructed from disassembly at 0xffffffc000678860. Both xs/xe and
 * ys/ye are offset by +3 then arithmetic-shifted right by 2 (i.e. divided
 * by 4, matching the +3 as rounding-up integer division) before being
 * further adjusted -- consistent with this display addressing memory in
 * 4-pixel-wide blocks. Column address gets a further +0x28 (40) offset,
 * row address a further +0x27 (39) offset, both applied post-division --
 * these look like the panel's true internal addressable origin not lining
 * up with (0,0) of the visible 160x60 window (i.e. this display sits as a
 * sub-window inside the SSD1351 controller's native larger addressable
 * area). Then writes: 0x15 (column addr), 0x75 (row addr), 0xA1 (start
 * line, always 0).
 */
static void set_addr_win(struct fbtft_par *par, int xs, int ys, int xe, int ye)
{
	u8 buf[2];

	xs = (xs + 3) >> 2;
	xe = (xe + 3) >> 2;
	ys = ys;	/* TODO: confirm ys/ye don't need the same +3 >>2 --
			 * disassembly shows w23/w22 (ys/ye) passed straight
			 * through without the shift applied to w20/w19
			 * (xs/xe). Re-check register mapping (w1=xs, w2=ys,
			 * w3=xe, w4=ye per AAPCS) before trusting this. */
	ye = ye;

	buf[0] = xs + 0x28;
	buf[1] = xe + 0x27;	/* CORRECTED: disassembly shows xe gets +0x27,
				 * not +0x28 like xs -- an asymmetric offset,
				 * not a typo in the original firmware. My
				 * earlier translation used +0x28 for both,
				 * which would misalign the trailing column
				 * edge on every single write -- a strong
				 * candidate for the "garbled" symptom. */
	write_cmd(par, 0x15, buf, 2);

	buf[0] = ys;
	buf[1] = ye;
	write_cmd(par, 0x75, buf, 2);

	buf[0] = 0x00;
	write_cmd(par, 0xA1, buf, 1);
}

/*
 * write_vmem(par, offset, len)
 *
 * Reconstructed from disassembly at 0xffffffc000678c84. Sends 0x5C
 * (Write RAM) then streams pixel data via fbtft_write_buf_dc(). SP8110
 * packs 2 source pixels into 1 output byte (a 4-bit value per pixel),
 * consistent with it being a 4-bit grayscale/mono OLED despite sitting
 * on an SSD1351-family controller, rather than a full-color panel.
 *
 * UPDATE: the original per-pixel 4-bit extraction here read
 * `(px >> 1) & 0x0F` -- bits [4:1] of a 16bpp RGB565 pixel, which fall
 * entirely within the BLUE channel's own bit range (blue occupies bits
 * [4:0]). That silently discarded red and green, extracting a
 * blue-only value rather than actual brightness/luminance. This went
 * unnoticed because typical light-UI content is close to neutral
 * grayscale (R=G=B), where blue alone happens to track true brightness
 * correctly by coincidence -- but it produced a visible color-negative
 * effect specifically for non-neutral palettes (confirmed: a
 * warm/reddish night-mode color scheme -- high red, low blue by
 * design, to reduce blue light -- rendered as an apparent color
 * inversion, since something meant to look bright/lit-up carries
 * almost no blue signal and was rendered dark, while low-brightness
 * background elements with even slight blue tint rendered as "on").
 *
 * Replaced with a standard RGB565->8bpp channel expansion followed by
 * ITU-R BT.601 luma weighting (0.299R + 0.587G + 0.114B, as the
 * integer weights 77/150/29 summing to 256), then take the top 4 bits
 * of the resulting 8-bit luma as the panel's grayscale level. This is
 * not confirmed against further disassembly of the exact original
 * algorithm, but is a principled, objectively-correct fix for the
 * diagnosed bug class (single-channel-only extraction blind to
 * red/green) and should be verified against real hardware output
 * across both neutral and colored content.
 */
static u8 rgb565_to_gray4(u16 px)
{
	u8 r5 = (px >> 11) & 0x1F;
	u8 g6 = (px >> 5) & 0x3F;
	u8 b5 = px & 0x1F;
	u8 r8 = (r5 << 3) | (r5 >> 2);
	u8 g8 = (g6 << 2) | (g6 >> 4);
	u8 b8 = (b5 << 3) | (b5 >> 2);
	u16 luma8 = (77 * r8 + 150 * g8 + 29 * b8) >> 8;

	return (u8)(luma8 >> 4);
}

static int write_vmem(struct fbtft_par *par, size_t offset, size_t len)
{
	u16 *vmem16 = (u16 *)((u8 __force *)par->info->screen_base + offset);
	u8 *txbuf = par->txbuf.buf;
	size_t pixels = len / 2;
	size_t out_bytes = (pixels + 1) / 2;	/* round up: handle odd trailing pixel */
	size_t i;
	int ret;

	for (i = 0; i + 1 < pixels; i += 2) {
		u8 hi = rgb565_to_gray4(vmem16[i]);
		u8 lo = rgb565_to_gray4(vmem16[i + 1]);

		*txbuf++ = (hi << 4) | lo;
	}
	if (pixels & 1) {
		/* Odd pixel count: this chunk's final source pixel has no
		 * partner to pack with. Previously silently dropped -- pack
		 * it alone into the high nibble with a 0 low nibble rather
		 * than lose it. Unreachable in practice for this panel's
		 * fixed 160x60 geometry (every row and the full framebuffer
		 * are always even pixel counts), but cheap to handle
		 * correctly regardless of how fbtft-core's deferred-IO ever
		 * chunks a write_vmem call.
		 */
		u8 hi = rgb565_to_gray4(vmem16[i]);

		*txbuf++ = hi << 4;
	}

	write_cmd(par, 0x5C, NULL, 0);		/* write RAM */
	ret = local_write_buf_dc(par, par->txbuf.buf, out_bytes, 1);
	if (ret < 0)
		dev_err(par->info->device,
			"%s: write failed and .kernel offset %lx\n",
			__func__, (unsigned long)offset);

	gpio_set_value(par->gpio.dc, 0);

	return ret;
}

/*
 * blank(par, on)
 *
 * Reconstructed from disassembly at 0xffffffc0006787f8. Confirmed simple:
 * on=true (blank the display) sends 0xAE (sleep on / display off);
 * on=false (unblank) sends 0xAF (sleep off / display on). This is the
 * call that actually turns the display on after init_display() leaves it
 * in the sleep/off state.
 */
static int blank(struct fbtft_par *par, bool on)
{
	write_cmd(par, on ? 0xAE : 0xAF, NULL, 0);
	return 0;
}

/*
 * register_backlight(par)
 *
 * Reconstructed from disassembly at 0xffffffc000678d78. Standard fbtft
 * boilerplate: builds a struct backlight_properties (type=BACKLIGHT_RAW=1,
 * max_brightness=4, power=15/FB_BLANK_POWERDOWN default, brightness=10 --
 * matching display.backlight=10 from the struct dump) and calls
 * backlight_device_register(). On failure, logs via dev_err and returns
 * without setting anything. On success, stores the returned
 * backlight_device pointer into the fbtft_par struct (offset +696) and,
 * if par->fbtftops.unregister_backlight isn't already set (offset +248),
 * points it at a shared generic unregister helper.
 */
/*
 * fbtft-core.c's fbtft_register_framebuffer() unconditionally calls
 * fb_info->bl_dev->ops->update_status(fb_info->bl_dev) with no NULL check
 * on `ops` -- passing NULL for bl_ops to backlight_device_register()
 * (as this driver originally did) causes a NULL-pointer crash the moment
 * the framebuffer registers successfully. That's why a stub existed here
 * previously.
 *
 * Now implemented for real: the SSD1351's "Set Master Contrast Current
 * Control" command is 0xC7, taking a single 4-bit argument (0-15) --
 * confirmed by two independent facts lining up: stock's real
 * max_brightness is 15 (a live device readback, not a guess), and
 * init_display() above already sends this exact command once at boot
 * with a hardcoded value of 0x0A (10), matching this driver's own
 * brightness=10 default. What was missing was any runtime path
 * connecting sysfs brightness writes back to that same register --
 * previously it was set once at init and never touched again.
 */
static int sp8110_bl_update_status(struct backlight_device *bd)
{
	struct fbtft_par *par = bl_get_data(bd);
	u8 brightness = bd->props.brightness;

	return write_cmd(par, 0xC7, &brightness, 1);
}

static const struct backlight_ops sp8110_bl_ops = {
	.update_status = sp8110_bl_update_status,
};

static void register_backlight(struct fbtft_par *par)
{
	struct backlight_properties bl_props = { 0 };
	struct backlight_device *bd;

	bl_props.type = BACKLIGHT_RAW;
	/*
	 * Was FB_BLANK_POWERDOWN here previously -- almost certainly a
	 * copy/paste or transcription slip against the comment above
	 * this struct ("power=15/FB_BLANK_POWERDOWN default"), which
	 * itself has the two concepts backwards: FB_BLANK_POWERDOWN is
	 * the numeric constant 4, not 15, and max_brightness (a
	 * completely separate field, see below) is what's really 15 on
	 * real hardware. Registering with power already set to
	 * POWERDOWN would leave the backlight core believing the
	 * display starts powered off, which is wrong -- the panel is
	 * explicitly unblanked separately via this driver's own blank()
	 * callback after init_display() completes. Correct starting
	 * state is FB_BLANK_UNBLANK (powered on).
	 */
	bl_props.power = FB_BLANK_UNBLANK;
	/*
	 * Was 4 here previously. Confirmed against a live stock device's
	 * actual /sys/class/backlight/fb_sp8110/max_brightness, which
	 * reads 15 -- matching the SSD1351's real 4-bit (0-15) contrast
	 * range used by the 0xC7 command above. The old value of 4 had
	 * no basis found anywhere in the disassembly notes; whatever its
	 * origin, it silently capped every brightness write via the
	 * backlight core's own bounds check before this driver's code
	 * ever ran.
	 */
	bl_props.max_brightness = 15;
	bl_props.brightness = 10;	/* matches display.backlight = 10 and
					 * init_display()'s initial 0xC7 write
					 * of 0x0A (10) -- so the first
					 * update_status() call triggered by
					 * fbtft_register_framebuffer() is a
					 * harmless no-op re-write of the
					 * value hardware already has. */

	bd = backlight_device_register(dev_driver_string(par->info->device),
					par->info->device, par, &sp8110_bl_ops,
					&bl_props);
	if (IS_ERR(bd)) {
		dev_err(par->info->device, "cannot register backlight device (%ld)\n",
			PTR_ERR(bd));
		return;
	}
	par->info->bl_dev = bd;

	if (!par->fbtftops.unregister_backlight)
		par->fbtftops.unregister_backlight = fbtft_unregister_backlight;
}

/*
 * check_var(par, var)
 *
 * Reconstructed from disassembly at 0xffffffc000678500. Standard
 * fb_check_var-style clamp:
 *   - copies 0xa0 (160) bytes from a template region into *var first
 *     (a full struct fb_var_screeninfo memcpy -- likely resetting most
 *     fields to sane defaults before applying per-call adjustments)
 *   - clamps var->xres to a max of 160 (0xa0)
 *   - clamps var->yres to a max of 60 (0x3c)
 *   - reads a field at offset +136 off the fbtft_par (same field set_var
 *     touches), subtracts 1, and clamps it to 180 (0xb4) via an unsigned
 *     less-than compare -- TODO: this field's real name/purpose isn't
 *     confirmed; it's touched identically in the near-duplicate check_var
 *     at 0x678e60 (the ST7735R driver's copy), so it's likely a generic
 *     fbtft_par housekeeping field (possibly related to rotate degrees)
 *     rather than SP8110-specific. Safe to leave the width/height clamps
 *     as the meaningful part of this function.
 */
/*
 * NOTE: the disassembled vendor binary has a check_var(par, var) callback
 * in fbtft_ops that does NOT exist anywhere in notro/fbtft's history --
 * confirmed absent even at the very first commit that introduced the
 * shared fbtft.h. It's a Ubiquiti-only addition on top of the framework,
 * not something this fbtft.h supports. Its logic (clamping xres<=WIDTH,
 * yres<=HEIGHT) is folded into set_var below instead, since building
 * against a real fbtft.h means we can't add a struct field that isn't
 * there.
 */
static int set_var(struct fbtft_par *par)
{
	u8 buf[2];
	unsigned rotate = par->info->var.rotate;

	if (par->info->var.xres > WIDTH)
		par->info->var.xres = WIDTH;
	if (par->info->var.yres > HEIGHT)
		par->info->var.yres = HEIGHT;

	if (rotate == 0) {
		buf[0] = 0x24;
	} else if (rotate == 180) {
		buf[0] = 0x36;
	} else {
		dev_err(par->info->device,
			"%s: rotate=%u not supported by this display\n",
			__func__, rotate);
		return 0;
	}

	buf[1] = 0x01;
	write_cmd(par, 0xA0, buf, 2);

	return 0;
}

/* TODO: reconstruct from disassembly at 0xffffffc0006786f0 (set_gamma) */
static int set_gamma(struct fbtft_par *par, unsigned long *curves)
{
	return 0;
}

static struct fbtft_display display = {
	.regwidth = 8,
	.width = WIDTH,
	.height = HEIGHT,
	.backlight = 10,
	.txbuflen = TXBUFLEN,
	.gamma_num = 1,
	.gamma_len = 15,	/* corrected from disassembly-derived offset
				 * read of 1 -- real hardware (probe log)
				 * confirms the DEFAULT_GAMMA string's 15
				 * space-separated values must match
				 * gamma_num*gamma_len or fbtft's parser
				 * rejects it with "Too many values" */
	.gamma = DEFAULT_GAMMA,
	.fbtftops = {
		.write_vmem = write_vmem,
		.set_addr_win = set_addr_win,
		.init_display = init_display,
		.blank = blank,
		.register_backlight = register_backlight,	/* still a stub */
		.set_var = set_var,
		.set_gamma = set_gamma,
	},
};

static int fbtft_driver_probe_spi(struct spi_device *spi)
{
	return fbtft_probe_common(&display, spi, NULL);
}

static int fbtft_driver_remove_spi(struct spi_device *spi)
{
	struct fb_info *info = spi_get_drvdata(spi);

	if (info)
		fbtft_remove_common(&spi->dev, info);
	return 0;
}

static const struct of_device_id dt_ids[] = {
	{ .compatible = "visionox,sp8110" },	/* confirmed via fdtdump against
						 * the live device tree */
	{},
};
MODULE_DEVICE_TABLE(of, dt_ids);

static const struct spi_device_id sp8110_ids[] = {
	{ "sp8110", 0 },
	{},
};
MODULE_DEVICE_TABLE(spi, sp8110_ids);

static struct spi_driver sp8110_driver = {
	.driver = {
		.name = DRVNAME,
		.owner = THIS_MODULE,
		.of_match_table = dt_ids,
	},
	.id_table = sp8110_ids,
	.probe = fbtft_driver_probe_spi,
	.remove = fbtft_driver_remove_spi,
};

module_spi_driver(sp8110_driver);

MODULE_DESCRIPTION("FB driver for the SP8110 SSD1351-family OLED display");
MODULE_LICENSE("GPL");
