#include <sys/ioctl.h>
#include <sys/socket.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <arpa/inet.h>
#include <netinet/in.h>

#include "dns.h"
#include "cache.h"
#include "interface.h"

int cfg_proto = 0;
int cfg_no_subnet = 0;

// Helper function to setup IPv4 interface
static void setup_ipv4_interface(struct interface *iface, enum umdns_socket_type type) {
    memset(iface, 0, sizeof(*iface));
    iface->name = "fuzz0";
    iface->type = type;
    iface->ifindex = 1;
    iface->need_multicast = (type == SOCK_MC_IPV4);
    
    // Set up IPv4 addresses
    iface->addrs.n_addr = 1;
    iface->addrs.v4 = calloc(1, sizeof(*iface->addrs.v4));
    if (iface->addrs.v4) {
        inet_pton(AF_INET, "192.168.1.100", &iface->addrs.v4[0].addr);
        inet_pton(AF_INET, "255.255.255.0", &iface->addrs.v4[0].mask);
    }
}

// Helper function to setup IPv6 interface
static void setup_ipv6_interface(struct interface *iface, enum umdns_socket_type type) {
    memset(iface, 0, sizeof(*iface));
    iface->name = "fuzz0";
    iface->type = type;
    iface->ifindex = 1;
    iface->need_multicast = (type == SOCK_MC_IPV6);
    
    // Set up IPv6 addresses
    iface->addrs.n_addr = 1;
    iface->addrs.v6 = calloc(1, sizeof(*iface->addrs.v6));
    if (iface->addrs.v6) {
        inet_pton(AF_INET6, "fe80::1", &iface->addrs.v6[0].addr);
        inet_pton(AF_INET6, "ffff:ffff:ffff:ffff::", &iface->addrs.v6[0].mask);
    }
}

// Helper function to setup IPv4 sockaddr
static void setup_ipv4_sockaddr(struct sockaddr_in *addr, uint16_t port) {
    memset(addr, 0, sizeof(*addr));
    addr->sin_family = AF_INET;
    addr->sin_port = htons(port);
    inet_pton(AF_INET, "192.168.1.50", &addr->sin_addr);
}

// Helper function to setup IPv6 sockaddr
static void setup_ipv6_sockaddr(struct sockaddr_in6 *addr, uint16_t port) {
    memset(addr, 0, sizeof(*addr));
    addr->sin6_family = AF_INET6;
    addr->sin6_port = htons(port);
    inet_pton(AF_INET6, "fe80::2", &addr->sin6_addr);
}

static void fuzz_dns_handle_packet_comprehensive(uint8_t *input, size_t size) {
    // Initialize cache
    cache_init();
    
    // If input is too small, just test basic functionality
    if (size < 12) { // DNS header is 12 bytes minimum
        struct interface iface;
        struct sockaddr_in from;
        
        setup_ipv4_interface(&iface, SOCK_MC_IPV4);
        setup_ipv4_sockaddr(&from, MCAST_PORT);
        
        dns_handle_packet(&iface, (struct sockaddr *)&from, MCAST_PORT, input, size);
        
        free(iface.addrs.v4);
        goto cleanup;
    }
    
    // Use first few bytes of input to determine test configuration
    uint8_t config = input[0];
    uint8_t port_config = input[1];
    
    // Skip config bytes for actual packet data
    uint8_t *packet_data = input + 2;
    size_t packet_size = size - 2;
    
    // Test different interface types and address families
    for (int test_case = 0; test_case < 8; test_case++) {
        if ((config & (1 << test_case)) == 0) continue; // Skip this test case
        
        struct interface iface;
        union {
            struct sockaddr_in v4;
            struct sockaddr_in6 v6;
        } from;
        
        uint16_t port;
        
        // Determine port based on configuration
        switch (port_config & 0x3) {
            case 0: port = MCAST_PORT; break;
            case 1: port = 1024; break;
            case 2: port = 0; break;
            default: port = 65535; break;
        }
        port_config >>= 2;
        
        switch (test_case) {
            case 0: // IPv4 Multicast, MCAST_PORT
                setup_ipv4_interface(&iface, SOCK_MC_IPV4);
                setup_ipv4_sockaddr(&from.v4, MCAST_PORT);
                dns_handle_packet(&iface, (struct sockaddr *)&from.v4, MCAST_PORT, packet_data, packet_size);
                break;
                
            case 1: // IPv4 Unicast, MCAST_PORT  
                setup_ipv4_interface(&iface, SOCK_UC_IPV4);
                setup_ipv4_sockaddr(&from.v4, MCAST_PORT);
                dns_handle_packet(&iface, (struct sockaddr *)&from.v4, MCAST_PORT, packet_data, packet_size);
                break;
                
            case 2: // IPv4 Multicast, different port
                setup_ipv4_interface(&iface, SOCK_MC_IPV4);
                setup_ipv4_sockaddr(&from.v4, port);
                dns_handle_packet(&iface, (struct sockaddr *)&from.v4, port, packet_data, packet_size);
                break;
                
            case 3: // IPv4 Unicast, different port
                setup_ipv4_interface(&iface, SOCK_UC_IPV4);
                setup_ipv4_sockaddr(&from.v4, port);
                dns_handle_packet(&iface, (struct sockaddr *)&from.v4, port, packet_data, packet_size);
                break;
                
            case 4: // IPv6 Multicast, MCAST_PORT
                setup_ipv6_interface(&iface, SOCK_MC_IPV6);
                setup_ipv6_sockaddr(&from.v6, MCAST_PORT);
                dns_handle_packet(&iface, (struct sockaddr *)&from.v6, MCAST_PORT, packet_data, packet_size);
                break;
                
            case 5: // IPv6 Unicast, MCAST_PORT
                setup_ipv6_interface(&iface, SOCK_UC_IPV6);
                setup_ipv6_sockaddr(&from.v6, MCAST_PORT);
                dns_handle_packet(&iface, (struct sockaddr *)&from.v6, MCAST_PORT, packet_data, packet_size);
                break;
                
            case 6: // IPv6 Multicast, different port
                setup_ipv6_interface(&iface, SOCK_MC_IPV6);
                setup_ipv6_sockaddr(&from.v6, port);
                dns_handle_packet(&iface, (struct sockaddr *)&from.v6, port, packet_data, packet_size);
                break;
                
            case 7: // IPv6 Unicast, different port
                setup_ipv6_interface(&iface, SOCK_UC_IPV6);
                setup_ipv6_sockaddr(&from.v6, port);
                dns_handle_packet(&iface, (struct sockaddr *)&from.v6, port, packet_data, packet_size);
                break;
        }
        
        // Clean up interface addresses
        if (interface_ipv6(&iface)) {
            free(iface.addrs.v6);
        } else {
            free(iface.addrs.v4);
        }
    }
    
cleanup:
    // Clean up all cache services and records
    cache_cleanup(NULL);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    // Skip empty inputs
    if (size == 0) {
        return 0;
    }
    
    // Create a copy of the input data to avoid const issues
    uint8_t *buf = malloc(size);
    if (!buf) {
        return 0;
    }
    
    memcpy(buf, data, size);
    fuzz_dns_handle_packet_comprehensive(buf, size);
    free(buf);
    
    return 0;
}