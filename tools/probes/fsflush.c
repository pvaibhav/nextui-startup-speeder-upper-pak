// fsflush: write an ext4 file system's journal into place and mark it clean,
// without unmounting it, so the next mount has nothing to replay.
//
// Build: docker run --rm --platform linux/arm64 -v "$PWD":/w -w /w alpine:3.20 sh -c 'apk add -q gcc musl-dev linux-headers && gcc -static -Os -s -o NAME tools/probes/NAME.c'
// usage: fsflush [-k] MOUNTPOINT...
//
// It freezes and at once thaws each file system (FIFREEZE, FITHAW). Freezing
// makes ext4 flush its journal and clear the "needs recovery" flag. Thawing
// sets that flag again, but the journal stays empty until the next write.
// With -k the file systems stay frozen, and clean on disk, for a power-off
// that follows at once. Any later write to them blocks.
#include <fcntl.h>
#include <linux/fs.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	int rc = 0, keep = argc > 1 && !strcmp(argv[1], "-k");
	for (int i = 1 + keep; i < argc; i++) {
		int fd = open(argv[i], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		if (fd < 0) {
			perror(argv[i]);
			rc = 1;
			continue;
		}
		if (ioctl(fd, FIFREEZE, 0)) {
			perror(argv[i]);
			rc = 1;
		} else if (!keep && ioctl(fd, FITHAW, 0)) {
			perror(argv[i]);
			rc = 2; // still frozen: report loudly
		}
		close(fd);
	}
	return rc;
}
