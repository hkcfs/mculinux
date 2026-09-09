/* wificfg: stage WiFi credentials into the esp32-wifi-shmem driver.
 *
 * Usage: wificfg [ifname] <ssid> [passphrase]
 *
 * Sends SSID/passphrase via SIOCDEVPRIVATE. The driver stores them and
 * logs receipt (dmesg); they take effect once the Core-0 firmware grows
 * an IPC connect command (Part B). Today the firmware uses its own config.
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <net/if.h>

#ifndef SIOCDEVPRIVATE
#define SIOCDEVPRIVATE 0x89F0
#endif

struct esp32_wifi_cfg {
	unsigned char ssid[32];
	unsigned char ssid_len;
	unsigned char pass[64];
	unsigned char pass_len;
};

int main(int argc, char **argv)
{
	struct esp32_wifi_cfg cfg;
	struct ifreq ifr;
	const char *ifname = "eth0";
	const char *ssid, *pass = "";
	int fd, ret;

	if (argc == 3) {
		ssid = argv[1];
		pass = argv[2];
	} else if (argc == 4) {
		ifname = argv[1];
		ssid = argv[2];
		pass = argv[3];
	} else {
		fprintf(stderr, "usage: %s [ifname] <ssid> [passphrase]\n", argv[0]);
		return 2;
	}
	if (strlen(ssid) < 1 || strlen(ssid) > 32 || strlen(pass) > 64) {
		fprintf(stderr, "wificfg: ssid 1-32 chars, passphrase 0-64 chars\n");
		return 2;
	}

	memset(&cfg, 0, sizeof(cfg));
	memcpy(cfg.ssid, ssid, strlen(ssid));
	cfg.ssid_len = strlen(ssid);
	memcpy(cfg.pass, pass, strlen(pass));
	cfg.pass_len = strlen(pass);

	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		perror("socket");
		return 1;
	}
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	ifr.ifr_data = (void *)&cfg;

	ret = ioctl(fd, SIOCDEVPRIVATE, &ifr);
	if (ret < 0) {
		perror("ioctl(SIOCDEVPRIVATE)");
		close(fd);
		return 1;
	}
	printf("credentials staged for '%s' on %s (dmesg to confirm)\n", ssid, ifname);
	close(fd);
	return 0;
}
