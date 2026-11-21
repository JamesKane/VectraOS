#!/bin/bash
# Temporary: regenerate the Vulkan header, command table and loader tables, and print the difference.
set -e
swift build --product vkgen 2>&1 | tail -1
(cd graphics/vulkan && ../../.build/debug/vkgen c/include/td_vulkan.h swift/generated/Commands.swift ../../data/vulkan/vk.xml \
  && ../../.build/debug/vkgen --loader loader/generated/Dispatch.swift ../../data/vulkan/vk.xml)
git --no-pager diff --stat
echo "=====DIFF====="
git --no-pager diff
git checkout -- .
