// fbprobe: log to the kernel log each time the picture on screen changes, so
// boot traces show when the frontend's first frame replaced the boot logo.
//
// Build: docker run --rm --platform linux/arm64 -v "$PWD":/w -w /w alpine:3.20 sh -c 'apk add -q gcc musl-dev linux-headers && gcc -static -Os -s -o NAME tools/probes/NAME.c'
// usage: fbprobe [seconds]   (default 30)
//
// Every 20 ms it hashes a 32x24 grid of pixels in the visible half of
// /dev/fb0 (the panned buffer) and writes "fbprobe: frame N ..." to
// /dev/kmsg when the hash differs from the previous sample. dmesg timestamps
// then give the time since Linux started.
#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static void klog(const char *msg)
{
	int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
	if (fd >= 0) {
		(void)!write(fd, msg, strlen(msg));
		close(fd);
	}
}

int main(int argc, char **argv)
{
	int seconds = argc > 1 ? atoi(argv[1]) : 30;
	struct timespec tick = {0, 20 * 1000 * 1000};
	char msg[160];
	int fd;

	// The frame buffer may appear a little after init starts.
	for (int i = 0; (fd = open("/dev/fb0", O_RDONLY | O_CLOEXEC)) < 0; i++) {
		if (i > 500) {
			klog("fbprobe: no /dev/fb0\n");
			return 1;
		}
		nanosleep(&tick, NULL);
	}

	struct fb_fix_screeninfo fix;
	struct fb_var_screeninfo var;
	if (ioctl(fd, FBIOGET_FSCREENINFO, &fix) || ioctl(fd, FBIOGET_VSCREENINFO, &var)) {
		klog("fbprobe: fb ioctl failed\n");
		return 1;
	}
	if (var.bits_per_pixel != 32 || var.xres == 0 || var.yres == 0) {
		klog("fbprobe: unsupported pixel format\n");
		return 1;
	}
	const uint8_t *mem = mmap(NULL, fix.smem_len, PROT_READ, MAP_SHARED, fd, 0);
	if (mem == MAP_FAILED) {
		klog("fbprobe: mmap failed\n");
		return 1;
	}

	// The sunxi driver reports the panned buffer in sysfs ("x,y"), not
	// always in FBIOGET_VSCREENINFO.
	int pan = open("/sys/class/graphics/fb0/pan", O_RDONLY | O_CLOEXEC);

	uint64_t prev = 0;
	int frames = 0;
	for (long n = 0; n < seconds * 50L; n++) {
		uint64_t yoff = 0;
		char buf[32];
		ssize_t len = pan >= 0 ? pread(pan, buf, sizeof buf - 1, 0) : -1;
		char *comma = NULL;
		if (len > 0) {
			buf[len] = 0;
			comma = strchr(buf, ',');
		}
		if (comma) {
			yoff = strtoull(comma + 1, NULL, 10);
		} else {
			ioctl(fd, FBIOGET_VSCREENINFO, &var);
			yoff = var.yoffset;
		}
		if ((yoff + var.yres) * fix.line_length > fix.smem_len)
			yoff = 0;
		uint64_t hash = 1469598103934665603ULL;
		uint64_t lit = 0;
		for (uint32_t gy = 0; gy < 24; gy++) {
			const uint32_t *row = (const uint32_t *)(mem + (yoff + gy * var.yres / 24 + var.yres / 48) * fix.line_length);
			for (uint32_t gx = 0; gx < 32; gx++) {
				uint32_t px = row[gx * var.xres / 32 + var.xres / 64] & 0xffffff;
				hash = (hash ^ px) * 1099511628211ULL;
				lit += ((px >> 16) & 0xff) + ((px >> 8) & 0xff) + (px & 0xff);
			}
		}
		if (n == 0 || hash != prev) {
			snprintf(msg, sizeof msg, "fbprobe: frame %d yoffset %llu brightness %llu hash %016llx\n",
				 frames++, (unsigned long long)yoff, (unsigned long long)(lit / (32 * 24 * 3)),
				 (unsigned long long)hash);
			klog(msg);
			prev = hash;
			if (frames >= 40)
				break;
		}
		nanosleep(&tick, NULL);
	}
	klog("fbprobe: done\n");
	return 0;
}
