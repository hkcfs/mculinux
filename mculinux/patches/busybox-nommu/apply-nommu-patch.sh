#!/bin/bash
# Apply NOMMU patch to busybox hush.c
# Changes BUILD_AS_NOMMU from 0 to 1 to enable NOMMU re-exec code paths
sed -i 's/^#define BUILD_AS_NOMMU 0$/#define BUILD_AS_NOMMU 1/' shell/hush.c
