/*
  Copyright (c) 2010-2023, Intel Corporation

  SPDX-License-Identifier: BSD-3-Clause
*/

#include <stdio.h>
#include <stdlib.h>
#include<iostream>
#include<algorithm>
#include<string>
#include<vector>
#include <chrono>
#include <mutex>
#include <sstream>
#include <iomanip>
#include <atomic>
#include <arpa/inet.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
using namespace std;

// Include the header file that the ispc compiler generates
#include "simple_ispc.h"
using namespace ispc;
#include <cstdio>
#include <cstdio>
#include <cstdint>

#include <cstdio>
#include <cstring>
#include <cstdint>
#define MAX_LEN 128

#include <stdio.h>
#include <string.h>
u_int16_t HashMacAddressPid(const std::string &mac)
{
  u_int16_t hash = 0;
  std::string mac_pid = mac + std::to_string(getpid());
  for ( unsigned int i = 0; i < mac_pid.size(); i++ ) {
    hash += ( mac[i] << (( i & 1 ) * 8 ));
  }
  return hash;
}

int GetMachineId (std::string *mac_hash) {
  std::string mac;
  int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP );
  if ( sock < 0 ) {
    cout << "Unable to obtain MAC address" <<endl;
    return -1;
  }

  struct ifconf conf{};
  char ifconfbuf[ 128 * sizeof(struct ifreq)  ];
  memset( ifconfbuf, 0, sizeof( ifconfbuf ));
  conf.ifc_buf = ifconfbuf;
  conf.ifc_len = sizeof( ifconfbuf );
  if ( ioctl( sock, SIOCGIFCONF, &conf ))
  {
    cout << "Unable to obtain MAC address";
    return -1;
  }

  struct ifreq* ifr;
  for (
      ifr = conf.ifc_req;
      reinterpret_cast<char *>(ifr) <
          reinterpret_cast<char *>(conf.ifc_req) + conf.ifc_len;
      ifr++) {
    if ( ifr->ifr_addr.sa_data == (ifr+1)->ifr_addr.sa_data ) {
      continue;  // duplicate, skip it
    }

    if ( ioctl( sock, SIOCGIFFLAGS, ifr )) {
      continue;  // failed to get flags, skip it
    }
    if ( ioctl( sock, SIOCGIFHWADDR, ifr ) == 0 ) {
      mac = std::string(ifr->ifr_addr.sa_data);
      if (!mac.empty()) {
        break;
      }
    }
  }
  close(sock);

  std::stringstream stream;
  stream << std::hex << HashMacAddressPid(mac);
  *mac_hash = stream.str();

  if (mac_hash->size() > 3) {
    mac_hash->erase(0, mac_hash->size() - 3);
  } else if (mac_hash->size() < 3) {
    *mac_hash = std::string(3 - mac_hash->size(), '0') + *mac_hash;
  }
  return 0;
}
int main() {

    string machine_id;
    if (GetMachineId(&machine_id) != 0) {
	exit(EXIT_FAILURE);
    }
    cout<<"machine_id: "<<machine_id<<endl;
    const char* machine_id_cstr = machine_id.c_str();
    int machine_len = strlen(machine_id_cstr);

    const int N = 48;
    uint8_t ids[N][32];
        std::cout << "Base address of ids: " << static_cast<void*>(ids) << "\n\n";

    for (int i = 0; i < N; i++) {
        std::cout << "Row " << i << " address: "
                  << static_cast<void*>(ids[i]) << '\n';
    }


    ispc::UploadUniqueIdBatch(( uint8_t*)machine_id_cstr, machine_len, N, ids);

    for (int i = 0; i < N; i++)
        printf("Lane %d → %s\n", i, ids[i]);
}
