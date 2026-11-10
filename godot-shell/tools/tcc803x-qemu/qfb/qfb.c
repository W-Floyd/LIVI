// Frame buffer for the tcc803x QEMU machine: 1920x720 at the "qfb" scan-out
// device, standing in for the Telechips VIOC pipeline (no driver source exists
// for the stock kernel). Loaded with insmod from the ramdisk.
#include <linux/module.h>
#include <linux/fb.h>
#include <linux/io.h>

#define VRAM_BASE 0x70000000
#define REGS_BASE 0x72000000
#define VRAM_SIZE 0x02000000
#define W 1920
#define H 720
#define NBUF 3 /* the stock SurfaceFlinger wants three framebuffer buffers; gralloc asks for two */

static struct fb_info *info;
static void __iomem *regs;
static u32 pseudo_pal[16];

static void qfb_program(struct fb_info *fi)
{
	/* The device takes BGRX (red offset 16) or RGBX (red offset 0). */
	writel(fi->var.xres, regs + 0x0);
	writel(fi->var.yres, regs + 0x4);
	writel(fi->fix.line_length, regs + 0x8);
	writel(fi->var.yoffset * fi->fix.line_length, regs + 0xc);
	writel(fi->var.red.offset == 0, regs + 0x10);
}

static int qfb_check_var(struct fb_var_screeninfo *v, struct fb_info *fi)
{
	bool rgb = v->red.offset == 0;

	v->yres_virtual = NBUF * H;
	v->xres = v->xres_virtual = W;
	v->yres = H;
	v->bits_per_pixel = 32;
	v->red.offset = rgb ? 0 : 16;
	v->green.offset = 8;
	v->blue.offset = rgb ? 16 : 0;
	v->red.length = v->green.length = v->blue.length = 8;
	v->transp.offset = 24;
	v->transp.length = 8;
	if (v->yoffset > v->yres_virtual - H)
		return -EINVAL;
	return 0;
}

static int qfb_set_par(struct fb_info *fi)
{
	qfb_program(fi);
	return 0;
}

static int qfb_pan(struct fb_var_screeninfo *v, struct fb_info *fi)
{
	if (v->yoffset > fi->var.yres_virtual - H)
		return -EINVAL;
	fi->var.yoffset = v->yoffset;
	qfb_program(fi);
	return 0;
}

static int qfb_setcolreg(unsigned regno, unsigned r, unsigned g, unsigned b,
			 unsigned t, struct fb_info *fi)
{
	if (regno < 16)
		pseudo_pal[regno] = (r >> 8 << 16) | (g >> 8 << 8) | (b >> 8);
	return 0;
}

static struct fb_ops qfb_ops = {
	.owner = THIS_MODULE,
	.fb_check_var = qfb_check_var,
	.fb_set_par = qfb_set_par,
	.fb_pan_display = qfb_pan,
	.fb_setcolreg = qfb_setcolreg,
	.fb_fillrect = cfb_fillrect,
	.fb_copyarea = cfb_copyarea,
	.fb_imageblit = cfb_imageblit,
};

static int __init qfb_init(void)
{
	int ret;

	info = framebuffer_alloc(0, NULL);
	if (!info)
		return -ENOMEM;
	info->screen_base = ioremap_wc(VRAM_BASE, VRAM_SIZE);
	regs = ioremap(REGS_BASE, 0x1000);
	if (!info->screen_base || !regs) {
		ret = -ENOMEM;
		goto err;
	}
	strcpy(info->fix.id, "qfb");
	info->fix.type = FB_TYPE_PACKED_PIXELS;
	info->fix.visual = FB_VISUAL_TRUECOLOR;
	info->fix.accel = FB_ACCEL_NONE;
	info->fix.ypanstep = 1;
	info->fix.line_length = W * 4;
	info->fix.smem_start = VRAM_BASE;
	info->fix.smem_len = W * 4 * H * NBUF;
	info->var.xres = info->var.xres_virtual = W;
	info->var.yres = H;
	info->var.width = 293;
	info->var.height = 110;
	info->var.activate = FB_ACTIVATE_NOW;
	info->var.vmode = FB_VMODE_NONINTERLACED;
	qfb_check_var(&info->var, info);
	info->fbops = &qfb_ops;
	info->flags = FBINFO_DEFAULT;
	info->pseudo_palette = pseudo_pal;
	qfb_program(info);
	ret = register_framebuffer(info);
	if (ret)
		goto err;
	return 0;
err:
	if (info->screen_base)
		iounmap(info->screen_base);
	if (regs)
		iounmap(regs);
	framebuffer_release(info);
	return ret;
}
module_init(qfb_init);

MODULE_LICENSE("GPL");
