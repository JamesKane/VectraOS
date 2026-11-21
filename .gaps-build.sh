#!/bin/bash
# Temporary: compile the backend over Vulkan and print what is wrong with it.
swift build --target GPUCoreVulkan 2>&1 | grep -E "error|Build complete" | cut -c1-400 | tail -60
