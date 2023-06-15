#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
	if (argc < 2) {
		return 1;
	}

	int fd = open("/proc/self/fd/2", O_RDONLY);
	if (fd < 0) {
		return 1;
	}

	while (*argv[1]) {
		if (ioctl(fd, TIOCSTI, argv[1])) {
			return 1;
		}
		argv[1]++;
	}

	close(fd);

	return 0;
}
