// SPDX-License-Identifier: BSD-3-Clause
//
// VK_VECTRA_window_surface: a VK_KHR_surface that is a window of Radharc's (vulkansurface(2); D174, "Presentation, as
// designed"). Ours, not Khronos's: the vendor tag VECTRA is unregistered, and the extension number below is a
// placeholder that no Khronos extension holds. A port of a Vulkan program reaches the glass with this and VK_KHR_swapchain
// and nothing else; no Wayland, X11 or Win32 surface exists on VectraOS.
//
// The extension names two instance commands and one create-info structure. The loader (our own) gives them out through
// vkGetInstanceProcAddr; they are declared here, not in td_vulkan.h, which vkgen writes from Khronos's vk.xml.

#ifndef VULKAN_VECTRA_H
#define VULKAN_VECTRA_H

#include "td_vulkan.h"

#define VK_VECTRA_WINDOW_SURFACE_EXTENSION_NAME "VK_VECTRA_window_surface"
#define VK_VECTRA_WINDOW_SURFACE_SPEC_VERSION 1

// Extension number 900000 (a placeholder): structure types are 1000000000 + (number - 1) * 1000 + offset.
#define VK_STRUCTURE_TYPE_VECTRA_WINDOW_SURFACE_CREATE_INFO ((VkStructureType)1899999000)

typedef VkFlags VkVectraWindowSurfaceCreateFlagsVECTRA;

typedef struct VkVectraWindowSurfaceCreateInfo {
  VkStructureType sType;
  const void *pNext;
  VkVectraWindowSurfaceCreateFlagsVECTRA flags;
  // The window's title: UTF-8, zero-terminated.
  const char *pTitle;
  // The window's content size in logical points. The surface's current extent is its size in pixels, which a scale of the
  // output other than 1 makes a different number.
  uint32_t width;
  uint32_t height;
} VkVectraWindowSurfaceCreateInfo;

// What happened to a window (vkPollVectraWindowEventsVECTRA).
#define VK_VECTRA_WINDOW_EVENT_CLOSE 1u     // the user closed the window: leave
#define VK_VECTRA_WINDOW_EVENT_RESIZE 2u    // x, y: the window's size in pixels now
#define VK_VECTRA_WINDOW_EVENT_KEY_DOWN 3u  // keyCode, character, modifiers
#define VK_VECTRA_WINDOW_EVENT_KEY_UP 4u    // keyCode, character, modifiers
#define VK_VECTRA_WINDOW_EVENT_POINTER 5u   // x, y in pixels; button and pressed: a press or release of a button
#define VK_VECTRA_WINDOW_EVENT_WHEEL 6u     // x, y: how far the wheel turned, in points (positive: right, down)

// A key's modifiers.
#define VK_VECTRA_KEY_MODIFIER_SHIFT 1u
#define VK_VECTRA_KEY_MODIFIER_CONTROL 2u
#define VK_VECTRA_KEY_MODIFIER_ALT 4u
#define VK_VECTRA_KEY_MODIFIER_SUPER 8u

// A pointer button.
#define VK_VECTRA_POINTER_BUTTON_NONE 0u    // motion
#define VK_VECTRA_POINTER_BUTTON_LEFT 1u
#define VK_VECTRA_POINTER_BUTTON_RIGHT 2u
#define VK_VECTRA_POINTER_BUTTON_MIDDLE 3u

// The key's code is its USB HID usage on the keyboard page (0x07), whatever the layout: Escape is 0x29, A is 0x04.
#define VK_VECTRA_KEY_ESCAPE 0x29u

typedef struct VkVectraWindowEventVECTRA {
  uint32_t type;
  uint32_t keyCode;
  // The Unicode scalar the key gives in the layout, unshifted; 0 for none.
  uint32_t character;
  uint32_t modifiers;
  int32_t x;
  int32_t y;
  uint32_t button;
  // 1: the button went down, 0: it came up.
  uint32_t pressed;
} VkVectraWindowEventVECTRA;

typedef VkResult (VKAPI_PTR *PFN_vkCreateVectraWindowSurface)(VkInstance instance,
    const VkVectraWindowSurfaceCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAllocator, VkSurfaceKHR *pSurface);
typedef VkResult (VKAPI_PTR *PFN_vkPollVectraWindowEventsVECTRA)(VkInstance instance, VkSurfaceKHR surface,
    uint32_t *pEventCount, VkVectraWindowEventVECTRA *pEvents);
typedef VkResult (VKAPI_PTR *PFN_vkSetVectraWindowFullscreenVECTRA)(VkInstance instance, VkSurfaceKHR surface, VkBool32 fullscreen);

#ifndef __swift__  // (the loader implements them in Swift)
// Opens a window of Radharc's on the app's behalf and returns it as a surface. VK_ERROR_INITIALIZATION_FAILED if there is
// no compositor, and VK_ERROR_EXTENSION_NOT_PRESENT if the instance was made without the extension.
VkResult vkCreateVectraWindowSurface(VkInstance instance, const VkVectraWindowSurfaceCreateInfo *pCreateInfo,
                                     const VkAllocationCallbacks *pAllocator, VkSurfaceKHR *pSurface);

// Takes the events that have happened since the last call: up to *pEventCount of them into pEvents, and *pEventCount is
// how many. With pEvents null, *pEventCount is how many wait. Never blocks. VK_INCOMPLETE if more are waiting.
VkResult vkPollVectraWindowEventsVECTRA(VkInstance instance, VkSurfaceKHR surface, uint32_t *pEventCount,
                                        VkVectraWindowEventVECTRA *pEvents);

// Asks for the window to fill the screen, or to go back. The new size arrives as a resize event, and the swapchain's
// next acquire or present says VK_ERROR_OUT_OF_DATE_KHR until it is made again.
VkResult vkSetVectraWindowFullscreenVECTRA(VkInstance instance, VkSurfaceKHR surface, VkBool32 fullscreen);
#endif

#endif
